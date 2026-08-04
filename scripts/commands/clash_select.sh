#!/usr/bin/env bash

# 交互选择 Mihomo 的 PROXY 代理组节点。
set -euo pipefail

CONFIG_FILE="$HOME/mihomo/config.yaml"
GROUP_NAME="${CLASH_PROXY_GROUP:-PROXY}"
DELAY_TEST_URL="${CLASH_DELAY_TEST_URL:-https://www.gstatic.com/generate_204}"
DELAY_TIMEOUT_MS="${CLASH_DELAY_TIMEOUT_MS:-5000}"
DELAY_WARN_MS="${CLASH_DELAY_WARN_MS:-1500}"
AUTO_MODE=false
if [[ "${1:-}" == "--auto" ]]; then
    AUTO_MODE=true
    shift
fi
if (($# > 0)); then
    echo "用法：clash select [--auto]" >&2
    exit 1
fi

CURRENT_COLOR_START=""
CURRENT_COLOR_END=""
if [[ -t 1 || -t 2 ]]; then
    CURRENT_COLOR_START=$'\033[1;36m'
    CURRENT_COLOR_END=$'\033[0m'
fi

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
CURRENT_IN_NODES=false
while IFS= read -r NODE; do
    NODES+=("$NODE")
    if [[ "$NODE" == "$CURRENT" ]]; then
        CURRENT_IN_NODES=true
    fi
done < <(jq -r '.all[] | select(. != "DIRECT")' <<< "$RESPONSE")
if ((${#NODES[@]} == 0)); then
    echo "订阅未加载到真实代理节点（DIRECT 兜底不计入）。" >&2
    echo "请检查订阅链接与 Mihomo 日志，修复后重新执行 clash select。" >&2
    exit 1
fi

DELAY_API_URL="${CONTROLLER_URL}/group/${GROUP_URI}/delay"
CURL_MAX_TIME=$(((DELAY_TIMEOUT_MS + 999) / 1000 + 5))

if [[ "$CURRENT_IN_NODES" == true ]]; then
    printf '当前节点：%s★ %s%s\n' "$CURRENT_COLOR_START" "$CURRENT" "$CURRENT_COLOR_END"
elif [[ -n "$CURRENT" ]]; then
    echo "当前节点：${CURRENT}（不是可选的真实订阅节点）"
else
    echo "当前节点：未选择"
fi
echo "正在检测 ${#NODES[@]} 个节点的延迟（超时 ${DELAY_TIMEOUT_MS} ms）..."
DELAY_TEST_FAILED=false
if ! DELAY_RESPONSE="$(
    curl -fsS --noproxy '127.0.0.1,localhost,::1' --max-time "$CURL_MAX_TIME" "${CURL_AUTH_ARGS[@]}" \
        --get \
        --data-urlencode "url=${DELAY_TEST_URL}" \
        --data-urlencode "timeout=${DELAY_TIMEOUT_MS}" \
        --data-urlencode "expected=200-299" \
        "$DELAY_API_URL"
)"; then
    echo "节点延迟检测请求失败；仍将保留全部节点供选择。" >&2
    echo "请留意异常标记，并检查测试地址：${DELAY_TEST_URL}" >&2
    DELAY_RESPONSE='{}'
    DELAY_TEST_FAILED=true
elif ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$DELAY_RESPONSE"; then
    echo "控制接口返回了无效的延迟结果；仍将保留全部节点供选择。" >&2
    DELAY_RESPONSE='{}'
    DELAY_TEST_FAILED=true
fi

NODE_DELAYS=()
AVAILABLE_COUNT=0
UNAVAILABLE_COUNT=0
CURRENT_DELAY=0
for INDEX in "${!NODES[@]}"; do
    NODE="${NODES[$INDEX]}"
    DELAY="$(
        jq -r --arg node "$NODE" \
            '(.[$node] // 0) as $delay | if ($delay | type) == "number" then $delay else 0 end' \
            <<< "$DELAY_RESPONSE"
    )"
    if [[ "$NODE" == "$CURRENT" && "$DELAY" =~ ^[0-9]+$ ]]; then
        CURRENT_DELAY="$DELAY"
    fi
    NODE_DELAYS[$INDEX]="$DELAY"
    if [[ "$DELAY" =~ ^[0-9]+$ ]] && ((DELAY > 0)); then
        AVAILABLE_COUNT=$((AVAILABLE_COUNT + 1))
    else
        UNAVAILABLE_COUNT=$((UNAVAILABLE_COUNT + 1))
    fi
done

SELECT_NODES=()
SELECT_DELAYS=()
SELECT_LABELS=()
if [[ "$DELAY_TEST_FAILED" == true ]]; then
    UNAVAILABLE_LABEL="测速失败"
else
    UNAVAILABLE_LABEL="超时/不可用"
fi
for INDEX in "${!NODES[@]}"; do
    NODE="${NODES[$INDEX]}"
    DELAY="${NODE_DELAYS[$INDEX]:-0}"
    CURRENT_MARK=""
    [[ "$NODE" == "$CURRENT" ]] && CURRENT_MARK="，当前"
    SELECT_NODES+=("$NODE")
    SELECT_DELAYS+=("$DELAY")
    if [[ "$DELAY" =~ ^[0-9]+$ ]] && ((DELAY > 0)); then
        if ((DELAY <= 300)); then
            DELAY_LEVEL="快"
        elif ((DELAY < DELAY_WARN_MS)); then
            DELAY_LEVEL="正常"
        else
            DELAY_LEVEL="高延迟"
        fi
        DISPLAY_LABEL="${NODE} [${DELAY} ms，${DELAY_LEVEL}${CURRENT_MARK}]"
    else
        DISPLAY_LABEL="${NODE} [${UNAVAILABLE_LABEL}${CURRENT_MARK}]"
    fi
    if [[ "$NODE" == "$CURRENT" ]]; then
        # Bash select 会把 ANSI 控制符计入列宽，导致后续列错位。
        # 选择列表只使用可见字符标记；上方的当前节点提示仍保留颜色高亮。
        DISPLAY_LABEL="★ ${DISPLAY_LABEL}"
    fi
    SELECT_LABELS+=("$DISPLAY_LABEL")
done

echo "测速完成：${AVAILABLE_COUNT} 个测得延迟，${UNAVAILABLE_COUNT} 个超时或未测得；全部真实节点均按订阅原始顺序保留。"
echo "提示：延迟与异常标记仅供参考，不会改变节点顺序，也不会阻止用户选择。"

if [[ "$AUTO_MODE" == true ]]; then
    if [[ "$CURRENT_IN_NODES" == true ]] && ((CURRENT_DELAY > 0)); then
        printf '%s★ 当前节点 %s 可用（%s ms），继续使用并跳过选择。%s\n' \
            "$CURRENT_COLOR_START" "$CURRENT" "$CURRENT_DELAY" "$CURRENT_COLOR_END"
        exit 0
    fi
    if [[ "$CURRENT_IN_NODES" == true ]]; then
        printf '%s⚠ 当前节点 %s 超时或未测得延迟，需要重新选择。%s\n' \
            "$CURRENT_COLOR_START" "$CURRENT" "$CURRENT_COLOR_END" >&2
    else
        echo "当前没有已选择且可用的真实订阅节点，需要进行选择。" >&2
    fi
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
    if ((DELAY == 0)); then
        read -r -p "该节点测速超时或未测得延迟，仍要选择吗？[y/N]: " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo "已放弃该节点，请重新选择。"
            continue
        fi
    elif ((DELAY >= DELAY_WARN_MS)); then
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
    if ((DELAY > 0)); then
        echo "已切换到：${NODE}（${DELAY} ms）"
    else
        echo "已切换到：${NODE}（未测得延迟）"
    fi
    exit 0
done
