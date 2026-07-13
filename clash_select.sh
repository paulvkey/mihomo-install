#!/usr/bin/env bash

# 交互选择 Mihomo 的 PROXY 代理组节点。
set -euo pipefail

CONFIG_FILE="$HOME/mihomo/config.yaml"
GROUP_NAME="PROXY"

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "clash_select 需要 curl 和 jq，请安装 jq 后重试。" >&2
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "未找到配置文件：$CONFIG_FILE" >&2
    exit 1
fi

if ! systemctl --user is-active --quiet mihomo; then
    echo "Mihomo 未运行，请先执行 clashon。" >&2
    exit 1
fi

CONTROLLER_PORT="$(awk -F: '/^external-controller:/ { print $3; exit }' "$CONFIG_FILE")"
if [[ ! "$CONTROLLER_PORT" =~ ^[0-9]+$ ]]; then
    echo "无法从配置文件读取控制接口端口。" >&2
    exit 1
fi

API_URL="http://127.0.0.1:${CONTROLLER_PORT}/proxies/${GROUP_NAME}"
RESPONSE="$(curl -fsS "$API_URL")" || {
    echo "无法连接 Mihomo 控制接口：$API_URL" >&2
    exit 1
}

CURRENT="$(jq -r '.now // ""' <<< "$RESPONSE")"
mapfile -t NODES < <(jq -r '.all[]' <<< "$RESPONSE")
if ((${#NODES[@]} == 0)); then
    echo "订阅中没有可选节点，请检查订阅链接与 Mihomo 日志。" >&2
    exit 1
fi

echo "当前节点：${CURRENT:-未选择}"
echo "请选择节点（输入 0 取消）："
select NODE in "${NODES[@]}"; do
    if [[ "$REPLY" == "0" ]]; then
        echo "已取消节点选择。"
        exit 0
    fi
    if [[ -z "${NODE:-}" ]]; then
        echo "无效选择，请重新输入。"
        continue
    fi

    PAYLOAD="$(jq -n --arg name "$NODE" '{name: $name}')"
    curl -fsS -X PUT -H 'Content-Type: application/json' -d "$PAYLOAD" "$API_URL" >/dev/null
    echo "已切换到：$NODE"
    exit 0
done
