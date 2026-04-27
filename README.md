# ops-scripts

KazuhaHub 的运维脚本集合，覆盖 Linux SSH 加固和 Windows 设备策略配置。

## 目录

| Path | 平台 | 用途 | 详细文档 |
| --- | --- | --- | --- |
| [ssh/](ssh/) | Linux | SSH 加固 / Duo 2FA | [ssh/README.md](ssh/README.md) |
| [windows/](windows/) | Windows | ORG 设备策略 | [windows/README.md](windows/README.md) |

## 子目录概要

### [ssh/](ssh/) — Linux SSH 加固

**一行安装**：

```bash
curl -fsSL https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install.sh | sudo bash
```

各脚本：

- [install.sh](ssh/install.sh) — bootstrap 安装器。
- [install-duo-ssh.sh](ssh/install-duo-ssh.sh) — 一键安装、配置、卸载和更新 Duo SSH 2FA，支持 Debian / Ubuntu / RHEL / CentOS / Rocky / AlmaLinux / Oracle Linux / Fedora / Amazon Linux 2023。

详细使用方式、参数说明、卸载和回滚见 [ssh/README.md](ssh/README.md)。

### [windows/](windows/) — Windows ORG 设备策略

**一行安装**（管理员 PowerShell）：

```powershell
iex (irm 'https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/windows/Install.ps1')
```

会出现菜单选 Public / Limited / Cleanup，自动下载到 `C:\ProgramData\KazuhaHub\` 并启动。

各脚本：

- [Install.ps1](windows/Install.ps1) — bootstrap 安装器。
- [ORG_PUBLIC_ALL.ps1](windows/ORG_PUBLIC_ALL.ps1) — 公共/共享设备策略（20 分钟空闲注销，盖上即注销，更短电源超时）。
- [ORG_LIMITED_USERS.ps1](windows/ORG_LIMITED_USERS.ps1) — 个人受限用户设备策略（2 小时空闲注销，盖上即注销，较宽松电源超时）。
- [CLEAN_ALL.ps1](windows/CLEAN_ALL.ps1) — 还原 ORG 策略 + 自动更新任务，重新启用锁屏。

v1.5.0 起三个 ORG/CLEAN 脚本都带 **交互菜单**、`-CheckUpdate` / `-SelfUpdate` 命令、以及每天 04:00 SYSTEM 计划任务自动检查并应用最新版（`Kazuha Hub Auto Update`）。详见 [windows/README.md](windows/README.md)。

## 通用开发命令

查看工作区状态：

```bash
git status
```

检查 Git diff 空白问题：

```bash
git diff --check
```

各平台脚本的语法检查命令见对应子目录的 README。

## 反馈与贡献

如需新增脚本，请在对应平台子目录下创建文件，并同步更新该子目录的 `README.md`。新增子目录时，再回到本文件添加一行索引即可。
