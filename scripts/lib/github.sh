#!/usr/bin/env bash

# GitHub 下载镜像与超时配置，供两个安装入口和资源维护脚本共用。
# 资产下载优先镜像；Release 元数据优先官方，降低第三方元数据被篡改的风险。

GITHUB_MIRRORS=(
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghproxy.net/"
    "https://mirror.ghproxy.com/"
    ""
)
GITHUB_METADATA_MIRRORS=(
    ""
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghproxy.net/"
    "https://mirror.ghproxy.com/"
)

MIHOMO_CURL_CONNECT_TIMEOUT="${MIHOMO_CURL_CONNECT_TIMEOUT:-10}"
MIHOMO_CURL_METADATA_TIMEOUT="${MIHOMO_CURL_METADATA_TIMEOUT:-90}"
MIHOMO_CURL_DOWNLOAD_TIMEOUT="${MIHOMO_CURL_DOWNLOAD_TIMEOUT:-300}"

mihomo_validate_github_config() {
    local value
    for value in "$MIHOMO_CURL_CONNECT_TIMEOUT" "$MIHOMO_CURL_METADATA_TIMEOUT" "$MIHOMO_CURL_DOWNLOAD_TIMEOUT"; do
        if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
            echo "GitHub 下载超时必须是正整数秒：$value" >&2
            return 1
        fi
    done
}

mihomo_warn_mirror_metadata() {
    local mirror="$1"
    if [[ -n "$mirror" ]]; then
        echo "[WARN] GitHub 官方元数据不可用，正在使用第三方镜像提供的 Release 元数据：${mirror}" >&2
    fi
}
