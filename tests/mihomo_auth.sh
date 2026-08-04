#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    echo '[SKIP] Mihomo HTTP/SOCKS 认证集成测试仅在 x86_64 Linux 运行。'
    exit 0
fi
for command_name in curl gzip python3; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "[FAIL] 认证集成测试缺少命令：$command_name" >&2
        exit 1
    }
done

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-auth-integration.XXXXXX")" || exit 1
MIHOMO_PID=""
HTTP_SERVER_PID=""
cleanup() {
    [[ -n "$MIHOMO_PID" ]] && kill "$MIHOMO_PID" >/dev/null 2>&1 || true
    [[ -n "$HTTP_SERVER_PID" ]] && kill "$HTTP_SERVER_PID" >/dev/null 2>&1 || true
    [[ -n "$MIHOMO_PID" ]] && wait "$MIHOMO_PID" 2>/dev/null || true
    [[ -n "$HTTP_SERVER_PID" ]] && wait "$HTTP_SERVER_PID" 2>/dev/null || true
    rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

pick_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

HTTP_PROXY_PORT="$(pick_port)"
SOCKS_PROXY_PORT="$(pick_port)"
TARGET_PORT="$(pick_port)"
while [[ "$SOCKS_PROXY_PORT" == "$HTTP_PROXY_PORT" ]]; do SOCKS_PROXY_PORT="$(pick_port)"; done
while [[ "$TARGET_PORT" == "$HTTP_PROXY_PORT" || "$TARGET_PORT" == "$SOCKS_PROXY_PORT" ]]; do TARGET_PORT="$(pick_port)"; done

archive="$(find "$PROJECT_DIR/resources/bin" -maxdepth 1 -name 'mihomo-linux-amd64-v2-*.gz' | sort -V | tail -n 1)"
[[ -n "$archive" ]] || { echo '[FAIL] 未找到 Mihomo AMD64 v2 核心。' >&2; exit 1; }
gzip -cd "$archive" > "$TMP_ROOT/mihomo"
chmod +x "$TMP_ROOT/mihomo"

cat > "$TMP_ROOT/config.yaml" <<EOF
port: ${HTTP_PROXY_PORT}
socks-port: ${SOCKS_PROXY_PORT}
allow-lan: false
bind-address: 127.0.0.1
mode: direct
log-level: silent
authentication:
  - "integration_user:0123456789abcdef0123456789abcdef"
skip-auth-prefixes: []
rules:
  - MATCH,DIRECT
EOF

python3 -m http.server "$TARGET_PORT" --bind 127.0.0.1 --directory "$TMP_ROOT" \
    > "$TMP_ROOT/http.log" 2>&1 &
HTTP_SERVER_PID=$!
"$TMP_ROOT/mihomo" -d "$TMP_ROOT" > "$TMP_ROOT/mihomo.log" 2>&1 &
MIHOMO_PID=$!

http_code=""
for _ in {1..30}; do
    http_code="$(curl --noproxy '' --max-time 1 -s -o /dev/null -w '%{http_code}' \
        -x "http://127.0.0.1:${HTTP_PROXY_PORT}" "http://127.0.0.1:${TARGET_PORT}/" || true)"
    [[ "$http_code" == 407 ]] && break
    sleep 0.2
done
if [[ "$http_code" != 407 ]]; then
    echo "[FAIL] 无凭据 HTTP 请求未被拒绝（状态码：${http_code:-无}）。" >&2
    cat "$TMP_ROOT/mihomo.log" >&2
    exit 1
fi

authenticated_code="$(curl --noproxy '' --max-time 3 -s -o /dev/null -w '%{http_code}' \
    --proxy-user 'integration_user:0123456789abcdef0123456789abcdef' \
    -x "http://127.0.0.1:${HTTP_PROXY_PORT}" "http://127.0.0.1:${TARGET_PORT}/")"
[[ "$authenticated_code" == 200 ]] || {
    echo "[FAIL] 带凭据 HTTP 请求失败（状态码：$authenticated_code）。" >&2
    exit 1
}

if curl --noproxy '' --max-time 3 -s -o /dev/null \
    --proxy "socks5h://127.0.0.1:${SOCKS_PROXY_PORT}" "http://127.0.0.1:${TARGET_PORT}/"; then
    echo '[FAIL] 无凭据 SOCKS5 请求未被拒绝。' >&2
    exit 1
fi
curl --noproxy '' --max-time 3 -fsS -o /dev/null \
    --proxy "socks5h://integration_user:0123456789abcdef0123456789abcdef@127.0.0.1:${SOCKS_PROXY_PORT}" \
    "http://127.0.0.1:${TARGET_PORT}/"

echo '[PASS] Mihomo HTTP/SOCKS 认证集成测试通过。'
