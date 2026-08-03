#!/usr/bin/env bash

# Mihomo 系统级共享卸载脚本。不会修改任何用户的 Home 或用户级服务。
set -euo pipefail
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

SERVICE_NAME="mihomo-system.service"
SERVICE_FILE="/etc/systemd/system/mihomo-system.service"
CORE_DIR="/usr/local/lib/mihomo"
CONFIG_DIR="/etc/mihomo"
MANAGED_MARKER="$CONFIG_DIR/.managed-by-mihomo-install"
STATE_DIR="/var/lib/mihomo"
COMMAND_FILE="/usr/local/bin/clashsys"
PROFILE_FILE="/etc/profile.d/mihomo-system.sh"
AUTO_PROFILE_FILE="/etc/profile.d/zz-mihomo-system-auto.sh"
SUDOERS_FILE="/etc/sudoers.d/mihomo-system"

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "系统级卸载仅支持 Linux。" >&2
    exit 1
fi
if ((EUID != 0)); then
    echo "请使用管理员权限执行：sudo bash system/uninstall.sh" >&2
    exit 1
fi
if [[ ! -f "$MANAGED_MARKER" ]] || ! grep -Fq 'mihomo-install system mode' "$MANAGED_MARKER"; then
    echo "$CONFIG_DIR 不是本项目管理的系统安装，拒绝删除。" >&2
    exit 1
fi

echo "即将删除以下系统共享 Mihomo 资源："
echo "  - $CORE_DIR"
echo "  - $CONFIG_DIR"
echo "  - $STATE_DIR"
echo "  - $SERVICE_FILE"
echo "  - $COMMAND_FILE"
echo "  - $PROFILE_FILE"
echo "  - $AUTO_PROFILE_FILE"
echo "不会删除任何用户的 ~/mihomo、~/.bashrc 或 systemctl --user 服务。"
read -r -p "确定继续吗？[y/N]: " choice
if [[ ! "$choice" =~ ^[Yy]$ ]]; then
    echo "系统级卸载已取消。"
    exit 0
fi

systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true

if [[ -f "$SERVICE_FILE" ]] && grep -Fq 'Mihomo System-wide Proxy Service' "$SERVICE_FILE"; then
    rm -f "$SERVICE_FILE"
fi
if [[ -f "$COMMAND_FILE" ]] && grep -Fq '# Managed by mihomo-install (system mode)' "$COMMAND_FILE"; then
    rm -f "$COMMAND_FILE"
fi
if [[ -f "$PROFILE_FILE" ]] && grep -Fq 'Mihomo 系统共享代理 shell 函数' "$PROFILE_FILE"; then
    rm -f "$PROFILE_FILE"
fi
if [[ -f "$AUTO_PROFILE_FILE" ]] && grep -Fq 'mihomo-install system auto-enable' "$AUTO_PROFILE_FILE"; then
    rm -f "$AUTO_PROFILE_FILE"
fi
if [[ -f "$SUDOERS_FILE" ]] && grep -Fq 'MIHOMO_SYSTEM_CONTROL' "$SUDOERS_FILE"; then
    rm -f "$SUDOERS_FILE"
fi

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

for managed_dir in "$CORE_DIR" "$CONFIG_DIR" "$STATE_DIR"; do
    case "$managed_dir" in
        /usr/local/lib/mihomo|/etc/mihomo|/var/lib/mihomo)
            [[ -d "$managed_dir" ]] && rm -rf -- "$managed_dir"
            ;;
    esac
done

echo "系统共享 Mihomo 已卸载。"
echo "专用账户 mihomo 和权限组 mihomo-control 被保留，避免误删预先存在的系统账户或用户组。"
