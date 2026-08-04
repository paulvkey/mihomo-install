#!/usr/bin/env bash

# Managed by mihomo-install
set -euo pipefail

COMMON_FILE="$HOME/.local/lib/mihomo-install/common.sh"
if [[ ! -r "$COMMON_FILE" ]]; then
    echo "缺少 Mihomo 命令库：${COMMON_FILE}，请重新执行 install.sh。" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$COMMON_FILE"

if systemctl --user is-active --quiet mihomo; then
    write_proxy_env
    echo "Mihomo 已在运行，未修改端口；当前 HTTP 代理环境已同步。"
    echo "如需切换节点，请执行 clash select。"
    exit 0
fi

if start_mihomo_with_retries; then
    echo "Mihomo 已启动，HTTP 代理环境已更新。"
    if [[ -t 0 && -x "$HOME/.local/bin/clash" ]]; then
        "$HOME/.local/bin/clash" select || echo "节点选择未完成，可稍后执行 clash select。" >&2
    fi
    exit 0
fi
exit 1
