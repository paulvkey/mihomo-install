#!/usr/bin/env bash

# 交互选择 Mihomo 的 PROXY 代理组节点。
set -euo pipefail

CONFIG_FILE="$HOME/mihomo/config.yaml"
GROUP_NAME="${CLASH_PROXY_GROUP:-PROXY}"
DELAY_TEST_URL="${CLASH_DELAY_TEST_URL:-https://www.gstatic.com/generate_204}"
DELAY_TIMEOUT_MS="${CLASH_DELAY_TIMEOUT_MS:-5000}"
DELAY_WARN_MS="${CLASH_DELAY_WARN_MS:-1500}"

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "clash select 需要 curl 和 jq，请安装 jq 后重试。" >&2
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "未找到配置文件：$CONFIG_FILE" >&2
    exit 1
fi

if [[ ! "$DELAY_TIMEOUT_MS" =~ ^[0-9]+$ ]] || ((DELAY_TIMEOUT_MS < 100 || DELAY_TIMEOUT_MS > 60000)); then
    echo "CLASH_DELAY_TIMEOUT_MS 必须是 100-60000 之间的整数。" >&2
    exit 1
fi
if [[ ! "$DELAY_WARN_MS" =~ ^[0-9]+$ ]] || ((DELAY_WARN_MS < 100 || DELAY_WARN_MS > DELAY_TIMEOUT_MS)); then
    echo "CLASH_DELAY_WARN_MS 必须是 100-${DELAY_TIMEOUT_MS} 之间的整数。" >&2
    exit 1
fi

if ! systemctl --user is-active --quiet mihomo; then
    echo "Mihomo 未运行，请先执行 clash on。" >&2
    exit 1
fi

CONTROLLER_PORT="$(awk -F: '/^external-controller:/ { print $3; exit }' "$CONFIG_FILE")"
if [[ ! "$CONTROLLER_PORT" =~ ^[0-9]+$ ]]; then
    echo "无法从配置文件读取控制接口端口。" >&2
    exit 1
fi

CONTROLLER_SECRET="$(awk -F: '/^secret:/ {sub(/^[[:space:]]*/, "", $2); gsub(/^\"|\"$/, "", $2); print $2; exit}' "$CONFIG_FILE")"
CURL_AUTH_ARGS=()
if [[ -n "$CONTROLLER_SECRET" ]]; then
    CURL_AUTH_ARGS=(-H "Authorization: Bearer $CONTROLLER_SECRET")
fi

CONTROLLER_URL="http://127.0.0.1:${CONTROLLER_PORT}"
GROUP_URI="$(jq -rn --arg value "$GROUP_NAME" '$value | @uri')"
API_URL="${CONTROLLER_URL}/proxies/${GROUP_URI}"
RESPONSE="$(curl -fsS --noproxy '127.0.0.1,localhost,::1' "${CURL_AUTH_ARGS[@]}" "$API_URL")" || {
    echo "无法连接 Mihomo 控制接口：$API_URL" >&2
    exit 1
}

CURRENT="$(jq -r '.now // ""' <<< "$RESPONSE")"
NODES=()
while IFS= read -r NODE; do
    NODES+=("$NODE")
