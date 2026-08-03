#!/usr/bin/env bash

# 由 clashon/clash_restart 共用的用户级 Mihomo 服务与端口管理函数。
# 安装后位于 ~/.local/lib/mihomo-install/common.sh。

MIHOMO_HOME_DIR="$HOME/mihomo"
MIHOMO_CONFIG_FILE="$MIHOMO_HOME_DIR/config.yaml"
MIHOMO_PROXY_ENV_FILE="$MIHOMO_HOME_DIR/proxy.env"

write_proxy_env() {
    local http_port
    http_port="$(awk '/^port:/ {print $2; exit}' "$MIHOMO_CONFIG_FILE")"
    if [[ ! "$http_port" =~ ^[0-9]+$ ]]; then
        echo "无法从 $MIHOMO_CONFIG_FILE 读取 HTTP 代理端口。" >&2
        return 1
    fi

    umask 077
    cat > "$MIHOMO_PROXY_ENV_FILE" <<ENV
# Managed by mihomo-install. 此文件会由 clashon/clash_restart 自动更新。
export http_proxy="http://127.0.0.1:${http_port}"
export https_proxy="http://127.0.0.1:${http_port}"
export HTTP_PROXY="http://127.0.0.1:${http_port}"
export HTTPS_PROXY="http://127.0.0.1:${http_port}"
ENV
}

port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnuH 2>/dev/null | awk -v port="$port" '$5 ~ ":" port "$" { found = 1 } END { exit !found }'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltnu 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" { found = 1 } END { exit !found }'
    else
        return 1
    fi
}

random_available_port() {
    local candidate
    local -a chosen=("$@")
    for _ in {1..100}; do
        candidate=$((20000 + RANDOM % 40000))
        [[ " ${chosen[*]} " == *" $candidate "* ]] && continue
        if ! port_in_use "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    echo "无法在 20000-59999 范围内找到可用端口。" >&2
    return 1
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
