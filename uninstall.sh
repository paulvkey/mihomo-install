#!/usr/bin/env bash

# 用户级 Mihomo 卸载脚本：与 install.sh 的 ~/mihomo 和 systemctl --user 对应。
set -euo pipefail

MIHOMO_DIR="$HOME/mihomo"
SERVICE_FILE="$HOME/.config/systemd/user/mihomo.service"
COMMAND_DIR="$HOME/.local/bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo -e "${YELLOW}即将删除以下当前用户资源：${NC}"
echo "  - $MIHOMO_DIR"
echo "  - $SERVICE_FILE"
read -r -p "确定继续卸载吗？[y/N]: " choice
if [[ ! "$choice" =~ ^[Yy]$ ]]; then
    log_info "卸载已取消"
    exit 0
fi

if systemctl --user disable --now mihomo 2>/dev/null; then
    log_success "Mihomo 用户服务已停止并禁用"
else
    log_warn "Mihomo 用户服务未运行或用户 systemd 不可用"
fi

if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    log_success "已删除用户服务文件"
fi
systemctl --user daemon-reload 2>/dev/null || true

for command in clashon clashoff clash_restart clash_status clash_select; do
    command_file="$COMMAND_DIR/$command"
    if [[ -f "$command_file" ]] && grep -q '^# Managed by mihomo-install$' "$command_file"; then
        rm -f "$command_file"
        log_success "已删除命令：$command"
    fi
done

if [[ -d "$MIHOMO_DIR" ]]; then
    rm -rf "$MIHOMO_DIR"
    log_success "已删除 $MIHOMO_DIR"
else
    log_warn "未找到 $MIHOMO_DIR"
fi

log_success "卸载完成"
