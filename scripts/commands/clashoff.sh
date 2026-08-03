#!/usr/bin/env bash

# Managed by mihomo-install
set -euo pipefail

if ! systemctl --user is-active --quiet mihomo; then
    rm -f "$HOME/mihomo/proxy.env"
    echo "Mihomo 已处于停止状态；代理环境文件已清理。"
    exit 0
fi

if systemctl --user stop mihomo; then
    rm -f "$HOME/mihomo/proxy.env"
    echo "Mihomo 已停止；新终端不会再加载代理环境。"
else
    echo "Mihomo 停止失败，请查看：journalctl --user -u mihomo -n 80 --no-pager" >&2
    exit 1
fi
