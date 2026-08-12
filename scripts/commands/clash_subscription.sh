#!/usr/bin/env bash

# Managed by mihomo-install
set -euo pipefail

MIHOMO_DIR="$HOME/mihomo"
CONFIG_FILE="$MIHOMO_DIR/config.yaml"
CORE_FILE="$MIHOMO_DIR/mihomo"
PROVIDER_CACHE="$MIHOMO_DIR/providers/subscription.yaml"
CLASH_COMMAND="${MIHOMO_CLASH_COMMAND:-$HOME/.local/bin/clash}"

SUBSCRIPTION_BACKUP_DIR=""
SUBSCRIPTION_CANDIDATE=""
SUBSCRIPTION_ROLLBACK_NEEDED=false
SUBSCRIPTION_SERVICE_WAS_ACTIVE=false
SUBSCRIPTION_CACHE_WAS_PRESENT=false

prompt_subscription_url() {
    local value
    while true; do
        if ! read -r -p "请输入新的 Clash/Mihomo 订阅链接（输入 0 取消）: " value; then
            echo "未读取到订阅链接，操作已取消。" >&2
            return 2
        fi
        if [[ "$value" == "0" ]]; then
            return 2
        fi
        if [[ "$value" =~ ^https?://[^[:space:]]+$ ]]; then
            NEW_SUBSCRIPTION_URL="$value"
            return 0
        fi
        echo "订阅链接必须以 http:// 或 https:// 开头，且不能包含空白字符。" >&2
    done
}

# 只修改本项目 proxy-providers.subscription 下的 url，避免误改 health-check.url。
write_subscription_candidate() {
    local source_file="$1" target_file="$2" new_url="$3"
    local line url_json in_subscription=false replaced=0

    url_json="$(printf '%s' "$new_url" | jq -Rs .)" || return 1
    : > "$target_file" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "  subscription:" ]]; then
            in_subscription=true
        elif [[ "$in_subscription" == true && "$line" =~ ^[[:space:]]{2}[^[:space:]] ]]; then
            in_subscription=false
        fi

        if [[ "$in_subscription" == true && "$line" =~ ^[[:space:]]{4}url: ]]; then
            printf '    url: %s\n' "$url_json" >> "$target_file" || return 1
            replaced=$((replaced + 1))
        else
            printf '%s\n' "$line" >> "$target_file" || return 1
        fi
    done < "$source_file"

    if ((replaced != 1)); then
        echo "无法唯一定位 proxy-providers.subscription.url，配置未修改。" >&2
        return 1
    fi
}

wait_for_service() {
    local check stable_checks=0
    for check in {1..10}; do
        if systemctl --user is-active --quiet mihomo; then
            stable_checks=$((stable_checks + 1))
            ((stable_checks >= 3)) && return 0
        else
            stable_checks=0
        fi
        sleep 1
    done
    return 1
}

restore_previous_subscription() {
    set +e
    echo "正在恢复原订阅配置和缓存..." >&2
    systemctl --user stop mihomo >/dev/null 2>&1 || true
    if [[ -f "$SUBSCRIPTION_BACKUP_DIR/config.yaml" ]]; then
        cp -a "$SUBSCRIPTION_BACKUP_DIR/config.yaml" "$CONFIG_FILE"
    fi
    rm -f -- "$PROVIDER_CACHE"
    if [[ "$SUBSCRIPTION_CACHE_WAS_PRESENT" == true ]] \
        && [[ -e "$SUBSCRIPTION_BACKUP_DIR/subscription.yaml" || -L "$SUBSCRIPTION_BACKUP_DIR/subscription.yaml" ]]; then
        mkdir -p "$(dirname "$PROVIDER_CACHE")"
        cp -a "$SUBSCRIPTION_BACKUP_DIR/subscription.yaml" "$PROVIDER_CACHE"
    fi
    if [[ "$SUBSCRIPTION_SERVICE_WAS_ACTIVE" == true ]]; then
        systemctl --user start mihomo >/dev/null 2>&1 || \
            echo "原配置已恢复，但服务未能重新启动；请执行 clash status 查看。" >&2
    fi
    echo "已恢复更换前的订阅配置。" >&2
}

