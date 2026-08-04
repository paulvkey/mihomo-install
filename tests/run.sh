#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-install-tests.XXXXXX")" || exit 1
trap 'rm -rf -- "$TMP_ROOT"' EXIT

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

# README 必须将详细使用说明链接到独立文档。
[[ -f "$PROJECT_DIR/docs/USAGE.md" ]] || fail '缺少独立使用说明 docs/USAGE.md'
grep -Fq '[完整使用说明](docs/USAGE.md)' "$PROJECT_DIR/README.md" \
    || fail 'README 未链接独立使用说明'

# 随机端口必须覆盖指定范围，并排除本轮已选择的端口。
# shellcheck source=../scripts/lib/ports.sh
source "$PROJECT_DIR/scripts/lib/ports.sh"
mihomo_port_in_use() { return 1; }
for _ in {1..200}; do
    port="$(mihomo_random_available_port 20000 59999)"
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 20000 && "$port" -le 59999 ]] \
        || fail "随机端口超出 20000-59999：$port"
done
[[ "$(mihomo_random_available_port 20000 20001 20000)" == 20001 ]] \
    || fail '随机端口未排除已选择值'

# 认证写入应幂等，凭据文件只允许当前用户读取，并强制关闭 loopback 免认证。
AUTH_DIR="$TMP_ROOT/auth"
mkdir -p "$AUTH_DIR"
cp "$PROJECT_DIR/config/config.yaml" "$AUTH_DIR/config.yaml"
# shellcheck source=../scripts/lib/user_auth.sh
source "$PROJECT_DIR/scripts/lib/user_auth.sh"
mihomo_ensure_proxy_auth_config "$AUTH_DIR/config.yaml" "$AUTH_DIR/proxy-auth"
first_auth="$(awk -F= '/^username=|^password=/ {print}' "$AUTH_DIR/proxy-auth")"
mihomo_ensure_proxy_auth_config "$AUTH_DIR/config.yaml" "$AUTH_DIR/proxy-auth"
second_auth="$(awk -F= '/^username=|^password=/ {print}' "$AUTH_DIR/proxy-auth")"
[[ "$first_auth" == "$second_auth" ]] || fail '重装时认证凭据发生了非预期变化'
[[ "$(grep -c '^authentication:' "$AUTH_DIR/config.yaml")" == 1 ]] || fail 'authentication 被重复写入'
grep -Fqx 'skip-auth-prefixes: []' "$AUTH_DIR/config.yaml" || fail '未关闭 loopback 免认证'
old_credential="$(awk -F= '/^username=/ {username=$2} /^password=/ {print username ":" $2}' "$AUTH_DIR/proxy-auth")"
rm -f "$AUTH_DIR/proxy-auth"
mihomo_ensure_proxy_auth_config "$AUTH_DIR/config.yaml" "$AUTH_DIR/proxy-auth"
new_credential="$(awk -F= '/^username=/ {username=$2} /^password=/ {print username ":" $2}' "$AUTH_DIR/proxy-auth")"
[[ "$old_credential" != "$new_credential" ]] || fail '删除凭据后未生成新认证信息'
! grep -Fq "$old_credential" "$AUTH_DIR/config.yaml" || fail '轮换凭据后旧密码仍保留在配置中'
permissions="$(stat -c '%a' "$AUTH_DIR/proxy-auth" 2>/dev/null || stat -f '%Lp' "$AUTH_DIR/proxy-auth")"
[[ "$permissions" == 600 ]] || fail "proxy-auth 权限不是 600：$permissions"

