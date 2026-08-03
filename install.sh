#!/usr/bin/env bash

# Mihomo 安装脚本
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
RESOURCE_DIR="$SCRIPT_DIR/resources"
COMMAND_SOURCE_DIR="$SCRIPT_DIR/scripts/commands"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
COUNTRY_FILE="$RESOURCE_DIR/Country.mmdb"
SELECT_SCRIPT="$COMMAND_SOURCE_DIR/clash_select.sh"
COMMON_SCRIPT="$COMMAND_SOURCE_DIR/common.sh"
CLASHON_SCRIPT="$COMMAND_SOURCE_DIR/clashon.sh"
CLASHOFF_SCRIPT="$COMMAND_SOURCE_DIR/clashoff.sh"
CLASH_RESTART_SCRIPT="$COMMAND_SOURCE_DIR/clash_restart.sh"
CLASH_STATUS_SCRIPT="$COMMAND_SOURCE_DIR/clash_status.sh"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/mihomo.service"
COMMAND_DIR="$HOME/.local/bin"
COMMAND_LIB_DIR="$HOME/.local/lib/mihomo-install"

# 镜像地址为 GitHub URL 前缀；最后的空字符串表示 GitHub 原始地址。
GITHUB_MIRRORS=(
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghproxy.net/"
    "https://mirror.ghproxy.com/"
    ""
)
# 校验元数据优先从 GitHub 原站获取；原站不可达时再尝试镜像。
GITHUB_METADATA_MIRRORS=(
    ""
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghproxy.net/"
    "https://mirror.ghproxy.com/"
)
CURL_RETRY_ARGS=(--retry 2)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 普通用户安装：所有文件均位于当前用户的家目录，不需要 sudo。
MIHOMO_DIR="$HOME/mihomo"

require_commands() {
    local command_name missing=0
    for command_name in bash curl gzip jq systemctl journalctl awk sed grep sort mktemp wc od tr; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            log_error "缺少依赖命令：$command_name"
            missing=1
        fi
    done
    if (( missing )); then
        log_error "依赖检查失败，尚未修改现有 Mihomo 安装"
        return 1
    fi
    if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
        log_warn "未找到 ss 或 netstat，将依赖启动日志检测端口冲突"
    fi
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        log_error "缺少 SHA256 校验工具：需要 sha256sum 或 shasum"
        return 1
    fi
    if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
        CURL_RETRY_ARGS+=(--retry-all-errors)
    fi
}

require_project_files() {
    local source_file
    for source_file in "$CONFIG_FILE" "$COMMON_SCRIPT" "$CLASHON_SCRIPT" "$CLASHOFF_SCRIPT" "$CLASH_RESTART_SCRIPT" "$CLASH_STATUS_SCRIPT" "$SELECT_SCRIPT"; do
        if [[ ! -f "$source_file" ]]; then
            log_error "项目文件缺失：$source_file"
            return 1
        fi
    done
}

ensure_x86_64() {
    if [[ "$(uname -m)" != "x86_64" ]]; then
        log_error "此安装脚本仅支持 x86_64，当前架构：$(uname -m)"
        exit 1
    fi
}

calculate_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

valid_gzip() {
    local file="$1" expected_sha="${2:-}" actual_sha
    [[ -f "$file" ]] && [[ $(wc -c < "$file") -gt 1000000 ]] && gzip -t "$file" 2>/dev/null || return 1
    if [[ -n "$expected_sha" ]]; then
        actual_sha="$(calculate_sha256 "$file")"
        [[ "$actual_sha" == "$expected_sha" ]] || return 1
    fi
}

download_file() {
    local url="$1" output="$2" description="$3" expected_sha="$4"
    local mirror candidate

    for mirror in "${GITHUB_MIRRORS[@]}"; do
        candidate="${mirror}${url}"
        log_info "尝试下载 ${description}：${candidate}"
        if curl -fL "${CURL_RETRY_ARGS[@]}" --connect-timeout 10 --max-time 180 -o "$output" "$candidate"; then
            if valid_gzip "$output" "$expected_sha"; then
                log_success "下载成功并通过 SHA256 校验：${description}"
                return 0
            fi
            log_warn "下载文件校验失败，尝试下一个镜像"
        fi
        rm -f "$output"
    done

    log_error "所有镜像均无法下载 ${description}"
    return 1
}

