# OpenBayes Codex Connect

在 Windows 上配置 OpenBayes 容器的 SSH 连接，更新容器重启后变化的端口，并检查远程 Codex 是否已安装和登录。

日常操作：**复制 OpenBayes 的 SSH 命令 → 双击更新入口 → 在桌面应用中重新连接**。

本项目是独立的社区脚本，与 OpenBayes、OpenAI 无官方隶属关系。

## 环境要求

- Windows 10/11、Windows PowerShell 5.1+、Windows OpenSSH 客户端（`ssh`、`ssh-keygen`、`scp`）。
- 支持 SSH 连接的 Codex / ChatGPT 桌面应用。
- 可通过 `root@ssh.openbayes.com` 登录、使用 Bash 的 OpenBayes Linux 容器。
- 容器首次安装脚本需要 glibc、x86_64 或 aarch64、curl、tar、sha256sum，以及可访问 Node.js、npm 和 OpenAI 服务的网络。

脚本不需要第三方 PowerShell 模块。容器安装器默认使用 `/openbayes/home`；使用前请确认该目录可写，且属于容器的持久化存储。

## 文件

| 文件 | 用途 |
| --- | --- |
| `首次配置OpenBayes.cmd` | 双击完成 Windows 首次配置 |
| `更新OpenBayes连接.cmd` | 双击更新本次 SSH 端口并检查远程环境 |
| `Setup-OpenBayesCodex.ps1` | 创建密钥、SSH 配置和公钥授权脚本 |
| `Update-OpenBayesCodex.ps1` | 解析端口、备份配置、执行 SSH 和 Codex 检查 |
| `Install-OpenBayesCodex.sh` | 在容器中安装 Node.js 和 Codex |
| `tests/` | 无需连接真实容器的离线测试 |

运行时会生成 `.local/authorize-key.sh` 和 `last-run.log`，它们不属于发布文件，已由 `.gitignore` 排除。开发过程中的 `docs/` 记录也不纳入版本控制。

## 首次配置

### 1. 配置 Windows SSH

启动 OpenBayes 容器，复制网页给出的完整 SSH 命令，例如：

```text
ssh root@ssh.openbayes.com -p12345
```

`12345` 仅为示例，使用时以网页显示的本次端口为准。脚本只解析端口，不执行剪贴板中的命令。

在剪贴板中保留该命令，双击 `首次配置OpenBayes.cmd`。脚本会：

1. 创建专用 Ed25519 密钥 `%USERPROFILE%\.ssh\id_ed25519_openbayes`，已有密钥不会覆盖。
2. 在 `%USERPROFILE%\.ssh\config` 中创建固定别名 `openbayes-codex`；已有同名 Host 时仅更新端口。
3. 尝试公钥登录；失败时由 `ssh.exe` 请求本次容器密码并安装公钥。
4. 验证公钥登录及远程 Codex 状态。

密码输入没有回显，按回车提交。脚本不收集或保存密码。新密钥使用空口令以便非交互式连接，私钥保存在当前用户的 `.ssh` 目录。

若提示 `Codex executable is unavailable`，继续完成下一步后重跑更新入口。

如需通过网页终端安装公钥，在本项目目录的 PowerShell 中运行：

```powershell
.\Setup-OpenBayesCodex.ps1 -SshCommand 'ssh root@ssh.openbayes.com -p12345' -PrepareOnly
Get-Content .\.local\authorize-key.sh -Raw | Set-Clipboard
```

将生成的脚本粘贴到 **OpenBayes 容器网页终端**执行，然后验证：

```powershell
ssh -o BatchMode=yes openbayes-codex 'echo OPENBAYES_SSH_OK'
```

应输出 `OPENBAYES_SSH_OK`。若已有同名 Host，请确认它的 `IdentityFile` 指向已授权的本机密钥。可用 `-IdentityPath` 指定其他 Ed25519 密钥；已有 Host 的密钥路径需自行同步。

### 2. 安装并登录远程 Codex

已安装 Codex 时，先检查：

```powershell
ssh openbayes-codex 'command -v codex; codex --version; codex login status'
```

全新容器可从本机上传并执行安装器：

```powershell
scp .\Install-OpenBayesCodex.sh openbayes-codex:/tmp/Install-OpenBayesCodex.sh
ssh openbayes-codex 'bash /tmp/Install-OpenBayesCodex.sh'
```

安装器下载 Node.js 24 并校验官方 SHA-256 清单，通过 npm 安装 `@openai/codex`，将文件保存到 `/openbayes/home/.codex-connect/`。它会备份并修改 `~/.bashrc`，使 SSH 非交互式 shell 能找到 Codex；PATH 中已有 Codex 时直接复用。安装版本随上游更新而变化。

进入远程容器：

```powershell
ssh openbayes-codex
```

在 **远程 Linux shell** 中运行：

```bash
codex login --device-auth
codex login status
```

