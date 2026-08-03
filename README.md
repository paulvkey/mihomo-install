# Mihomo 核心安装脚本

用于在 systemd Linux 上安装和运行 Mihomo，同时支持“当前用户独享”和“系统服务共享”两种模式。

## 模式选择

| 模式 | 安装命令 | 适用场景 |
|---|---|---|
| 当前用户模式 | `bash install.sh` | 每个用户拥有独立配置、端口和节点 |
| 系统共享模式 | `sudo bash system/install.sh` | 管理员安装一次，所有本机用户共享服务和节点 |

两种模式相互独立，可以同时安装。原有 `install.sh`、`uninstall.sh` 和 `clashon` 等个人模式逻辑保持不变。

## 当前用户模式

```bash
git clone https://ghfast.top/https://github.com/paulvkey/mihomo-install.git
cd mihomo-install
bash install.sh
```

安装过程中需要输入 Clash/Mihomo 订阅链接；安装成功后会交互选择节点。

脚本会将命令路径和代理加载函数写入 `~/.bashrc`。安装后在当前终端执行一次：

```bash
source ~/.bashrc
```

之后可直接使用：

```bash
clashon             # 未运行时启动并选择节点；已运行时仅同步当前 HTTP/HTTPS 代理
clashoff            # 停止 Mihomo，并清除当前终端的 HTTP/HTTPS 代理变量
clash_restart       # 重启 Mihomo，并更新当前终端的 HTTP/HTTPS 代理变量
clash_status        # 查看 Mihomo 状态
clash_select        # 测速、过滤异常节点并交互选择订阅节点
```

`clash_select` 会通过 Mihomo 控制接口测试 `PROXY` 组内的节点，按延迟从低到高展示。超时或不可用节点不会进入选择列表；选择延迟达到 `1500 ms` 的节点时会要求再次确认。默认测试地址为 `https://www.gstatic.com/generate_204`，超时时间为 `5000 ms`。

如需临时调整测试参数，可在执行命令时传入环境变量：

```bash
CLASH_DELAY_TIMEOUT_MS=8000 CLASH_DELAY_WARN_MS=2000 clash_select
```

## 系统共享模式

管理员执行：

```bash
sudo bash system/install.sh
```

安装时还会交互询问两项系统共享设置：

```text
请输入本次要加入 mihomo-control 的用户（空格分隔，默认：admin）: alice bob
是否让没有个人 Mihomo 的用户登录后自动启用系统代理？[y/N]: y
```

