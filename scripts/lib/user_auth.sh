#!/usr/bin/env bash

# 个人模式 HTTP/SOCKS 随机认证管理。凭据只使用 URL/YAML 安全字符。

mihomo_generate_hex() {
    local byte_count="$1"
    od -An -N "$byte_count" -tx1 /dev/urandom | tr -d ' \n'
}

mihomo_read_proxy_auth() {
    local auth_file="$1" key value
    MIHOMO_PROXY_USERNAME=""
    MIHOMO_PROXY_PASSWORD=""
    [[ -r "$auth_file" ]] || return 1
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        case "$key" in
            username) MIHOMO_PROXY_USERNAME="$value" ;;
            password) MIHOMO_PROXY_PASSWORD="$value" ;;
        esac
    done < "$auth_file"
    [[ "$MIHOMO_PROXY_USERNAME" =~ ^[A-Za-z0-9_]+$ ]] \
        && [[ "$MIHOMO_PROXY_PASSWORD" =~ ^[A-Fa-f0-9]{32,128}$ ]]
}

mihomo_ensure_proxy_auth_file() {
    local auth_file="$1" username password temp_file
    if mihomo_read_proxy_auth "$auth_file"; then
        return 0
    fi
    username="mihomo_$(mihomo_generate_hex 6)" || return 1
    password="$(mihomo_generate_hex 32)" || return 1
    temp_file="$(mktemp "${auth_file}.XXXXXX")" || return 1
    {
        printf '%s\n' '# Managed by mihomo-install. HTTP/SOCKS credentials.'
        printf 'username=%s\n' "$username"
        printf 'password=%s\n' "$password"
    } > "$temp_file" || { rm -f "$temp_file"; return 1; }
    chmod 600 "$temp_file" || { rm -f "$temp_file"; return 1; }
    mv "$temp_file" "$auth_file" || return 1
    mihomo_read_proxy_auth "$auth_file"
}

mihomo_ensure_proxy_auth_config() {
    local config_file="$1" auth_file="$2" credential temp_file
    mihomo_ensure_proxy_auth_file "$auth_file" || return 1
    credential="${MIHOMO_PROXY_USERNAME}:${MIHOMO_PROXY_PASSWORD}"

    # 先移除旧的项目管理项，保证凭据文件被删除并重装时不会留下可继续使用的旧密码。
    if grep -Fq '# mihomo-install-managed' "$config_file"; then
        temp_file="$(mktemp "${config_file}.old-auth.XXXXXX")" || return 1
        awk '!/# mihomo-install-managed[[:space:]]*$/' "$config_file" > "$temp_file" \
            || { rm -f "$temp_file"; return 1; }
        mv "$temp_file" "$config_file" || return 1
    fi

    if ! grep -Fq -- "- \"${credential}\"" "$config_file"; then
        temp_file="$(mktemp "${config_file}.auth.XXXXXX")" || return 1
        if grep -Eq '^authentication:[[:space:]]*$' "$config_file"; then
            awk -v credential="$credential" '
                !inserted && /^authentication:[[:space:]]*$/ {
                    print
                    print "  - \"" credential "\" # mihomo-install-managed"
                    inserted = 1
                    next
                }
                { print }
            ' "$config_file" > "$temp_file" || { rm -f "$temp_file"; return 1; }
        elif grep -Eq '^authentication:[[:space:]]*\[\][[:space:]]*$' "$config_file"; then
            awk -v credential="$credential" '
                /^authentication:[[:space:]]*\[\][[:space:]]*$/ {
                    print "authentication:"
                    print "  - \"" credential "\" # mihomo-install-managed"
                    next
                }
                { print }
            ' "$config_file" > "$temp_file" || { rm -f "$temp_file"; return 1; }
        elif grep -Eq '^authentication:' "$config_file"; then
            echo "config.yaml 使用了不受支持的行内 authentication 写法，未自动修改。" >&2
            rm -f "$temp_file"
            return 1
        else
            awk -v credential="$credential" '
                !inserted && /^proxy-providers:/ {
                    print "authentication:"
                    print "  - \"" credential "\" # mihomo-install-managed"
                    print ""
                    inserted = 1
                }
                { print }
                END {
                    if (!inserted) {
                        print ""
                        print "authentication:"
                        print "  - \"" credential "\" # mihomo-install-managed"
                    }
                }
            ' "$config_file" > "$temp_file" || { rm -f "$temp_file"; return 1; }
        fi
        mv "$temp_file" "$config_file" || return 1
    fi

    # Mihomo 的完整示例常将 loopback 加入跳过认证范围；个人模式必须显式清空，
    # 否则同一台 Linux 主机上的其他用户仍能绕过随机凭据。
    if grep -Eq '^skip-auth-prefixes:' "$config_file"; then
        temp_file="$(mktemp "${config_file}.skip-auth.XXXXXX")" || return 1
        awk '
            /^skip-auth-prefixes:/ {
                print "skip-auth-prefixes: []"
                skipping = 1
                next
            }
            skipping && /^[^[:space:]]/ { skipping = 0 }
            skipping { next }
            { print }
        ' "$config_file" > "$temp_file" || { rm -f "$temp_file"; return 1; }
        mv "$temp_file" "$config_file" || return 1
    else
        printf '\nskip-auth-prefixes: []\n' >> "$config_file" || return 1
    fi
}