done < <(jq -r '.all[] | select(. != "DIRECT")' <<< "$RESPONSE")
if ((${#NODES[@]} == 0)); then
    echo "订阅未加载到真实代理节点（DIRECT 兜底不计入）。" >&2
    echo "请检查订阅链接与 Mihomo 日志，修复后重新执行 clash select。" >&2
    exit 1
fi

DELAY_API_URL="${CONTROLLER_URL}/group/${GROUP_URI}/delay"
CURL_MAX_TIME=$(((DELAY_TIMEOUT_MS + 999) / 1000 + 5))

echo "当前节点：${CURRENT:-未选择}"
echo "正在检测 ${#NODES[@]} 个节点的延迟（超时 ${DELAY_TIMEOUT_MS} ms）..."
DELAY_RESPONSE="$(
    curl -fsS --noproxy '127.0.0.1,localhost,::1' --max-time "$CURL_MAX_TIME" "${CURL_AUTH_ARGS[@]}" \
        --get \
        --data-urlencode "url=${DELAY_TEST_URL}" \
        --data-urlencode "timeout=${DELAY_TIMEOUT_MS}" \
        --data-urlencode "expected=200-299" \
        "$DELAY_API_URL"
)" || {
    echo "节点延迟检测失败，未进入节点选择。" >&2
    echo "请检查 Mihomo 日志、订阅状态和测试地址：${DELAY_TEST_URL}" >&2
    exit 1
}

if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$DELAY_RESPONSE"; then
    echo "控制接口返回了无效的延迟检测结果。" >&2
    exit 1
fi

AVAILABLE_RECORDS=()
UNAVAILABLE_NODES=()
for INDEX in "${!NODES[@]}"; do
    NODE="${NODES[$INDEX]}"
    DELAY="$(
        jq -r --arg node "$NODE" \
            '(.[$node] // 0) as $delay | if ($delay | type) == "number" then $delay else 0 end' \
            <<< "$DELAY_RESPONSE"
    )"
    if [[ "$DELAY" =~ ^[0-9]+$ ]] && ((DELAY > 0)); then
        AVAILABLE_RECORDS+=("${DELAY}"$'\t'"${INDEX}")
    else
        UNAVAILABLE_NODES+=("$NODE")
    fi
done

if ((${#AVAILABLE_RECORDS[@]} == 0)); then
    echo "所有节点均超时或不可用，请检查订阅、网络和 Mihomo 日志。" >&2
    exit 1
fi

SORTED_RECORDS=()
while IFS= read -r RECORD; do
    SORTED_RECORDS+=("$RECORD")
done < <(printf '%s\n' "${AVAILABLE_RECORDS[@]}" | sort -n -k1,1)
SELECT_NODES=()
SELECT_DELAYS=()
SELECT_LABELS=()
for RECORD in "${SORTED_RECORDS[@]}"; do
    IFS=$'\t' read -r DELAY INDEX <<< "$RECORD"
    NODE="${NODES[$INDEX]}"
    if ((DELAY <= 300)); then
        DELAY_LEVEL="快"
    elif ((DELAY < DELAY_WARN_MS)); then
        DELAY_LEVEL="正常"
    else
        DELAY_LEVEL="高延迟"
    fi
    CURRENT_MARK=""
    [[ "$NODE" == "$CURRENT" ]] && CURRENT_MARK="，当前"
    SELECT_NODES+=("$NODE")
    SELECT_DELAYS+=("$DELAY")
    SELECT_LABELS+=("${NODE} [${DELAY} ms，${DELAY_LEVEL}${CURRENT_MARK}]")
done

echo "测速完成：${#SELECT_NODES[@]} 个可用，${#UNAVAILABLE_NODES[@]} 个不可用；可用节点已按延迟升序排列。"
if ((${#UNAVAILABLE_NODES[@]} > 0)); then
    echo "以下节点超时或不可用，已从选择列表排除："
    printf '  - %s\n' "${UNAVAILABLE_NODES[@]}"
fi

echo "请选择节点（输入 0 取消）："
PS3="请输入序号: "
select DISPLAY_NODE in "${SELECT_LABELS[@]}"; do
    if [[ "$REPLY" == "0" ]]; then
        echo "已取消节点选择。"
        exit 0
    fi
    if [[ -z "${DISPLAY_NODE:-}" ]]; then
        echo "无效选择，请重新输入。"
        continue
    fi

    SELECTED_INDEX=$((REPLY - 1))
    NODE="${SELECT_NODES[$SELECTED_INDEX]}"
    DELAY="${SELECT_DELAYS[$SELECTED_INDEX]}"
    if ((DELAY >= DELAY_WARN_MS)); then
        read -r -p "节点延迟为 ${DELAY} ms，可能不稳定，仍要选择吗？[y/N]: " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo "已放弃该节点，请重新选择。"
            continue
        fi
    fi

    PAYLOAD="$(jq -n --arg name "$NODE" '{name: $name}')"
    if ! curl -fsS --noproxy '127.0.0.1,localhost,::1' "${CURL_AUTH_ARGS[@]}" -X PUT -H 'Content-Type: application/json' -d "$PAYLOAD" "$API_URL" >/dev/null; then
        echo "切换节点失败，请重新选择或查看 Mihomo 日志。" >&2
        continue
    fi
    echo "已切换到：${NODE}（${DELAY} ms）"
    exit 0
done