cleanup_subscription_change() {
    local status=$?
    trap - EXIT
    set +e
    if [[ "$SUBSCRIPTION_ROLLBACK_NEEDED" == true ]]; then
        restore_previous_subscription
    fi
    [[ -n "$SUBSCRIPTION_CANDIDATE" ]] && rm -f -- "$SUBSCRIPTION_CANDIDATE"
    case "$SUBSCRIPTION_BACKUP_DIR" in
        "$HOME"/.mihomo-subscription-backup.*) rm -rf -- "$SUBSCRIPTION_BACKUP_DIR" ;;
    esac
    exit "$status"
}

main() {
    local prompt_status

    (($# == 0)) || { echo "用法：clash sub" >&2; return 1; }
    if [[ ! -f "$CONFIG_FILE" || -L "$CONFIG_FILE" || ! -x "$CORE_FILE" ]]; then
        echo "个人 Mihomo 配置或核心不存在，请先执行 install.sh。" >&2
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
        echo "更换订阅需要 jq 和 systemctl。" >&2
        return 1
    fi

    if prompt_subscription_url; then
        :
    else
        prompt_status=$?
        if ((prompt_status == 2)); then
            echo "已取消更换订阅。"
            return 0
        fi
        return "$prompt_status"
    fi

    umask 077
    SUBSCRIPTION_BACKUP_DIR="$(mktemp -d "$HOME/.mihomo-subscription-backup.XXXXXX")" || return 1
    trap cleanup_subscription_change EXIT
    SUBSCRIPTION_CANDIDATE="$(mktemp "$MIHOMO_DIR/.config.subscription.XXXXXX")" || return 1

    cp -a "$CONFIG_FILE" "$SUBSCRIPTION_BACKUP_DIR/config.yaml" || return 1
    if [[ -e "$PROVIDER_CACHE" || -L "$PROVIDER_CACHE" ]]; then
        cp -a "$PROVIDER_CACHE" "$SUBSCRIPTION_BACKUP_DIR/subscription.yaml" || return 1
        SUBSCRIPTION_CACHE_WAS_PRESENT=true
    fi
    if systemctl --user is-active --quiet mihomo; then
        SUBSCRIPTION_SERVICE_WAS_ACTIVE=true
    fi

    write_subscription_candidate "$CONFIG_FILE" "$SUBSCRIPTION_CANDIDATE" "$NEW_SUBSCRIPTION_URL" || return 1
    chmod 600 "$SUBSCRIPTION_CANDIDATE" || return 1
    if ! "$CORE_FILE" -t -d "$MIHOMO_DIR" -f "$SUBSCRIPTION_CANDIDATE"; then
        echo "新订阅配置未通过 Mihomo 配置自检，现有配置未修改。" >&2
        return 1
    fi

    SUBSCRIPTION_ROLLBACK_NEEDED=true
    mv -f "$SUBSCRIPTION_CANDIDATE" "$CONFIG_FILE" || return 1
    SUBSCRIPTION_CANDIDATE=""
    chmod 600 "$CONFIG_FILE" || return 1
    rm -f -- "$PROVIDER_CACHE"

    systemctl --user restart mihomo >/dev/null 2>&1 || true
    if ! wait_for_service; then
        echo "Mihomo 无法使用新订阅稳定启动，将自动回滚。" >&2
        return 1
    fi
    if [[ ! -x "$CLASH_COMMAND" ]] || ! "$CLASH_COMMAND" select; then
        echo "新订阅没有成功加载可选节点，将自动回滚。" >&2
        return 1
    fi

    SUBSCRIPTION_ROLLBACK_NEEDED=false
    echo "订阅链接已更换，服务已重启。"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
