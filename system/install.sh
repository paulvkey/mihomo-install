#!/usr/bin/env bash

# Mihomo 系统级共享安装脚本。不会修改任何用户的 ~/mihomo 或 systemctl --user 服务。
set -Eeuo pipefail
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

SYSTEM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SYSTEM_DIR/.." && pwd)"
CONFIG_TEMPLATE="$PROJECT_DIR/config/config.yaml"
RESOURCE_DIR="$PROJECT_DIR/resources"
COMMAND_SOURCE="$SYSTEM_DIR/commands/clashsys.sh"
PROFILE_SOURCE="$SYSTEM_DIR/profile.d/mihomo-system.sh"
AUTO_PROFILE_SOURCE="$SYSTEM_DIR/profile.d/zz-mihomo-system-auto.sh"
SERVICE_SOURCE="$SYSTEM_DIR/mihomo-system.service"
SUDOERS_SOURCE="$SYSTEM_DIR/sudoers/mihomo-system"

SERVICE_USER="mihomo"
SERVICE_GROUP="mihomo"
CONTROL_GROUP="mihomo-control"
CORE_DIR="/usr/local/lib/mihomo"
CORE_FILE="$CORE_DIR/mihomo"
CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
PROXY_ENV_FILE="$CONFIG_DIR/proxy.env"
MANAGED_MARKER="$CONFIG_DIR/.managed-by-mihomo-install"
STATE_DIR="/var/lib/mihomo"
SERVICE_FILE="/etc/systemd/system/mihomo-system.service"
COMMAND_FILE="/usr/local/bin/clashsys"
PROFILE_FILE="/etc/profile.d/mihomo-system.sh"
AUTO_PROFILE_FILE="/etc/profile.d/zz-mihomo-system-auto.sh"
SUDOERS_FILE="/etc/sudoers.d/mihomo-system"
SERVICE_NAME="mihomo-system.service"

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
DOWNLOADED_ARCHIVE=""
STAGING_DIR=""
BACKUP_DIR=""
SERVICE_WAS_ACTIVE=false
SERVICE_WAS_ENABLED=false
COMMIT_STARTED=false
CONTROL_USERS_INPUT=""
CONTROL_USERS_ADDED=""
AUTO_ENABLE_SYSTEM_PROXY=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

require_root_linux() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        log_error "系统级安装仅支持 Linux"
        return 1
    fi
    if [[ "$(uname -m)" != "x86_64" ]]; then
        log_error "系统级安装仅支持 x86_64，当前架构：$(uname -m)"
        return 1
    fi
    if ((EUID != 0)); then
        log_error "系统级安装需要管理员权限，请执行：sudo bash system/install.sh"
        return 1
    fi
}

require_commands() {
    local command_name missing=0
    for command_name in bash curl gzip jq systemctl journalctl awk sed grep sort mktemp wc od tr \
        getent groupadd useradd usermod install sudo visudo; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            log_error "缺少依赖命令：$command_name"
            missing=1
        fi
    done
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        log_error "缺少 SHA256 校验工具：需要 sha256sum 或 shasum"
        missing=1
    fi
    if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
        log_error "系统级安装需要 ss 或 netstat 检查共享端口"
        missing=1
    fi
    ((missing == 0)) || return 1
    if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
        CURL_RETRY_ARGS+=(--retry-all-errors)
    fi
}

require_project_files() {
    local file
    for file in "$CONFIG_TEMPLATE" "$COMMAND_SOURCE" "$PROFILE_SOURCE" "$AUTO_PROFILE_SOURCE" "$SERVICE_SOURCE" "$SUDOERS_SOURCE"; do
        if [[ ! -f "$file" ]]; then
            log_error "项目文件缺失：$file"
            return 1
        fi
    done
    if ! visudo -cf "$SUDOERS_SOURCE" >/dev/null; then
        log_error "sudoers 模板校验失败：$SUDOERS_SOURCE"
        return 1
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
    local file="$1" expected_sha="$2" actual_sha
    [[ -f "$file" ]] && [[ $(wc -c < "$file") -gt 1000000 ]] && gzip -t "$file" 2>/dev/null || return 1
    actual_sha="$(calculate_sha256 "$file")"
    [[ "$actual_sha" == "$expected_sha" ]]
}

