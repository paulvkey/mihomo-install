#!/usr/bin/env bash

# 通过 GitHub 镜像更新安装脚本实际使用的 GeoIP 数据库。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$SCRIPT_DIR/Country.mmdb"
URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb"
GITHUB_MIRRORS=(
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghproxy.net/"
    "https://mirror.ghproxy.com/"
    ""
)
TEMP_FILE="$(mktemp "$SCRIPT_DIR/.Country.mmdb.XXXXXX")"
trap 'rm -f "$TEMP_FILE"' EXIT

for mirror in "${GITHUB_MIRRORS[@]}"; do
    candidate="${mirror}${URL}"
    echo "尝试下载最新 Country.mmdb：$candidate"
    if curl -fL --retry 2 --retry-all-errors --connect-timeout 10 --max-time 180 -o "$TEMP_FILE" "$candidate" \
        && [[ $(wc -c < "$TEMP_FILE") -gt 100000 ]]; then
        mv "$TEMP_FILE" "$OUTPUT"
        trap - EXIT
        echo "已更新：$OUTPUT"
        exit 0
    fi
    rm -f "$TEMP_FILE"
done

echo "所有镜像均无法下载有效的 Country.mmdb，原文件未修改。" >&2
exit 1
