# Mihomo 使用说明

[返回项目首页](../README.md)

本项目支持“当前用户独享”和“系统服务共享”两种模式。两种模式相互独立，可以同时安装：

| 模式         | 安装命令                   | 管理命令          | 适用场景                                   |
| ------------ | -------------------------- | ----------------- | ------------------------------------------ |
| 当前用户模式 | `bash install.sh`          | `clash <命令>`    | 每个用户使用独立订阅、端口和节点           |
| 系统共享模式 | `sudo bash install_sys.sh` | `clashsys <命令>` | 管理员安装一次，所有本机用户共享服务和节点 |

## 获取项目

优先从 GitHub 官方仓库克隆：

```bash
git clone https://github.com/paulvkey/mihomo-install.git
cd mihomo-install
```

### GitHub 克隆网络异常

如果使用第三方加速出现 `gnutls_handshake() failed`、连接超时或连接被重置时，可以操作如下：

```bash
git remote -v
git remote set-url origin https://github.com/paulvkey/mihomo-install.git
git remote -v
```

如果当前机器已经有可用的 Mihomo 代理，先执行 `clash on` 或 `clashsys on`，再克隆官方仓库：

```bash
clash on
git clone https://github.com/paulvkey/mihomo-install.git
cd mihomo-install
```

也可以只为本次 Git 命令指定已有 HTTP 代理，以下端口仅为示例：

```bash
git -c http.proxy=http://127.0.0.1:7890 clone https://github.com/paulvkey/mihomo-install.git
```

已经为 GitHub 配置 SSH 密钥时，可以改用 SSH：

```bash
git clone git@github.com:paulvkey/mihomo-install.git
```

## 当前用户模式

### 安装

使用普通 Linux 用户执行，无需 `sudo`：

```bash
bash install.sh
```

安装过程中需要输入 Clash/Mihomo 订阅链接，输入内容会正常回显。首次安装或明确覆盖配置时会生成随机端口；服务启动成功后，脚本会测速并交互选择节点。

脚本会将命令路径和代理加载函数写入 `~/.bashrc`。安装结束后，只需在当前已经打开的终端执行一次：

```bash
source ~/.bashrc
```

以后新开的 Bash 终端会自动加载，不需要每次执行 `source ~/.bashrc`。

### 日常命令

```bash
clash on       # 启动服务并让当前终端使用个人代理
clash off      # 停止服务，并清理当前终端中的个人代理变量
clash restart  # 重启服务，并更新当前终端的代理变量
clash status   # 查看用户级 Mihomo 服务状态
clash select   # 测速、标记异常节点并交互选择节点
clash auth     # 显示手动配置应用所需的地址和用户名、密码
clash help     # 查看帮助
```

服务已经运行时再次执行 `clash on` 不会随机修改端口，只会读取现有配置并同步当前终端的代理变量。服务未运行时也会优先复用原端口；只有确认启动失败是端口占用造成时，才会提示并重新分配端口，最多尝试 3 次。

### 选择节点

```bash
clash select
```

命令会检测 `PROXY` 组内真实代理节点的延迟，并把测得延迟的节点按从低到高排列。`DIRECT` 是配置兜底，不作为订阅节点展示；超时、不可用或测速请求失败的真实节点不会被删除，而是在列表中标记后继续允许选择。选择高延迟或未测得延迟的节点时会要求再次确认，测速结果仅作为参考。

临时调整测速超时和高延迟阈值：

```bash
CLASH_DELAY_TIMEOUT_MS=8000 CLASH_DELAY_WARN_MS=2000 clash select
```

如果提示没有真实代理节点，请确认订阅有效，并查看服务日志：

```bash
journalctl --user -u mihomo -n 80 --no-pager
```

修复配置或订阅后重新执行 `clash select`。

### 应用代理配置

`clash on` 和 `clash restart` 会自动设置当前终端的 `http_proxy`、`https_proxy`、`HTTP_PROXY` 和 `HTTPS_PROXY`，`curl`、`wget` 等读取代理环境变量的程序可直接使用。

