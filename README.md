# ScoopArchive

通过 GitHub Actions 构建 Scoop 离线归档，用于在内网环境还原 Windows 软件环境。

## 变体

| 变体 | 内容 |
|---|---|
| `base` | 最小 CLI 工具集 + VC++ 运行库 |
| `codeql` | base + JDK×4 + CodeQL + Maven/Gradle + 规则仓库 |
| `python` | base + Python 3.14 + uv + 常用库 |
| `agent` | base + Node.js 24 + pnpm + bun + Claude Code / Codex / pi / opencode |
| `dev` | base + MinGW / 语言运行时 / 包管理 / 容器 / IDE |
| `pentest` | base + 信息收集 / 扫描 / 口令 / 凭据扫描 / Web 代理 |
| `re` | base + 反汇编 / 调试 / PE 分析 / .NET 反编译 / 样本取证 |
| `apps` | base + 常用软件：终端与 Nerd 字体 / 浏览器 / 文档 / 影音 / 系统工具 / 密码管理 |
| `apps-plus` | base + 增强软件：媒体处理 / 云存储 / 虚拟化 / 开发向桌面工具 |

每个变体都是 **base + 一层**，互不重叠、可以叠加使用。需要哪一类就构建哪个，
不必为了几个工具去构建一个「全家桶」。

`base` 保持精简——只放所有变体都要用的东西（git / 7zip / aria2 / 解包器 /
基础 CLI / VC++ 运行库）。功能性的工具按**用途**归到对应变体，不按 GUI/CLI 分：
`apps` 的「系统工具」组里既有 Sysinternals 这样的 GUI 套件，也有 `nircmd`、
`scoop-search`、`everything-cli` 这样的命令行工具，因为它们解决的是同一类问题。

具体包清单见 [`.github/scripts/layers.psd1`](.github/scripts/layers.psd1)。

## 使用

### 1. 构建

Fork 本仓库 → 在 Actions 页面启用 Workflows → 手动触发 **Scoop Archive** 并选择变体。
构建完成后从 Artifacts 下载 `Scoop-{variant}-{run_id}.7z`（默认保留 3 天）。

### 2. 还原

解压归档到目标路径（例：`D:\00PackageManager\`），然后以**管理员身份**运行 PowerShell：

```powershell
[Environment]::SetEnvironmentVariable('SCOOP', 'D:\00PackageManager\Scoop', 'User')

# dev 变体的 go：构建时把 GOPATH 指到了 $SCOOP\gopath（否则 go install 的产物
# 落在 %USERPROFILE%\go，不进归档）。注册表不随归档走，这里要重设一次。
[Environment]::SetEnvironmentVariable('GOPATH', 'D:\00PackageManager\Scoop\gopath', 'User')

# 把归档内的目录追加进用户级 PATH（幂等，重复执行不会重复追加）
#   %SCOOP%\shims       —— 所有 scoop shim
#   %SCOOP%\gopath\bin  —— go install 的产物（go 的 manifest 不管这个目录）
$regPath = 'HKCU:\Environment'
$currentPath = (Get-ItemProperty -Path $regPath -Name PATH -ErrorAction Ignore).PATH
if (-not $currentPath) { $currentPath = '' }
foreach ($p in '%SCOOP%\shims', '%SCOOP%\gopath\bin') {
    if ($currentPath -notlike "*$p*") { $currentPath = $currentPath.TrimEnd(';') + ';' + $p }
}
Set-ItemProperty -Path $regPath -Name PATH -Value $currentPath.TrimStart(';')

# 刷新当前会话
$env:SCOOP = 'D:\00PackageManager\Scoop'
$env:PATH += ';D:\00PackageManager\Scoop\shims;D:\00PackageManager\Scoop\gopath\bin'

Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
scoop reset *
scoop cleanup *
```

还有两步装包时无法完成，需要还原后手动跑一次：

```powershell
# 所有变体：VC++ 运行库合集（安装器写系统目录，归档覆盖不到）
vcredist-aio

