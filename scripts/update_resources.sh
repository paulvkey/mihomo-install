#!/usr/bin/env bash

# 更新安装脚本使用的资源：
#   1) GeoIP 数据库（Country.mmdb，来自 meta-rules-dat）
#   2) resources/bin/ 下的 mihomo 核心安装包（可指定版本，前后缀自动补齐）
# 下载失败时保留原有文件，不会破坏已有资源。

set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCE_DIR="$PROJECT_DIR/resources"
BIN_DIR="$RESOURCE_DIR/bin"
GEOIP_OUTPUT="$RESOURCE_DIR/Country.mmdb"
GEOIP_RELEASE_API="https://api.github.com/repos/MetaCubeX/meta-rules-dat/releases/tags/latest"
# bin 包命名规则：前缀 + 版本号 + 后缀，脚本自动拼接
BIN_PREFIX="mihomo-linux-amd64-v2-v"
BIN_SUFFIX=".gz"
RELEASE_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
RELEASE_PAGE="https://github.com/MetaCubeX/mihomo/releases/latest"

# 镜像地址为 GitHub URL 前缀；最后的空字符串表示 GitHub 原始地址。
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
CURL_RETRY_ARGS=(--retry 2)
RESOURCE_TEMP_FILE=""

log_info()   { echo "[INFO] $*"; }
log_warn()   { echo "[WARN] $*" >&2; }
log_error()  { echo "[ERROR] $*" >&2; }
log_success(){ echo "[SUCCESS] $*"; }

require_commands() {
    local command_name missing=0
    for command_name in curl gzip jq awk sed grep mktemp wc; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            log_error "缺少依赖命令：$command_name"
            missing=1
        fi
    done
    (( missing == 0 )) || return 1
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        log_error "缺少 SHA256 校验工具：需要 sha256sum 或 shasum"
        return 1
    fi
    if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
        CURL_RETRY_ARGS+=(--retry-all-errors)
    fi
}

calculate_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

usage() {
    cat <<EOF
用法: $(basename "$0") [选项] [版本]

选项:
  -g, --geoip       仅更新 GeoIP 数据库（Country.mmdb）
  -b, --bin [版本]  更新 resources/bin/ 下的 mihomo 核心安装包；
                    版本号可省略，省略时自动获取 GitHub 最新 Release
  -a, --all         同时更新 GeoIP 与 mihomo 核心包（核心取最新版）
  -h, --help        显示本帮助

版本写法:
  直接写版本号即可，脚本自动补齐前后缀，例如:
    bash scripts/update_resources.sh 1.19.29
    等价于下载 resources/bin/${BIN_PREFIX}1.19.29${BIN_SUFFIX}，
    并删除 resources/bin/ 下其他 v2 系列安装包（install.sh 会按版本号取最高者）。
    也可写成 v1.19.29，脚本会自动去掉前导 v。

  不带任何参数时，默认仅更新 GeoIP 数据库（保持原行为）。
EOF
}

