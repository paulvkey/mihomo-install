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
grep -Fq 'VS Code Tunnel' "$PROJECT_DIR/docs/USAGE.md" \
    || fail '使用说明缺少 VS Code Tunnel 独立 Shell 提示'
grep -Fq '# Load mihomo-system command for interactive Bash shells' "$PROJECT_DIR/docs/USAGE.md" \
    || fail '使用说明缺少 clashsys 的一次性 Bash 配置命令'

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
MIHOMO_COMMAND_LIB_DIR="$PROJECT_DIR/scripts/commands" bash "$PROJECT_DIR/scripts/commands/clash.sh" help \
    | grep -Eq '^[[:space:]]+sub[[:space:]]' || fail 'clash help 缺少 sub 子命令'
bash "$PROJECT_DIR/system/commands/clashsys.sh" help \
    | grep -Eq '^[[:space:]]+sub[[:space:]]' || fail 'clashsys help 缺少 sub 子命令'
grep -Fq -- "--noproxy '127.0.0.1,localhost,::1'" "$PROJECT_DIR/scripts/commands/clash_select.sh" \
    || fail '个人节点选择未绕过代理访问控制接口'
grep -Fq 'select(. != "DIRECT")' "$PROJECT_DIR/scripts/commands/clash_select.sh" \
    || fail '个人节点选择仍会把 DIRECT 兜底当成订阅节点'
grep -Fq 'select(. != "DIRECT")' "$PROJECT_DIR/system/commands/clashsys.sh" \
    || fail '系统节点选择仍会把 DIRECT 兜底当成订阅节点'
grep -Fq 'node_delays[$index]="$delay"' "$PROJECT_DIR/system/commands/clashsys.sh" \
    || fail '系统节点选择未保留超时或未测得延迟的真实节点'
! grep -Fq 'sort -n -k1,1' "$PROJECT_DIR/scripts/commands/clash_select.sh" \
    || fail '个人节点选择仍按测速延迟排序'
! grep -Fq 'sort -n -k1,1' "$PROJECT_DIR/system/commands/clashsys.sh" \
    || fail '系统节点选择仍按测速延迟排序'
grep -Fq 'DISPLAY_LABEL="★ ${DISPLAY_LABEL}"' "$PROJECT_DIR/scripts/commands/clash_select.sh" \
    || fail '个人节点选择没有使用纯文本当前节点标记'
! grep -Fq 'DISPLAY_LABEL="${CURRENT_COLOR_START}★' "$PROJECT_DIR/scripts/commands/clash_select.sh" \
    || fail '个人节点选择把 ANSI 控制符放入 select 标签，可能造成多列错位'
grep -Fq 'display_label="★ ${display_label}"' "$PROJECT_DIR/system/commands/clashsys.sh" \
    || fail '系统节点选择没有使用纯文本当前节点标记'
! grep -Fq 'display_label="${current_color_start}★' "$PROJECT_DIR/system/commands/clashsys.sh" \
    || fail '系统节点选择把 ANSI 控制符放入 select 标签，可能造成多列错位'
grep -Fq '/usr/local/bin/clashsys select --auto' "$PROJECT_DIR/system/sudoers/mihomo-system" \
    || fail '系统 sudoers 未授权控制组执行启动时节点检查'
grep -Fq '/usr/local/bin/clashsys sub' "$PROJECT_DIR/system/sudoers/mihomo-system" \
    || fail '系统 sudoers 未授权控制组更换共享订阅'
grep -Fq 'command "$_mihomo_command_file" select --auto' "$PROJECT_DIR/system/profile.d/mihomo-system.sh" \
    || fail 'clashsys on 未为控制用户触发当前节点检查'
grep -Fq -- '--proxy "$http_proxy"' "$PROJECT_DIR/system/profile.d/mihomo-system.sh" \
    || fail 'clashsys on 未为普通用户通过共享代理检测节点可用性'
grep -Fq '普通用户不会自动切换节点' "$PROJECT_DIR/system/profile.d/mihomo-system.sh" \
    || fail '普通用户节点检测失败时缺少不自动选择的提示'
grep -Fq 'MIHOMO_SYSTEM_SKIP_NODE_CHECK=1 clashsys on' "$PROJECT_DIR/system/profile.d/zz-mihomo-system-auto.sh" \
    || fail '系统自动代理登录脚本可能触发隐藏的交互选择'
grep -Fq 'select --auto' "$PROJECT_DIR/scripts/commands/clashon.sh" \
    || fail 'clash on 未启用当前节点自动检查'