浏览器、IDE、Docker 等需要手动填写代理的程序，可运行：

```bash
clash auth
```

个人模式使用随机 HTTP/SOCKS 用户名和密码，其他本机用户即使发现端口也不能直接使用。凭据保存在权限为 `600` 的 `~/mihomo/proxy-auth`，正常重装会继续复用。

验证代理：

```bash
curl -I https://www.google.com
```

`ping` 使用 ICMP，不会经过 HTTP/SOCKS 代理，不能用于验证本项目的代理是否生效。

查看实际端口：

```bash
grep -E '^(port|socks-port|external-controller):|^  listen:' ~/mihomo/config.yaml
```

### 重装、登录与卸载

再次执行 `bash install.sh` 即可重装。已有 `~/mihomo/config.yaml` 时默认保留订阅和端口；只有明确选择覆盖才会重新输入订阅并分配端口。

安装脚本会启用用户级 `mihomo.service`。正常登录且用户 systemd 可用时，重新登录后服务会自动启动；未启动时执行：

```bash
clash on
```

无 `sudo` 权限时，用户登出后服务通常不会继续运行。若需要登出或系统重启后保持运行，需要管理员执行：

```bash
loginctl enable-linger <用户名>
```

卸载个人模式会删除当前用户的 `~/mihomo`：

```bash
bash uninstall.sh
```

## 系统共享模式

### 管理员安装

```bash
sudo bash install_sys.sh
```

安装程序会询问：

```text
请输入本次要加入 mihomo-control 的用户（空格分隔，默认：admin）: alice bob
是否让没有个人 Mihomo 的用户登录后自动启用系统代理？[y/N]: y
```

- 可以一次添加多个控制用户。通过 `sudo` 安装时，留空默认添加当前管理员；直接以 root 安装时，留空表示不新增控制用户。
- 自动启用默认选择 `N`，普通用户需要在自己的终端执行 `clashsys on`。选择 `y` 后，没有个人 Mihomo 的用户下次登录 Bash 时会自动使用共享代理。
- 新增组权限需要用户重新登录后才能生效。

服务启动成功后，安装脚本会立即检测订阅节点并进入首次选择。`DIRECT` 不会被当作订阅节点；超时或未测得延迟的真实节点仍会显示并允许选择。如果订阅没有加载到任何真实节点，脚本会发出警告并保留已经安装的服务，修复后执行：

```bash
clashsys select
```

系统服务随系统启动，不依赖管理员保持登录。

### 普通用户使用

当前已经打开的 Bash 终端可以先加载命令：

```bash
source /etc/profile.d/mihomo-system.sh
```

`source` 只影响执行它的当前 Shell。网页终端、SSH 终端和 VS Code Tunnel 集成终端分别是独立进程；在网页终端执行过 `source`，不会把函数和代理变量同步到 VS Code 之后创建的终端。VS Code 集成终端通常还是交互式非登录 Shell，只读取当前用户的 `~/.bashrc`，不一定读取 `/etc/profile` 和 `/etc/profile.d/`。

希望当前用户只配置一次，以后新开的 Bash、SSH 或 VS Code 终端都能直接使用 `clashsys`，可将下面整段复制执行一次。命令带有固定标记，重复执行不会重复写入：

```bash
grep -Fq '# Load mihomo-system command for interactive Bash shells' "$HOME/.bashrc" 2>/dev/null || \
  printf '\n%s\n' \
    '# Load mihomo-system command for interactive Bash shells' \
    'if [[ $- == *i* && -r /etc/profile.d/mihomo-system.sh ]]; then' \
    '    source /etc/profile.d/mihomo-system.sh' \
    'fi' >> "$HOME/.bashrc"
source "$HOME/.bashrc"
```

这段配置只负责自动加载 `clashsys` 命令，不会强制每个终端使用代理。以后新终端根据需要执行：

```bash
clashsys on
```

如果明确希望每个新 Bash 终端都自动启用系统共享代理，可以在完成上一步后，再将下面整段执行一次：

