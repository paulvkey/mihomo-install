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
clashon             # 启动 Mihomo、选择节点，并自动为当前终端启用 HTTP/HTTPS 代理
clashoff            # 停止 Mihomo，并清除当前终端的 HTTP/HTTPS 代理变量
clash_restart       # 重启 Mihomo，并更新当前终端的 HTTP/HTTPS 代理变量
clash_status        # 查看 Mihomo 状态
clash_select        # 单独交互选择订阅节点
```

`clash_select` 依赖 `jq`；缺少时请联系管理员安装，或手动通过 Mihomo 控制 API 选择节点。

## 使用代理

端口会在安装时随机分配。执行 `clashon` 后，会按 `~/mihomo/config.yaml` 中的当前 HTTP 端口自动设置当前终端的 `http_proxy`、`https_proxy`、`HTTP_PROXY` 和 `HTTPS_PROXY`。重装或端口重新分配后，无需再次编辑或 `source ~/.bashrc`；下次执行 `clashon` 即会读取新端口。

新开终端也会自动加载上一次 `clashon` 或 `clash_restart` 保存的代理端口。

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
2. 优先使用同级 `bin/` 的 `mihomo-linux-amd64-v2-*.gz`，存在多个时选版本最高者。
3. 本地包不存在或无效时，查询 GitHub 最新 Release；查询和下载依次尝试加速镜像，最后回退原始 GitHub。
4. 核心、配置和 GeoIP 数据安装在当前用户的 `~/mihomo`。
5. 创建用户级 `mihomo.service`，无需 sudo；代理、控制接口和 DNS 均只监听 `127.0.0.1`，不向局域网开放。
6. HTTP、SOCKS、控制接口和 DNS 在 `20000-59999` 内使用不同随机端口。端口绑定失败时会自动重分配并重试，最多 3 次；仍失败则终止安装并显示诊断日志命令。

## 安装结果

- 核心文件：`~/mihomo/mihomo`
- 主配置：`~/mihomo/config.yaml`
- GeoIP 数据库：`~/mihomo/Country.mmdb`
- systemd 用户服务：`~/.config/systemd/user/mihomo.service`
- 管理命令：`~/.local/bin/clashon`、`clashoff`、`clash_restart`、`clash_status`、`clash_select`

## 要求

- 支持 systemd 的 Linux 发行版
- `x86_64`（AMD64）CPU
- `bash`、`curl`、`gzip`、`systemctl`
- 普通 Linux 用户权限；无需 sudo
- 支持用户级 systemd（`systemctl --user`）
