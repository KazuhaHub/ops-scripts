# ssh/

Linux 服务器 SSH 加固相关脚本。

| Script | Description |
| --- | --- |
| [install.sh](install.sh) | **一行 bootstrap 安装器**：从 GitHub 拉取并安装 `install-duo-ssh.sh` 到 `/usr/local/sbin/`，可选择直接转发参数完成安装。 |
| [install-duo-ssh.sh](install-duo-ssh.sh) | 一键安装、配置、卸载和更新 Duo SSH 2FA。 |

## 一行安装（推荐）

最快的方式：

```bash
curl -fsSL https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install.sh | sudo bash
```

bootstrap 会下载 `install-duo-ssh.sh` 到 `/usr/local/sbin/`、做 `bash -n` 校验、安装 `kh-duo` 快捷方式。安装完后跑 `sudo kh-duo` 进交互菜单。

**完全自动化部署**（适合 Ansible / cloud-init / MDM）—— 把 Duo 凭据通过 `--` 转发给主脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install.sh \
  | sudo bash -s -- \
      --ikey DIXXXXXXXXXXXXXXXXXX \
      --skey your-secret-key \
      --host api-xxxxxxxx.duosecurity.com \
      --yes
```

bootstrap 会下载、安装、然后 `exec` 主脚本，把 `--` 之后的所有参数转发过去，一气呵成。

> ⚠️ `curl ... | sudo bash` 的 stdin 是 pipe 不是 TTY，所以**主脚本的菜单不会自动触发**（它要 `[[ -t 0 && -t 1 ]]`）。这是为啥不传参数时 bootstrap 装好就退出，让你下次单独跑 `sudo kh-duo`。

### 中国大陆一行安装（推荐 jsDelivr）

raw.githubusercontent.com 在大陆经常不可达。把 bootstrap 自身和主脚本都走 jsDelivr CDN：

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/KazuhaHub/ops-scripts@master/ssh/install.sh \
  | sudo bash -s -- --cdn jsdelivr
```

`--cdn jsdelivr` 让 bootstrap：
1. 用 jsDelivr 下载主脚本（v1.2.0+ bootstrap 内置 jsDelivr / Statically / canonical 三个 prefix 的白名单）
2. 自动持久化 jsDelivr 到 `/etc/duo/install-duo-ssh.conf`，未来 `kh-duo --update` 也走 CDN

支持的 provider：`jsdelivr` / `statically` / `github`（默认 = canonical）。

