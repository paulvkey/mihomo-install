#!/usr/bin/env bash

# Managed by mihomo-install (system mode)
set -euo pipefail
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

SERVICE_NAME="mihomo-system.service"
CONFIG_FILE="/etc/mihomo/config.yaml"
CORE_FILE="/usr/local/lib/mihomo/mihomo"
STATE_DIR="/var/lib/mihomo"
PROVIDER_CACHE="$STATE_DIR/providers/subscription.yaml"
SERVICE_GROUP="mihomo"
CONTROL_GROUP="mihomo-control"
GROUP_NAME="PROXY"
DELAY_TEST_URL="https://www.gstatic.com/generate_204"
DELAY_TIMEOUT_MS=5000
DELAY_WARN_MS=1500

SUBSCRIPTION_BACKUP_DIR=""
SUBSCRIPTION_CANDIDATE=""
SUBSCRIPTION_ROLLBACK_NEEDED=false
SUBSCRIPTION_SERVICE_WAS_ACTIVE=false
SUBSCRIPTION_CACHE_WAS_PRESENT=false

usage() {
    cat <<'EOF'
Mihomo 系统共享模式帮助

用法：
  clashsys <命令>

首次使用：
  source /etc/profile.d/mihomo-system.sh
  clashsys on

所有用户命令：
  on       启用共享代理；普通用户只检测可用性，控制用户可自动选节点
  off      在当前终端停用系统共享代理
  status   查看系统共享 Mihomo 服务状态
  help     显示本帮助，也可以使用 -h 或 --help

控制组命令（需要 root 或 mihomo-control 组权限）：
  select   测速并切换共享节点；会影响所有使用系统代理的用户
  sub      更换共享订阅、重启服务并重新选择节点
  restart  重启系统共享 Mihomo 服务

说明：
  1. on/off 只修改当前 shell 的 HTTP/HTTPS 代理变量，不会启动或停止共享服务。
  2. 如果安装时启用了自动代理，没有个人 Mihomo 的用户下次登录 Bash 后无需执行 on。
  3. 同时存在个人代理时，当前终端最后执行的 clash on 或 clashsys on 生效。
  4. 新加入 mihomo-control 组后，需要重新登录才能执行 select/sub/restart。
  5. 安装成功后会执行首次节点测速；若订阅未加载节点，请修复后执行 clashsys select。
  6. 普通用户执行 on 时只检测共享代理可用性，异常时提醒管理员，不会进入节点选择。
  7. 控制用户执行 on 时，当前共享节点可用则沿用；不可用时才进入选择。

示例：
  clashsys on
  clashsys status
  clashsys select
  clashsys sub
  clashsys off
EOF
}

require_root_control() {
    local action="$1"
    shift
    if ((EUID == 0)); then
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        echo "${action} 需要 root 或 ${CONTROL_GROUP} 组权限，当前系统未安装 sudo。" >&2
        exit 1
    fi
    exec sudo -n "$0" "$action" "$@"
}

read_controller() {
    if [[ ! -r "$CONFIG_FILE" ]]; then
        echo "无法读取系统配置：${CONFIG_FILE}" >&2
        return 1
    fi

    CONTROLLER_PORT="$(awk -F: '/^external-controller:/ {print $3; exit}' "$CONFIG_FILE")"
    CONTROLLER_SECRET="$(awk -F: '/^secret:/ {sub(/^[[:space:]]*/, "", $2); gsub(/^\"|\"$/, "", $2); print $2; exit}' "$CONFIG_FILE")"
    if [[ ! "$CONTROLLER_PORT" =~ ^[0-9]+$ || -z "$CONTROLLER_SECRET" ]]; then
        echo "系统配置中的控制端口或认证密钥无效。" >&2
        return 1
    fi
    CONTROLLER_URL="http://127.0.0.1:${CONTROLLER_PORT}"
    CURL_AUTH_ARGS=(-H "Authorization: Bearer ${CONTROLLER_SECRET}")
}

