# windows/action1/

`windows/` 下三个策略脚本的 **Action1 批量部署版本**。用来通过 [Action1](https://www.action1.com/) RMM 一次性推送给一批 Windows 端点。

> 这些是**独立副本**，不影响 `../` 下的原版脚本（原版仍用于 `iex` 一行安装 / `Install.ps1` 引导 / 每天 04:00 自助更新那一套）。

| Script | 用途 | 与原版差异 |
| --- | --- | --- |
| [ORG_PUBLIC_ALL.ps1](ORG_PUBLIC_ALL.ps1) | 公共/共享设备策略（20m 空闲注销、短电源超时、盖上即注销、8 天配置文件清理） | 见下 |
| [ORG_LIMITED_USERS.ps1](ORG_LIMITED_USERS.ps1) | 个人受限设备策略（120m 空闲注销、较宽松电源超时、盖上即注销、保留配置文件） | 见下 |
| [CLEAN_ALL.ps1](CLEAN_ALL.ps1) | 撤销以上所有策略 + logoff / 自动更新计划任务，重新启用锁屏（LAPS 保留） | 见下 |

核心策略与原版一致；Action1 版**额外**加了锁屏图 + 桌面壁纸强制（见下），版本号 `1.6.0`（Legal Notice 标记 `<ScriptName>-v1.6.0`）。差异在"外壳"、下面的**兼容性加固**、以及**锁屏/壁纸**。

## 锁屏 / 桌面壁纸（v1.6.0 起，PersonalizationCSP）

两个 ORG 脚本通过 `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP` 强制并**锁定**锁屏图和桌面壁纸（用户改不了）；CLEAN_ALL 撤销。

- **仅 Enterprise/Education 生效**：Pro 需 SharedPC 策略配合，Home **完全不生效**（键写了也被忽略 —— 所以那台 Home 测试机看不到效果，属正常）。
- **图片来源**：顶部常量 `$LockScreenImageUrl` / `$DesktopImageUrl`（http(s)）下载到 `$LockScreenImagePath` / `$DesktopImagePath`（默认在 `C:\ProgramData\KazuhaHub\`，**文件名不能有空格**，否则 CSP 报 Status=2 失败）。预置好图片就把对应 URL 设成 `''`。
- **下载 best-effort**：CDN/网络失败只 `[!]` 告警并跳过强制（绝不写一个不存在的路径），**不**让整个 run 失败；只有注册表写失败才 `exit 1`。已强制 **TLS 1.2**（PS 5.1 默认可能连不上 HTTPS CDN）。
- **省流量**：图片已存在就不重复下载（除非填了校验和且不匹配）。
- PUBLIC 与 LIMITED 用**同一套图片**，仍只差那 5 个文档化常量。

> 改图片：编辑脚本顶部常量重推即可。回滚：推 CLEAN_ALL（清 6 个 CSP 值 + 删两张图）。

## 为什么要单独一套

Action1 agent 在端点上以 **LocalSystem** 身份、**非交互**会话运行脚本，并且通常**不带任何参数**。原版脚本的菜单 / `Read-Host` / GitHub 自助更新 / 每天 04:00 自动更新计划任务在这种环境下要么卡死、要么没意义、要么会和 Action1 的版本管理打架，所以 Action1 版把它们都去掉了：

- **无菜单、无 `Read-Host`** —— 直接应用，不会等输入。
- **无 `-SelfUpdate` / 所有权校验** —— Action1 从临时路径跑脚本，所有权校验会误伤；版本由 Action1 集中管理，推脚本就是发版本。
- **不注册** `Kazuha Hub Auto Update` 计划任务；两个 ORG 版反而会**主动删除**端点上遗留的该任务（如果之前用 `iex`/`Install.ps1` 装过），避免两套更新机制打架。
- **无 `param()` / `[CmdletBinding()]`** —— Action1 会在脚本最前面插入 `$ErrorActionPreference` / `$ProgressPreference` 赋值语句，顶层 `param()` 会因此变成 parse error（`Unexpected attribute 'CmdletBinding'` / `Unexpected token 'param'`）。所以 Action1 版不带参数、用普通变量。
- **无需重启**：实测所有策略在下次登录 / `gpupdate` 后即生效，脚本不重启、也不再用 `3010`。
- **退出码**对接 Action1：`0` = 成功，`1` = 失败（后续步骤不再执行）。

## 兼容性加固（vs 原版，Action1 build）

针对"会不会在特定系统上失效"的问题，Action1 版做了四处加固（只增强健壮性，**不改变写入的策略**）：

1. **空闲注销 / 唤醒注销改用 WTS API**（替代 `quser` + `logoff.exe` 文本解析）。
   - helper（`C:\ProgramData\KazuhaHub\IdleLogoffAll.ps1` / `LogoffOnResume.ps1`）现在调 `wtsapi32.dll`（`WTSEnumerateSessions` / `WTSQuerySessionInformation` / `WTSLogoffSession`），**语言无关**，也**不依赖 `quser.exe`/`logoff.exe`** —— 修复了非英文 Windows（本地化表头）和精简 SKU 上空闲注销失效的问题（#1 + #2）。
   - **失败安全**：读不到会话时间、或算出的空闲值不合理（负数 / >31 天）时**跳过该会话，绝不误注销**正在使用的用户。即使原生 struct 偏移有 bug，最坏也只是"空闲注销不生效"，不会踢人。
2. **Modern Standby 检测（#3）**：apply 时读 `HKLM:\SYSTEM\CurrentControlSet\Control\Power` 的 `CsEnabled`；若为 S0 / Connected Standby 设备，打 `[!]` 警告说明"盖上即注销可能不触发"。仅告警，不改行为（这是硬件/固件限制，脚本无法根治）。
3. **LAPS / Entra 前置检测（#4）**：检测不到 Windows LAPS（`Invoke-LapsPolicyProcessing` 不存在）或设备非 Entra 加入（`dsregcmd /status`）时打 `[!]` 警告，说明 LAPS 策略已写但暂不生效。仅告警。
4. **错误上报（#5）**：apply 前 `$Error.Clear()`，apply 后扫描错误流，**只要有"真失败"**（注册表写入、计划任务注册等；排除"清理不存在的值 / 读取 / 缺 LAPS"这类正常无操作）就 `exit 1` 并打印明细 —— 这样"部分失败"会在 Action1 里**标红**，不再被当成成功。

> ⚠️ **上线前请在 Windows 上冒烟测一次**：第 1 项是 `Add-Type` 原生互操作代码，我在 macOS 上无法运行 PowerShell 验证。建议在一台普通机 + 一台非英文系统 + 一台 Modern Standby 笔记本上各跑一次 helper，确认会话能被正确枚举、空闲注销按预期触发、且**不会误踢活动会话**。安全测法（先用超大阈值确认"不会误注销"）：
>
> ```powershell
> # 以 SYSTEM 运行(psexec -s),先用很大的阈值 —— 预期:什么都不发生
> powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\KazuhaHub\IdleLogoffAll.ps1 -Minutes 99999
> # 在测试会话上用 0 确认"能注销"(会注销当前用户,勿在生产会话执行)
> # powershell ... -File ...\IdleLogoffAll.ps1 -Minutes 0
> ```

## 部署步骤

1. Action1 console → **Scripts** → 新建 PowerShell 脚本，把对应 `.ps1` 内容粘进去（或上传文件）。文件是 **UTF-8 with BOM**（含中文 Legal Notice，BOM 保证 Windows PowerShell 5.1 不乱码）—— 上传文件比粘贴更稳妥。
2. 用 **Run Script** / Automation 推给目标端点组，**不带任何参数**。脚本以 SYSTEM 身份应用策略，`exit 0` = 成功、`exit 1` = 失败（Action1 标红）。**无需配置重启** —— 实测策略在下次登录 / `gpupdate` 后即生效。

## 升级 / 回滚

- **改策略参数**（如空闲注销分钟数）：直接在 Action1 里编辑脚本内容（顶部 Constants 区），重新推一次即可。
- **回滚某台/某批**：推 [CLEAN_ALL.ps1](CLEAN_ALL.ps1)（无参数）。它会撤销策略、删除 logoff 任务和遗留的自动更新任务、重新启用锁屏；LAPS 保留。

## 关于 Install.ps1

原版 [../Install.ps1](../Install.ps1) 是从 GitHub 拉脚本落地的 **引导安装器** —— 在 Action1 场景里它被 Action1 本身取代了（Action1 就是分发机制），所以这里**不提供** Action1 版。如果确实需要（比如想让 Action1 去 GitHub 拉最新版而不是推内置副本），告诉我再加。

## 语法检查

Windows 上（无报错即通过）：

```powershell
$tokens = $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    "ORG_PUBLIC_ALL.ps1", [ref]$tokens, [ref]$errors) | Out-Null
$errors
```

这些脚本没有 SHA 校验（仓库只对 `ssh/install-duo-ssh.sh` 维护哈希），`Install.ps1` 对 Windows 脚本也只做 parse 校验，所以改完跑一遍上面的 parse 检查就够了。