下载完都会跑[多锚点 SHA256 quorum 校验](#威胁-2镜像被攻破推恶意脚本v160)（v1.2.0+），任意单一 CDN 被污染都会被另两个识别。

也可以组合 `--channel beta`：

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/KazuhaHub/ops-scripts@beta/ssh/install.sh \
  | sudo bash -s -- --cdn jsdelivr --channel beta
```

### 高级覆盖

`KH_DUO_BOOTSTRAP_URL` 环境变量可以覆盖下载源，但必须匹配下面三个 prefix 之一（v1.2.0+）：

- `https://raw.githubusercontent.com/KazuhaHub/ops-scripts/`
- `https://cdn.jsdelivr.net/gh/KazuhaHub/ops-scripts@`
- `https://cdn.statically.io/gh/KazuhaHub/ops-scripts/`

绝大多数场景用 `--cdn` 就够了，env 覆盖只在用自建镜像/企业代理时才需要。

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
| `--allow-password` | 强制开启 password + Duo fallback（即使有 SSH key）。 |
| `--strict-publickey` | 强制 publickey-only，没找到 key 时直接 abort（不允许密码登录）。 |
| `--skip-key-check` | 跳过 authorized_keys 检查。 |
| `--use-cdn PROVIDER` | 一键切换更新源到指定 CDN：`jsdelivr` / `statically` / `github`（v1.6.1+）。 |
| `--set-mirror URL` | 持久化任意 https 更新 URL（覆盖 channel 默认）。 |
| `--clear-mirror` | 移除持久化的 mirror，恢复 channel 默认。 |
| `--install-auto-update` | 单独注册每天 04:00 自动更新（systemd timer，cron fallback）。 |
| `--remove-auto-update` | 移除自动更新任务（systemd 和 cron 两边都清）。 |
| `--no-auto-update` | 安装时**不要**自动注册更新任务（适合用 Ansible 等外部工具管理）。 |
| `--uninstall` | 卸载 Duo SSH 2FA 并恢复 SSH 配置。 |
| `--no-menu` | 即使在 TTY 中也不进入交互菜单。 |
| `-y`, `--yes` | 自动确认提示，适合自动化执行。 |
| `-h`, `--help` | 显示帮助。 |

### 交互菜单（v1.2.0+）

直接跑 `sudo kh-duo`（或 `sudo ./install-duo-ssh.sh`）会进交互菜单：

```
What would you like to do?
  1) Install / configure Duo 2FA  (default — full setup with new credentials)
  2) Adjust settings              (keep credentials; change auth/bypass/breakglass)
  3) Show current configuration
  4) Uninstall Duo 2FA
  5) Check for script updates
  6) Install / refresh the 'kh-duo' shortcut
  7) Quit without changes
```

**Adjust settings (选项 2)** 是 v1.2.0 新增的：自动从 `/etc/duo/pam_duo.conf` 和 `/etc/ssh/sshd_config` 的 Duo 块读出当前 ikey/skey/host 和所有开关，让你在不重新输凭据的情况下切换：

- 是否允许 password fallback
- 是否绕过 localhost
- 额外的 bypass CIDR（多个用逗号隔开）
- breakglass user

子菜单里多次切换会先在内存里累积，最后选 "5) Apply pending changes" 一次性写文件 + 重启 sshd。期间任何时候 `q` 都能放弃改动退出。

**Show current configuration (选项 3)** 不动任何东西，只 dump 当前生效的设置（含 ikey 前 8 位脱敏）。

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

更新脚本（写 `$SCRIPT_PATH`，需要 root）：

```bash
sudo ./install-duo-ssh.sh --update
# 或保留兼容性，--self-update 是 alias：
sudo ./install-duo-ssh.sh --self-update
```

默认更新源是 canonical GitHub：

```text
https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install-duo-ssh.sh
```

完整性由 [多锚点 SHA256 quorum 校验](#威胁-2镜像被攻破推恶意脚本v160) 保证（即使 raw.github 自身被污染，也会被另两个独立锚点检测到）。

### 中国大陆加速（推荐 jsDelivr，v1.6.1+）

raw.githubusercontent.com 在大陆经常不可达。一行命令切到 jsDelivr CDN（公共服务，国内 POP 可达，内容直接从 GitHub 拉）：

```bash
sudo kh-duo --use-cdn jsdelivr
```

脚本会按当前 channel（stable / beta）自动拼对应分支的 jsDelivr URL，写到 `/etc/duo/install-duo-ssh.conf`。下次 `--update` 和每天 04:00 的自动更新都走 jsDelivr。

支持的 provider：

| provider | 用途 |
|---|---|
| `jsdelivr` | jsDelivr CDN，CN POP 可达，**推荐** |
| `statically` | Statically CDN，备用 |
| `github` | 等价于 `--clear-mirror`，回到 canonical |

> **不用担心 CDN 被攻破**——下载完都会从三个**独立** CDN（raw.github / jsDelivr / Statically）并发拉 `.sha256` 做 quorum 校验。任意一个 CDN 单独被污染，都会被另外两个识别并拒绝。详见下面的[防篡改设计](#防篡改设计)。

首次安装就要 CN 加速？bootstrap 也支持，见 [中国大陆一行安装（推荐 jsDelivr）](#中国大陆一行安装推荐-jsdelivr)。

### 自定义镜像源（v1.3.0+）

如果你不想用 `--use-cdn` 提供的预设——例如想走企业内部镜像、自建 OSS、或某个特定加速器（ghproxy / ghfast）：

```bash
# 设置一次（写到 root-owned 600 的 /etc/duo/install-duo-ssh.conf）
sudo kh-duo --set-mirror https://ghproxy.com/https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install-duo-ssh.sh

# 看现在用什么 URL（任何用户都能看，纯只读）
kh-duo --show-config

# 撤销，回到默认 GitHub
sudo kh-duo --clear-mirror
```

无论镜像怎么换，下载完都会跑多锚点 SHA256 quorum 校验，被污染的镜像会被立刻识别并拒绝。

URL 解析顺序（trust priority 由高到低）：

1. `/etc/duo/install-duo-ssh.conf` 里的 `update_url = ...`
2. `KH_DUO_UPDATE_URL` 环境变量 —— **只在 `SUDO_USER` 为空时生效**（裸 root，比如 cron / 系统服务）。`sudo` 调用时被拒。
3. 默认 canonical GitHub URL

也可以直接编辑配置文件（任何能写 `/etc/duo/` 的方式都行，比如 Ansible template）：

```ini
# /etc/duo/install-duo-ssh.conf
update_url = https://cdn.jsdelivr.net/gh/KazuhaHub/ops-scripts@master/ssh/install-duo-ssh.sh
```

### 防篡改设计

两个独立威胁，分别防：

#### 威胁 1：本地非特权用户篡改

| 层 | 怎么防 |
|---|---|
| **URL 来源** | 优先读 `/etc/duo/install-duo-ssh.conf`（root-owned 600）。`KH_DUO_UPDATE_URL` / `KH_DUO_CHANNEL` 在 sudo 上下文（`SUDO_USER` 非空）被拒，避免 `sudo -E KH_DUO_UPDATE_URL=evil kh-duo` 攻击。 |
| **`$SCRIPT_PATH` 所有权** | `--update` 前要求脚本文件 owner 是 root。否则用户把脚本放 `/home/<user>/` 里执行就能在 root 写下去之前换文件。 |
| **PATH pin** | 脚本顶部 `PATH=/usr/sbin:/usr/bin:/sbin:/bin`，curl/awk/install 等不会被攻击者的 `$HOME/bin/` 同名脚本劫持。 |

#### 威胁 2：镜像被攻破推恶意脚本（v1.6.0+）

威胁场景：脚本从某个 mirror 下载（默认 jsDelivr，或 admin 用 `--set-mirror` 设的代理），mirror 被攻破，attacker 替换 `install-duo-ssh.sh`。仅靠 shebang + `bash -n` 拦不住——attacker 写合法 bash 即可。

防御：**`.sha256` 文件并发从多个独立 CDN 拉取，要求所有可达锚点结果一致**（quorum）。

```
download source     →  install-duo-ssh.sh        (~50KB，可能被换)
3 independent CDNs  →  install-duo-ssh.sh.sha256 (~80B 各一份，要求全部一致)
                       ├── raw.githubusercontent.com  (canonical)
                       ├── cdn.jsdelivr.net           (CN 可达)
                       └── cdn.statically.io          (CN 可达)
```

设计要点：

- **三个 CDN 完全独立**——分别由 GitHub、Cloudflare/Fastly、独立运营商承载。攻击者要绕过 quorum，得**同时**污染至少两个完全独立的基础设施。
- **CN 大陆友好**——即使 raw.githubusercontent.com 被墙，jsDelivr + Statically 通常还能形成 quorum。0 个可达时才退到要求 `KH_DUO_PIN_SHA256` 的离线模式。
- **任意两个 anchor 不一致 → 立即拒绝** 并打印每个 anchor 返回的 hash，方便事故定位。
- **3 个并发拉取**，每个 8s 超时；总耗时 < 1 秒。

`.sha256` 由 GitHub Actions ([.github/workflows/update-sha256.yml](../.github/workflows/update-sha256.yml)) 在每次 `install-duo-ssh.sh` 提交后自动重生。jsDelivr / Statically 都直接镜像 GitHub 内容，无需单独发布。

信任优先级（高到低）：

1. **`KH_DUO_PIN_SHA256` 环境变量** —— 带外信任，最高优先级。适合**3 个 CDN 全部不可达** 的极端隔离环境，hash 通过 VPN/sneakernet 拿到后塞 env 里。
2. **多锚点 quorum** —— 默认行为。并发拉 3 个 anchor 的 `.sha256`，所有可达的必须一致；本地 hash 必须匹配该值。
   - 3/3 可达 → ok
   - 2/3 或 1/3 可达 → warn 并通过（提示考虑设 PIN 加强）
   - 0/3 可达 → 拒绝（要求 PIN）

| 攻击者控制 | 结果 |
|---|---|
| 任一单一 CDN（含默认 jsDelivr）被攻破，其他正常 | ❌ 拒绝（anchors disagree） |
| 用户自定义 `--set-mirror` 被攻破 | ❌ 拒绝（mirror 服务的脚本 hash 与 3 个 anchor 不匹配） |
| 同时控制 ≥2 个独立 CDN | ⚠️ 绕过（out-of-scope，建议设 PIN） |
| 同时控制 GitHub 仓库本身（PAT 泄露） | ⚠️ 绕过（attacker 改源 + 改 anchor，所有 anchor 同步污染。建议 GitHub 账号开 2FA + 关键变更走人审 release） |
| 本地 `KH_DUO_PIN_SHA256` 被普通用户篡改 | ❌ 拒绝（sudo 上下文 env 被忽略） |

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

### Beta 通道（v1.5.1+）

为了避免 v1.4.x 自更新崩溃那种悲剧波及整个 fleet，仓库分两条分支：

| 分支 | 用途 | 谁在用 |
|---|---|---|
| `master` | stable，fleet 默认 | 所有生产服务器 |
| `beta` | 预览，新版本先在这里 soak | 一台/几台测试机 |

工作流：commit 先进 `beta` → 测试机自动更新到 beta 版本 → 跑几天没问题 → merge 到 `master` → fleet 第二天 04:00 全量更新。

**切换通道（菜单或 flag）：**

```bash
# 把这台机器切到 beta（持久写到 /etc/duo/install-duo-ssh.conf）
sudo kh-duo --set-channel beta

# 或在菜单里：sudo kh-duo → 5) Update settings → 1) Switch update channel

# 切回 stable
sudo kh-duo --set-channel stable
```

**bootstrap 时直接选 beta：**

```bash
curl -fsSL https://raw.githubusercontent.com/KazuhaHub/ops-scripts/beta/ssh/install.sh \
  | sudo bash -s -- --channel beta
```

bootstrap 会从 beta 分支拉脚本 + 持久化 `channel = beta` 到配置文件，之后 `kh-duo --update` 自动跟 beta。

### 自动更新（v1.5.0+）

每次成功安装后，脚本会自动注册一个每天 **04:00** 跑 `--update --no-menu --yes` 的任务，跟 Windows 那边的 `Kazuha Hub Auto Update` 行为对齐。优先级：

1. **systemd timer** —— 检测到 `systemctl` 时安装 `/etc/systemd/system/kh-duo-update.{timer,service}`，`Persistent=true` + `RandomizedDelaySec=15min`（错过窗口会补跑、最多 15 分钟随机延迟避免 fleet 同时打满 GitHub）
2. **cron fallback** —— 没 systemd 时写 `/etc/cron.d/kh-duo-update`，跳点 sleep `0–900` 秒再跑，同样的 fleet 错峰目的
3. **两个都没** —— 报错让用户手动调度

`kh-duo --show-config` 顶部会显示当前用的是哪种、下次什么时候跑。`--uninstall` 会同时清两边（即使一开始用的 systemd，将来切到 cron 后再卸载也能干净）。

控制 flag：

```bash
sudo kh-duo --install-auto-update    # 单独注册（不重装 Duo 的话）
sudo kh-duo --remove-auto-update     # 单独移除
sudo kh-duo --no-auto-update         # 安装 Duo 时跳过注册（外部工具管理时用）
```

立即触发（不等 04:00）：

```bash
# systemd
sudo systemctl start kh-duo-update.service

# cron
sudo /usr/local/sbin/install-duo-ssh.sh --update --no-menu --yes
```

### 登录方式自动检测（v1.4.0+）

脚本会自动读取 `/root/.ssh/authorized_keys` 和 `$SUDO_USER` 主目录：

| 现状 | 默认行为 |
| --- | --- |
| 找到 SSH key | publickey + Duo（password 拒绝）—— 推荐配置 |
| 没有 SSH key | **publickey OR password + Duo**（避免管理员锁死自己），同时**大字提醒**强烈建议加 key |

`--allow-password` 仍然能强制打开 password fallback（即使有 key）；`--strict-publickey` 则强制走 key-only，没有 key 时直接 abort。这两个 flag 互斥，优先级高于自动检测。

向导（`sudo kh-duo` 进菜单选 1）的 Step 2/5 也会按这个逻辑选择默认值，并在没找到 key 时把"强烈建议加 key"放在最显眼的位置。

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