# 仅 dev 变体：把 msys2 接进 ruby（gem install 带原生扩展的包需要）
ridk install 3
```

> 归档如果是从 Actions 下载的 `.zip`，需要解压两次——外层 zip，内层 `.7z`。

**PATH 说明**：python / nodejs / pnpm 用 manifest 的 `env_add_path` 注册 PATH，
`vcredist-aio`、AI Agents 等用 shim 落在 `Scoop\shims`。两者都由 `scoop reset *`
重建，无需手工配置。

### 前提条件

- Windows 10 / 11 或 Windows Server 2019+
- PowerShell 5.1+
- 管理员权限

## 项目结构

```
.github/
├── actions/setup-scoop/action.yml   ← Scoop 环境：安装 / bucket 注册 / aria2 配置
├── scripts/layers.psd1              ← 变体 / 层 / 包清单（唯一事实来源）
├── scripts/ScoopLib.ps1             ← 构建共享库
└── workflows/scoop-archive.yml      ← 唯一入口（只做编排）
requirements.txt                     ← Python 常用库清单（python 变体）
```

注册的 bucket：`main`（scoop 自带）/ `extras` / `versions` / `nirsoft` / `java` /
`nonportable` / `nerd-fonts` / `ktools`（第三方，渗透工具），外加 `codeql` / `python`
变体才注册的 `r-bucket`。

`ScoopLib.ps1` 是逻辑中心。GitHub Actions 的每个 step 是独立进程、函数不跨 step
存活，所以共享逻辑必须落成文件、由每个 step 点源引入：

```powershell
. "$env:GITHUB_WORKSPACE\.github\scripts\ScoopLib.ps1"
```

| 函数 | 用途 |
|---|---|
| `Invoke-Native` | 运行原生命令并检查退出码（基元） |
| `Invoke-ScoopRetry` | 装 scoop 包：整批快路径 → 失败降级逐包重试 |
| `Get-BuildPlan` | 把变体展开成有序层列表（读 layers.psd1，校验未知变体/层） |
| `Install-ScoopLayer` | 装一个层：Early/Required fail-loud、Optional 告警，并处理 `Env` / `MkDir` / `Pin` |
| `Add-ScoopBucket` | 幂等注册 bucket |
| `Install-PipPackages` | 按 requirements.txt 安装 + 导出环境快照 |
| `Write-BuildSummary` | 把构建计划写进 Step Summary（归档是不透明的 7z，至少让 run 页面留个记录） |

### 失败策略：哪些层 fail-loud，哪些跳过

策略在 `layers.psd1` 里按**组**声明：`Required`（含 `Early`）走 fail-loud，`Optional` 走跳过。
`Invoke-ScoopRetry` 默认在重试耗尽后**终止构建**；加 `-ContinueOnError` 则跳过并发出
`::warning::` annotation（会出现在 Actions 的 annotations 面板，不会被日志淹没）。

| 层 | 策略 | 理由 |
|---|---|---|
| 解包器（`innounp` / `dark`） | fail-loud | 后续包依赖它们解包 |
| CLI 工具集、`apps`、`apps-plus` | 跳过 + 告警 | 单个工具失败不该作废一两小时的构建 |
| `codeql` / `python` / `agent` / `dev` / `pentest` / `re` | fail-loud | 这些层的包是变体的核心价值，缺一个就该重新构建 |

## 维护须知

### 加包 / 加层 / 加变体

包清单、失败策略、层顺序、变体映射全部在 `.github/scripts/layers.psd1`，workflow 只做编排。
**加包不需要碰 YAML。**

| 想做什么 | 改哪里 |
|---|---|
| 加一个包 | 找到对应层，放进 `Required`（失败即终止）或 `Optional`（失败只告警） |
| 加一个层 | `Order` 加层名 → `Layers` 里定义 → 需要的话在 `Variants` 里映射 |
| 加一个变体 | `Layers` 定义层 → `Variants` 加映射 → **workflow 的 `options:` 也加一行** |
| 加一个全家桶变体 | `Variants` 里写 `@('*')`，会被展开成 `Order` 全集 |

两处必须手工同步，改错会在构建时报明确错误而不是静默出错：

- `workflow_dispatch` 的 `options:` 是静态列表，加变体必须同时改 workflow
- 新层名要进 `Order`，否则不会被 `'*'` 展开；`base` 必须留在第一位，它的解包器是
  后续所有包的前提

`Install-ScoopLayer` 还认三个可选字段：`Env`（装包前设持久环境变量）、`MkDir`（装包前
建目录）、`Pin`（装完后按顺序 `scoop reset`，给写同一个变量的多个包定序 —— JDK 都写
`JAVA_HOME`，不定序的话结果由 `scoop reset *` 的字典序决定，`liberica8` 会排在最后）。

### 原生命令必须走 Invoke-Native

`$ErrorActionPreference = 'Stop'` 对原生命令（`scoop.cmd` / `pip.exe` / `git.exe`）
**无效**——失败只设置 `$LASTEXITCODE`，step 依然报成功。实测 PowerShell 7.6.5：

```powershell
PS> $ErrorActionPreference = 'Stop'
PS> cmd /c "exit 3"; "still running"
still running
```

这会让构建「绿色失败」，产出静默缺包的归档。**新增 step 时所有原生命令调用都必须
经 `Invoke-Native` / `Invoke-ScoopRetry`**，由它们显式检查退出码。

### 包名要带 bucket 前缀

同一个包名可能存在于多个 bucket（例如 `ffuf` 同时在 `main` 和 `ktools`），裸名安装
的结果取决于 bucket 遍历顺序。用 `main/ffuf` 保证确定性。

### 已被移入 deprecated/ 的包装不上

Scoop 的 manifest 查找只搜 `<bucket>/bucket/`，`deprecated/` 只在「已安装」分支才回退。
`cwrsync`、`idea-ultimate` 这类包在全新安装时**无论带不带 bucket 前缀都找不到**，会直接
abort。替代方案见 `extras/idea`（JetBrains 合并版）。

### 不要加装到系统目录的包

跑安装器写进 WinSxS / `C:\Program Files` 的包（manifest 里出现 `RunAs` / `msiexec` /
`is_admin`）**不会**被归档覆盖——还原后只有 Scoop 的「已安装」记录、没有实际组件。

例外是 manifest 把安装器声明成 `bin` 的包（如 `vcredist-aio`）：文件会留在 `$dir`
里不被清理，随归档一起走，还原后直接执行即可。新增此类包时先确认有没有 `bin` 声明。

### 确认包在离线环境真能跑通

「装上了」不等于「能用」。加包前读一遍 manifest 的 `notes` / `suggest` / `depends`，
问三个问题：

**1. 它依赖的构建工具在不在归档里？**
`rust` / `rust-msvc` / `rustup-msvc` 三个包的 notes 都写着需要 MSVC Build Tools +
Windows SDK，而那套东西在 main/extras/versions/nonportable 四个 bucket 里**都不存在**——
装了也是死的，`cargo build` 到链接阶段必失败。改用 `rustup-gnu`，它默认
`--default-host x86_64-pc-windows-gnu`，链接走已装的 mingw gcc。

同理：`ruby` 的 notes 要求先装 `msys2`，否则 `gem install` 带原生扩展的包会编译失败；
没有 VS generator 时 `cmake` 需要 `ninja`。

**2. 是不是同一个包装了两遍？**
`rust` 和 `rust-msvc` 的 manifest 除 `checkver` 块外**完全相同**——同一个 MSI，
而且两者都声明 `bin\rustc.exe|rustdoc.exe|cargo.exe`，shim 直接冲突。
用 `diff a.json b.json` 对比一下就知道了。

**3. PATH 有没有写到归档外面？**
`go` 的 manifest 用 `Add-Path` 把 `$env:GOPATH\bin`（缺省 `%USERPROFILE%\go\bin`）
写进**持久用户 PATH**。那在 `D:\00PackageManager` 之外，而且不是 `env_add_path`，
`scoop reset` 不会重建。所以构建时先把 `GOPATH` 指到 `$SCOOP\gopath`，
还原时再手工把这个目录加进 PATH（见上面的还原步骤）。

判断标准：manifest 里用 `env_add_path` / `env_set` 的由 scoop 托管，`scoop reset`
会重建；用 `Add-Path` 手工写的则不会。

### requirements.txt 只写直接使用的库

不要写传递依赖，让 pip 自己解析。历史版本是 `pip freeze` 的产物，55 条声明里 21 条
是别处自动带入的，还夹带了 `accelerate → torch`（下载 118 MB / 安装 531 MB）这条
与安全审计无关的 ML 依赖链。

版本锁定在构建时生成的 `requirements.lock` 里做，不在这里。

```bash
# 查某个包是不是别人的传递依赖
pip install --dry-run --ignore-installed --report - -r requirements.txt
```