- 第一项可以一次输入多个本机用户名。通过 `sudo` 安装时，留空默认添加当前管理员；直接用 root 安装时，留空表示不新增控制用户。已有组成员不会被删除，输入不存在的用户时脚本会要求重新输入。
- 第二项默认选择 `N`，此时每个用户仍需在自己的终端执行 `clashsys on`。选择 `y` 后，没有个人 Mihomo 安装痕迹的用户会在下次登录 Bash 时自动加载系统代理；当前已经打开的终端不会被修改。
- 重装时，自动启用选项默认保持现状。新增的组权限需要相关用户重新登录后才会生效。

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
clashon           # 再执行后，切换到当前用户代理
clashsys on       # 再执行后，重新切回系统共享代理
```

`clashsys off` 只会在当前代理地址确实指向系统端口时清除变量，不会误删之后加载的个人代理。个人模式的 `clashoff` 保持原行为，会清除当前终端代理变量；需要继续使用系统代理时，再执行一次 `clashsys on`。

自动启用选项为默认关闭。管理员开启后，登录脚本只会为不存在 `~/.local/bin/clashon`、`~/.config/systemd/user/mihomo.service` 和 `~/mihomo` 的用户自动执行 `clashsys on`；检测到任一项个人安装痕迹时都不会覆盖个人代理。个人用户仍可显式执行 `clashsys on` 切换到系统代理。这里的“系统共享代理”是所有用户都能访问的本机 HTTP/SOCKS 服务，并不是透明代理；只有遵循代理环境变量或显式配置代理地址的程序会使用它，`ping` 仍不会经过代理。

系统共享端口只在首次安装或明确覆盖系统配置时从 `10000-19999` 随机一次，和个人模式使用的 `20000-59999` 分开，之后重启保持不变。系统端口冲突会导致启动失败并显示日志，不会静默换端口造成所有用户的环境变量失效。

卸载系统共享模式：

```bash
sudo bash system/uninstall.sh
```

系统卸载不会删除任何用户的个人模式文件或用户级服务。
专用账户 `mihomo` 及 `mihomo-control` 组默认保留，避免卸载脚本误删安装前已经存在的系统账户或组。

## 使用代理

端口会在安装时随机分配。服务正常停止后，`clashon` 会使用原端口启动，不会重新分配端口；若 Mihomo 已运行，它只读取 `~/mihomo/config.yaml` 的当前 HTTP 端口并同步当前终端的 `http_proxy`、`https_proxy`、`HTTP_PROXY` 和 `HTTPS_PROXY`。只有启动失败且日志确认端口被占用时，`clashon` 才会提示用户、重新分配四个端口并重试，最多 3 次。重装或端口重新分配后，无需再次编辑或 `source ~/.bashrc`；下次执行 `clashon` 即会读取新端口。

新开终端只会在 Mihomo 确实运行时加载上一次 `clashon` 或 `clash_restart` 保存的代理端口。`clashoff` 会删除代理环境文件，避免服务停止后新终端仍使用失效代理。

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

已有 `~/mihomo` 时，脚本会询问是否更新核心。已有 `~/mihomo/config.yaml` 默认保留；只有明确输入 `y` 才会覆盖。覆盖配置时需要重新输入订阅链接，并重新分配端口。

安装和重装会先在临时目录准备核心、配置并执行自检，通过后才停止现有服务并切换文件。若新服务启动失败，会恢复安装前的核心、配置和 systemd 服务状态。

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
├── install.sh                 # 安装和重装入口
├── uninstall.sh               # 当前用户卸载入口
├── README.md
├── config/
│   └── config.yaml            # 默认配置模板
├── scripts/
│   ├── update_resources.sh    # GeoIP 与核心包维护工具
│   └── commands/              # 安装到 ~/.local/bin 的管理命令源文件
├── system/
│   ├── install.sh             # 系统共享模式安装入口
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

个人模式仍在项目根目录执行 `bash install.sh`、`bash uninstall.sh`；资源维护工具位于 `scripts/`，系统共享模式入口位于 `system/`。

## 登录、退出与卸载

安装脚本已执行 `systemctl --user enable mihomo`。正常登录且用户 systemd 可用时，重新登录后会自动启动；未启动时可执行：

```bash
clashon
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
6. HTTP、SOCKS、控制接口和 DNS 在 `20000-59999` 内使用不同随机端口。端口绑定失败时会自动重分配并重试，最多 3 次；仍失败则终止安装并显示诊断日志命令。
7. 核心和配置先写入临时目录，再用 `mihomo -t` 自检；语法或规则错误不会停止、覆盖现有安装。
8. `~/mihomo` 权限设置为 `700`，`config.yaml` 权限设置为 `600`，订阅链接和控制密钥仅允许当前用户读取。

## 安装结果

- 核心文件：`~/mihomo/mihomo`
- 主配置：`~/mihomo/config.yaml`
- GeoIP 数据库：`~/mihomo/Country.mmdb`
- systemd 用户服务：`~/.config/systemd/user/mihomo.service`
- 管理命令：`~/.local/bin/clashon`、`clashoff`、`clash_restart`、`clash_status`、`clash_select`
- 命令公共库：`~/.local/lib/mihomo-install/common.sh`

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
- 系统提供 `useradd`、`groupadd`、`usermod`、`getent`、`sudo`、`visudo`
- 支持系统级 systemd 服务
