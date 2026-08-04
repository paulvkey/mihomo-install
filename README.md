# Mihomo 核心安装脚本

用于在 systemd Linux 上安装和运行 Mihomo，同时支持“当前用户独享”和“系统服务共享”两种模式。

## 模式选择

| 模式 | 安装命令 | 适用场景 |
|---|---|---|
| 当前用户模式 | `bash install.sh` | 每个用户拥有独立配置、端口和节点 |
| 系统共享模式 | `sudo bash install_sys.sh` | 管理员安装一次，所有本机用户共享服务和节点 |

两种模式相互独立，可以同时安装。个人模式统一使用 `clash <命令>`，系统共享模式使用 `clashsys <命令>`。

## 当前用户模式

```bash
git clone https://ghfast.top/https://github.com/paulvkey/mihomo-install.git
cd mihomo-install
bash install.sh
```

安装过程中需要输入 Clash/Mihomo 订阅链接，输入内容会正常回显，便于确认；安装成功后会交互选择节点。

脚本会将命令路径和代理加载函数写入 `~/.bashrc`。安装后在当前终端执行一次：

```bash
source ~/.bashrc
```

之后可直接使用：

```bash
clash on       # 未运行时启动并选择节点；已运行时保持原端口并同步代理
clash off      # 停止 Mihomo；仅在当前终端使用个人代理时清除对应变量
clash restart  # 重启 Mihomo，并更新当前终端的 HTTP/HTTPS 代理变量
clash status   # 查看 Mihomo 状态
clash select   # 测速、过滤异常节点并交互选择订阅节点
clash auth     # 显示手动配置应用时需要的代理用户名、密码和地址
clash help     # 查看个人模式命令帮助
```

`clash select` 会通过 Mihomo 控制接口测试 `PROXY` 组内的真实代理节点，按延迟从低到高展示。`DIRECT` 兜底、超时或不可用节点不会进入选择列表；选择延迟达到 `1500 ms` 的节点时会要求再次确认。默认测试地址为 `https://www.gstatic.com/generate_204`，超时时间为 `5000 ms`。

从旧版本重装后，脚本会删除本项目创建的 `clashon`、`clashoff`、`clash_restart`、`clash_status` 和 `clash_select` 旧命令，统一改用上述 `clash` 子命令；不会删除用户自己创建的同名文件。

个人模式首次安装会生成随机 HTTP/SOCKS 用户名和密码，保存于权限为 `600` 的 `~/mihomo/proxy-auth`；正常重装会复用，不会让已配置的客户端突然失效。`clash on` 和 `clash restart` 写出的代理环境变量会自动携带凭据，因此 `curl`、`wget` 等读取环境变量的程序无需额外操作。浏览器、IDE、Docker 等手工配置的客户端需要填写 `clash auth` 显示的地址或用户名/密码；缺少凭据时会被拒绝。这样可以防止同一台 Linux 主机上的其他用户仅通过发现个人端口来使用该代理。若删除 `proxy-auth` 后重装，脚本会撤销旧的项目管理凭据并生成新凭据，手工配置的客户端也必须同步更新。

如需临时调整测试参数，可在执行命令时传入环境变量：

```bash
CLASH_DELAY_TIMEOUT_MS=8000 CLASH_DELAY_WARN_MS=2000 clash select
```

## 系统共享模式

管理员执行：

```bash
sudo bash install_sys.sh
```

安装时还会交互询问两项系统共享设置：

```text
请输入本次要加入 mihomo-control 的用户（空格分隔，默认：admin）: alice bob
是否让没有个人 Mihomo 的用户登录后自动启用系统代理？[y/N]: y
```

- 第一项可以一次输入多个本机用户名。通过 `sudo` 安装时，留空默认添加当前管理员；直接用 root 安装时，留空表示不新增控制用户。已有组成员不会被删除，输入不存在的用户时脚本会要求重新输入。
- 第二项默认选择 `N`，此时每个用户仍需在自己的终端执行 `clashsys on`。选择 `y` 后，没有个人 Mihomo 安装痕迹的用户会在下次登录 Bash 时自动加载系统代理；当前已经打开的终端不会被修改。
- 重装时，自动启用选项默认保持现状。新增的组权限需要相关用户重新登录后才会生效。

