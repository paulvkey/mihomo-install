#!/usr/bin/env bash

# Mihomo 安装脚本共用的安全随机端口与占用检测函数。

mihomo_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnuH 2>/dev/null | awk -v port="$port" '$5 ~ ":" port "$" { found = 1 } END { exit !found }'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltnu 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" { found = 1 } END { exit !found }'
    else
        return 1
    fi
}

mihomo_random_available_port() {
    local min_port="$1" max_port="$2" raw candidate selected
    shift 2
    if [[ ! "$min_port" =~ ^[0-9]+$ || ! "$max_port" =~ ^[0-9]+$ ]] \
        || ((min_port < 1024 || max_port > 65535 || min_port > max_port)); then
        echo "无效端口范围：${min_port}-${max_port}" >&2
        return 1
    fi

    for _ in {1..200}; do
        raw="$(od -An -N 2 -tu2 /dev/urandom | tr -d ' \n')" || return 1
        [[ "$raw" =~ ^[0-9]+$ ]] || continue
        candidate=$((min_port + raw % (max_port - min_port + 1)))
        for selected in "$@"; do
            [[ "$selected" == "$candidate" ]] && continue 2
        done
        if ! mihomo_port_in_use "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    echo "无法在 ${min_port}-${max_port} 范围内找到可用端口。" >&2
    return 1
}
