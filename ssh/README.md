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

检查脚本版本：

```bash
sudo ./install-duo-ssh.sh --version
sudo ./install-duo-ssh.sh --check-update
```

自更新脚本：

```bash
sudo ./install-duo-ssh.sh --self-update
```

默认更新源是：

```text
https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install-duo-ssh.sh
```

如需使用 fork 或内部镜像，可以覆盖更新源：

```bash
sudo KH_DUO_UPDATE_URL=https://example.com/install-duo-ssh.sh \
     ./install-duo-ssh.sh --self-update
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

### 开发

检查 shell 脚本语法：

```bash
bash -n install-duo-ssh.sh
```