服务启动成功后，安装脚本会立即检测订阅节点的延迟并进入首次节点选择。配置中的 `DIRECT` 只是兜底项，不会被当作订阅节点；如果订阅异常、未加载到真实节点或所有节点均不可用，脚本会明确警告，但会保留已经安装并运行的系统服务。修复订阅后执行 `clashsys select` 即可重新测速和选择。

系统模式安装到 `/usr/local/lib/mihomo`、`/etc/mihomo` 和 `/var/lib/mihomo`，创建随系统启动的 `mihomo-system.service`，不依赖管理员登录，也不会修改任何用户的 `~/mihomo` 或 `~/.bashrc`。服务以无登录的专用 `mihomo` 用户运行，仍然只监听 `127.0.0.1`；系统配置权限为 `root:mihomo 0640`，普通用户不能读取订阅和控制密钥。

安装后，用户重新登录，或者在当前 Bash 终端执行：

```bash
source /etc/profile.d/mihomo-system.sh
```

所有用户均可执行：

```bash
clashsys on       # 当前终端切换到系统共享代理
clashsys off      # 当前终端停用系统代理；不会停止共享服务
clashsys status   # 查看共享服务状态
clashsys help     # 查看帮助
```

安装脚本会根据交互输入创建 `mihomo-control` 组并添加控制用户。相关用户重新登录后可以执行：

```bash
clashsys select   # 测速并切换共享节点，会影响所有系统代理用户
clashsys restart  # 重启共享服务，保持原端口
```

授权其他控制用户：

```bash
sudo usermod -aG mihomo-control <用户名>
```

新增组权限需要用户重新登录后生效。普通用户不允许停止或重启共享服务，也不能读取订阅链接和控制密钥。

### 个人代理与系统代理优先级

这两种服务可以同时运行，但 shell 中只有一组 `http_proxy`、`https_proxy`、`HTTP_PROXY` 和 `HTTPS_PROXY` 变量，不存在服务自身的固定优先级。当前终端最后一次加载的代理地址生效：

```bash
clashsys on       # 切换到系统共享代理
clash on          # 再执行后，切换到当前用户代理
clashsys on       # 再执行后，重新切回系统共享代理
```

`clashsys off` 只会在当前代理地址确实指向系统端口时清除变量，不会误删之后加载的个人代理。`clash off` 同样只清理本项目的个人代理变量；如果当前终端正在使用系统代理或用户原有的其他代理，则保持不变。个人代理停止后若要切换到系统代理，可执行 `clashsys on`。

自动启用选项为默认关闭。管理员开启后，登录脚本只会为不存在 `~/.local/bin/clash`、`~/.config/systemd/user/mihomo.service` 和 `~/mihomo` 的用户自动执行 `clashsys on`；检测到任一项个人安装痕迹时都不会覆盖个人代理。个人用户仍可显式执行 `clashsys on` 切换到系统代理。这里的“系统共享代理”是所有用户都能访问的本机 HTTP/SOCKS 服务，并不是透明代理；只有遵循代理环境变量或显式配置代理地址的程序会使用它，`ping` 仍不会经过代理。

系统共享端口只在首次安装或明确覆盖系统配置时从 `10000-19999` 随机一次，和个人模式使用的 `20000-59999` 分开，之后重启保持不变。系统端口冲突会导致启动失败并显示日志，不会静默换端口造成所有用户的环境变量失效。

卸载系统共享模式：

```bash
sudo bash system/uninstall.sh
```

系统卸载不会删除任何用户的个人模式文件或用户级服务。
专用账户 `mihomo` 及 `mihomo-control` 组默认保留，避免卸载脚本误删安装前已经存在的系统账户或组。

## 使用代理

端口会在安装时随机分配。服务正常停止后，`clash on` 会使用原端口启动，不会重新分配端口；若 Mihomo 已运行，它只读取 `~/mihomo/config.yaml` 的当前 HTTP 端口并同步当前终端的 `http_proxy`、`https_proxy`、`HTTP_PROXY` 和 `HTTPS_PROXY`。只有启动失败且日志确认端口被占用时，`clash on` 才会提示用户、重新分配四个端口并重试，最多 3 次。重装或端口重新分配后，无需再次编辑或 `source ~/.bashrc`；下次执行 `clash on` 即会读取新端口。

