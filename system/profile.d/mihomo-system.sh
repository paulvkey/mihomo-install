# Mihomo 系统共享代理 shell 函数。由 install_sys.sh 安装。

clashsys() {
    _mihomo_action="${1:-help}"
    _mihomo_env_file="${MIHOMO_SYSTEM_ENV_FILE:-/etc/mihomo/proxy.env}"
    _mihomo_expected_proxy=""
    _mihomo_can_control=false
    _mihomo_check_url="${MIHOMO_SYSTEM_CHECK_URL:-https://www.gstatic.com/generate_204}"
    _mihomo_command_file="${MIHOMO_SYSTEM_COMMAND_FILE:-/usr/local/bin/clashsys}"

    case "$_mihomo_action" in
        on)
            if ! systemctl is-active --quiet mihomo-system.service 2>/dev/null; then
                echo "系统共享 Mihomo 未运行，请联系管理员或执行 clashsys status。" >&2
                unset _mihomo_action _mihomo_env_file _mihomo_expected_proxy _mihomo_can_control _mihomo_check_url _mihomo_command_file
                return 1
            fi
            if [ ! -r "$_mihomo_env_file" ]; then
                echo "无法读取系统代理环境文件：${_mihomo_env_file}" >&2
                unset _mihomo_action _mihomo_env_file _mihomo_expected_proxy _mihomo_can_control _mihomo_check_url _mihomo_command_file
                return 1
            fi
            if [ "$(id -u)" -eq 0 ]; then
                _mihomo_can_control=true
            else
                case " $(id -nG 2>/dev/null) " in
                    *" mihomo-control "*) _mihomo_can_control=true ;;
                esac
            fi
            # shellcheck source=/dev/null
            . "$_mihomo_env_file"
            export MIHOMO_PROXY_SCOPE=system
            if [ "${MIHOMO_SYSTEM_SKIP_NODE_CHECK:-}" != 1 ]; then
                if [ "$_mihomo_can_control" = true ]; then
                    if [ -t 0 ]; then
                        command "$_mihomo_command_file" select --auto || \
                            echo "当前共享节点检查或选择未完成，可稍后执行 clashsys select。" >&2
                    fi
                elif command -v curl >/dev/null 2>&1; then
                    if command curl -fsS -o /dev/null --noproxy '' --proxy "$http_proxy" \
                        --connect-timeout 3 --max-time 8 "$_mihomo_check_url"; then
                        echo "当前共享代理节点可用。"
                    else
                        echo "当前共享代理节点可能不可用；普通用户不会自动切换节点，请联系管理员或 mihomo-control 用户执行 clashsys select。" >&2
                    fi
                else
                    echo "未找到 curl，无法检测当前共享代理节点；已跳过检测。" >&2
                fi
            fi
            echo "当前终端已切换到系统共享代理：${http_proxy}"
            ;;
        off)
            if [ -r "$_mihomo_env_file" ]; then
                _mihomo_expected_proxy="$(sed -n 's/^export http_proxy="\([^"]*\)"$/\1/p' "$_mihomo_env_file" | head -n 1)"
            fi
            if [ -n "$_mihomo_expected_proxy" ] && [ "${http_proxy:-}" = "$_mihomo_expected_proxy" ]; then
                unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY MIHOMO_PROXY_SCOPE
                echo "当前终端已停用系统共享代理。"
            else
                echo "当前终端没有使用系统共享代理，未修改现有代理变量。"
            fi
            ;;
        *)
            unset _mihomo_action _mihomo_env_file _mihomo_expected_proxy _mihomo_can_control _mihomo_check_url
            command "$_mihomo_command_file" "$@"
            _mihomo_status=$?
            unset _mihomo_command_file
            if [ "$_mihomo_status" -eq 0 ]; then
                unset _mihomo_status
                return 0
            fi
            unset _mihomo_status
            return 1
            ;;
    esac
    unset _mihomo_action _mihomo_env_file _mihomo_expected_proxy _mihomo_can_control _mihomo_check_url _mihomo_command_file
}