grep -Fq '"$COMMAND_FILE" select' "$PROJECT_DIR/install_sys.sh" \
    || fail '系统安装完成后未进入首次节点选择'
grep -Fq 'clash_subscription.sh' "$PROJECT_DIR/install.sh" \
    || fail '个人安装脚本未部署 subscription 命令组件'
grep -Fq -- '- GEOIP,CN,DIRECT,no-resolve' "$PROJECT_DIR/config/config.yaml" \
    || fail '配置模板未使用 Country.mmdb'

# 普通用户执行 clashsys on 只能经共享 HTTP 代理做可用性检测，不能调用全局节点选择。
SYSTEM_ON_DIR="$TMP_ROOT/system-on"
SYSTEM_ON_BIN="$SYSTEM_ON_DIR/bin"
SYSTEM_ON_ENV="$SYSTEM_ON_DIR/proxy.env"
SYSTEM_ON_COMMAND_LOG="$SYSTEM_ON_DIR/command.log"
SYSTEM_ON_CURL_LOG="$SYSTEM_ON_DIR/curl.log"
mkdir -p "$SYSTEM_ON_BIN"
cat > "$SYSTEM_ON_ENV" <<'EOF'
export http_proxy="http://127.0.0.1:12345"
export https_proxy="http://127.0.0.1:12345"
export HTTP_PROXY="http://127.0.0.1:12345"
export HTTPS_PROXY="http://127.0.0.1:12345"
EOF
cat > "$SYSTEM_ON_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SYSTEM_ON_BIN/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -u) printf '%s\n' 1000 ;;
    -nG) printf '%s\n' 'users' ;;
    *) exit 1 ;;
esac
EOF
cat > "$SYSTEM_ON_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_CURL_LOG:?}"
[[ "${MOCK_CURL_FAIL:-}" != 1 ]]
EOF
cat > "$SYSTEM_ON_BIN/clashsys-command" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 0
EOF
chmod +x "$SYSTEM_ON_BIN/systemctl" "$SYSTEM_ON_BIN/id" "$SYSTEM_ON_BIN/curl" \
    "$SYSTEM_ON_BIN/clashsys-command"
system_on_output="$(
    PATH="$SYSTEM_ON_BIN:$PATH" MIHOMO_SYSTEM_ENV_FILE="$SYSTEM_ON_ENV" \
    MIHOMO_SYSTEM_COMMAND_FILE="$SYSTEM_ON_BIN/clashsys-command" \
    MIHOMO_SYSTEM_CHECK_URL='https://check.example/generate_204' \
    MOCK_COMMAND_LOG="$SYSTEM_ON_COMMAND_LOG" MOCK_CURL_LOG="$SYSTEM_ON_CURL_LOG" \
    PROJECT_UNDER_TEST="$PROJECT_DIR" bash -c '
        source "$PROJECT_UNDER_TEST/system/profile.d/mihomo-system.sh"
        clashsys on
        [[ "$http_proxy" == "http://127.0.0.1:12345" ]]
    ' 2>&1
)" || fail '普通用户 clashsys on 可用节点检测执行失败'
grep -Fq '当前共享代理节点可用。' <<< "$system_on_output" \
    || fail '普通用户共享节点可用时缺少成功提示'
grep -Fq -- '--proxy http://127.0.0.1:12345' "$SYSTEM_ON_CURL_LOG" \
    || fail '普通用户节点检测没有显式使用共享 HTTP 代理'
grep -Fq -- '--noproxy  --proxy' "$SYSTEM_ON_CURL_LOG" \
    || fail '普通用户节点检测可能被 NO_PROXY 绕过共享代理'
grep -Fq 'https://check.example/generate_204' "$SYSTEM_ON_CURL_LOG" \
    || fail '普通用户节点检测没有访问测试地址'
[[ ! -s "$SYSTEM_ON_COMMAND_LOG" ]] \
    || fail '普通用户 clashsys on 错误调用了节点选择命令'

: > "$SYSTEM_ON_CURL_LOG"
system_on_failed_output="$(
    PATH="$SYSTEM_ON_BIN:$PATH" MIHOMO_SYSTEM_ENV_FILE="$SYSTEM_ON_ENV" \
    MIHOMO_SYSTEM_COMMAND_FILE="$SYSTEM_ON_BIN/clashsys-command" \
    MOCK_COMMAND_LOG="$SYSTEM_ON_COMMAND_LOG" MOCK_CURL_LOG="$SYSTEM_ON_CURL_LOG" \
    MOCK_CURL_FAIL=1 PROJECT_UNDER_TEST="$PROJECT_DIR" bash -c '
        source "$PROJECT_UNDER_TEST/system/profile.d/mihomo-system.sh"
        clashsys on
        [[ "$http_proxy" == "http://127.0.0.1:12345" ]]
    ' 2>&1
)" || fail '普通用户 clashsys on 异常节点提醒流程执行失败'
grep -Fq '普通用户不会自动切换节点' <<< "$system_on_failed_output" \
    || fail '普通用户共享节点不可用时缺少提醒'
