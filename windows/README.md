# windows/

Windows 设备的 ORG 策略配置脚本。所有脚本都需要 **管理员权限** 运行（推荐 PowerShell 7+）。

| Script | Description |
| --- | --- |
| [ORG_PUBLIC_ALL-v1.4.1.ps1](ORG_PUBLIC_ALL-v1.4.1.ps1) | 公共/共享设备策略：20 分钟空闲注销，更短的电源超时，盖上即注销。 |
| [ORG_LIMITED_USERS-v1.4.1.ps1](ORG_LIMITED_USERS-v1.4.1.ps1) | 个人受限用户设备策略：2 小时空闲注销，更宽松的电源超时，盖上即注销。 |
| [CLEAN_ALL-v1.4.1.ps1](CLEAN_ALL-v1.4.1.ps1) | 撤销上述两个脚本写入的所有策略。 |

## 使用方式

以 **管理员身份** 打开 PowerShell（推荐 PowerShell 7+），切换到本目录后运行所需脚本：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force

# 公共设备
.\ORG_PUBLIC_ALL-v1.4.1.ps1

# 个人受限用户设备
.\ORG_LIMITED_USERS-v1.4.1.ps1

# 还原所有策略
.\CLEAN_ALL-v1.4.1.ps1
```

`ORG_LIMITED_USERS` 在脚本开头会自检管理员权限，未提权时会直接退出。其它脚本依赖管理员权限写入 `HKLM`，请务必使用 "以管理员身份运行"。

每个脚本结束时都会执行 `gpupdate /force` 并询问是否立即重启，部分策略需要重启或重新登录后才能完全生效。

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

设置完成后立即调用 `Invoke-LapsPolicyProcessing` 触发一次。

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

> ⚠️ 这些脚本会禁用锁屏功能。配合短的空闲注销时间使用，未活动的会话会被直接注销而不是锁屏。如果需要恢复锁屏，运行 `CLEAN_ALL-v1.4.1.ps1`。

### 登录界面信息显示

| Value | Setting |
| --- | --- |
| `DontDisplayLastUserName` | `1` |
| `DontDisplayUserName` | `0` |
| `DontDisplayUserNameOnLockScreen` | `1` |
| `DontDisplayLockedUserId` | `3`（不显示锁屏用户 ID） |
| `EnumerateLocalUsers` | `0`（域/Entra 登录时不列举本地用户） |

### 中英双语 Legal Notice

在 Ctrl+Alt+Delete 之前显示，分别写入 `Policies\System` 和 `Winlogon` 两个键。每个脚本会在文末附上自身版本号（如 `ORG_PUBLIC_ALL-v1.4.1`），便于现场识别当前生效的版本。

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
   - 这个事件在系统从睡眠/休眠唤醒时触发
   - 任务以 `SYSTEM` 身份运行 `powershell.exe -File LogoffOnResume.ps1`，对每个活动 session 调 `logoff.exe`

UX 流程：
- 用户合上笔记本 → 系统进入 sleep
- 用户掀开笔记本 → 系统唤醒 → 触发 Event 1 → 注销当前 session → 用户看到登录界面

桌面机没有 lid，LIDACTION 设置无效，但 `Logoff On Resume` 任务在任何 sleep/hibernate 唤醒时仍会触发（包括按电源键或定时唤醒）。

> ⚠️ 部分使用 Modern Standby (S0) 的设备可能不会触发 `Power-Troubleshooter` Event 1。如遇问题可以临时把 LIDACTION 改成 `3`（关机）作为备选方案。

---

## ORG_PUBLIC_ALL-v1.4.1.ps1

适用于 **公共/共享设备**，例如展厅机器、会议室电脑、共享工作站。差异点：

| Setting | Value |
| --- | --- |
| 用户配置文件清理（`CleanupProfiles`） | `8` 天 |
| 空闲注销 | `20` 分钟 |
| 屏幕关闭（AC + DC） | `30` 分钟 |
| 进入睡眠（AC + DC） | `60` 分钟 |
| 计划任务名 | `Idle 20m Logoff` |

空闲注销实现：在 `C:\ProgramData\KazuhaHub\IdleLogoffAll.ps1` 写入 helper 脚本，按 `quser` 表头列位置解析每个 session 的 ID/State/Idle Time（不是按空格 split，避免 disconnected session 的 SESSIONNAME 列空导致字段错位）。然后通过 `schtasks /Create /SC MINUTE /MO 1 /RU SYSTEM` 每分钟运行一次，超过阈值即调用 `logoff.exe <sessionId>`。

电源超时通过两个层面同时锁定：
- `HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\...` 写入策略，用户无法修改。
- `powercfg /X monitor-timeout-{ac,dc}` 和 `standby-timeout-{ac,dc}` 立即应用到当前电源计划。

> 历史 bug：v1.4.0 及更早版本的 helper 脚本里用了 `??`（PowerShell 7+ 才有的 null-coalescing 运算符），但计划任务调的是 `powershell.exe`（Windows PowerShell 5.1），所以脚本每次解析就直接挂掉、空闲注销实际没生效。v1.4.1 起改成 PS 5.1 兼容的写法。如果你之前部署过老版本，重新跑一次本脚本即可覆盖更新 helper。

## ORG_LIMITED_USERS-v1.4.1.ps1

适用于 **个人受限用户设备**，例如分配给员工但禁用本地管理员的 Windows 终端。差异点：

| Setting | Value |
| --- | --- |
| 空闲注销 | `120` 分钟（2 小时） |
| 屏幕关闭（AC + DC） | `10` 分钟 |
| 进入睡眠（AC + DC） | `180` 分钟（3 小时） |
| 计划任务名 | `Idle 2h Logoff` |
| 用户配置文件清理 | **不启用**（保留个人配置） |

空闲注销、电源策略、盖上注销的实现方式与 `ORG_PUBLIC_ALL` 完全相同，仅 idle 阈值和电源超时数值不同。脚本开头额外加了管理员自检，未提权时直接退出。

## CLEAN_ALL-v1.4.1.ps1

撤销 `ORG_PUBLIC_ALL` / `ORG_LIMITED_USERS`（v1.3.6 - v1.4.1）写入的所有策略。

- 清理所有上面列出的注册表值（PIN、锁屏、用户名显示、Legal Notice、CleanupProfiles、电源策略、Sleep 隐藏、LIDACTION）。
- 删除以下计划任务（兼容历史命名）：
  - `AutoLogoff-RealIdle`
  - `AutoLogoff-Idle`
  - `AutoLogoff-RealIdle-Limited`
  - `Idle 20m Logoff`
  - `Idle 2h Logoff`
  - `Logoff On Resume`
- 删除 helper 脚本 `C:\ProgramData\KazuhaHub\IdleLogoff.ps1`、`IdleLogoffAll.ps1`、`LogoffOnResume.ps1`。
- **重新启用** 工作站锁屏：在 `HKLM`、`HKCU`、`HKU\.DEFAULT` 多处写入 `DisableLockWorkstation = 0`。
- LAPS 策略 **不会被清理**（保留 LAPS 配置）。

最后执行 `gpupdate /force` 并询问是否重启。

---

## 安全注意事项

- 这些脚本会修改 `HKLM` 注册表、Winlogon 行为、计划任务和电源策略，请先在测试机验证。
- Legal Notice 会在每次开机/锁屏后显示，部署到生产前请确认文本与公司合规要求一致。
- 部分策略需要重启后才能完全生效，脚本末尾会提示是否重启。
- 如需回滚，使用 `CLEAN_ALL-v1.4.1.ps1`；它会兼容清理 v1.3.6 起的旧计划任务名。
- LAPS 备份目标默认是 Microsoft Entra Join (`BackupDirectory=1`)，未加入 Entra 的设备需要先加入或修改这个值。

## 开发

检查 PowerShell 脚本语法（无错误为通过）：

```powershell
$tokens = $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    "ORG_PUBLIC_ALL-v1.4.1.ps1", [ref]$tokens, [ref]$errors) | Out-Null
$errors
```

文件编码：UTF-8 with BOM（包含中文 Legal Notice，BOM 用于兼容 Windows PowerShell 5.1）。