# 代理环境文件必须使用带凭据的 URL。
TEST_HOME="$TMP_ROOT/home"
TEST_LIB="$TMP_ROOT/lib"
mkdir -p "$TEST_HOME/mihomo" "$TEST_LIB"
cp "$PROJECT_DIR/scripts/lib/ports.sh" "$TEST_LIB/ports.sh"
cp "$PROJECT_DIR/scripts/lib/user_auth.sh" "$TEST_LIB/user_auth.sh"
cp "$PROJECT_DIR/scripts/commands/common.sh" "$TEST_LIB/common.sh"
cp "$AUTH_DIR/proxy-auth" "$TEST_HOME/mihomo/proxy-auth"
printf '%s\n' 'port: 23456' > "$TEST_HOME/mihomo/config.yaml"
HOME="$TEST_HOME" bash -c 'source "$1/common.sh"; write_proxy_env' _ "$TEST_LIB"
grep -Eq '^export http_proxy="http://mihomo_[0-9a-f]+:[0-9a-f]+@127\.0\.0\.1:23456"$' \
    "$TEST_HOME/mihomo/proxy.env" || fail '代理环境没有写入随机凭据'

# 命令入口和配置模板的关键安全项。
MIHOMO_COMMAND_LIB_DIR="$PROJECT_DIR/scripts/commands" bash "$PROJECT_DIR/scripts/commands/clash.sh" help \
    | grep -Fq 'auth' || fail 'clash help 缺少 auth 子命令'
grep -Fq -- "--noproxy '127.0.0.1,localhost,::1'" "$PROJECT_DIR/scripts/commands/clash_select.sh" \
    || fail '个人节点选择未绕过代理访问控制接口'
grep -Fq 'select(. != "DIRECT")' "$PROJECT_DIR/scripts/commands/clash_select.sh" \
    || fail '个人节点选择仍会把 DIRECT 兜底当成订阅节点'
grep -Fq 'select(. != "DIRECT")' "$PROJECT_DIR/system/commands/clashsys.sh" \
    || fail '系统节点选择仍会把 DIRECT 兜底当成订阅节点'
grep -Fq 'select_delays+=("0")' "$PROJECT_DIR/system/commands/clashsys.sh" \
    || fail '系统节点选择未保留超时或未测得延迟的真实节点'
grep -Fq '"$COMMAND_FILE" select' "$PROJECT_DIR/install_sys.sh" \
    || fail '系统安装完成后未进入首次节点选择'
grep -Fq -- '- GEOIP,CN,DIRECT,no-resolve' "$PROJECT_DIR/config/config.yaml" \
    || fail '配置模板未使用 Country.mmdb'

# 节点测速只提供状态提示：超时节点必须继续出现在选择列表中，DIRECT 仍需隐藏。
SELECT_HOME="$TMP_ROOT/select-home"
SELECT_MOCK_BIN="$TMP_ROOT/select-bin"
mkdir -p "$SELECT_HOME/mihomo" "$SELECT_MOCK_BIN"
cat > "$SELECT_HOME/mihomo/config.yaml" <<'EOF'
external-controller: 127.0.0.1:23457
secret: "test-secret"
EOF
cat > "$SELECT_MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SELECT_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
    */proxies/PROXY)
        printf '%s\n' '{"now":"Node A","all":["Node A","Node B","DIRECT"]}'
        ;;
    */group/PROXY/delay)
        printf '%s\n' '{"Node A":123}'
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$SELECT_MOCK_BIN/systemctl" "$SELECT_MOCK_BIN/curl"
selection_output="$(
    printf '0\n' | PATH="$SELECT_MOCK_BIN:$PATH" HOME="$SELECT_HOME" \
        bash "$PROJECT_DIR/scripts/commands/clash_select.sh" 2>&1
)" || fail '节点选择保留异常节点测试执行失败'
grep -Fq 'Node A [123 ms' <<< "$selection_output" || fail '可用节点未显示测速延迟'
grep -Fq 'Node B [超时/不可用]' <<< "$selection_output" || fail '超时节点未保留在选择列表'
! grep -Fq 'DIRECT [' <<< "$selection_output" || fail 'DIRECT 兜底错误地出现在选择列表'

