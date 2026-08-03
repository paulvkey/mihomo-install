# Managed by mihomo-install system auto-enable.
# 仅为没有个人模式安装痕迹的用户自动启用系统共享代理。

if [ -n "${HOME:-}" ] \
    && [ ! -x "$HOME/.local/bin/clashon" ] \
    && [ ! -f "$HOME/.config/systemd/user/mihomo.service" ] \
    && [ ! -d "$HOME/mihomo" ]; then
    # 确保 clashsys shell 函数已定义；重复加载只会覆盖同名函数，不会启用代理。
    . "${MIHOMO_SYSTEM_PROFILE_FILE:-/etc/profile.d/mihomo-system.sh}"
    clashsys on >/dev/null 2>&1 || true
fi