[[ ! -s "$SYSTEM_ON_COMMAND_LOG" ]] \
    || fail '普通用户检测失败后错误进入了节点选择'

# 更换订阅只能修改 provider URL；健康检查地址及其他配置必须保持不变。
SUBSCRIPTION_REWRITE_DIR="$TMP_ROOT/subscription-rewrite"
mkdir -p "$SUBSCRIPTION_REWRITE_DIR"
cp "$PROJECT_DIR/config/config.yaml" "$SUBSCRIPTION_REWRITE_DIR/source.yaml"
PROJECT_UNDER_TEST="$PROJECT_DIR" REWRITE_DIR="$SUBSCRIPTION_REWRITE_DIR" bash -c '
    source "$PROJECT_UNDER_TEST/scripts/commands/clash_subscription.sh"
    write_subscription_candidate "$REWRITE_DIR/source.yaml" "$REWRITE_DIR/personal.yaml" \
        "https://new.example/sub?token=a&name=b"
' || fail '个人订阅地址重写失败'
PROJECT_UNDER_TEST="$PROJECT_DIR" REWRITE_DIR="$SUBSCRIPTION_REWRITE_DIR" bash -c '
    source "$PROJECT_UNDER_TEST/system/commands/clashsys.sh"
    write_subscription_candidate "$REWRITE_DIR/source.yaml" "$REWRITE_DIR/system.yaml" \
        "https://new.example/sub?token=a&name=b"
' || fail '系统订阅地址重写失败'
cmp -s "$SUBSCRIPTION_REWRITE_DIR/personal.yaml" "$SUBSCRIPTION_REWRITE_DIR/system.yaml" \
    || fail '个人和系统订阅地址重写结果不一致'
grep -Fq '    url: "https://new.example/sub?token=a&name=b"' "$SUBSCRIPTION_REWRITE_DIR/personal.yaml" \
    || fail '新订阅地址没有安全写入 YAML'
grep -Fq '      url: https://www.gstatic.com/generate_204' "$SUBSCRIPTION_REWRITE_DIR/personal.yaml" \
    || fail '更换订阅时误改了健康检查地址'

# 个人订阅更换成功时清理旧缓存；服务验证失败时恢复原配置和缓存。
SUBSCRIPTION_HOME="$TMP_ROOT/subscription-home"
SUBSCRIPTION_MOCK_BIN="$TMP_ROOT/subscription-bin"
SUBSCRIPTION_STATE="$TMP_ROOT/subscription-restarted"
mkdir -p "$SUBSCRIPTION_HOME/mihomo/providers" "$SUBSCRIPTION_HOME/.local/bin" "$SUBSCRIPTION_MOCK_BIN"
cp "$PROJECT_DIR/config/config.yaml" "$SUBSCRIPTION_HOME/mihomo/config.yaml"
printf '%s\n' 'old-provider-cache' > "$SUBSCRIPTION_HOME/mihomo/providers/subscription.yaml"
cat > "$SUBSCRIPTION_HOME/mihomo/mihomo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SUBSCRIPTION_HOME/.local/bin/clash" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "select" ]]
EOF
cat > "$SUBSCRIPTION_MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "--user is-active --quiet mihomo" ]]; then
    if [[ "${MOCK_SUBSCRIPTION_FAIL:-}" == 1 && -e "${MOCK_STATE_FILE:?}" ]]; then
        exit 1
    fi
    exit 0
fi
if [[ "$*" == "--user restart mihomo" ]]; then
    : > "${MOCK_STATE_FILE:?}"
fi
exit 0
EOF
cat > "$SUBSCRIPTION_MOCK_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SUBSCRIPTION_HOME/mihomo/mihomo" "$SUBSCRIPTION_HOME/.local/bin/clash" \
    "$SUBSCRIPTION_MOCK_BIN/systemctl" "$SUBSCRIPTION_MOCK_BIN/sleep"
subscription_output="$(
    printf '%s\n' 'https://new.example/sub?token=success' | \
        HOME="$SUBSCRIPTION_HOME" PATH="$SUBSCRIPTION_MOCK_BIN:$PATH" MOCK_STATE_FILE="$SUBSCRIPTION_STATE" \
        bash "$PROJECT_DIR/scripts/commands/clash_subscription.sh" 2>&1
)" || fail '个人订阅更换成功流程执行失败'
grep -Fq '    url: "https://new.example/sub?token=success"' "$SUBSCRIPTION_HOME/mihomo/config.yaml" \
    || fail '个人订阅更换后配置未生效'
