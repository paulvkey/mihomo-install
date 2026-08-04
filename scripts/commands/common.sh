#!/usr/bin/env bash

# 由 clash on/clash restart 共用的用户级 Mihomo 服务与端口管理函数。
# 安装后位于 ~/.local/lib/mihomo-install/common.sh。

MIHOMO_HOME_DIR="$HOME/mihomo"
MIHOMO_CONFIG_FILE="$MIHOMO_HOME_DIR/config.yaml"
MIHOMO_PROXY_ENV_FILE="$MIHOMO_HOME_DIR/proxy.env"
MIHOMO_PROXY_AUTH_FILE="$MIHOMO_HOME_DIR/proxy-auth"
MIHOMO_COMMAND_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -r "$MIHOMO_COMMAND_LIB_DIR/ports.sh" || ! -r "$MIHOMO_COMMAND_LIB_DIR/user_auth.sh" ]]; then
    echo "缺少 Mihomo 端口或认证命令库，请重新执行 install.sh。" >&2
    return 1
fi
# shellcheck source=/dev/null
source "$MIHOMO_COMMAND_LIB_DIR/ports.sh"
# shellcheck source=/dev/null
source "$MIHOMO_COMMAND_LIB_DIR/user_auth.sh"

write_proxy_env() {
    local http_port temp_file
    http_port="$(awk '/^port:/ {print $2; exit}' "$MIHOMO_CONFIG_FILE")"
    if [[ ! "$http_port" =~ ^[0-9]+$ ]]; then
        echo "无法从 $MIHOMO_CONFIG_FILE 读取 HTTP 代理端口。" >&2
        return 1
    fi

    if ! mihomo_read_proxy_auth "$MIHOMO_PROXY_AUTH_FILE"; then
        echo "无法读取个人代理认证信息，请重新执行 install.sh。" >&2
        return 1
    fi

    umask 077
    temp_file="$(mktemp "$MIHOMO_HOME_DIR/.proxy-env.XXXXXX")" || return 1
    cat > "$temp_file" <<ENV
# Managed by mihomo-install. 此文件会由 clash on/clash restart 自动更新。
export http_proxy="http://${MIHOMO_PROXY_USERNAME}:${MIHOMO_PROXY_PASSWORD}@127.0.0.1:${http_port}"
export https_proxy="http://${MIHOMO_PROXY_USERNAME}:${MIHOMO_PROXY_PASSWORD}@127.0.0.1:${http_port}"
export HTTP_PROXY="http://${MIHOMO_PROXY_USERNAME}:${MIHOMO_PROXY_PASSWORD}@127.0.0.1:${http_port}"
export HTTPS_PROXY="http://${MIHOMO_PROXY_USERNAME}:${MIHOMO_PROXY_PASSWORD}@127.0.0.1:${http_port}"
ENV
    chmod 600 "$temp_file" || { rm -f "$temp_file"; return 1; }
    mv "$temp_file" "$MIHOMO_PROXY_ENV_FILE" || { rm -f "$temp_file"; return 1; }
}

random_available_port() {
    mihomo_random_available_port 20000 59999 "$@"
}

reassign_ports() {
    local http_port socks_port controller_port dns_port
    http_port="$(random_available_port)" || return 1
    socks_port="$(random_available_port "$http_port")" || return 1
    controller_port="$(random_available_port "$http_port" "$socks_port")" || return 1
    dns_port="$(random_available_port "$http_port" "$socks_port" "$controller_port")" || return 1

    sed -i -E \
        -e "s/^port: [0-9]+$/port: $http_port/" \
        -e "s/^socks-port: [0-9]+$/socks-port: $socks_port/" \
        -e "s|^external-controller: 127\\.0\\.0\\.1:[0-9]+$|external-controller: 127.0.0.1:$controller_port|" \
        -e "s|^  listen: 127\\.0\\.0\\.1:[0-9]+$|  listen: 127.0.0.1:$dns_port|" \
        "$MIHOMO_CONFIG_FILE" || return 1
    echo "已重新分配端口：HTTP ${http_port}，SOCKS ${socks_port}，控制接口 ${controller_port}，DNS ${dns_port}。"
}

is_port_binding_failure() {
    grep -Eqi 'address already in use|bind.*(failed|error|in use)|EADDRINUSE|port.*in use' <<< "$1"
}

wait_for_mihomo_stable() {
    local check
    for check in 1 2 3; do
        systemctl --user is-active --quiet mihomo || return 1
        sleep 1
    done
}

start_mihomo_with_retries() {
    local attempt service_log
    for attempt in 1 2 3; do
        systemctl --user start mihomo >/dev/null 2>&1 || true
        if wait_for_mihomo_stable; then
            write_proxy_env || return 1
            return 0
        fi

        service_log="$(journalctl --user -u mihomo -n 80 --no-pager 2>&1 || true)"
        if is_port_binding_failure "$service_log" && (( attempt < 3 )); then
            echo "Mihomo 因端口占用启动失败（第 $attempt/3 次）；正在重新分配端口..." >&2
            systemctl --user stop mihomo >/dev/null 2>&1 || true
            reassign_ports || return 1
            continue
        fi

        if is_port_binding_failure "$service_log"; then
            echo "已尝试 3 组端口，Mihomo 仍无法绑定端口。" >&2
        else
            echo "Mihomo 启动失败，原因不是可自动恢复的端口占用。" >&2
        fi
        echo "请查看：journalctl --user -u mihomo -n 80 --no-pager" >&2
        return 1
    done
}