# 去掉可能的前导 v，并校验为 数字.数字.数字 格式
normalize_version() {
    local v="${1#v}"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

valid_geoip() {
    local file="$1" expected_sha="$2" actual_sha
    [[ -f "$file" ]] && [[ $(wc -c < "$file") -gt 100000 ]] || return 1
    actual_sha="$(calculate_sha256 "$file")"
    [[ "$actual_sha" == "$expected_sha" ]]
}

valid_bin() {
    local file="$1" version="$2" expected_sha="$3" actual_sha
    [[ -f "$file" ]] || return 1
    [[ $(wc -c < "$file") -gt 1000000 ]] || return 1
    gzip -t "$file" 2>/dev/null || return 1
    actual_sha="$(calculate_sha256 "$file")"
    [[ "$actual_sha" == "$expected_sha" ]] || return 1
    # 解压后再确认二进制内含目标版本号，防止下错资产。
    # 注意：不能用 grep -q（提前退出会让 gzip 收到 SIGPIPE，pipefail 下误判失败）。
    gzip -dc "$file" 2>/dev/null | grep -aF "v${version}" >/dev/null
}

download_via_mirrors() {
    local url="$1" output="$2" description="$3" kind="$4" version="$5" expected_sha="${6:-}"
    local mirror candidate
    for mirror in "${GITHUB_MIRRORS[@]}"; do
        candidate="${mirror}${url}"
        log_info "尝试下载 ${description}：${candidate}"
        if curl -fL "${CURL_RETRY_ARGS[@]}" --connect-timeout 10 --max-time 300 -o "$output" "$candidate"; then
            if [[ "$kind" == geoip ]] && valid_geoip "$output" "$expected_sha"; then
                log_success "下载成功：${description}"
                return 0
            fi
            if [[ "$kind" == bin ]] && valid_bin "$output" "$version" "$expected_sha"; then
                log_success "下载成功：${description}"
                return 0
            fi
            log_warn "下载内容校验失败，尝试下一个镜像"
        fi
        rm -f "$output"
    done
    log_error "所有镜像均无法下载 ${description}"
    return 1
}

update_geoip() {
    local temp_file metadata asset_url expected_sha
    metadata="$(get_geoip_release_metadata)" || return 1
    IFS=$'\t' read -r asset_url expected_sha <<< "$metadata"
    mkdir -p "$RESOURCE_DIR" || return 1
    temp_file="$(mktemp "$RESOURCE_DIR/.Country.mmdb.XXXXXX")" || return 1
    RESOURCE_TEMP_FILE="$temp_file"
    trap 'rm -f "${RESOURCE_TEMP_FILE:-}"' EXIT
    if download_via_mirrors "$asset_url" "$temp_file" "最新 Country.mmdb" geoip "" "$expected_sha"; then
        mv "$temp_file" "$GEOIP_OUTPUT" || return 1
        printf '%s  %s\n' "$expected_sha" "$(basename "$GEOIP_OUTPUT")" > "${GEOIP_OUTPUT}.sha256" || return 1
        chmod 644 "${GEOIP_OUTPUT}.sha256" || return 1
        trap - EXIT
        RESOURCE_TEMP_FILE=""
        log_success "已更新：$GEOIP_OUTPUT"
        return 0
    fi
    trap - EXIT
    RESOURCE_TEMP_FILE=""
    log_error "GeoIP 数据库更新失败，原文件未修改"
    return 1
}

get_geoip_release_metadata() {
    local mirror response asset_url digest expected_sha
    for mirror in "${GITHUB_METADATA_MIRRORS[@]}"; do
        if response="$(curl -fsSL "${CURL_RETRY_ARGS[@]}" --connect-timeout 10 --max-time 90 "${mirror}${GEOIP_RELEASE_API}" 2>/dev/null)"; then
            asset_url="$(jq -r '.assets[] | select(.name == "country.mmdb") | .browser_download_url // empty' <<< "$response")"
            digest="$(jq -r '.assets[] | select(.name == "country.mmdb") | .digest // empty' <<< "$response")"
            expected_sha="${digest#sha256:}"
            if [[ -n "$asset_url" && "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
                printf '%s\t%s\n' "$asset_url" "$expected_sha"
                return 0
            fi
        fi
    done
    log_error "无法获取 Country.mmdb 的官方下载地址和 SHA256"
    return 1
}

get_latest_version() {
    local mirror version response html
    for mirror in "${GITHUB_METADATA_MIRRORS[@]}"; do
        # 优先走 GitHub API
        if response="$(curl -fsSL "${CURL_RETRY_ARGS[@]}" --connect-timeout 10 --max-time 90 "${mirror}${RELEASE_API}" 2>/dev/null)" \
            && grep -q '"tag_name"' <<< "$response"; then
            version="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$response" | head -n 1)"
            if [[ -n "$version" ]] && normalize_version "$version"; then
                echo "$version"
                return 0
            fi
        fi
        # API 不可用（限流等）时，退化为解析 releases/latest 页面
        if html="$(curl -fsSL "${CURL_RETRY_ARGS[@]}" --connect-timeout 10 --max-time 90 "${mirror}${RELEASE_PAGE}" 2>/dev/null)" \
            && grep -q 'releases/tag/v' <<< "$html"; then
            version="$(grep -oE 'releases/tag/v[0-9][^"&]*' <<< "$html" | head -n 1 | sed 's|releases/tag/||')"
            if [[ -n "$version" ]] && normalize_version "$version"; then
                echo "$version"
                return 0
            fi
        fi
    done
    log_error "无法获取 mihomo 最新版本号"
    return 1
}

get_bin_release_metadata() {
    local version="$1" mirror response asset_url digest expected_sha
    for mirror in "${GITHUB_METADATA_MIRRORS[@]}"; do
        if response="$(curl -fsSL "${CURL_RETRY_ARGS[@]}" --connect-timeout 10 --max-time 90 "${mirror}https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/v${version}" 2>/dev/null)"; then
            asset_url="$(jq -r --arg name "${BIN_PREFIX}${version}${BIN_SUFFIX}" '.assets[] | select(.name == $name) | .browser_download_url // empty' <<< "$response")"
            digest="$(jq -r --arg name "${BIN_PREFIX}${version}${BIN_SUFFIX}" '.assets[] | select(.name == $name) | .digest // empty' <<< "$response")"
            expected_sha="${digest#sha256:}"
            if [[ -n "$asset_url" && "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
                printf '%s\t%s\n' "$asset_url" "$expected_sha"
                return 0
            fi
        fi
    done
    log_error "无法获取 mihomo v${version} 的官方下载地址和 SHA256"
    return 1
}

update_bin() {
    local version="${1#v}"          # 去掉可能的前导 v
    local asset="${BIN_PREFIX}${version}${BIN_SUFFIX}"
    local temp_file old removed=0 metadata asset_url expected_sha

    log_info "目标安装包：$asset"
    metadata="$(get_bin_release_metadata "$version")" || return 1
    IFS=$'\t' read -r asset_url expected_sha <<< "$metadata"
    mkdir -p "$BIN_DIR" || return 1
    temp_file="$(mktemp "$BIN_DIR/.mihomo-download.XXXXXX.gz")" || return 1
    RESOURCE_TEMP_FILE="$temp_file"
    trap 'rm -f "${RESOURCE_TEMP_FILE:-}"' EXIT
    if download_via_mirrors \
        "$asset_url" "$temp_file" "mihomo 核心 v${version}" bin "$version" "$expected_sha"; then

        # 删除同系列旧安装包，只保留本次版本
        shopt -s nullglob
        for old in "$BIN_DIR"/mihomo-linux-amd64-v2-*.gz; do
            [[ "$(basename "$old")" == "$asset" ]] && continue
            rm -f "$old"
            rm -f "${old}.sha256"
            log_info "已移除旧安装包：$(basename "$old")"
            removed=1
        done
        shopt -u nullglob

        mv "$temp_file" "$BIN_DIR/$asset" || return 1
        chmod 644 "$BIN_DIR/$asset" || return 1
        printf '%s  %s\n' "$expected_sha" "$asset" > "$BIN_DIR/${asset}.sha256" || return 1
        chmod 644 "$BIN_DIR/${asset}.sha256" || return 1
        trap - EXIT
        RESOURCE_TEMP_FILE=""
        log_success "已更新：$BIN_DIR/$asset"
        [[ "$removed" == 1 ]] && log_info "resources/bin/ 目录现仅保留 $(basename "$asset")"
        return 0
    fi
    trap - EXIT
    RESOURCE_TEMP_FILE=""
    log_error "mihomo 核心包更新失败，resources/bin/ 原有文件未修改"
    return 1
}

main() {
    local opt_geoip=false opt_bin=false bin_version=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -g|--geoip) opt_geoip=true; shift ;;
            -b|--bin)
                opt_bin=true; shift
                if [[ $# -gt 0 && "$1" != -* && "$1" =~ ^[0-9v] ]]; then
                    bin_version="$1"; shift
                fi
                ;;
            -a|--all) opt_geoip=true; opt_bin=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *)
                # 裸版本号作为位置参数：等价于 --bin <版本>
                if [[ "$1" =~ ^[0-9v] ]]; then
                    opt_bin=true; bin_version="$1"; shift
                else
                    log_error "未知参数：$1"
                    usage >&2
                    exit 1
                fi
                ;;
        esac
    done

    require_commands

    # 不带参数时保持原行为：仅更新 GeoIP
    if ! $opt_geoip && ! $opt_bin; then
        opt_geoip=true
    fi

    local rc=0

    if $opt_bin; then
        if [[ -z "$bin_version" ]]; then
            log_info "未指定版本，正在获取 GitHub 最新 Release..."
            bin_version="$(get_latest_version)" || rc=1
        fi
        if [[ -n "$bin_version" ]]; then
            if normalize_version "$bin_version"; then
                update_bin "$bin_version" || rc=1
            else
                log_error "无效版本号：${bin_version}（应为 数字.数字.数字 格式）"
                rc=1
            fi
        fi
    fi

    if $opt_geoip; then
        update_geoip || rc=1
    fi

    if [[ "$rc" == 0 ]]; then
        log_success "全部更新完成"
    else
        log_error "部分资源更新失败，请检查网络或镜像可用性"
    fi
    return "$rc"
}

main "$@"
