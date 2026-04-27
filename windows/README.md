# windows/

Windows 设备的 ORG 策略配置脚本。所有写注册表的动作都需要 **管理员权限**；只读动作（`-Version` / `-CheckUpdate`）任何用户都能跑。

| Script | Description |
| --- | --- |
| [Install.ps1](Install.ps1) | **一行 bootstrap 安装器**：从 GitHub 拉取所选 profile + CLEAN_ALL，落到 `C:\ProgramData\KazuhaHub\`，校验并启动菜单。 |
| [ORG_PUBLIC_ALL.ps1](ORG_PUBLIC_ALL.ps1) | 公共/共享设备策略：20 分钟空闲注销，更短电源超时，盖上即注销，8 天用户配置文件清理。 |
| [ORG_LIMITED_USERS.ps1](ORG_LIMITED_USERS.ps1) | 个人受限用户设备策略：2 小时空闲注销，较宽松电源超时，盖上即注销。 |
| [CLEAN_ALL.ps1](CLEAN_ALL.ps1) | 撤销上述两个脚本写入的所有策略 + 自动更新任务。 |

## 一行安装（推荐）

最快的方式 —— **以管理员身份打开 PowerShell**，跑：

```powershell
iex (irm 'https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/windows/Install.ps1')
```

会出现菜单让你选 Public / Limited / Cleanup / Quit。选完后 bootstrap 会下载所选 ORG 脚本（连同 CLEAN_ALL）到 `C:\ProgramData\KazuhaHub\`，做 PowerShell parse 校验，把 Owner 强制改成 `BUILTIN\Administrators`（让所有权校验通过），然后跑选中的脚本进入它自己的菜单。

跳过菜单、自动化部署：

```powershell
# 公共设备 - 应用并跳过重启提问
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/windows/Install.ps1'))) -Profile Public -Unattended

# 个人受限设备
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/windows/Install.ps1'))) -Profile Limited -Unattended

# 清理
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/windows/Install.ps1'))) -Profile Cleanup -Unattended
```

`-Profile` 可选值：`Public` / `Limited` / `Cleanup`。bootstrap 会同时拉 CLEAN_ALL.ps1，所以将来菜单选 "Uninstall" 时不需要再下载。

## 离线 / 手动使用

如果不能在线拉，也可以把整个 `windows/` 目录拷到机器上，**以管理员身份** 打开 PowerShell 后直接跑：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\ORG_PUBLIC_ALL.ps1     # → 菜单
```

菜单选项：

```
  1) Apply this profile  (default)
  2) Uninstall (revert all Kazuha Hub policies via CLEAN_ALL)
  3) Check for script updates
  4) Self-update now (download latest and re-apply)
  5) Quit
```

非交互（自动化）也可以跳过菜单直接走某个动作：

| 命令 | 行为 | 需要 admin |
| --- | --- | --- |
| `.\ORG_PUBLIC_ALL.ps1 -Apply` | 直接应用策略 | ✓ |
| `.\ORG_PUBLIC_ALL.ps1 -Uninstall` | 直接调用 `CLEAN_ALL.ps1` | ✓ |
| `.\ORG_PUBLIC_ALL.ps1 -CheckUpdate` | 报告本地 vs 上游版本，不写任何东西 | ✗ |
| `.\ORG_PUBLIC_ALL.ps1 -SelfUpdate` | 下载新版替换自己（交互式） | ✓ |
| `.\ORG_PUBLIC_ALL.ps1 -Version` | 打印 `ORG_PUBLIC_ALL 1.5.0` 退出 | ✗ |
| `.\ORG_PUBLIC_ALL.ps1 -Apply -Unattended` | 应用策略 + 跳过重启提示 | ✓ |
| `.\ORG_PUBLIC_ALL.ps1 -SelfUpdate -Unattended` | 下载新版后自动用 `-Apply -Unattended` 重跑 | ✓ |

`-Unattended`（或别名 `-NoMenu`）是给 SYSTEM 计划任务用的：跳过 `Read-Host` 提示，跳过菜单。

---

## 自动更新

每次跑 `Apply` 时，脚本会顺手注册一个**每天凌晨 04:00 的 SYSTEM 计划任务** `Kazuha Hub Auto Update`：

- 触发器：`Daily -At "04:00"`
- 用户：`SYSTEM`，`RunLevel Highest`
- 动作：`powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<本脚本路径>" -Unattended -SelfUpdate`
- 设置：电池上也跑、错过时间窗口会补跑、最长执行 30 分钟

`-SelfUpdate -Unattended` 的流程：
1. 检查上游 `$ScriptVersion`，若不大于本地 → 退出（什么都不做）
2. 若有新版 → 下载到 temp、shebang/语法校验、备份 `${PSCommandPath}.bak.<TS>`、替换原文件
3. 启动新进程跑 `<新脚本> -Apply -Unattended`，让新版本应用所有策略
4. 退出原进程，退出码 = 子进程退出码

整个过程在 `Microsoft-Windows-PowerShell` Event Log 留痕（PowerShell 默认行为）。