新开终端只会在 Mihomo 确实运行时加载 `clash on` 或 `clash restart` 保存的代理端口。`clash off` 会删除代理环境文件，避免服务停止后新终端仍使用失效代理。

验证代理连通性：

```bash
curl -I https://www.google.com
```

`ping` 使用 ICMP，不会经过 HTTP/SOCKS 代理；请用 `curl` 等 HTTP/HTTPS 请求验证节点。

查看实际端口：

```bash
grep -E '^(port|socks-port|external-controller):|^  listen:' ~/mihomo/config.yaml
```

## 安装与重装

GitHub 网络异常时可使用镜像克隆：

```bash
git clone https://ghfast.top/https://github.com/paulvkey/mihomo-install.git
cd mihomo-install
bash install.sh
```

已有 `~/mihomo` 时，脚本会询问是否更新核心。已有 `~/mihomo/config.yaml` 默认保留订阅和端口；只有明确输入 `y` 才会使用模板覆盖，覆盖时需要重新输入订阅链接并重新分配端口。为修复旧版的同机用户越权风险，即使选择保留配置，重装也会补齐个人 HTTP/SOCKS 认证并清空 loopback 免认证列表。

安装和重装会先在临时目录准备核心、配置并执行自检，通过后才停止现有服务并切换文件。若核心、服务、命令安装或 `~/.bashrc` 集成中的任何一步失败，会恢复安装前的核心、配置、认证、代理环境、systemd 服务、命令组件和 Bash 配置。系统模式也会回滚本次新建的账户、组、组成员关系和目录，并拒绝覆盖无项目标记的系统文件或符号链接。

GitHub 资产下载优先尝试镜像，Release 元数据优先访问 GitHub 官方地址，官方不可用时才回退镜像并显示信任边界警告。下载的核心和 GeoIP 必须通过 Release 元数据中的 SHA256 校验。可按网络情况临时调整超时秒数：

```bash
MIHOMO_CURL_CONNECT_TIMEOUT=15 MIHOMO_CURL_DOWNLOAD_TIMEOUT=600 bash install.sh
```

维护仓库资源：

```bash
bash scripts/update_resources.sh --geoip          # 更新 Country.mmdb
bash scripts/update_resources.sh --bin            # 更新到最新 Mihomo v2 核心
bash scripts/update_resources.sh --bin 1.19.29    # 更新到指定版本
bash scripts/update_resources.sh --all            # 同时更新两类资源
```

## 项目结构

```text
mihomo-install/
├── install.sh                 # 当前用户模式安装和重装入口
├── install_sys.sh             # 系统共享模式安装入口（需要 root/sudo）
├── uninstall.sh               # 当前用户卸载入口
├── LICENSE
├── THIRD_PARTY_NOTICES.md
├── README.md
├── config/
│   └── config.yaml            # 默认配置模板
├── scripts/
│   ├── update_resources.sh    # GeoIP 与核心包维护工具
│   ├── check.sh               # 语法、行为和可选 ShellCheck 检查
│   ├── lib/                   # 端口、认证和 GitHub 下载共用函数
│   └── commands/              # clash 入口及其内部命令组件
├── tests/
│   ├── run.sh                 # 不需要 systemd/root 的行为测试
│   └── mihomo_auth.sh         # x86_64 Linux 上验证真实核心的 HTTP/SOCKS 认证
├── system/
│   ├── uninstall.sh           # 系统共享模式卸载入口
│   ├── mihomo-system.service  # 系统级 systemd 服务模板
│   ├── commands/              # clashsys 命令源文件
│   ├── profile.d/             # 全局 Bash 函数
│   └── sudoers/               # 控制组的受限授权规则
└── resources/
    ├── Country.mmdb
    ├── Country.mmdb.sha256
    └── bin/                   # AMD64 v2 核心包及其 SHA256
```

个人模式仍执行 `bash install.sh`、`bash uninstall.sh`；系统共享模式执行根目录的 `sudo bash install_sys.sh`，其服务模板和卸载入口保留在 `system/`；资源维护工具位于 `scripts/`。

