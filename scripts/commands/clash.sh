#!/usr/bin/env bash

# Managed by mihomo-install
set -euo pipefail

COMMAND_LIB_DIR="${MIHOMO_COMMAND_LIB_DIR:-$HOME/.local/lib/mihomo-install}"

usage() {
    cat <<'EOF'
Mihomo 当前用户模式帮助

用法：
  clash <命令>

命令：
  on       启动 Mihomo 并检查当前节点；可用时沿用，不可用时重新选择
  off      停止 Mihomo，并清理当前终端代理
  restart  重启 Mihomo，保持原端口；端口冲突时最多重试 3 次
  status   查看 Mihomo 用户服务状态
  select   测速、标记异常节点并交互选择节点
  sub      更换订阅链接、重启服务并重新选择节点
  auth     显示手动配置代理时需要的用户名、密码和地址
  help     显示本帮助，也可以使用 -h 或 --help

示例：
  clash on
  clash select
  clash sub
  clash status
  clash auth
  clash restart
  clash off

说明：
  on、off 和 restart 需要使用 install.sh 写入 ~/.bashrc 的 clash 函数，
  才能同步修改当前 shell 的 HTTP/HTTPS 代理变量。
EOF
}

run_action() {
    local script_name="$1"
    shift
    local script_file="$COMMAND_LIB_DIR/$script_name"
    if [[ ! -x "$script_file" ]]; then
        echo "缺少 Mihomo 命令组件：${script_file}，请重新执行 install.sh。" >&2
        return 1
    fi
    exec "$script_file" "$@"
}

main() {
    local action="${1:-help}"
    (($# == 0)) || shift

    case "$action" in
        on)
            run_action clashon.sh "$@"
            ;;
        off)
            run_action clashoff.sh "$@"
            ;;
        restart)
            run_action clash_restart.sh "$@"
            ;;
        status)
            run_action clash_status.sh "$@"
            ;;
        select)
            run_action clash_select.sh "$@"
            ;;
        sub|subscription)
            run_action clash_subscription.sh "$@"
            ;;
        auth)
            run_action clash_auth.sh "$@"
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "未知命令：${action}" >&2
            usage >&2
            return 1
            ;;
    esac
}

main "$@"