prompt_subscription_url() {
    local value
    while true; do
        if ! read -r -p "请输入新的系统共享 Clash/Mihomo 订阅链接（输入 0 取消）: " value; then
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

wait_for_subscription_service() {
    local check stable_checks=0
    for check in {1..10}; do
        if systemctl is-active --quiet "$SERVICE_NAME"; then
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
    echo "正在恢复原系统共享订阅配置和缓存..." >&2
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    if [[ -f "$SUBSCRIPTION_BACKUP_DIR/config.yaml" ]]; then
        rm -f -- "$CONFIG_FILE"
        cp -a "$SUBSCRIPTION_BACKUP_DIR/config.yaml" "$CONFIG_FILE"
    fi
    rm -f -- "$PROVIDER_CACHE"
    if [[ "$SUBSCRIPTION_CACHE_WAS_PRESENT" == true ]] \
        && [[ -e "$SUBSCRIPTION_BACKUP_DIR/subscription.yaml" || -L "$SUBSCRIPTION_BACKUP_DIR/subscription.yaml" ]]; then
        mkdir -p "$(dirname "$PROVIDER_CACHE")"
        cp -a "$SUBSCRIPTION_BACKUP_DIR/subscription.yaml" "$PROVIDER_CACHE"
    fi
    if [[ "$SUBSCRIPTION_SERVICE_WAS_ACTIVE" == true ]]; then
        systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || \
            echo "原系统配置已恢复，但服务未能重新启动；请执行 clashsys status 查看。" >&2
    fi
    echo "已恢复更换前的系统共享订阅配置。" >&2
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
        /var/tmp/mihomo-system-subscription.*) rm -rf -- "$SUBSCRIPTION_BACKUP_DIR" ;;
    esac
    exit "$status"
}

change_subscription() {
    local prompt_status

    require_root_control sub
    if [[ ! -f "$CONFIG_FILE" || -L "$CONFIG_FILE" || ! -x "$CORE_FILE" ]]; then
        echo "系统共享 Mihomo 配置或核心不存在，请先执行 install_sys.sh。" >&2
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
        echo "更换系统共享订阅需要 jq 和 systemctl。" >&2
        return 1
    fi

    if prompt_subscription_url; then
        :
    else
        prompt_status=$?
        if ((prompt_status == 2)); then
            echo "已取消更换系统共享订阅。"
            return 0
        fi
        return "$prompt_status"
    fi

    umask 077
    SUBSCRIPTION_BACKUP_DIR="$(mktemp -d /var/tmp/mihomo-system-subscription.XXXXXX)" || return 1
    trap cleanup_subscription_change EXIT
    SUBSCRIPTION_CANDIDATE="$(mktemp "$CONFIG_FILE.subscription.XXXXXX")" || return 1

    cp -a "$CONFIG_FILE" "$SUBSCRIPTION_BACKUP_DIR/config.yaml" || return 1
    if [[ -e "$PROVIDER_CACHE" || -L "$PROVIDER_CACHE" ]]; then
        cp -a "$PROVIDER_CACHE" "$SUBSCRIPTION_BACKUP_DIR/subscription.yaml" || return 1
        SUBSCRIPTION_CACHE_WAS_PRESENT=true
    fi
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        SUBSCRIPTION_SERVICE_WAS_ACTIVE=true
    fi

    write_subscription_candidate "$CONFIG_FILE" "$SUBSCRIPTION_CANDIDATE" "$NEW_SUBSCRIPTION_URL" || return 1
    chown root:"$SERVICE_GROUP" "$SUBSCRIPTION_CANDIDATE" || return 1
    chmod 640 "$SUBSCRIPTION_CANDIDATE" || return 1
    if ! "$CORE_FILE" -t -d "$STATE_DIR" -f "$SUBSCRIPTION_CANDIDATE"; then
        echo "新系统共享订阅配置未通过 Mihomo 配置自检，现有配置未修改。" >&2
        return 1
    fi

    SUBSCRIPTION_ROLLBACK_NEEDED=true
    mv -f "$SUBSCRIPTION_CANDIDATE" "$CONFIG_FILE" || return 1
    SUBSCRIPTION_CANDIDATE=""
    chown root:"$SERVICE_GROUP" "$CONFIG_FILE" || return 1
    chmod 640 "$CONFIG_FILE" || return 1
    rm -f -- "$PROVIDER_CACHE"

    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    if ! wait_for_subscription_service; then
        echo "系统共享 Mihomo 无法使用新订阅稳定启动，将自动回滚。" >&2
        return 1
    fi
    if ! select_node; then
        echo "新系统共享订阅没有成功加载可选节点，将自动回滚。" >&2
        return 1
    fi

    SUBSCRIPTION_ROLLBACK_NEEDED=false
    echo "系统共享订阅链接已更换，服务已重启；所有共享用户使用新的订阅节点。"
}