fetch_release_json() {
    local url="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    local mirror response
    for mirror in "${GITHUB_METADATA_MIRRORS[@]}"; do
        log_info "尝试查询 Mihomo Release：${mirror}${url}"
        if response="$(curl -fsSL "${CURL_RETRY_ARGS[@]}" --connect-timeout 10 --max-time 90 "${mirror}${url}")" \
            && grep -q '"browser_download_url"' <<< "$response"; then
            RELEASE_JSON="$response"
            return 0
        fi
    done
    log_error "无法查询 Mihomo 最新 Release"
    return 1
}

download_core() {
    local target_dir="$1" url digest expected_sha mirror candidate
    fetch_release_json || return 1
    url="$(jq -r '[.assets[] | select(.name | test("^mihomo-linux-amd64-v2-v[0-9].*\\.gz$"))][0].browser_download_url // empty' <<< "$RELEASE_JSON")"
    digest="$(jq -r --arg url "$url" '.assets[] | select(.browser_download_url == $url) | .digest // empty' <<< "$RELEASE_JSON")"
    expected_sha="${digest#sha256:}"
    if [[ -z "$url" || ! "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
        log_error "Release 没有提供可校验的 AMD64 v2 gzip 资源"
        return 1
    fi

    DOWNLOADED_ARCHIVE="$(mktemp "$target_dir/.mihomo-download.XXXXXX.gz")"
    for mirror in "${GITHUB_MIRRORS[@]}"; do
        candidate="${mirror}${url}"
        log_info "尝试下载系统核心：$candidate"
        if curl -fL "${CURL_RETRY_ARGS[@]}" --connect-timeout 10 --max-time 300 -o "$DOWNLOADED_ARCHIVE" "$candidate" \
            && valid_gzip "$DOWNLOADED_ARCHIVE" "$expected_sha"; then
            log_success "系统核心下载完成并通过 SHA256 校验"
            return 0
        fi
        rm -f "$DOWNLOADED_ARCHIVE"
        DOWNLOADED_ARCHIVE="$(mktemp "$target_dir/.mihomo-download.XXXXXX.gz")"
    done
    log_error "所有镜像均无法下载系统核心"
    return 1
}

find_local_core() {
    local candidates=()
    shopt -s nullglob
    candidates=("$RESOURCE_DIR/bin/mihomo-linux-amd64-v2-"*.gz)
    shopt -u nullglob
    [[ -n "${candidates[0]:-}" ]] || return 1
    printf '%s\n' "${candidates[@]}" | sort -V | tail -n 1
}

install_core_to_staging() {
    local local_archive="" archive="" checksum_file="" expected_sha=""
    if local_archive="$(find_local_core)"; then
        checksum_file="${local_archive}.sha256"
        [[ -f "$checksum_file" ]] && expected_sha="$(awk 'NR == 1 {print $1}' "$checksum_file")"
    fi
    if [[ -n "$local_archive" && "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]] \
        && valid_gzip "$local_archive" "$expected_sha"; then
        archive="$local_archive"
        log_info "使用本地系统核心：$(basename "$archive")"
    else
        [[ -n "$local_archive" ]] && log_warn "本地核心校验失败，改为下载最新 Release"
        download_core "$STAGING_DIR" || return 1
        archive="$DOWNLOADED_ARCHIVE"
    fi
    gzip -cd "$archive" > "$STAGING_DIR/mihomo" || return 1
    chmod 755 "$STAGING_DIR/mihomo" || return 1
}

port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnuH 2>/dev/null | awk -v port="$port" '$5 ~ ":" port "$" {found = 1} END {exit !found}'
    else
        netstat -ltnu 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" {found = 1} END {exit !found}'
    fi
}

random_available_port() {
    local candidate selected_port already_chosen
    for _ in {1..200}; do
        # 与个人模式的 20000-59999 分开，避免服务先后启动时发生跨模式端口冲突。
        candidate=$((10000 + RANDOM % 10000))
        already_chosen=false
        for selected_port in "$@"; do
            if [[ "$selected_port" == "$candidate" ]]; then
                already_chosen=true
                break
            fi
        done
        [[ "$already_chosen" == true ]] && continue
        if ! port_in_use "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    log_error "无法在 10000-19999 范围内为系统服务分配可用端口"
    return 1
}

configure_random_ports() {
    local config="$1" http_port socks_port controller_port dns_port temp_file
    http_port="$(random_available_port)" || return 1
    socks_port="$(random_available_port "$http_port")" || return 1
    controller_port="$(random_available_port "$http_port" "$socks_port")" || return 1
    dns_port="$(random_available_port "$http_port" "$socks_port" "$controller_port")" || return 1
    temp_file="$(mktemp "${config}.ports.XXXXXX")" || return 1
    if ! awk \
        -v http_port="$http_port" \
        -v socks_port="$socks_port" \
        -v controller_port="$controller_port" \
        -v dns_port="$dns_port" '
        /^port: [0-9]+$/ {$0 = "port: " http_port}
        /^socks-port: [0-9]+$/ {$0 = "socks-port: " socks_port}
        /^external-controller: 127\.0\.0\.1:[0-9]+$/ {$0 = "external-controller: 127.0.0.1:" controller_port}
        /^  listen: 127\.0\.0\.1:[0-9]+$/ {$0 = "  listen: 127.0.0.1:" dns_port}
        {print}
    ' "$config" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    mv "$temp_file" "$config" || return 1
    log_success "系统端口已固定：HTTP ${http_port}，SOCKS ${socks_port}，控制接口 ${controller_port}，DNS ${dns_port}"
}

generate_secret() {
    od -An -N 32 -tx1 /dev/urandom | tr -d ' \n'
}

ensure_secret() {
    local config="$1" secret temp_file
    secret="$(awk -F: '/^secret:/ {sub(/^[[:space:]]*/, "", $2); gsub(/^\"|\"$/, "", $2); print $2; exit}' "$config")"
    [[ -n "$secret" ]] && return 0
    secret="$(generate_secret)" || return 1
    temp_file="$(mktemp "${config}.secret.XXXXXX")" || return 1
    if ! awk -v secret="$secret" '
        /^secret:/ {next}
        {print}
        /^external-controller:/ {print "secret: \"" secret "\""}
    ' "$config" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    mv "$temp_file" "$config" || return 1
}

write_subscription() {
    local config="$1" temp_file line
    temp_file="$(mktemp "${config}.subscription.XXXXXX")" || return 1
    if ! while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "    url:"* ]]; then
            printf '    url: '
            jq -n --arg value "$SUBSCRIPTION_URL" '$value'
        else
            printf '%s\n' "$line"
        fi
    done < "$config" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    mv "$temp_file" "$config" || return 1
}

prompt_subscription() {
    local value
    while true; do
        read -r -p "请输入系统共享 Clash/Mihomo 订阅链接: " value
        if [[ "$value" =~ ^https?:// ]]; then
            SUBSCRIPTION_URL="$value"
            return 0
        fi
        log_warn "订阅链接必须以 http:// 或 https:// 开头"
    done
}

prompt_control_users() {
    local default_user="" input user normalized invalid
    local -a requested_users

    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        default_user="$SUDO_USER"
    fi

    while true; do
        if [[ -n "$default_user" ]]; then
            read -r -p "请输入本次要加入 mihomo-control 的用户（空格分隔，默认：${default_user}）: " input || return 1
            [[ -n "$input" ]] || input="$default_user"
        else
            read -r -p "请输入本次要加入 mihomo-control 的用户（空格分隔，留空则仅 root 可控制）: " input || return 1
        fi

        normalized=""
        invalid=false
        if [[ -n "$input" ]]; then
            requested_users=()
            IFS=$' \t' read -r -a requested_users <<< "$input"
            for user in "${requested_users[@]}"; do
                if [[ "$user" == "root" ]]; then
                    continue
                fi
                if ! getent passwd "$user" >/dev/null; then
                    log_warn "用户不存在：$user"
                    invalid=true
                    continue
                fi
                if [[ " $normalized " != *" $user "* ]]; then
                    normalized="${normalized:+$normalized }$user"
                fi
            done
        fi
        if [[ "$invalid" == true ]]; then
            log_warn "请重新输入有效的本机用户名"
            continue
        fi
        CONTROL_USERS_INPUT="$normalized"
        return 0
    done
}

prompt_auto_enable() {
    local choice
    if [[ -f "$AUTO_PROFILE_FILE" ]] && grep -Fq 'mihomo-install system auto-enable' "$AUTO_PROFILE_FILE"; then
        read -r -p "当前已自动为无个人 Mihomo 的用户启用系统代理，是否保留？[Y/n]: " choice || return 1
        if [[ "$choice" =~ ^[Nn]$ ]]; then
            AUTO_ENABLE_SYSTEM_PROXY=false
        else
            AUTO_ENABLE_SYSTEM_PROXY=true
        fi
    else
        read -r -p "是否让没有个人 Mihomo 的用户登录后自动启用系统代理？[y/N]: " choice || return 1
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            AUTO_ENABLE_SYSTEM_PROXY=true
        else
            AUTO_ENABLE_SYSTEM_PROXY=false
        fi
    fi
}

stage_country_database() {
    local expected actual
    if [[ -f "$RESOURCE_DIR/Country.mmdb" && -f "$RESOURCE_DIR/Country.mmdb.sha256" ]]; then
        expected="$(awk 'NR == 1 {print $1}' "$RESOURCE_DIR/Country.mmdb.sha256")"
        actual="$(calculate_sha256 "$RESOURCE_DIR/Country.mmdb")"
        if [[ "$expected" == "$actual" ]]; then
            cp "$RESOURCE_DIR/Country.mmdb" "$STAGING_DIR/Country.mmdb" || return 1
            return 0
        fi
        log_warn "仓库 Country.mmdb 校验失败，不更新系统 GeoIP"
    fi
    if [[ -f "$STATE_DIR/Country.mmdb" ]]; then
        cp -a "$STATE_DIR/Country.mmdb" "$STAGING_DIR/Country.mmdb" || return 1
    fi
}

prepare_staging() {
    install_core_to_staging || return 1
    if [[ "$UPDATE_CONFIG" == true ]]; then
        cp "$CONFIG_TEMPLATE" "$STAGING_DIR/config.yaml" || return 1
        write_subscription "$STAGING_DIR/config.yaml" || return 1
        configure_random_ports "$STAGING_DIR/config.yaml" || return 1
    else
        cp -a "$CONFIG_FILE" "$STAGING_DIR/config.yaml" || return 1
    fi
    ensure_secret "$STAGING_DIR/config.yaml" || return 1
    chmod 600 "$STAGING_DIR/config.yaml" || return 1
    stage_country_database || return 1
    if ! "$STAGING_DIR/mihomo" -t -d "$STAGING_DIR"; then
        log_error "系统配置自检失败，现有服务未修改"
        return 1
    fi
    log_success "系统核心和配置自检通过"
}

ensure_system_accounts() {
    local nologin_shell control_user
    local -a control_users
    if ! getent group "$SERVICE_GROUP" >/dev/null; then
        groupadd --system "$SERVICE_GROUP" || return 1
    fi
    if ! getent passwd "$SERVICE_USER" >/dev/null; then
        nologin_shell="$(command -v nologin || true)"
        [[ -n "$nologin_shell" ]] || nologin_shell="/usr/sbin/nologin"
        useradd --system --gid "$SERVICE_GROUP" --home-dir "$STATE_DIR" --shell "$nologin_shell" "$SERVICE_USER" || return 1
    fi
    if ! getent group "$CONTROL_GROUP" >/dev/null; then
        groupadd --system "$CONTROL_GROUP" || return 1
    fi
    if [[ -n "$CONTROL_USERS_INPUT" ]]; then
        IFS=' ' read -r -a control_users <<< "$CONTROL_USERS_INPUT"
        for control_user in "${control_users[@]}"; do
            usermod -aG "$CONTROL_GROUP" "$control_user" || return 1
            CONTROL_USERS_ADDED="${CONTROL_USERS_ADDED:+$CONTROL_USERS_ADDED }$control_user"
        done
    fi
}

snapshot_file() {
    local source="$1" name="$2"
    if [[ -e "$source" ]]; then
        cp -a "$source" "$BACKUP_DIR/$name" || return 1
    fi
}

snapshot_installation() {
    BACKUP_DIR="$(mktemp -d /var/tmp/mihomo-system-backup.XXXXXX)"
    snapshot_file "$CORE_FILE" core || return 1
    snapshot_file "$CONFIG_FILE" config.yaml || return 1
    snapshot_file "$PROXY_ENV_FILE" proxy.env || return 1
    snapshot_file "$MANAGED_MARKER" managed-marker || return 1
    snapshot_file "$STATE_DIR/Country.mmdb" Country.mmdb || return 1
    snapshot_file "$SERVICE_FILE" service || return 1
    snapshot_file "$COMMAND_FILE" clashsys || return 1
    snapshot_file "$PROFILE_FILE" profile || return 1
    snapshot_file "$AUTO_PROFILE_FILE" auto-profile || return 1
    snapshot_file "$SUDOERS_FILE" sudoers || return 1
    systemctl is-active --quiet "$SERVICE_NAME" && SERVICE_WAS_ACTIVE=true || SERVICE_WAS_ACTIVE=false
    systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && SERVICE_WAS_ENABLED=true || SERVICE_WAS_ENABLED=false
}

restore_file() {
    local backup_name="$1" target="$2"
    rm -f "$target"
    if [[ -e "$BACKUP_DIR/$backup_name" ]]; then
        mkdir -p "$(dirname "$target")"
        cp -a "$BACKUP_DIR/$backup_name" "$target"
    fi
}

rollback_installation() {
    log_warn "正在恢复安装前的系统级 Mihomo..."
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    restore_file core "$CORE_FILE"
    restore_file config.yaml "$CONFIG_FILE"
    restore_file proxy.env "$PROXY_ENV_FILE"
    restore_file managed-marker "$MANAGED_MARKER"
    restore_file Country.mmdb "$STATE_DIR/Country.mmdb"
    restore_file service "$SERVICE_FILE"
    restore_file clashsys "$COMMAND_FILE"
    restore_file profile "$PROFILE_FILE"
    restore_file auto-profile "$AUTO_PROFILE_FILE"
    restore_file sudoers "$SUDOERS_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ "$SERVICE_WAS_ENABLED" == true ]]; then
        systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    else
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    if [[ "$SERVICE_WAS_ACTIVE" == true ]]; then
        systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || log_warn "旧系统服务未能自动恢复，请检查日志"
    fi
    log_warn "系统级安装已回滚"
}

write_proxy_env() {
    local http_port
    http_port="$(awk '/^port:/ {print $2; exit}' "$CONFIG_FILE")"
    [[ "$http_port" =~ ^[0-9]+$ ]] || return 1
    cat > "$PROXY_ENV_FILE" <<EOF
# Managed by mihomo-install system mode. 不包含控制密钥，可供所有本机用户读取。
export http_proxy="http://127.0.0.1:${http_port}"
export https_proxy="http://127.0.0.1:${http_port}"
export HTTP_PROXY="http://127.0.0.1:${http_port}"
export HTTPS_PROXY="http://127.0.0.1:${http_port}"
EOF
    chmod 644 "$PROXY_ENV_FILE" || return 1
}

wait_for_service() {
    local check stable_checks=0
    for check in {1..10}; do
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            stable_checks=$((stable_checks + 1))
            ((stable_checks >= 3)) && return 0
        else
            stable_checks=0
        fi
        sleep 1
    done
    return 1
}

commit_installation() {
    ensure_system_accounts || return 1
    snapshot_installation || return 1
    COMMIT_STARTED=true
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

    mkdir -p "$(dirname "$SERVICE_FILE")" "$(dirname "$COMMAND_FILE")" \
        "$(dirname "$PROFILE_FILE")" "$(dirname "$SUDOERS_FILE")" || return 1
    install -d -m 0755 "$CORE_DIR" "$CONFIG_DIR" || return 1
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0750 "$STATE_DIR" || return 1
    install -o root -g root -m 0755 "$STAGING_DIR/mihomo" "$CORE_FILE" || return 1
    install -o root -g "$SERVICE_GROUP" -m 0640 "$STAGING_DIR/config.yaml" "$CONFIG_FILE" || return 1
    printf '%s\n' 'mihomo-install system mode' > "$MANAGED_MARKER" || return 1
    chmod 0644 "$MANAGED_MARKER" || return 1
    if [[ -f "$STAGING_DIR/Country.mmdb" ]]; then
        install -o root -g "$SERVICE_GROUP" -m 0644 "$STAGING_DIR/Country.mmdb" "$STATE_DIR/Country.mmdb" || return 1
    fi
    install -o root -g root -m 0644 "$SERVICE_SOURCE" "$SERVICE_FILE" || return 1
    install -o root -g root -m 0755 "$COMMAND_SOURCE" "$COMMAND_FILE" || return 1
    install -o root -g root -m 0644 "$PROFILE_SOURCE" "$PROFILE_FILE" || return 1
    if [[ "$AUTO_ENABLE_SYSTEM_PROXY" == true ]]; then
        install -o root -g root -m 0644 "$AUTO_PROFILE_SOURCE" "$AUTO_PROFILE_FILE" || return 1
    elif [[ -f "$AUTO_PROFILE_FILE" ]] && grep -Fq 'mihomo-install system auto-enable' "$AUTO_PROFILE_FILE"; then
        rm -f "$AUTO_PROFILE_FILE" || return 1
    fi
    install -o root -g root -m 0440 "$SUDOERS_SOURCE" "$SUDOERS_FILE" || return 1
    visudo -cf "$SUDOERS_FILE" >/dev/null || return 1
    write_proxy_env || return 1

    systemctl daemon-reload || return 1
    systemctl enable "$SERVICE_NAME" || return 1
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    if ! wait_for_service; then
        log_error "系统服务启动失败；端口不会被静默修改"
        journalctl -u "$SERVICE_NAME" -n 50 --no-pager >&2 || true
        return 1
    fi
    log_success "系统共享 Mihomo 已安装并启动"
}

cleanup_temp() {
    local path="$1"
    [[ -n "$path" ]] || return 0
    case "$path" in
        /var/tmp/mihomo-system-stage.*|/var/tmp/mihomo-system-backup.*)
            rm -rf -- "$path"
            ;;
        *)
            log_warn "拒绝清理非预期目录：$path"
            ;;
    esac
}

main() {
    local choice
    require_root_linux
    require_commands
    require_project_files

    if [[ -d "$CONFIG_DIR" && ! -f "$MANAGED_MARKER" ]]; then
        log_error "$CONFIG_DIR 已存在但不是本项目管理的系统安装，为避免覆盖而终止"
        return 1
    fi
    if [[ -f "$AUTO_PROFILE_FILE" ]] && ! grep -Fq 'mihomo-install system auto-enable' "$AUTO_PROFILE_FILE"; then
        log_error "$AUTO_PROFILE_FILE 已存在但不是本项目管理的文件，为避免覆盖而终止"
        return 1
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        read -r -p "检测到现有系统级 Mihomo，是否继续更新核心？[y/N]: " choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log_info "系统级安装已取消"
            return 0
        fi
        read -r -p "是否覆盖系统配置和订阅？默认保留 [y/N]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            UPDATE_CONFIG=true
        else
            UPDATE_CONFIG=false
            log_info "保留现有系统配置、订阅和固定端口"
        fi
    else
        UPDATE_CONFIG=true
    fi
    if [[ "$UPDATE_CONFIG" == true ]]; then
        prompt_subscription
    fi
    prompt_control_users
    prompt_auto_enable

    STAGING_DIR="$(mktemp -d /var/tmp/mihomo-system-stage.XXXXXX)"
    trap 'cleanup_temp "${STAGING_DIR:-}"; cleanup_temp "${BACKUP_DIR:-}"' EXIT
    prepare_staging || return 1
    if ! commit_installation; then
        [[ "$COMMIT_STARTED" == true ]] && rollback_installation
        return 1
    fi

    echo
    log_success "所有本机用户现在都可以使用系统共享代理"
    log_info "当前终端加载命令：source /etc/profile.d/mihomo-system.sh"
    log_info "启用代理：clashsys on"
    log_info "停用当前终端代理：clashsys off"
    log_info "查看服务：clashsys status"
    if [[ -n "$CONTROL_USERS_ADDED" ]]; then
        log_info "已将 ${CONTROL_USERS_ADDED} 加入 ${CONTROL_GROUP}；相关用户重新登录后可执行 clashsys select/restart"
    else
        log_info "本次未新增控制用户；现有 ${CONTROL_GROUP} 成员保持不变"
    fi
    if [[ "$AUTO_ENABLE_SYSTEM_PROXY" == true ]]; then
        log_info "无个人 Mihomo 的用户将在下次登录时自动启用系统代理"
    else
        log_info "系统代理保持手动启用：source /etc/profile.d/mihomo-system.sh && clashsys on"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