```bash
grep -Fq '# Auto-enable mihomo-system in interactive Bash shells' "$HOME/.bashrc" 2>/dev/null || \
  printf '\n%s\n' \
    '# Auto-enable mihomo-system in interactive Bash shells' \
    'if [[ $- == *i* ]] && declare -F clashsys >/dev/null; then' \
    '    clashsys on >/dev/null 2>&1 || true' \
    'fi' >> "$HOME/.bashrc"
source "$HOME/.bashrc"
```

自动启用会让新终端默认使用系统共享代理。如果该用户还安装了个人 Mihomo，不建议添加第二段；需要哪个代理时显式执行 `clash on` 或 `clashsys on` 更清晰。

然后启用代理并验证：

```bash
clashsys on
curl -I https://www.google.com
```

正常的登录式 Bash 通常会通过 `/etc/profile` 自动加载 `clashsys`；非登录终端是否加载取决于 Shell 启动方式。按上面的方式写入 `~/.bashrc` 后，新开的交互式 Bash 终端无需再次手动 `source`。如果管理员安装时开启了自动代理，并且该用户没有个人 Mihomo，则正常重新登录后也无需执行 `clashsys on`。

所有用户均可执行：

```bash
clashsys on       # 当前终端切换到系统共享代理
clashsys off      # 当前终端停用共享代理，不停止系统服务
clashsys status   # 查看共享服务状态
clashsys help     # 查看帮助
```

普通用户不需要各自选择节点，管理员或控制用户选择的共享节点会对所有用户生效。

### 控制用户

管理员可授权其他用户控制共享节点和重启服务：

```bash
sudo usermod -aG mihomo-control <用户名>
```

该用户重新登录后可以执行：

```bash
clashsys select   # 测速并切换共享节点，会影响所有共享用户
clashsys restart  # 重启共享服务，保持原端口
```

普通用户不能读取系统订阅和控制密钥，也不能停止或重启共享服务。

### 与个人模式同时使用

Shell 中只有一组 HTTP/HTTPS 代理变量，因此不存在固定优先级，当前终端最后执行的命令生效：

```bash
clashsys on       # 切换到系统共享代理
clash on          # 切换到当前用户的个人代理
clashsys on       # 再切回系统共享代理
```

`clashsys off` 只会清除当前终端中的系统代理变量，不会误删之后加载的个人代理；`clash off` 也只清理本项目设置的个人代理变量。

开启系统代理自动加载后，如果检测到 `~/.local/bin/clash`、`~/.config/systemd/user/mihomo.service` 或 `~/mihomo` 中任一项个人安装痕迹，登录脚本不会自动覆盖个人代理。用户仍可显式执行 `clashsys on` 切换到系统共享代理。

系统共享模式不是透明代理，只有读取代理环境变量或显式配置代理地址的程序会使用它，`ping` 仍不会经过代理。

### 系统模式卸载

管理员执行：

```bash
sudo bash system/uninstall.sh
```

系统卸载不会删除任何用户的个人模式文件或用户级服务。专用账户 `mihomo` 和 `mihomo-control` 组默认保留。

## 常见问题

### 执行命令时提示找不到 clash 或 clashsys

个人模式当前终端执行：

```bash
source ~/.bashrc
```

系统共享模式当前 Bash 终端执行：

```bash
source /etc/profile.d/mihomo-system.sh
```

### curl 一直没有响应

先确认服务、代理变量和节点状态：

```bash
clash status
env | grep -i '_proxy'
clash select
```

使用系统共享模式时，将以上命令换成 `clashsys status` 和 `clashsys select`。如果普通用户没有控制权限，请让管理员或 `mihomo-control` 组成员检查节点。

### GitHub 下载容易超时

安装脚本下载核心和 GeoIP 时会依次尝试加速镜像并回退 GitHub 原始地址。也可临时增大连接和下载超时：

```bash
MIHOMO_CURL_CONNECT_TIMEOUT=15 MIHOMO_CURL_DOWNLOAD_TIMEOUT=600 bash install.sh
```
