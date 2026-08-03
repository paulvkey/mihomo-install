#!/usr/bin/env bash

# Managed by mihomo-install (system mode)
set -euo pipefail
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

SERVICE_NAME="mihomo-system.service"
CONFIG_FILE="/etc/mihomo/config.yaml"
CONTROL_GROUP="mihomo-control"
GROUP_NAME="PROXY"
DELAY_TEST_URL="https://www.gstatic.com/generate_204"
DELAY_TIMEOUT_MS=5000
DELAY_WARN_MS=1500

usage() {
    cat <<'EOF'
用法: clashsys <命令>

普通用户命令:
  on       在当前终端启用系统共享代理（需要加载 /etc/profile.d/mihomo-system.sh）
  off      在当前终端停用系统共享代理
  status   查看系统共享 Mihomo 服务状态

控制组命令:
  select   测速并切换共享节点；会影响所有使用系统代理的用户
  restart  重启系统共享 Mihomo 服务

其他:
  help     显示本帮助
EOF
}

require_root_control() {
    local action="$1"
    if ((EUID == 0)); then
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        echo "${action} 需要 root 或 ${CONTROL_GROUP} 组权限，当前系统未安装 sudo。" >&2
        exit 1
    fi
    exec sudo -n "$0" "$action"
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

select_node() {
    local group_uri api_url response current delay_api_url curl_max_time delay_response
    local index node delay record delay_level current_mark display_node selected_index confirm payload
    local node_count=0 available_count=0 unavailable_count=0
    local -a nodes=() available_records=() unavailable_nodes=()
    local -a sorted_records=() select_nodes=() select_delays=() select_labels=()

    require_root_control select
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "系统共享 Mihomo 未运行，请先执行 clashsys restart。" >&2
        return 1
    fi
    read_controller || return 1

    group_uri="$(jq -rn --arg value "$GROUP_NAME" '$value | @uri')"
    api_url="${CONTROLLER_URL}/proxies/${group_uri}"
    response="$(curl -fsS --noproxy 127.0.0.1 "${CURL_AUTH_ARGS[@]}" "$api_url")" || {
        echo "无法连接系统 Mihomo 控制接口。" >&2
        return 1
    }

    current="$(jq -r '.now // ""' <<< "$response")"
    while IFS= read -r node; do
        nodes+=("$node")
        node_count=$((node_count + 1))
    done < <(jq -r '.all[]' <<< "$response")
    if ((node_count == 0)); then
        echo "订阅中没有可选节点，请检查系统订阅和日志。" >&2
        return 1
    fi

    delay_api_url="${CONTROLLER_URL}/group/${group_uri}/delay"
    curl_max_time=$(((DELAY_TIMEOUT_MS + 999) / 1000 + 5))
    echo "当前共享节点：${current:-未选择}"
    echo "正在检测 ${node_count} 个节点的延迟（超时 ${DELAY_TIMEOUT_MS} ms）..."
    delay_response="$(
        curl -fsS --noproxy 127.0.0.1 --max-time "$curl_max_time" "${CURL_AUTH_ARGS[@]}" \
            --get \
            --data-urlencode "url=${DELAY_TEST_URL}" \
            --data-urlencode "timeout=${DELAY_TIMEOUT_MS}" \
            --data-urlencode "expected=200-299" \
            "$delay_api_url"
    )" || {
        echo "节点延迟检测失败，未进入节点选择。" >&2
        return 1
    }
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$delay_response"; then
        echo "控制接口返回了无效的延迟结果。" >&2
        return 1
    fi

    for index in "${!nodes[@]}"; do
        node="${nodes[$index]}"
        delay="$(
            jq -r --arg node "$node" \
                '(.[$node] // 0) as $delay | if ($delay | type) == "number" then $delay else 0 end' \
                <<< "$delay_response"
        )"
        if [[ "$delay" =~ ^[0-9]+$ ]] && ((delay > 0)); then
            available_records+=("${delay}"$'\t'"${index}")
            available_count=$((available_count + 1))
        else
            unavailable_nodes+=("$node")
            unavailable_count=$((unavailable_count + 1))
        fi
    done
    if ((available_count == 0)); then
        echo "所有共享节点均超时或不可用。" >&2
        return 1
    fi

    while IFS= read -r record; do
        sorted_records+=("$record")
    done < <(printf '%s\n' "${available_records[@]}" | sort -n -k1,1)
    for record in "${sorted_records[@]}"; do
        IFS=$'\t' read -r delay index <<< "$record"
        node="${nodes[$index]}"
        if ((delay <= 300)); then
            delay_level="快"
        elif ((delay < DELAY_WARN_MS)); then
            delay_level="正常"
        else
            delay_level="高延迟"
        fi
        current_mark=""
        [[ "$node" == "$current" ]] && current_mark="，当前"
        select_nodes+=("$node")
        select_delays+=("$delay")
        select_labels+=("${node} [${delay} ms，${delay_level}${current_mark}]")
    done

    echo "测速完成：${available_count} 个可用，${unavailable_count} 个不可用。"
    if ((unavailable_count > 0)); then
        echo "以下节点已排除："
        printf '  - %s\n' "${unavailable_nodes[@]}"
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
        if ((delay >= DELAY_WARN_MS)); then
            read -r -p "节点延迟为 ${delay} ms，可能不稳定，仍要选择吗？[y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "已放弃该节点，请重新选择。"
                continue
            fi
        fi

        payload="$(jq -n --arg name "$node" '{name: $name}')"
        if ! curl -fsS --noproxy 127.0.0.1 "${CURL_AUTH_ARGS[@]}" -X PUT -H 'Content-Type: application/json' -d "$payload" "$api_url" >/dev/null; then
            echo "共享节点切换失败，请重新选择或查看系统日志。" >&2
            continue
        fi
        echo "已切换共享节点：${node}（${delay} ms）"
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
    case "${1:-help}" in
        on|off)
            echo "当前 shell 尚未加载 clashsys 函数，无法直接修改父 shell 的代理变量。" >&2
            echo "请先执行：source /etc/profile.d/mihomo-system.sh" >&2
            return 1
            ;;
        status)
            systemctl status "$SERVICE_NAME" --no-pager
            ;;
        select)
            select_node
            ;;
        restart)
            restart_service
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "未知命令：$1" >&2
            usage >&2
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