select_node() {
    local group_uri api_url response current delay_api_url curl_max_time delay_response
    local index node delay delay_level current_mark display_node selected_index confirm payload unavailable_label display_label
    local delay_test_failed=false auto_mode=false current_in_nodes=false
    local current_delay=0 current_color_start="" current_color_end=""
    local node_count=0 available_count=0 unavailable_count=0
    local -a nodes=() node_delays=() select_nodes=() select_delays=() select_labels=()

    if [[ "${1:-}" == "--auto" ]]; then
        auto_mode=true
        shift
    fi
    if (($# > 0)); then
        echo "用法：clashsys select [--auto]" >&2
        return 1
    fi
    if [[ "$auto_mode" == true ]]; then
        require_root_control select --auto
    else
        require_root_control select
    fi
    if [[ -t 1 || -t 2 ]]; then
        current_color_start=$'\033[1;36m'
        current_color_end=$'\033[0m'
    fi
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "系统共享 Mihomo 未运行，请先执行 clashsys restart。" >&2
        return 1
    fi
    read_controller || return 1

    group_uri="$(jq -rn --arg value "$GROUP_NAME" '$value | @uri')"
    api_url="${CONTROLLER_URL}/proxies/${group_uri}"
    response="$(curl -fsS --noproxy '127.0.0.1,localhost,::1' "${CURL_AUTH_ARGS[@]}" "$api_url")" || {
        echo "无法连接系统 Mihomo 控制接口。" >&2
        return 1
    }

    current="$(jq -r '.now // ""' <<< "$response")"
    while IFS= read -r node; do
        nodes+=("$node")
        node_count=$((node_count + 1))
        if [[ "$node" == "$current" ]]; then
            current_in_nodes=true
        fi
    done < <(jq -r '.all[] | select(. != "DIRECT")' <<< "$response")
    if ((node_count == 0)); then
        echo "系统订阅未加载到真实代理节点（DIRECT 兜底不计入）。" >&2
        echo "请检查订阅和系统日志，修复后重新执行 clashsys select。" >&2
        return 1
    fi

    delay_api_url="${CONTROLLER_URL}/group/${group_uri}/delay"
    curl_max_time=$(((DELAY_TIMEOUT_MS + 999) / 1000 + 5))
    if [[ "$current_in_nodes" == true ]]; then
        printf '当前共享节点：%s★ %s%s\n' "$current_color_start" "$current" "$current_color_end"
    elif [[ -n "$current" ]]; then
        echo "当前共享节点：${current}（不是可选的真实订阅节点）"
    else
        echo "当前共享节点：未选择"
    fi
    echo "正在检测 ${node_count} 个节点的延迟（超时 ${DELAY_TIMEOUT_MS} ms）..."
    if ! delay_response="$(
        curl -fsS --noproxy '127.0.0.1,localhost,::1' --max-time "$curl_max_time" "${CURL_AUTH_ARGS[@]}" \
            --get \
            --data-urlencode "url=${DELAY_TEST_URL}" \
            --data-urlencode "timeout=${DELAY_TIMEOUT_MS}" \
            --data-urlencode "expected=200-299" \
            "$delay_api_url"
    )"; then
        echo "节点延迟检测请求失败；仍将保留全部共享节点供选择。" >&2
        echo "请留意异常标记，并检查测试地址：${DELAY_TEST_URL}" >&2
        delay_response='{}'
        delay_test_failed=true
    elif ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$delay_response"; then
        echo "控制接口返回了无效的延迟结果；仍将保留全部共享节点供选择。" >&2
        delay_response='{}'
        delay_test_failed=true
    fi

    for index in "${!nodes[@]}"; do
        node="${nodes[$index]}"
        delay="$(
            jq -r --arg node "$node" \
                '(.[$node] // 0) as $delay | if ($delay | type) == "number" then $delay else 0 end' \
                <<< "$delay_response"
        )"
        if [[ "$node" == "$current" && "$delay" =~ ^[0-9]+$ ]]; then
            current_delay="$delay"
        fi
        node_delays[$index]="$delay"
        if [[ "$delay" =~ ^[0-9]+$ ]] && ((delay > 0)); then
            available_count=$((available_count + 1))
        else
            unavailable_count=$((unavailable_count + 1))
        fi
    done

    if [[ "$delay_test_failed" == true ]]; then
        unavailable_label="测速失败"
    else
        unavailable_label="超时/不可用"
    fi
    for index in "${!nodes[@]}"; do
        node="${nodes[$index]}"
        delay="${node_delays[$index]:-0}"
        current_mark=""
        [[ "$node" == "$current" ]] && current_mark="，当前"
        select_nodes+=("$node")
        select_delays+=("$delay")
        if [[ "$delay" =~ ^[0-9]+$ ]] && ((delay > 0)); then
            if ((delay <= 300)); then
                delay_level="快"
            elif ((delay < DELAY_WARN_MS)); then
                delay_level="正常"
            else
                delay_level="高延迟"
            fi
            display_label="${node} [${delay} ms，${delay_level}${current_mark}]"
        else
            display_label="${node} [${unavailable_label}${current_mark}]"
        fi
        if [[ "$node" == "$current" ]]; then
            # Bash select 会把 ANSI 控制符计入列宽，导致后续列错位。
            # 选择列表只使用可见字符标记；上方的当前节点提示仍保留颜色高亮。
            display_label="★ ${display_label}"
        fi
        select_labels+=("$display_label")
    done

    echo "测速完成：${available_count} 个测得延迟，${unavailable_count} 个超时或未测得。"
    echo "提示：延迟与异常标记仅供参考，不会改变节点顺序，也不会阻止用户选择。"
    if [[ "$auto_mode" == true ]]; then
        if [[ "$current_in_nodes" == true ]] && ((current_delay > 0)); then
            printf '%s★ 当前共享节点 %s 可用（%s ms），继续使用并跳过选择。%s\n' \
                "$current_color_start" "$current" "$current_delay" "$current_color_end"
            return 0
        fi
        if [[ "$current_in_nodes" == true ]]; then
            printf '%s⚠ 当前共享节点 %s 超时或未测得延迟，需要重新选择。%s\n' \
                "$current_color_start" "$current" "$current_color_end" >&2
        else
            echo "当前没有已选择且可用的真实共享节点，需要进行选择。" >&2
        fi
    fi
    echo "注意：切换共享节点会影响所有系统代理用户。"
    echo "请选择节点（输入 0 取消）："
    PS3="请输入序号: "
    select display_node in "${select_labels[@]}"; do
        if [[ "$REPLY" == "0" ]]; then
            echo "已取消节点选择。"
            return 0
        fi
        if [[ -z "${display_node:-}" ]]; then
            echo "无效选择，请重新输入。"
            continue
        fi

        selected_index=$((REPLY - 1))
        node="${select_nodes[$selected_index]}"
        delay="${select_delays[$selected_index]}"
        if ((delay == 0)); then
            read -r -p "该节点测速超时或未测得延迟，仍要选择吗？[y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "已放弃该节点，请重新选择。"
                continue
            fi
        elif ((delay >= DELAY_WARN_MS)); then
            read -r -p "节点延迟为 ${delay} ms，可能不稳定，仍要选择吗？[y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "已放弃该节点，请重新选择。"
                continue
            fi
        fi

        payload="$(jq -n --arg name "$node" '{name: $name}')"
        if ! curl -fsS --noproxy '127.0.0.1,localhost,::1' "${CURL_AUTH_ARGS[@]}" -X PUT -H 'Content-Type: application/json' -d "$payload" "$api_url" >/dev/null; then
            echo "共享节点切换失败，请重新选择或查看系统日志。" >&2
            continue
        fi
        if ((delay > 0)); then
            echo "已切换共享节点：${node}（${delay} ms）"
        else
            echo "已切换共享节点：${node}（未测得延迟）"
        fi
        return 0
    done
}

