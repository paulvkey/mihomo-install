# Mihomo 核心安装脚本

用于在 systemd Linux 上安装 Mihomo 核心。

## 安装行为

1. 仅支持 `x86_64`（AMD64）Linux；其他架构会直接退出。
2. 优先使用脚本同级 `bin/` 目录内的 `mihomo-linux-amd64-v2-*.gz`；若有多个，使用版本号最高者。
3. 本地 v2 包不存在或校验失败时，通过 GitHub Releases API 下载最新版本的 AMD64 gzip 资源。Release 查询与文件下载都会依次尝试 GitHub 加速镜像，并在镜像失败后回退至 GitHub 原始地址。
4. 首次安装时交互输入订阅链接，并将核心、`config.yaml` 和（若存在）`Country.mmdb` 安装到当前用户的 `~/mihomo`。
5. 创建用户级 `mihomo.service`，无需 sudo。
6. 代理、控制接口和 DNS 仅监听 `127.0.0.1`，不会向局域网设备开放。
7. 每次安装会在 `20000-59999` 范围内为 HTTP、SOCKS、控制接口和 DNS 分配不同的可用随机端口。
8. 服务因端口绑定失败时，自动重新分配端口并重试，最多 3 次；仍失败时终止安装并显示日志诊断命令。

## 使用

```bash
git clone https://github.com/paulvkey/mihomo-install.git
cd mihomo-install
bash install.sh
```

### GitHub 网络异常

原始地址连接超时或被重置时，可改用镜像克隆：

```bash
git clone https://ghfast.top/https://github.com/paulvkey/mihomo-install.git
cd mihomo-install
bash install.sh
```

如果你已有本地 HTTP 代理（以下以 7890 为例），可让 Git 通过代理连接后再克隆：

```bash
git config --global http.proxy http://127.0.0.1:7890
git config --global https.proxy http://127.0.0.1:7890
git clone https://github.com/paulvkey/mihomo-install.git
```

不再需要代理时清除 Git 配置：

```bash
git config --global --unset http.proxy
git config --global --unset https.proxy
```

安装完成后检查服务：

```bash
systemctl --user status mihomo
```

重装时，核心会更新；已有 `~/mihomo/config.yaml` 默认保留，只有明确输入 `y` 才会覆盖。选择覆盖时，需要重新输入订阅链接，并会重新分配端口。

## 安装结果

- 核心文件：`~/mihomo/mihomo`
- 主配置：`~/mihomo/config.yaml`
- GeoIP 数据库：`~/mihomo/Country.mmdb`（项目内存在时）
- systemd 用户服务：`~/.config/systemd/user/mihomo.service`

随机端口保存在 `~/mihomo/config.yaml`。需要查看实际端口时，可执行：

```bash
grep -E '^(port|socks-port|external-controller):|^  listen:' ~/mihomo/config.yaml
```

安装文件与服务均限定在当前用户目录；不会创建系统级服务或修改其他用户的配置。网络端口仅对本机开放。

服务管理：

```bash
clashon             # 启动 Mihomo
clashoff            # 停止 Mihomo
clash_restart       # 重启 Mihomo
clash_status        # 查看 Mihomo 状态
```

上述命令位于 `~/.local/bin`。若提示找不到命令，将该目录加入当前 shell 的 PATH：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### 重新登录后启动

安装脚本已执行 `systemctl --user enable mihomo`。在正常登录且用户 systemd 可用的系统中，重新登录后会自动启动；可用以下命令确认：

```bash
systemctl --user status mihomo
```

若未自动启动，手动执行：

```bash
systemctl --user start mihomo
```

无 sudo 权限时，用户登出后服务通常不会持续运行；要让它在登出或重启后仍保持运行，需要管理员执行 `loginctl enable-linger <用户名>`。

卸载当前用户的 Mihomo（会删除 `~/mihomo`）：

```bash
bash uninstall.sh
```

## 要求

- 支持 systemd 的 Linux 发行版
- `x86_64`（AMD64）CPU
- `bash`、`curl`、`gzip`、`systemctl`
- 普通 Linux 用户权限；无需 sudo
- 支持用户级 systemd（`systemctl --user`）