## 登录、退出与卸载

安装脚本已执行 `systemctl --user enable mihomo`。正常登录且用户 systemd 可用时，重新登录后会自动启动；未启动时可执行：

```bash
clash on
```

无 sudo 权限时，用户登出后服务通常不会持续运行。若要在登出或重启后仍保持运行，需要管理员执行：

```bash
loginctl enable-linger <用户名>
```

卸载当前用户的 Mihomo（会删除 `~/mihomo`）：

```bash
bash uninstall.sh
```

## 安装行为

1. 仅支持 `x86_64`（AMD64）Linux；其他架构会直接退出。
2. 优先使用 `resources/bin/` 的 `mihomo-linux-amd64-v2-*.gz`，存在多个时选版本最高者；本地包必须有对应 `.sha256` 文件且校验通过。
3. 本地包不存在或无效时，查询 GitHub 最新 Release；查询和下载依次尝试加速镜像并回退原始 GitHub，下载结果必须匹配 Release API 提供的 SHA256。
4. 核心、配置和 GeoIP 数据安装在当前用户的 `~/mihomo`。
5. 创建用户级 `mihomo.service`，无需 sudo；代理、控制接口和 DNS 均只监听 `127.0.0.1`，不向局域网开放；控制接口使用安装时生成的随机密钥认证。
6. 个人 HTTP/SOCKS 入口使用随机用户名和密码认证，并显式禁止 loopback 跳过认证；系统共享模式不启用这组个人凭据。
7. HTTP、SOCKS、控制接口和 DNS 使用系统随机源，在完整的 `20000-59999` 范围内分配不同端口。端口绑定失败时会自动重分配并重试，最多 3 次；仍失败则终止安装并显示诊断日志命令。
8. 核心和配置先写入临时目录，再用 `mihomo -t` 自检；语法或规则错误不会停止、覆盖现有安装。
9. `~/mihomo` 权限设置为 `700`，`config.yaml`、`proxy-auth` 和 `proxy.env` 权限设置为 `600`，订阅、密钥和代理凭据仅允许当前用户读取。
10. 默认 DNS 优先使用系统解析器，并保留公共 DNS 回退；IPv4/IPv6 私网直连，`GEOIP,CN` 使用随项目安装的 `Country.mmdb` 直连。

## 安装结果

- 核心文件：`~/mihomo/mihomo`
- 主配置：`~/mihomo/config.yaml`
- 个人代理凭据：`~/mihomo/proxy-auth`
- 当前端口与凭据生成的环境文件：`~/mihomo/proxy.env`
- GeoIP 数据库：`~/mihomo/Country.mmdb`
- systemd 用户服务：`~/.config/systemd/user/mihomo.service`
- 管理命令：`~/.local/bin/clash`，支持 `on`、`off`、`restart`、`status`、`select`、`auth`、`help` 子命令
- 内部命令组件：`~/.local/lib/mihomo-install/`（不需要直接执行）

## 要求

- 支持 systemd 的 Linux 发行版
- `x86_64`（AMD64）CPU
- `bash`、`curl`、`gzip`、`jq`、`systemctl`、`journalctl`
- `sha256sum` 或 `shasum`
- 推荐提供 `ss` 或 `netstat`，用于安装前检测端口占用
- 普通 Linux 用户权限；无需 sudo
- 支持用户级 systemd（`systemctl --user`）

系统共享模式还要求：

- 使用 root 或具备 sudo 权限的管理员执行
- 系统提供 `useradd`、`userdel`、`groupadd`、`groupdel`、`usermod`、`gpasswd`、`getent`、`sudo`、`visudo`
- 支持系统级 systemd 服务

## 检查与许可证

提交前可执行：

```bash
bash scripts/check.sh
```

脚本会运行 Shell 语法检查和不依赖 Linux/systemd 的行为测试；本机安装了 ShellCheck 时还会运行其错误级别检查。GitHub Actions 也会执行同一入口。

项目脚本使用 [MIT License](LICENSE)。仓库附带的 Mihomo 核心和 Country.mmdb 保持上游 GPL-3.0 许可证，来源、对应源代码和许可证链接见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
