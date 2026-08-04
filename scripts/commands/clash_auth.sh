#!/usr/bin/env bash

# Managed by mihomo-install
set -euo pipefail

COMMAND_LIB_DIR="${MIHOMO_COMMAND_LIB_DIR:-$HOME/.local/lib/mihomo-install}"
AUTH_LIB="$COMMAND_LIB_DIR/user_auth.sh"
AUTH_FILE="$HOME/mihomo/proxy-auth"
CONFIG_FILE="$HOME/mihomo/config.yaml"

if [[ ! -r "$AUTH_LIB" ]]; then
    echo "缺少认证命令库：${AUTH_LIB}，请重新执行 install.sh。" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$AUTH_LIB"
if ! mihomo_read_proxy_auth "$AUTH_FILE"; then
    echo "未找到有效的个人代理凭据，请重新执行 install.sh。" >&2
    exit 1
fi

HTTP_PORT="$(awk '/^port:/ {print $2; exit}' "$CONFIG_FILE")"
SOCKS_PORT="$(awk '/^socks-port:/ {print $2; exit}' "$CONFIG_FILE")"
if [[ ! "$HTTP_PORT" =~ ^[0-9]+$ || ! "$SOCKS_PORT" =~ ^[0-9]+$ ]]; then
    echo "无法从 config.yaml 读取 HTTP/SOCKS 端口。" >&2
    exit 1
fi

cat <<EOF
个人代理认证信息（请勿分享）：
  用户名：${MIHOMO_PROXY_USERNAME}
  密码：${MIHOMO_PROXY_PASSWORD}
  HTTP：http://${MIHOMO_PROXY_USERNAME}:${MIHOMO_PROXY_PASSWORD}@127.0.0.1:${HTTP_PORT}
  SOCKS5：socks5://${MIHOMO_PROXY_USERNAME}:${MIHOMO_PROXY_PASSWORD}@127.0.0.1:${SOCKS_PORT}
EOF
