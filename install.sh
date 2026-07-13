#!/usr/bin/env bash

# Mihomo 安装脚本
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"
COUNTRY_FILE="$SCRIPT_DIR/Country.mmdb"
SELECT_SCRIPT="$SCRIPT_DIR/clash_select.sh"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/mihomo.service"
COMMAND_DIR="$HOME/.local/bin"

# 镜像地址为 GitHub URL 前缀；最后的空字符串表示 GitHub 原始地址。
GITHUB_MIRRORS=(
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghproxy.net/"
    "https://mirror.ghproxy.com/"
    ""
)

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

ensure_x86_64() {
    if [[ "$(uname -m)" != "x86_64" ]]; then
        log_error "此安装脚本仅支持 x86_64，当前架构：$(uname -m)"
        exit 1
    fi
}

valid_gzip() {
    [[ -f "$1" ]] && [[ $(wc -c < "$1") -gt 1000 ]] && gzip -t "$1" 2>/dev/null
}

download_file() {
    local url="$1" output="$2" description="$3"
    local mirror candidate

    for mirror in "${GITHUB_MIRRORS[@]}"; do
        candidate="${mirror}${url}"
        log_info "尝试下载 ${description}：${candidate}"
        if curl -fL --retry 2 --retry-all-errors --connect-timeout 10 --max-time 180 -o "$output" "$candidate"; then
            if valid_gzip "$output"; then
                log_success "下载成功：${description}"
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

    for mirror in "${GITHUB_MIRRORS[@]}"; do
        candidate="${mirror}${url}"
        log_info "尝试查询 GitHub Release：${candidate}"
        if response="$(curl -fsSL --retry 2 --retry-all-errors --connect-timeout 10 --max-time 90 "$candidate")" \
            && grep -q '"browser_download_url"' <<< "$response"; then
            GITHUB_JSON="$response"
            return 0
        fi
    done

    log_error "所有镜像均无法查询 GitHub Release"
    return 1
}