按提示在浏览器完成登录，再输入 `exit` 返回本机。设备码登录需要在账号安全设置或工作区权限中启用；其他登录方式见 [OpenAI 认证文档](https://learn.chatgpt.com/docs/auth#login-on-headless-devices)。

本机桌面应用与远程 Codex 需要分别登录。

### 3. 添加桌面连接

1. 运行 `ssh -o BatchMode=yes openbayes-codex 'codex --version; codex login status'`，确认 SSH 和远程环境可用。
2. 在桌面应用的 **设置 → 连接 → SSH** 中添加或启用 `openbayes-codex`。
3. 选择容器内实际存在的项目目录，例如 `/openbayes/home/my-project`。
4. 在远程项目中新建聊天，执行 `pwd` 确认工作目录。

桌面应用通过 SSH 启动远程 Codex 服务，远程 shell 的 PATH 必须能找到 `codex`。具体入口和要求见 [OpenAI 远程连接文档](https://learn.chatgpt.com/docs/remote-connections#connect-to-an-ssh-host)。

## 容器重启后

1. 复制 OpenBayes 网页显示的新 SSH 命令。
2. 双击 `更新OpenBayes连接.cmd`。
3. 等待 `OPENBAYES_CODEX_READY` 和成功提示，在桌面应用中重新连接 `openbayes-codex`。

更新脚本仅修改目标 Host 的 Port；端口变化时在 SSH 配置旁创建 `.bak` 备份，端口相同时不重复写入。脚本不启动云容器，也不自动登录 Codex。

如果容器重启后丢失了 `authorized_keys` 或 shell 配置，请重新授权公钥或恢复 PATH。文件是否持久化取决于容器的存储设置。

## 网络与代理

容器可直连时不需要代理。项目不提供代理服务、订阅或凭据。

安装器及其生成的 Codex 包装脚本会读取 `/openbayes/home/.codex-connect/proxy.env`。需要 HTTP 代理时，可在容器中创建此文件，例如：

```bash
mkdir -p /openbayes/home/.codex-connect
umask 077
cat > /openbayes/home/.codex-connect/proxy.env <<'EOF'
export HTTP_PROXY=http://proxy.example.com:8080
export HTTPS_PROXY="$HTTP_PROXY"
export http_proxy="$HTTP_PROXY"
export https_proxy="$HTTPS_PROXY"
unset ALL_PROXY all_proxy
EOF
chmod 600 /openbayes/home/.codex-connect/proxy.env
```

将示例地址替换为容器内部可访问的代理。`127.0.0.1` 指容器自身。该文件会作为 shell 脚本加载，只使用自己信任的内容。

对于已配置 Mihomo 的容器，更新脚本还支持检查 `/openbayes/home/mihomo/`：必要时启动代理，等待 `127.0.0.1:7890` 最多 15 秒，再验证配置。该目录不存在时跳过；存在但配置不完整时会报错。代理日志位于 `/openbayes/home/mihomo.log`。

## 命令行与排障

从本项目目录运行，可显式传入命令而不读取剪贴板：

```powershell
.\Update-OpenBayesCodex.ps1 -SshCommand 'ssh root@ssh.openbayes.com -p12345'
```

首次配置支持 `-ConfigPath`、`-IdentityPath`、`-PrepareOnly`；更新脚本支持 `-ConfigPath`、`-LogPath`、`-SkipRemoteCheck`。自定义配置会传给 SSH；桌面应用自动发现 Host 时仍使用默认的用户 SSH 配置。

| 现象 | 处理 |
| --- | --- |
| 无法运行 `.ps1` | 使用双击入口，或 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\脚本名.ps1` |
| `Invalid OpenBayes SSH command` | 复制完整命令，支持 `-p12345` 和 `-p 12345` |
| 缺少目标 Host | 先运行首次配置入口 |
| `Permission denied` | 重新授权公钥，并确认 IdentityFile 正确 |
| 连接超时或拒绝 | 确认容器运行中，并更新本次端口 |
| 主机指纹变化 | 核实目标和指纹后处理旧 known_hosts 记录 |
| `codex: command not found` | 检查远程 PATH；`.bashrc` 的 PATH 设置应位于非交互式提前返回之前 |
| CLI 可用但桌面连接失败 | 确认选中同一 SSH 别名，断开后重新连接 |

`last-run.log` 每次运行覆盖，可能包含本机路径、端口和远程输出，分享前需脱敏。检查成功表示相关命令通过，桌面端连接仍需在应用中验证。

## 开发与发布

运行离线测试（临时配置和密钥在测试结束后删除，不连接真实容器）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-UpdateOpenBayesCodex.ps1
```

提交前使用 `git status --short` 检查文件清单。不提交 `.local/`、`docs/`、日志、密钥、认证缓存和代理配置；直接打包文件夹时也需排除这些内容。

采用 [MIT License](LICENSE)。贡献修改时，请附上用途说明和适用的测试结果。