restart_service() {
    local check stable_checks=0
    require_root_control restart
    systemctl restart "$SERVICE_NAME" || true
    for check in {1..10}; do
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            stable_checks=$((stable_checks + 1))
            if ((stable_checks >= 3)); then
                echo "系统共享 Mihomo 已重启，端口保持不变。"
                return 0
            fi
        else
            stable_checks=0
        fi
        sleep 1
    done
    echo "系统共享 Mihomo 重启失败。" >&2
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager >&2 || true
    return 1
}

main() {
    local action="${1:-help}"
    (($# == 0)) || shift
    case "$action" in
        on|off)
            echo "当前 shell 尚未加载 clashsys 函数，无法直接修改父 shell 的代理变量。" >&2
            echo "请先执行：source /etc/profile.d/mihomo-system.sh" >&2
            return 1
            ;;
        status)
            (($# == 0)) || { echo "用法：clashsys status" >&2; return 1; }
            systemctl status "$SERVICE_NAME" --no-pager
            ;;
        select)
            select_node "$@"
            ;;
        sub|subscription)
            (($# == 0)) || { echo "用法：clashsys sub" >&2; return 1; }
            change_subscription
            ;;
        restart)
            (($# == 0)) || { echo "用法：clashsys restart" >&2; return 1; }
            restart_service
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "未知命令：$action" >&2
            usage >&2
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