# 仅选取脚本同级 bin/ 中的 AMD64 v2 构建；存在多个时取版本号最高者。
find_local_v2() {
    local candidates=()
    shopt -s nullglob
    candidates=("$SCRIPT_DIR/bin/mihomo-linux-amd64-v2-"*.gz)
    shopt -u nullglob
    ((${#candidates[@]})) || return 1
    printf '%s\n' "${candidates[@]}" | sort -V | tail -n 1
}

download_release() {
    local json url
    fetch_github_json "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    json="$GITHUB_JSON"
    # AMD64 资源可能带 compatible 后缀；两种 Release 命名均兼容。
    url="$(printf '%s\n' "$json" | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | grep -E '/mihomo-linux-amd64(-compatible)?-v[^/]*\.gz$' | head -n 1 || true)"
    [[ -n "$url" ]] || { log_error "最新 Release 中没有 AMD64 的 gzip 资源"; return 1; }

    DOWNLOADED_ARCHIVE="$(mktemp "$MIHOMO_DIR/.mihomo-download.XXXXXX.gz")"
    download_file "$url" "$DOWNLOADED_ARCHIVE" "最新 Mihomo 核心"
}

install_core() {
    local archive local_archive
    if local_archive="$(find_local_v2)" && valid_gzip "$local_archive"; then
        archive="$local_archive"
        log_info "使用本地资源: $(basename "$archive")"
    else
        [[ -n "${local_archive:-}" ]] && log_warn "本地资源无效，改为下载 GitHub Release"
        download_release
        archive="$DOWNLOADED_ARCHIVE"
    fi
    gzip -cd "$archive" > "$MIHOMO_DIR/mihomo"
    chmod 755 "$MIHOMO_DIR/mihomo"
    [[ -n "${DOWNLOADED_ARCHIVE:-}" ]] && rm -f "$DOWNLOADED_ARCHIVE"
    log_success "Mihomo 核心已安装"
}

copy_if_present() {
    local source="$1" target="$2"
    if [[ -f "$source" ]]; then
        cp "$source" "$target"
        log_success "已复制 $(basename "$source")"
    else
        log_warn "未找到 $(basename "$source")，跳过复制"
    fi
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
    local config="$MIHOMO_DIR/config.yaml"
    local http_port socks_port controller_port dns_port
    [[ -f "$config" ]] || return 0

    http_port="$(random_available_port)"
    socks_port="$(random_available_port "$http_port")"
    controller_port="$(random_available_port "$http_port" "$socks_port")"
    dns_port="$(random_available_port "$http_port" "$socks_port" "$controller_port")"

    sed -i -E \
        -e "s/^port: [0-9]+$/port: $http_port/" \
        -e "s/^socks-port: [0-9]+$/socks-port: $socks_port/" \
        -e "s|^external-controller: 127\\.0\\.0\\.1:[0-9]+$|external-controller: 127.0.0.1:$controller_port|" \
        -e "s|^  listen: 127\\.0\\.0\\.1:[0-9]+$|  listen: 127.0.0.1:$dns_port|" \
        "$config"
    log_success "已分配本机随机端口：HTTP $http_port，SOCKS $socks_port，控制接口 $controller_port，DNS $dns_port"
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
    local config="$MIHOMO_DIR/config.yaml" escaped_url
    escaped_url="$(printf '%s' "$SUBSCRIPTION_URL" | sed 's/[\\&|"]/\\&/g')"
    sed -i -E "s|^    url:.*$|    url: \"$escaped_url\"|" "$config"
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
        if systemctl --user restart mihomo && systemctl --user is-active --quiet mihomo; then
            log_success "mihomo 用户服务已启用并启动"
            return 0
        fi

        service_log="$(journalctl --user -u mihomo -n 50 --no-pager 2>&1 || true)"
        if is_port_binding_failure "$service_log" && (( attempt < 3 )); then
            log_warn "服务因端口绑定失败未能启动（第 $attempt/3 次），正在重新分配端口后重试..."
            configure_random_ports
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
    mkdir -p "$COMMAND_DIR"

    cat > "$COMMAND_DIR/clashon" <<'EOF'
#!/usr/bin/env bash
# Managed by mihomo-install
if systemctl --user start mihomo && systemctl --user is-active --quiet mihomo; then
    echo "Mihomo 已启动"
    if [[ -t 0 && -x "$HOME/.local/bin/clash_select" ]]; then
        "$HOME/.local/bin/clash_select" || echo "节点选择未完成，可稍后执行 clash_select。" >&2
    fi
    exit 0
else
    echo "Mihomo 启动失败，请查看：journalctl --user -u mihomo -n 50 --no-pager" >&2
    exit 1
fi
EOF

    cat > "$COMMAND_DIR/clashoff" <<'EOF'
#!/usr/bin/env bash
# Managed by mihomo-install
if systemctl --user stop mihomo; then
    echo "Mihomo 已停止"
else
    echo "Mihomo 停止失败，请查看：journalctl --user -u mihomo -n 50 --no-pager" >&2
    exit 1
fi
EOF

    cat > "$COMMAND_DIR/clash_restart" <<'EOF'
#!/usr/bin/env bash
# Managed by mihomo-install
if systemctl --user restart mihomo && systemctl --user is-active --quiet mihomo; then
    echo "Mihomo 已重启"
else
    echo "Mihomo 重启失败，请查看：journalctl --user -u mihomo -n 50 --no-pager" >&2
    exit 1
fi
EOF

    cat > "$COMMAND_DIR/clash_status" <<'EOF'
#!/usr/bin/env bash
# Managed by mihomo-install
exec systemctl --user status mihomo --no-pager
EOF

    if [[ ! -f "$SELECT_SCRIPT" ]]; then
        log_error "未找到节点选择脚本：$SELECT_SCRIPT"
        return 1
    fi
    cp "$SELECT_SCRIPT" "$COMMAND_DIR/clash_select"
    chmod 755 "$COMMAND_DIR/clashon" "$COMMAND_DIR/clashoff" "$COMMAND_DIR/clash_restart" "$COMMAND_DIR/clash_status" "$COMMAND_DIR/clash_select"
    log_success "已创建命令：clashon、clashoff、clash_restart、clash_status、clash_select"
}

configure_command_path() {
    local bashrc_file="$HOME/.bashrc"
    local path_line='export PATH="$HOME/.local/bin:$PATH"'

    touch "$bashrc_file"
    if ! grep -Fqx "$path_line" "$bashrc_file"; then
        printf '\n# Mihomo user commands\n%s\n' "$path_line" >> "$bashrc_file"
        log_success "已将 ~/.local/bin 添加到 $bashrc_file"
    fi
}

main() {
    local choice

    ensure_x86_64

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

    mkdir -p "$MIHOMO_DIR"
    mkdir -p "$SERVICE_DIR"
    systemctl --user stop mihomo 2>/dev/null || true
    install_core
    if [[ "$UPDATE_CONFIG" == true ]]; then
        copy_if_present "$CONFIG_FILE" "$MIHOMO_DIR/config.yaml"
        write_subscription_url
        configure_random_ports
    fi
    copy_if_present "$COUNTRY_FILE" "$MIHOMO_DIR/Country.mmdb"
    write_service
    if ! start_service_with_port_retries; then
        log_error "安装未完成：核心文件已写入 $MIHOMO_DIR，但 mihomo 服务未成功启动"
        return 1
    fi
    if ! create_service_commands; then
        return 1
    fi
    configure_command_path
    if [[ -t 0 ]]; then
        "$COMMAND_DIR/clash_select" || log_warn "首次节点选择未完成，稍后可执行 clash_select"
    fi

    echo
    log_success "安装完成：$MIHOMO_DIR"
    echo "配置文件：$MIHOMO_DIR/config.yaml"
    echo "服务管理：clashon、clashoff、clash_restart、clash_status、clash_select"
    echo "请执行 source ~/.bashrc 后直接使用上述命令"
}

main "$@"