> **如果不想让脚本每天 4 点自动更新自己**：跑 `CLEAN_ALL.ps1` 撤销所有，或者只删除任务：
> ```powershell
> Unregister-ScheduledTask -TaskName "Kazuha Hub Auto Update" -Confirm:$false
> ```

---

## 安全加固（v1.5.0）

`-SelfUpdate` 和注册自动更新任务都会触发：

- **`KH_WIN_UPDATE_URL` 白名单**：必须以 `https://raw.githubusercontent.com/` 开头，否则直接拒绝。防止通过环境变量把 SYSTEM 重定向到攻击者控制的脚本源。
- **`$PSCommandPath` 所有权校验**：Owner 必须是 `BUILTIN\Administrators` / `NT AUTHORITY\SYSTEM` / `NT SERVICE\TrustedInstaller` 之一。否则普通用户可以把脚本放到 `%USERPROFILE%\Downloads\` 然后 sudo-equivalent 运行，造成"在 SYSTEM 任务两次触发之间偷换文件"的攻击。
- **下载校验**：必须以 `[CmdletBinding`、`param(` 或 `#` 开头，且能通过 `[Parser]::ParseInput` 解析。GitHub 返回 HTML 错误页或下载到一半的文件都过不了这两道。
- **备份 + 原子替换**：下载到 `New-TemporaryFile`，校验后 `Move-Item -Force` 原子替换，旧版本保存为 `${PSCommandPath}.bak.<时间戳>`。

只读动作（`-Version` / `-CheckUpdate`）不要求 admin，所以非特权用户也能查"我现在是什么版本 / 上游有没有新版"，UX 友好且不开放任何攻击面。

---

## 三个脚本共用的策略

`ORG_PUBLIC_ALL` 和 `ORG_LIMITED_USERS` 都会写入下列策略，差异仅在末尾几个 section（空闲注销 / 电源 / 配置文件清理）。

### LAPS（Local Administrator Password Solution）

`HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS`

| Value | Setting |
| --- | --- |
| `BackupDirectory` | `1`（备份到 Microsoft Entra Join） |
| `PasswordComplexity` | `4`（大写 + 小写 + 数字 + 符号） |
| `PasswordLength` | `16` |
| `PasswordAgeDays` | `30` |
| `PostAuthenticationResetDelay` | `8` 小时 |
| `PostAuthenticationActions` | `3`（重置密码 + 注销） |

设置完成后立即调用 `Invoke-LapsPolicyProcessing` 触发一次。`CLEAN_ALL` **不会清理 LAPS** — 即便撤销 ORG profile 仍保留 LAPS 配置。

### 禁用 Windows Hello / PIN

| Path | Value |
| --- | --- |
| `HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork` → `Enabled` | `0` |
| `HKLM:\SOFTWARE\Policies\Microsoft\Windows\System` → `AllowDomainPINLogon` | `0` |
| `HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions` → `value` | `0` |

### 锁屏 / 切换用户 / Ctrl+Alt+Delete

- 隐藏快速用户切换：`HideFastUserSwitching = 1`
- 强制要求 Ctrl+Alt+Delete：`DisableCAD = 0`
- **同时禁用** 工作站锁屏：`DisableLockWorkstation = 1`（HKLM Policies\System、Winlogon、HKU\.DEFAULT 三处）

> ⚠️ 这些脚本会禁用锁屏功能。配合短的空闲注销时间使用，未活动的会话会被直接注销而不是锁屏。需要恢复锁屏运行 `CLEAN_ALL.ps1`。

### 登录界面信息显示

| Value | Setting |
| --- | --- |
| `DontDisplayLastUserName` | `1` |
| `DontDisplayUserName` | `0` |
| `DontDisplayUserNameOnLockScreen` | `1` |
| `DontDisplayLockedUserId` | `3`（不显示锁屏用户 ID） |
| `EnumerateLocalUsers` | `0`（域/Entra 登录时不列举本地用户） |

### 中英双语 Legal Notice

在 Ctrl+Alt+Delete 之前显示，分别写入 `Policies\System` 和 `Winlogon` 两个键。每个脚本会在文末附上 `<ScriptName>-v<ScriptVersion>`（如 `ORG_PUBLIC_ALL-v1.5.0`），便于现场识别当前生效的版本。

部署到生产前请确认 Legal Notice 文本与公司合规要求一致。

### 隐藏 Start 菜单的 Sleep 选项

通过 `HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer` → `ShowSleepOption = 0` 隐藏，并锁定 `HKLM:\SOFTWARE\Microsoft\PolicyManager\{default,current}\Start` → `value = 1`。

### 笔记本盖上自动注销

Windows 原生的 LIDACTION 没有"注销"选项（只有不动作 / 睡眠 / 休眠 / 关机），脚本通过两步实现"盖上即注销"的效果：

1. 把 LIDACTION 设为 **Sleep**（值 `1`），写入策略并应用到当前电源计划：
   - `HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\4f971e89-eebd-4455-a8de-9e59040e7347\5ca83367-6e45-459f-a27b-476b1d01c936` → `ACSettingIndex` / `DCSettingIndex` = `1`
   - 同时跑 `powercfg /SETACVALUEINDEX` 和 `/SETDCVALUEINDEX` 立即生效
2. 写入 helper 脚本 `C:\ProgramData\KazuhaHub\LogoffOnResume.ps1`，并通过 `Register-ScheduledTask` 注册一个事件触发任务 **`Logoff On Resume`**：
   - 触发器 XPath：`*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]`
   - 任务以 `SYSTEM` 身份运行 `powershell.exe -File LogoffOnResume.ps1`，对每个活动 session 调 `logoff.exe`

UX 流程：合上笔记本 → 系统进入 sleep → 掀开 → 唤醒 → 触发 Event 1 → 注销当前 session → 用户看到登录界面。

桌面机没有 lid，LIDACTION 设置无效，但 `Logoff On Resume` 任务在任何 sleep/hibernate 唤醒时仍会触发。

> ⚠️ 部分使用 Modern Standby (S0) 的设备可能不会触发 `Power-Troubleshooter` Event 1。如遇问题可临时把 LIDACTION 改成 `3`（关机）作为备选方案。

---

## ORG_PUBLIC_ALL.ps1

适用于 **公共/共享设备**（展厅机器、会议室电脑、共享工作站）。差异点：

| Setting | Value |
| --- | --- |
| 用户配置文件清理（`CleanupProfiles`） | `8` 天 |
| 空闲注销 | `20` 分钟 |
| 屏幕关闭（AC + DC） | `30` 分钟 |
| 进入睡眠（AC + DC） | `60` 分钟 |
| 计划任务名 | `Idle 20m Logoff` |

空闲注销实现：写 helper 到 `C:\ProgramData\KazuhaHub\IdleLogoffAll.ps1`，按 `quser` **表头列位置** 解析每个 session 的 ID/State/Idle Time（不是按空格 split），然后通过 `schtasks /Create /SC MINUTE /MO 1 /RU SYSTEM` 每分钟检查一次，超过阈值即调用 `logoff.exe <sessionId>`。

电源超时通过策略 + `powercfg /X` 双层锁定。

## ORG_LIMITED_USERS.ps1

适用于 **个人受限用户设备**（分配给员工但禁用本地管理员的 Windows 终端）。差异点：

| Setting | Value |
| --- | --- |
| 空闲注销 | `120` 分钟 |
| 屏幕关闭（AC + DC） | `10` 分钟 |
| 进入睡眠（AC + DC） | `180` 分钟 |
| 计划任务名 | `Idle 120m Logoff` |
| 用户配置文件清理 | **不启用**（保留个人配置） |

实现机制与 `ORG_PUBLIC_ALL` 完全相同，仅常量不同。

## CLEAN_ALL.ps1

撤销 `ORG_PUBLIC_ALL` / `ORG_LIMITED_USERS`（v1.3.6 - v1.5.0）写入的所有策略 + 自动更新任务。

- 清理所有上面列出的注册表值（PIN、锁屏、用户名显示、Legal Notice、CleanupProfiles、电源策略、Sleep 隐藏、LIDACTION）。
- 删除以下计划任务：
  - 历史名（向后兼容）：`AutoLogoff-RealIdle`、`AutoLogoff-Idle`、`AutoLogoff-RealIdle-Limited`、`Idle 2h Logoff`
  - **模式匹配**任何 `Idle <数字>m Logoff` 任务
  - `Logoff On Resume`
  - **自动更新任务** `Kazuha Hub Auto Update`
- 删除 helper 脚本 `C:\ProgramData\KazuhaHub\IdleLogoff.ps1`、`IdleLogoffAll.ps1`、`LogoffOnResume.ps1`
- **重新启用** 工作站锁屏：在 `HKLM`、`HKCU`、`HKU\.DEFAULT` 多处写入 `DisableLockWorkstation = 0`
- LAPS 策略 **不清理**（保留）

最后执行 `gpupdate /force` 并询问是否重启（`-Unattended` 时跳过提问）。CLEAN_ALL 自己也有菜单和 self-update。

---

## 历史 bug（v1.4.0 及更早）

v1.4.0 及更早版本的 idle helper 用了 `??`（PowerShell 7+ 才有的 null-coalescing 运算符），但计划任务调的是 `powershell.exe`（Windows PowerShell 5.1），脚本每次解析就直接挂掉，**空闲注销实际没生效**。v1.4.1 起改成 PS 5.1 兼容的写法。如果你之前部署过老版本，重新跑一次本脚本（或等到 04:00 自动更新跑过一次）即可覆盖更新 helper。

---

## 开发

检查 PowerShell 脚本语法（无错误为通过）：

```powershell
$tokens = $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    "ORG_PUBLIC_ALL.ps1", [ref]$tokens, [ref]$errors) | Out-Null
$errors
```

文件编码：UTF-8 with BOM（包含中文 Legal Notice，BOM 用于兼容 Windows PowerShell 5.1）。
