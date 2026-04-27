# ssh/

Linux 服务器 SSH 加固相关脚本。

| Script | Description |
| --- | --- |
| [install-duo-ssh.sh](install-duo-ssh.sh) | 一键安装、配置、卸载和更新 Duo SSH 2FA。 |

## install-duo-ssh.sh

把 SSH 登录改为：

```text
SSH public key + Duo Push/Passcode
```

默认情况下，纯密码登录会被拒绝。脚本会安装 Duo 官方软件包，写入 `/etc/duo/pam_duo.conf`，修改 `/etc/pam.d/sshd` 和 `/etc/ssh/sshd_config`，并在成功校验后重启 SSH 服务。

### 支持系统

- Debian 11+
- Ubuntu 20.04+
- RHEL 8+
- CentOS Stream 8+
- Rocky Linux / AlmaLinux / Oracle Linux
- Fedora 39+
- Amazon Linux 2023

### 安装前准备

1. 在 Duo Admin Panel 创建或打开 `UNIX Application`。
2. 准备以下三个值：
   - `Integration key` (`ikey`)
   - `Secret key` (`skey`)
   - `API hostname` (`host`)
3. 确认当前 SSH 用户已经配置可用的 public key。
4. 安装时保持一个现有 SSH 会话不要关闭，直到确认新会话可以正常登录。

### 快速使用

下载脚本后执行交互式安装：

```bash
chmod +x install-duo-ssh.sh
sudo ./install-duo-ssh.sh
```

使用参数进行非交互安装：

```bash
sudo ./install-duo-ssh.sh \
  --ikey DIXXXXXXXXXXXXXXXXXX \
  --skey your-secret-key \
  --host api-xxxxxxxx.duosecurity.com \
  --yes
```

也可以通过环境变量传入 Duo 凭据：

```bash
sudo DUO_IKEY=DIXXXXXXXXXXXXXXXXXX \
     DUO_SKEY=your-secret-key \
     DUO_HOST=api-xxxxxxxx.duosecurity.com \
     ./install-duo-ssh.sh --yes
```

### 常用选项

| Option | Description |
| --- | --- |
| `--ikey VALUE` | Duo Integration Key。 |
| `--skey VALUE` | Duo Secret Key。 |
| `--host VALUE` | Duo API hostname。 |
| `--breakglass USER` | 指定一个紧急用户绕过 Duo，仅允许 public key。 |
| `--bypass-local` | 对 localhost 连接绕过 Duo，默认开启。 |
| `--no-bypass-local` | 关闭 localhost 绕过。 |
| `--bypass-addr CIDR` | 指定额外绕过 Duo 的来源网段，可重复使用。 |
| `--allow-password` | 允许 password + Duo 作为 fallback。 |
| `--skip-key-check` | 跳过 authorized_keys 检查。 |
| `--uninstall` | 卸载 Duo SSH 2FA 并恢复 SSH 配置。 |
| `--no-menu` | 即使在 TTY 中也不进入交互菜单。 |
| `-y`, `--yes` | 自动确认提示，适合自动化执行。 |
| `-h`, `--help` | 显示帮助。 |

### 维护命令

安装快捷命令：

```bash
sudo ./install-duo-ssh.sh --install-shortcut
sudo kh-duo
```

检查脚本版本（v1.1.1 起 `--version` 和 `--check-update` 不需要 root）：

```bash
./install-duo-ssh.sh --version
./install-duo-ssh.sh --check-update
```

自更新脚本（写 `$SCRIPT_PATH`，需要 root）：

```bash
sudo ./install-duo-ssh.sh --self-update
```

默认更新源是：

```text
https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install-duo-ssh.sh
```

`KH_DUO_UPDATE_URL` 必须以 `https://raw.githubusercontent.com/` 开头，否则脚本会在任何网络 I/O 之前直接拒绝。这是为了防止通过 `sudo -E` 或 sudoers `env_keep` 让普通用户重定向 self-update 到攻击者控制的 URL：

```bash
# 允许：fork 在 GitHub 上的镜像
sudo KH_DUO_UPDATE_URL=https://raw.githubusercontent.com/myfork/ops-scripts/master/ssh/install-duo-ssh.sh \
     ./install-duo-ssh.sh --self-update

# 拒绝：任何非 raw.githubusercontent.com 的源
sudo KH_DUO_UPDATE_URL=https://example.com/x.sh ./install-duo-ssh.sh --self-update
# → [x] Refusing untrusted update URL ...
```

### 卸载

```bash
sudo ./install-duo-ssh.sh --uninstall
```

卸载会尽量移除脚本写入的 Duo PAM 配置、SSH `AuthenticationMethods` 配置、Duo 软件包和仓库配置，并重启 SSH 服务。

### 备份和回滚

脚本每次运行都会创建时间戳备份目录：

```text
/root/duo-install-backup-YYYYMMDD-HHMMSS
```

如果配置校验或重启失败，脚本会尝试自动恢复备份并重启 SSH。

### 安全注意事项

- 不要把 Duo `skey` 提交到 Git 仓库或写进共享日志。
- 首次安装时保留一个已登录的 SSH 会话。
- 推荐配置一个受控的 `--breakglass` 用户，用于 Duo 服务异常时的紧急恢复。
- 对生产服务器执行前，先在测试机验证登录流程。

### v1.1.1 起的越权加固

普通用户没法直接跑这个脚本（`require_root` 拦截），但如果通过 `sudo -E` 或 sudoers `env_keep` 让 env 透传，仍可能被利用。v1.1.1 加了这些防御：

- **PATH 固定**为 `/usr/sbin:/usr/bin:/sbin:/bin`，curl/awk 等命令不会被攻击者放在 `$HOME/bin/` 的同名脚本劫持。
- **`KH_DUO_UPDATE_URL` 白名单**：必须以 `https://raw.githubusercontent.com/` 开头，否则在任何网络 I/O 之前拒绝。
- **`KH_DUO_SHORTCUT` 白名单**：只允许 `/usr/local/{bin,sbin}/` 和 `/usr/{bin,sbin}/`，防止把 symlink 投到 `/etc/cron.hourly/` 之类的自动执行路径。
- **`$SCRIPT_PATH` 必须 root-owned** 才允许 `--self-update` 和 `--install-shortcut`。否则把脚本放到 `/home/<user>/` 再 sudo 调用，等于把后续 `sudo kh-duo` 引向用户可写的目标。
- **`--check-update` 不再需要 root**：纯只读，UX 改善的同时不增加风险。
- **`--version` / `--help`** 也不需要 root（一直如此）。

如果你的 sudoers 里没有 `Defaults env_keep += "..."`，并且团队不用 `sudo -E` 跑这个脚本，上述风险面其实很小；这些加固是 defense-in-depth。

### 开发

检查 shell 脚本语法：

```bash
bash -n install-duo-ssh.sh
```