# 两种安装模式都必须拒绝覆盖未受项目管理的同名目标。
PERSON_HOME="$TMP_ROOT/person-home"
mkdir -p "$PERSON_HOME/.local/bin"
printf '%s\n' '#!/usr/bin/env bash' > "$PERSON_HOME/.local/bin/clash"
if HOME="$PERSON_HOME" PROJECT_UNDER_TEST="$PROJECT_DIR" bash -c '
    source "$PROJECT_UNDER_TEST/install.sh"
    require_project_files
' 2>/dev/null; then
    fail '个人安装未拒绝非项目管理的 clash 命令'
fi

# Bash 集成不能清除用户原有/系统代理，只能清理由本项目加载的个人代理。
BASHRC_HOME="$TMP_ROOT/bashrc-home"
mkdir -p "$BASHRC_HOME/.local/bin" "$BASHRC_HOME/mihomo"
cat > "$BASHRC_HOME/.local/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$BASHRC_HOME/.local/bin/clash" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BASHRC_HOME/.local/bin/systemctl" "$BASHRC_HOME/.local/bin/clash"
printf '%s\n' \
    '# Managed by mihomo-install test' \
    'export http_proxy="http://mihomo_user:password@127.0.0.1:23456"' \
    'export https_proxy="http://mihomo_user:password@127.0.0.1:23456"' \
    'export HTTP_PROXY="http://mihomo_user:password@127.0.0.1:23456"' \
    'export HTTPS_PROXY="http://mihomo_user:password@127.0.0.1:23456"' \
    > "$BASHRC_HOME/mihomo/proxy.env"
HOME="$BASHRC_HOME" PROJECT_UNDER_TEST="$PROJECT_DIR" bash -c '
    source "$PROJECT_UNDER_TEST/install.sh"
    configure_command_path >/dev/null
    export http_proxy="http://other.proxy:8080"
    export https_proxy="$http_proxy" HTTP_PROXY="$http_proxy" HTTPS_PROXY="$http_proxy"
    source "$HOME/.bashrc"
    [[ "$http_proxy" == "http://other.proxy:8080" ]]
    clash off
    [[ "$http_proxy" == "http://other.proxy:8080" ]]
    export http_proxy="http://mihomo_user:password@127.0.0.1:23456"
    export https_proxy="$http_proxy" HTTP_PROXY="$http_proxy" HTTPS_PROXY="$http_proxy"
    clash off
    [[ -z "${http_proxy:-}" && -z "${https_proxy:-}" ]]
' || fail 'clash off 的代理环境归属判断失败'

SYSTEM_ROOT="$TMP_ROOT/system-root"
mkdir -p "$SYSTEM_ROOT/etc/mihomo"
if PROJECT_UNDER_TEST="$PROJECT_DIR" SYSTEM_ROOT="$SYSTEM_ROOT" bash -c '
    source "$PROJECT_UNDER_TEST/install_sys.sh"
    CORE_DIR="$SYSTEM_ROOT/usr/local/lib/mihomo"
    CORE_FILE="$CORE_DIR/mihomo"
    CONFIG_DIR="$SYSTEM_ROOT/etc/mihomo"
    CONFIG_FILE="$CONFIG_DIR/config.yaml"
    PROXY_ENV_FILE="$CONFIG_DIR/proxy.env"
    MANAGED_MARKER="$CONFIG_DIR/.managed-by-mihomo-install"
    STATE_DIR="$SYSTEM_ROOT/var/lib/mihomo"
    SERVICE_FILE="$SYSTEM_ROOT/etc/systemd/system/mihomo-system.service"
    COMMAND_FILE="$SYSTEM_ROOT/usr/local/bin/clashsys"
    PROFILE_FILE="$SYSTEM_ROOT/etc/profile.d/mihomo-system.sh"
    AUTO_PROFILE_FILE="$SYSTEM_ROOT/etc/profile.d/zz-mihomo-system-auto.sh"
    SUDOERS_FILE="$SYSTEM_ROOT/etc/sudoers.d/mihomo-system"
    preflight_system_targets
' 2>/dev/null; then
    fail '系统安装未拒绝缺少管理标记的既有目录'
fi

echo '[PASS] 行为测试通过。'
