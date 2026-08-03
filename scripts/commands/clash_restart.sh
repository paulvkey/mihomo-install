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

systemctl --user stop mihomo >/dev/null 2>&1 || true
if start_mihomo_with_retries; then
    echo "Mihomo 已重启，HTTP 代理环境已更新。"
    exit 0
fi
exit 1