[[ ! -e "$SUBSCRIPTION_HOME/mihomo/providers/subscription.yaml" ]] \
    || fail '个人订阅更换后未清理旧 provider 缓存'
grep -Fq '订阅链接已更换，服务已重启。' <<< "$subscription_output" \
    || fail '个人订阅更换成功时缺少完成提示'

cp "$PROJECT_DIR/config/config.yaml" "$SUBSCRIPTION_HOME/mihomo/config.yaml"
printf '%s\n' 'old-provider-cache' > "$SUBSCRIPTION_HOME/mihomo/providers/subscription.yaml"
rm -f "$SUBSCRIPTION_STATE"
if printf '%s\n' 'https://broken.example/sub' | \
    HOME="$SUBSCRIPTION_HOME" PATH="$SUBSCRIPTION_MOCK_BIN:$PATH" MOCK_STATE_FILE="$SUBSCRIPTION_STATE" \
    MOCK_SUBSCRIPTION_FAIL=1 bash "$PROJECT_DIR/scripts/commands/clash_subscription.sh" >/dev/null 2>&1; then
    fail '服务验证失败时订阅更换仍返回成功'
fi
grep -Fq '    url: "https://example.com/your-subscription"' "$SUBSCRIPTION_HOME/mihomo/config.yaml" \
    || fail '订阅更换失败时未恢复原配置'
grep -Fqx 'old-provider-cache' "$SUBSCRIPTION_HOME/mihomo/providers/subscription.yaml" \
    || fail '订阅更换失败时未恢复原 provider 缓存'

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
        printf '%s\n' '{"now":"Node A","all":["Node B","Node A","DIRECT"]}'
        ;;
    */group/PROXY/delay)
        if [[ "${MOCK_CURRENT_UNAVAILABLE:-}" == 1 ]]; then
            printf '%s\n' '{"Node B":456}'
        else
            printf '%s\n' '{"Node A":123}'
        fi
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$SELECT_MOCK_BIN/systemctl" "$SELECT_MOCK_BIN/curl"
selection_output="$(
    printf '0\n' | COLUMNS=40 PATH="$SELECT_MOCK_BIN:$PATH" HOME="$SELECT_HOME" \
        bash "$PROJECT_DIR/scripts/commands/clash_select.sh" 2>&1
)" || fail '节点选择保留异常节点测试执行失败'
grep -Fq 'Node A [123 ms' <<< "$selection_output" || fail '可用节点未显示测速延迟'
grep -Fq '★ Node A [123 ms' <<< "$selection_output" || fail '当前节点未使用醒目标记高亮'
grep -Fq 'Node B [超时/不可用]' <<< "$selection_output" || fail '超时节点未保留在选择列表'
grep -Eq '1\) Node B \[超时/不可用\]' <<< "$selection_output" \
    || fail '节点选择没有保持订阅返回的原始顺序'
! grep -Fq 'DIRECT [' <<< "$selection_output" || fail 'DIRECT 兜底错误地出现在选择列表'

auto_selection_output="$(
    PATH="$SELECT_MOCK_BIN:$PATH" HOME="$SELECT_HOME" \
        bash "$PROJECT_DIR/scripts/commands/clash_select.sh" --auto 2>&1
)" || fail '当前节点可用时的自动选择测试执行失败'
grep -Fq '★ 当前节点 Node A 可用（123 ms），继续使用并跳过选择。' <<< "$auto_selection_output" \
    || fail '当前节点可用时未自动沿用'
! grep -Fq '请选择节点' <<< "$auto_selection_output" || fail '当前节点可用时仍进入了选择列表'

unavailable_selection_output="$(
    printf '0\n' | MOCK_CURRENT_UNAVAILABLE=1 PATH="$SELECT_MOCK_BIN:$PATH" HOME="$SELECT_HOME" \
        bash "$PROJECT_DIR/scripts/commands/clash_select.sh" --auto 2>&1
)" || fail '当前节点不可用时的自动选择测试执行失败'
grep -Fq '当前节点 Node A 超时或未测得延迟，需要重新选择。' <<< "$unavailable_selection_output" \
    || fail '当前节点不可用时缺少重新选择提示'
grep -Fq '请选择节点' <<< "$unavailable_selection_output" || fail '当前节点不可用时未进入选择列表'

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
