# Mihomo 核心安装脚本

用于在 systemd Linux 上安装和运行 Mihomo，支持当前用户独享和系统服务共享两种模式。

## 快速开始

```bash
git clone https://github.com/paulvkey/mihomo-install.git
cd mihomo-install
```

如果 GitHub 直连异常，请不要关闭 TLS 校验；可按[完整使用说明中的网络异常处理](docs/USAGE.md#github-克隆网络异常)通过已有代理、SSH 或源码压缩包获取项目。

根据使用场景选择一种安装方式：

| 模式 | 安装命令 | 管理命令 | 适用场景 |
|---|---|---|---|
| 当前用户模式 | `bash install.sh` | `clash <命令>` | 普通用户安装，独立订阅、端口和节点，无需 sudo |
| 系统共享模式 | `sudo bash install_sys.sh` | `clashsys <命令>` | 管理员安装一次，所有本机用户共享服务和节点 |

两种模式相互独立，可以同时安装。完整的安装、日常命令、节点选择、普通用户使用共享代理、登录行为和卸载说明，请阅读：

> [完整使用说明](docs/USAGE.md)

## 主要特性

- 仅支持 `x86_64`（AMD64）Linux 和 systemd。
- 优先使用仓库内经过 SHA256 校验的 Mihomo v2 核心，没有有效本地包时从 GitHub 最新 Release 下载。
- GitHub 资产下载支持加速镜像和原始地址回退。
- 个人模式无需 sudo，文件和服务均限定在当前用户目录，并使用随机代理凭据防止同机其他用户直接复用端口。
- 系统共享模式使用独立的无登录服务账户，管理员可授权 `mihomo-control` 组成员切换共享节点。
- 安装前先完成核心与配置自检，提交阶段失败会恢复安装前状态。
- 节点选择会测速但保持订阅原始顺序；`DIRECT` 兜底不作为订阅节点，超时或未测得延迟的真实节点只作异常标记，仍允许用户选择。
- `clash on` 会高亮当前节点；当前节点可用时直接沿用并跳过选择，仅在未选择或当前节点不可用时进入列表。系统模式对 root 和 `mihomo-control` 控制用户提供相同行为。
- 可通过 `clash subscription` 或 `clashsys subscription` 交互更换订阅；新订阅无法启动或没有加载到真实节点时自动恢复旧配置和缓存。

## 安装实现与资源维护

已有个人配置时，重装默认保留订阅和端口；只有明确选择覆盖才会重新输入订阅并分配端口。为修复旧版的同机用户越权风险，即使保留配置，重装也会补齐个人 HTTP/SOCKS 认证并清空 loopback 免认证列表。

安装和重装会先在临时目录准备核心、配置并执行自检，通过后才停止现有服务并切换文件。若核心、服务、命令安装或 Shell 集成中的任何一步失败，会恢复安装前状态。系统模式也会回滚本次新建的账户、组、组成员关系和目录，并拒绝覆盖没有项目标记的系统文件或符号链接。

GitHub Release 元数据优先访问官方地址，官方不可用时才回退镜像并显示信任边界警告。核心和 GeoIP 下载结果必须通过 Release 元数据中的 SHA256 校验。

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
├── README.md
├── docs/
│   └── USAGE.md               # 两种模式的完整使用说明
├── config/
│   └── config.yaml            # 默认配置模板
├── scripts/
│   ├── update_resources.sh    # GeoIP 与核心包维护工具
│   ├── check.sh               # 语法、行为和可选 ShellCheck 检查
│   ├── lib/                   # 端口、认证和 GitHub 下载共用函数
│   └── commands/              # clash 入口及其内部命令组件
├── tests/
│   ├── run.sh                 # 不需要 systemd/root 的行为测试
│   └── mihomo_auth.sh         # x86_64 Linux 上验证真实核心的认证
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

## 安装行为

1. 仅支持 `x86_64`（AMD64）Linux；其他架构会直接退出。
2. 优先使用 `resources/bin/` 的 `mihomo-linux-amd64-v2-*.gz`，存在多个时选版本最高者；本地包必须有对应 `.sha256` 文件且校验通过。
3. 本地包不存在或无效时，查询 GitHub 最新 Release；查询和下载依次尝试加速镜像并回退原始 GitHub，下载结果必须匹配 Release API 提供的 SHA256。
4. 个人模式将核心、配置和 GeoIP 数据安装在当前用户的 `~/mihomo`。
5. 个人模式创建用户级 `mihomo.service`，无需 sudo；代理、控制接口和 DNS 均只监听 `127.0.0.1`，不向局域网开放；控制接口使用随机密钥认证。
6. 个人 HTTP/SOCKS 入口使用随机用户名和密码认证，并显式禁止 loopback 跳过认证；系统共享模式不启用个人凭据。
7. 个人模式的 HTTP、SOCKS、控制接口和 DNS 使用系统随机源，在 `20000-59999` 范围内分配不同端口。确认端口绑定失败时会自动重分配并重试，最多 3 次。
8. 核心和配置先写入临时目录，再用 `mihomo -t` 自检；语法或规则错误不会停止、覆盖现有安装。
9. `~/mihomo` 权限为 `700`，`config.yaml`、`proxy-auth` 和 `proxy.env` 权限为 `600`，订阅、密钥和代理凭据仅允许当前用户读取。
10. 默认 DNS 优先使用系统解析器，并保留公共 DNS 回退；IPv4/IPv6 私网直连，`GEOIP,CN` 使用随项目安装的 `Country.mmdb` 直连。

## 安装结果

个人模式：

- 核心文件：`~/mihomo/mihomo`
- 主配置：`~/mihomo/config.yaml`
- 代理凭据：`~/mihomo/proxy-auth`
- 代理环境文件：`~/mihomo/proxy.env`
- GeoIP 数据库：`~/mihomo/Country.mmdb`
- systemd 用户服务：`~/.config/systemd/user/mihomo.service`
- 管理命令：`~/.local/bin/clash`
- 内部命令组件：`~/.local/lib/mihomo-install/`

系统共享模式：

- 核心文件：`/usr/local/lib/mihomo/mihomo`
- 主配置：`/etc/mihomo/config.yaml`
- 运行数据：`/var/lib/mihomo`
- systemd 系统服务：`mihomo-system.service`
- 管理命令：`/usr/local/bin/clashsys`
- Shell 集成：`/etc/profile.d/mihomo-system.sh`

## 要求

- 支持 systemd 的 Linux 发行版
- `x86_64`（AMD64）CPU
- `bash`、`curl`、`gzip`、`jq`、`systemctl`、`journalctl`
- `sha256sum` 或 `shasum`
- 推荐提供 `ss` 或 `netstat`，用于安装前检测端口占用
- 个人模式需要普通 Linux 用户权限和用户级 systemd，无需 sudo

系统共享模式还要求：

- 使用 root 或具备 sudo 权限的管理员执行
- 系统提供 `useradd`、`userdel`、`groupadd`、`groupdel`、`usermod`、`gpasswd`、`getent`、`sudo`、`visudo`
- 支持系统级 systemd 服务

## 检查与许可证

提交前可执行：

```bash
bash scripts/check.sh
```

脚本会运行 Shell 语法检查和不依赖 Linux/systemd 的行为测试；本机安装 ShellCheck 时还会运行其错误级别检查。GitHub Actions 也会执行同一入口。

项目脚本使用 [MIT License](LICENSE)。仓库附带的 Mihomo 核心和 Country.mmdb 保持上游 GPL-3.0 许可证，来源、对应源代码和许可证链接见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