fetch_github_json() {
    local url="$1" mirror candidate response

    for mirror in "${GITHUB_METADATA_MIRRORS[@]}"; do
        candidate="${mirror}${url}"
        log_info "尝试查询 GitHub Release：${candidate}"
        if response="$(curl -fsSL "${CURL_RETRY_ARGS[@]}" --connect-timeout 10 --max-time 90 "$candidate")" \
            && grep -q '"browser_download_url"' <<< "$response"; then
            GITHUB_JSON="$response"
            return 0
        fi
    done

    log_error "所有镜像均无法查询 GitHub Release"
    return 1
}

# 仅选取 resources/bin/ 中的 AMD64 v2 构建；存在多个时取版本号最高者。
find_local_v2() {
    local candidates=()
    shopt -s nullglob
    candidates=("$RESOURCE_DIR/bin/mihomo-linux-amd64-v2-"*.gz)
    shopt -u nullglob
    ((${#candidates[@]})) || return 1
    printf '%s\n' "${candidates[@]}" | sort -V | tail -n 1
}

download_release() {
    local target_dir="$1" json url expected_digest expected_sha
    fetch_github_json "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" || return 1
    json="$GITHUB_JSON"
    url="$(jq -r '[.assets[] | select(.name | test("^mihomo-linux-amd64-v2-v[0-9].*\\.gz$"))][0].browser_download_url // empty' <<< "$json")"
    [[ -n "$url" ]] || { log_error "最新 Release 中没有 AMD64 的 gzip 资源"; return 1; }
    expected_digest="$(jq -r --arg url "$url" '.assets[] | select(.browser_download_url == $url) | .digest // empty' <<< "$json")"
    expected_sha="${expected_digest#sha256:}"
    if [[ ! "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
        log_error "GitHub Release 未提供有效 SHA256，拒绝安装未校验的核心"
        return 1
    fi

    DOWNLOADED_ARCHIVE="$(mktemp "$target_dir/.mihomo-download.XXXXXX.gz")"
    download_file "$url" "$DOWNLOADED_ARCHIVE" "最新 Mihomo 核心" "$expected_sha" || return 1
}

install_core() {
    local target_dir="$1" archive local_archive checksum_file expected_sha=""
    if local_archive="$(find_local_v2)"; then
        checksum_file="${local_archive}.sha256"
        if [[ -f "$checksum_file" ]]; then
            expected_sha="$(awk 'NR == 1 {print $1}' "$checksum_file")"
        fi
    fi
    if [[ -n "${local_archive:-}" ]] && [[ "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]] && valid_gzip "$local_archive" "$expected_sha"; then
        archive="$local_archive"
        log_info "使用已通过 SHA256 校验的本地资源：$(basename "$archive")"
    else
        [[ -n "${local_archive:-}" ]] && log_warn "本地资源缺少有效校验文件或校验失败，改为下载 GitHub Release"
        download_release "$target_dir" || return 1
        archive="$DOWNLOADED_ARCHIVE"
    fi
    if ! gzip -cd "$archive" > "$target_dir/mihomo"; then
        rm -f "$target_dir/mihomo"
        return 1
    fi
    chmod 755 "$target_dir/mihomo" || return 1
    [[ -n "${DOWNLOADED_ARCHIVE:-}" ]] && rm -f "$DOWNLOADED_ARCHIVE"
    log_success "Mihomo 核心已安装"
}

copy_if_present() {
    local source="$1" target="$2"
    if [[ -f "$source" ]]; then
        cp "$source" "$target" || return 1
        log_success "已复制 $(basename "$source")"
    else
        log_warn "未找到 $(basename "$source")，跳过复制"
    fi
}

# 用 mihomo 自带的 -t 做配置自检：只解析校验（executor.Parse），不启动服务、不联网拉订阅。
test_mihomo_config() {
    local config_dir="$1" core="$1/mihomo"
    if [[ ! -x "$core" ]]; then
        log_error "未找到可执行的 Mihomo 核心：$core"
        return 1
    fi
    if ! "$core" -t -d "$config_dir"; then
        log_error "配置自检未通过（mihomo -t -d ${config_dir}）"
        log_error "请检查 config.yaml 语法与规则是否合法"
        return 1
    fi
    log_success "Mihomo 配置自检通过"
}

port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnuH 2>/dev/null | awk -v port="$port" '$5 ~ ":" port "$" { found = 1 } END { exit !found }'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltnu 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" { found = 1 } END { exit !found }'
    else
        return 1
    fi
}

random_available_port() {
    local port candidate
    local -a chosen=("$@")
    for _ in {1..100}; do
        candidate=$((20000 + RANDOM % 40000))
        [[ " ${chosen[*]} " == *" $candidate "* ]] && continue
        if ! port_in_use "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    log_error "无法在 20000-59999 范围内找到可用端口"
    return 1
}

configure_random_ports() {
    local config="${1:-$MIHOMO_DIR/config.yaml}"
    local http_port socks_port controller_port dns_port
    [[ -f "$config" ]] || return 0

    http_port="$(random_available_port)" || return 1
    socks_port="$(random_available_port "$http_port")" || return 1
    controller_port="$(random_available_port "$http_port" "$socks_port")" || return 1
    dns_port="$(random_available_port "$http_port" "$socks_port" "$controller_port")" || return 1

    sed -i -E \
        -e "s/^port: [0-9]+$/port: $http_port/" \
        -e "s/^socks-port: [0-9]+$/socks-port: $socks_port/" \
        -e "s|^external-controller: 127\\.0\\.0\\.1:[0-9]+$|external-controller: 127.0.0.1:$controller_port|" \
        -e "s|^  listen: 127\\.0\\.0\\.1:[0-9]+$|  listen: 127.0.0.1:$dns_port|" \
        "$config" || return 1
    log_success "已分配本机随机端口：HTTP ${http_port}，SOCKS ${socks_port}，控制接口 ${controller_port}，DNS ${dns_port}"
}

generate_controller_secret() {
    od -An -N 32 -tx1 /dev/urandom | tr -d ' \n'
}

ensure_controller_secret() {
    local config="$1" controller_secret
    controller_secret="$(awk -F: '/^secret:/ {sub(/^[[:space:]]*/, "", $2); gsub(/^\"|\"$/, "", $2); print $2; exit}' "$config")"
    if [[ -n "$controller_secret" ]]; then
        return 0
    fi
    controller_secret="$(generate_controller_secret)" || return 1
    sed -i -E '/^secret:/d' "$config" || return 1
    sed -i -E "/^external-controller:/a secret: \"${controller_secret}\"" "$config" || return 1
    log_success "已为 Mihomo 控制接口生成随机认证密钥"
}

write_proxy_environment() {
    local http_port proxy_env_file="$MIHOMO_DIR/proxy.env"
    http_port="$(awk '/^port:/ {print $2; exit}' "$MIHOMO_DIR/config.yaml")"
    if [[ ! "$http_port" =~ ^[0-9]+$ ]]; then
        log_warn "无法从 config.yaml 读取 HTTP 代理端口，跳过代理环境文件生成"
        return 0
    fi

    umask 077
    cat > "$proxy_env_file" <<EOF
# Managed by mihomo-install. 此文件会由 clashon 自动按当前端口更新。
export http_proxy="http://127.0.0.1:${http_port}"
export https_proxy="http://127.0.0.1:${http_port}"
export HTTP_PROXY="http://127.0.0.1:${http_port}"
export HTTPS_PROXY="http://127.0.0.1:${http_port}"
EOF
}

prompt_subscription_url() {
    local url
    while true; do
        read -r -p "请输入 Clash/Mihomo 订阅链接（以 http:// 或 https:// 开头）: " url
        if [[ "$url" =~ ^https?:// ]]; then
            SUBSCRIPTION_URL="$url"
            return 0
        fi
        log_warn "订阅链接格式无效，请重新输入"
    done
}

write_subscription_url() {
    local config="${1:-$MIHOMO_DIR/config.yaml}" escaped_url
    escaped_url="$(printf '%s' "$SUBSCRIPTION_URL" | sed 's/[\\&|"]/\\&/g')"
    sed -i -E "s|^    url:.*$|    url: \"$escaped_url\"|" "$config" || return 1
}

write_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Daemon
After=network.target

[Service]
Type=simple
WorkingDirectory=$MIHOMO_DIR
ExecStart=$MIHOMO_DIR/mihomo -d $MIHOMO_DIR
Restart=on-failure
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=default.target
EOF
}

is_port_binding_failure() {
    local service_log="$1"
    grep -Eqi 'address already in use|bind.*(failed|error|in use)|EADDRINUSE|port.*in use' <<< "$service_log"
}

wait_for_service_stable() {
    local check
    for check in 1 2 3; do
        systemctl --user is-active --quiet mihomo || return 1
        sleep 1
    done
}

start_service_with_port_retries() {
    local attempt service_log

    if ! systemctl --user daemon-reload; then
        log_error "无法重载用户 systemd 配置"
        log_error "请确认当前会话支持 systemctl --user 后重试"
        return 1
    fi
    if ! systemctl --user enable mihomo; then
        log_error "无法启用 mihomo 用户服务"
        return 1
    fi

    for attempt in 1 2 3; do
        systemctl --user restart mihomo >/dev/null 2>&1 || true
        if wait_for_service_stable; then
            log_success "mihomo 用户服务已启用并启动"
            return 0
        fi

        service_log="$(journalctl --user -u mihomo -n 50 --no-pager 2>&1 || true)"
        if is_port_binding_failure "$service_log" && (( attempt < 3 )); then
            log_warn "服务因端口绑定失败未能启动（第 $attempt/3 次），正在重新分配端口后重试..."
            systemctl --user stop mihomo >/dev/null 2>&1 || true
            configure_random_ports || return 1
            continue
        fi

        if is_port_binding_failure "$service_log"; then
            log_error "已尝试 3 组随机端口，服务仍因端口绑定失败无法启动"
        else
            log_error "mihomo 服务启动失败，原因不是可自动恢复的端口绑定冲突"
        fi
        log_error "请查看日志：journalctl --user -u mihomo -n 50 --no-pager"
        return 1
    done
}

create_service_commands() {
    local source_file
    mkdir -p "$COMMAND_DIR" "$COMMAND_LIB_DIR"

    for source_file in "$COMMON_SCRIPT" "$CLASHON_SCRIPT" "$CLASHOFF_SCRIPT" "$CLASH_RESTART_SCRIPT" "$CLASH_STATUS_SCRIPT" "$SELECT_SCRIPT"; do
        if [[ ! -f "$source_file" ]]; then
            log_error "未找到管理命令源文件：$source_file"
            return 1
        fi
    done

    cp "$COMMON_SCRIPT" "$COMMAND_LIB_DIR/common.sh" || return 1
    cp "$CLASHON_SCRIPT" "$COMMAND_DIR/clashon" || return 1
    cp "$CLASHOFF_SCRIPT" "$COMMAND_DIR/clashoff" || return 1
    cp "$CLASH_RESTART_SCRIPT" "$COMMAND_DIR/clash_restart" || return 1
    cp "$CLASH_STATUS_SCRIPT" "$COMMAND_DIR/clash_status" || return 1
    cp "$SELECT_SCRIPT" "$COMMAND_DIR/clash_select" || return 1
    chmod 644 "$COMMAND_LIB_DIR/common.sh" || return 1
    chmod 755 "$COMMAND_DIR/clashon" "$COMMAND_DIR/clashoff" "$COMMAND_DIR/clash_restart" "$COMMAND_DIR/clash_status" "$COMMAND_DIR/clash_select" || return 1
    log_success "已创建命令：clashon、clashoff、clash_restart、clash_status、clash_select"
}

configure_command_path() {
    local bashrc_file="$HOME/.bashrc"
    local path_line='export PATH="$HOME/.local/bin:$PATH"'
    local proxy_marker='# >>> mihomo-install proxy environment >>>'
    local temp_file

    touch "$bashrc_file"
    if ! grep -Fqx "$path_line" "$bashrc_file"; then
        printf '\n# Mihomo user commands\n%s\n' "$path_line" >> "$bashrc_file"
        log_success "已将 ~/.local/bin 添加到 $bashrc_file"
    fi
    if grep -Fqx "$proxy_marker" "$bashrc_file"; then
        temp_file="$(mktemp "$HOME/.bashrc.mihomo.XXXXXX")"
        awk '
            /^# >>> mihomo-install proxy environment >>>$/ { skip = 1; next }
            /^# <<< mihomo-install proxy environment <<<$/ { skip = 0; next }
            !skip { print }
        ' "$bashrc_file" > "$temp_file"
        cat "$temp_file" > "$bashrc_file"
        rm -f "$temp_file"
    fi

    cat >> "$bashrc_file" <<'EOF'

# >>> mihomo-install proxy environment >>>
# 仅当 Mihomo 服务确实运行时，新终端才加载代理环境。
if systemctl --user is-active --quiet mihomo 2>/dev/null && [[ -r "$HOME/mihomo/proxy.env" ]]; then
    source "$HOME/mihomo/proxy.env"
else
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
fi

clashon() {
    command "$HOME/.local/bin/clashon" "$@" || return $?
    [[ -r "$HOME/mihomo/proxy.env" ]] && source "$HOME/mihomo/proxy.env"
}

clash_restart() {
    command "$HOME/.local/bin/clash_restart" "$@" || return $?
    [[ -r "$HOME/mihomo/proxy.env" ]] && source "$HOME/mihomo/proxy.env"
}

clashoff() {
    command "$HOME/.local/bin/clashoff" "$@" || return $?
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
}
# <<< mihomo-install proxy environment <<<
EOF
    log_success "已更新 clashon 自动代理环境配置"
}

cleanup_install_temp() {
    local temp_path="$1"
    [[ -n "$temp_path" ]] || return 0
    case "$temp_path" in
        "$HOME"/.mihomo-install-stage.*|"$HOME"/.mihomo-install-backup.*)
            rm -rf -- "$temp_path"
            ;;
        *)
            log_warn "拒绝清理非预期临时目录：$temp_path"
            ;;
    esac
}

prepare_staging_install() {
    install_core "$STAGING_DIR" || return 1

    if [[ "$UPDATE_CONFIG" == true ]]; then
        copy_if_present "$CONFIG_FILE" "$STAGING_DIR/config.yaml"
        [[ -f "$STAGING_DIR/config.yaml" ]] || return 1
        write_subscription_url "$STAGING_DIR/config.yaml" || return 1
        configure_random_ports "$STAGING_DIR/config.yaml" || return 1
    else
        cp -a "$MIHOMO_DIR/config.yaml" "$STAGING_DIR/config.yaml" || return 1
    fi

    if [[ -d "$MIHOMO_DIR/providers" ]]; then
        cp -a "$MIHOMO_DIR/providers" "$STAGING_DIR/providers" || return 1
    fi
    if [[ -f "$COUNTRY_FILE" && -f "${COUNTRY_FILE}.sha256" ]]; then
        local country_expected_sha country_actual_sha
        country_expected_sha="$(awk 'NR == 1 {print $1}' "${COUNTRY_FILE}.sha256")"
        country_actual_sha="$(calculate_sha256 "$COUNTRY_FILE")"
        if [[ "$country_expected_sha" == "$country_actual_sha" ]]; then
            cp "$COUNTRY_FILE" "$STAGING_DIR/Country.mmdb" || return 1
        else
            log_warn "Country.mmdb SHA256 校验失败，本次不更新 GeoIP 数据库"
        fi
    elif [[ -f "$MIHOMO_DIR/Country.mmdb" ]]; then
        cp -a "$MIHOMO_DIR/Country.mmdb" "$STAGING_DIR/Country.mmdb" || return 1
    fi

    ensure_controller_secret "$STAGING_DIR/config.yaml" || return 1
    chmod 600 "$STAGING_DIR/config.yaml" || return 1
    test_mihomo_config "$STAGING_DIR"
}

snapshot_current_install() {
    local item
    BACKUP_DIR="$(mktemp -d "$HOME/.mihomo-install-backup.XXXXXX")" || return 1
    for item in mihomo config.yaml Country.mmdb; do
        if [[ -e "$MIHOMO_DIR/$item" ]]; then
            cp -a "$MIHOMO_DIR/$item" "$BACKUP_DIR/$item" || return 1
        fi
    done
    if [[ -f "$SERVICE_FILE" ]]; then
        cp -a "$SERVICE_FILE" "$BACKUP_DIR/mihomo.service" || return 1
    fi
    if systemctl --user is-active --quiet mihomo; then
        SERVICE_WAS_ACTIVE=true
    else
        SERVICE_WAS_ACTIVE=false
    fi
    if systemctl --user is-enabled --quiet mihomo 2>/dev/null; then
        SERVICE_WAS_ENABLED=true
    else
        SERVICE_WAS_ENABLED=false
    fi
}

rollback_install() {
    local item
    log_warn "正在恢复安装前的核心、配置和服务状态..."
    systemctl --user stop mihomo >/dev/null 2>&1 || true
    for item in mihomo config.yaml Country.mmdb; do
        rm -f "$MIHOMO_DIR/$item"
        if [[ -e "$BACKUP_DIR/$item" ]]; then
            cp -a "$BACKUP_DIR/$item" "$MIHOMO_DIR/$item"
        fi
    done
    if [[ "$SERVICE_WAS_ENABLED" != true ]]; then
        systemctl --user disable mihomo >/dev/null 2>&1 || true
    fi
    rm -f "$SERVICE_FILE"
    if [[ -f "$BACKUP_DIR/mihomo.service" ]]; then
        cp -a "$BACKUP_DIR/mihomo.service" "$SERVICE_FILE"
    fi
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if [[ "$SERVICE_WAS_ACTIVE" == true ]]; then
        systemctl --user start mihomo >/dev/null 2>&1 || log_warn "旧服务恢复后未能自动启动，请手动检查"
    fi
    log_warn "已回滚到安装前状态"
}

commit_staged_install() {
    snapshot_current_install || return 1
    systemctl --user stop mihomo >/dev/null 2>&1 || true
    mkdir -p "$MIHOMO_DIR" "$SERVICE_DIR" || return 1
    chmod 700 "$MIHOMO_DIR" || return 1

    mv -f "$STAGING_DIR/mihomo" "$MIHOMO_DIR/.mihomo.new" || return 1
    chmod 755 "$MIHOMO_DIR/.mihomo.new" || return 1
    mv -f "$MIHOMO_DIR/.mihomo.new" "$MIHOMO_DIR/mihomo" || return 1

    mv -f "$STAGING_DIR/config.yaml" "$MIHOMO_DIR/.config.yaml.new" || return 1
    chmod 600 "$MIHOMO_DIR/.config.yaml.new" || return 1
    mv -f "$MIHOMO_DIR/.config.yaml.new" "$MIHOMO_DIR/config.yaml" || return 1

    if [[ -f "$STAGING_DIR/Country.mmdb" ]]; then
        mv -f "$STAGING_DIR/Country.mmdb" "$MIHOMO_DIR/Country.mmdb" || return 1
        chmod 644 "$MIHOMO_DIR/Country.mmdb" || return 1
    fi
    write_service || return 1
    start_service_with_port_retries
}

main() {
    local choice

    STAGING_DIR=""
    BACKUP_DIR=""
    SERVICE_WAS_ACTIVE=false
    SERVICE_WAS_ENABLED=false

    ensure_x86_64
    require_commands
    require_project_files

    if [[ -d "$MIHOMO_DIR" ]]; then
        read -r -p "$MIHOMO_DIR 已存在，是否继续更新 Mihomo 核心？[y/N]: " choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log_info "安装已取消"
            return 0
        fi
    fi

    UPDATE_CONFIG=false
    if [[ -f "$MIHOMO_DIR/config.yaml" ]]; then
        read -r -p "检测到已有 config.yaml，是否覆盖？[y/N]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            UPDATE_CONFIG=true
        else
            log_info "保留现有 config.yaml，不会修改订阅链接或端口"
        fi
    else
        UPDATE_CONFIG=true
    fi

    if [[ "$UPDATE_CONFIG" == true ]]; then
        prompt_subscription_url
    fi

    STAGING_DIR="$(mktemp -d "$HOME/.mihomo-install-stage.XXXXXX")"
    trap 'cleanup_install_temp "${STAGING_DIR:-}"; cleanup_install_temp "${BACKUP_DIR:-}"' EXIT

    if ! prepare_staging_install; then
        log_error "安装未开始：暂存核心或配置自检失败，现有服务未被修改"
        return 1
    fi

    if ! commit_staged_install; then
        if [[ -n "$BACKUP_DIR" ]]; then
            rollback_install
        fi
        log_error "安装失败，已恢复安装前状态"
        return 1
    fi
    write_proxy_environment
    if ! create_service_commands; then
        return 1
    fi
    configure_command_path
    if [[ -t 0 ]]; then
        "$COMMAND_DIR/clash_select" || log_warn "首次节点选择未完成，稍后可执行 clash_select"
    fi

    echo
    log_success "安装完成：$MIHOMO_DIR \n"
    log_info "配置文件：$MIHOMO_DIR/config.yaml"
    log_info "服务管理：clashon（服务启动）、clashoff（服务关闭）、clash_select（订阅节点选择）、clash_restart（服务重启）、clash_status（服务状态） \n"
    log_info "安装完成请执行 source ~/.bashrc && curl -I https://www.google.com 命令来加载并验证是否成功\n"
}

main "$@"
