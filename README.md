# Mihomo 核心安装脚本

用于在 systemd Linux 上以普通用户身份安装和运行 Mihomo。

## 快速使用

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
clash_select        # 单独交互选择订阅节点
```

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
└── resources/
    ├── Country.mmdb
    ├── Country.mmdb.sha256
    └── bin/                   # AMD64 v2 核心包及其 SHA256
```

日常安装和卸载仍在项目根目录执行 `bash install.sh`、`bash uninstall.sh`；只有资源维护脚本移动到了 `scripts/`。

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
