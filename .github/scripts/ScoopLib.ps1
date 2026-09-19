# =============================================================================
# ScoopLib.ps1 — 构建共享库：读构建计划 + 装包
#
# 点源引入：. "$env:GITHUB_WORKSPACE\.github\scripts\ScoopLib.ps1"
# 校验相关的函数在 ValidateLib.ps1（它点源本文件，反向不依赖）。
#
# 本库存在的理由：$ErrorActionPreference = 'Stop' 对原生命令无效 —— 失败只设置
# $LASTEXITCODE，step 依然报成功，构建会「绿色失败」并产出静默缺包的归档。
# 所以所有原生命令都走 Invoke-Native / Invoke-ScoopRetry，显式检查退出码。
#
# 不设 $PSNativeCommandUseErrorActionPreference = $true：那个开关会把 pip / git /
# 7z 写进 stderr 的进度条和警告都变成终止错误，误报太多。
# =============================================================================

$ErrorActionPreference = 'Stop'

# dot-source 期间 $PSScriptRoot 指向本文件目录；这样本地也能直接点源调试
$script:ScoopLibRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:GITHUB_WORKSPACE '.github\scripts' }
$script:PlanFile = Join-Path $script:ScoopLibRoot 'layers.psd1'

function Write-Section {
    <#
    .SYNOPSIS
        打印带分隔线的阶段标题，让长日志可读。
    #>
    param([Parameter(Mandatory)][string]$Title)

    Write-Host "`n$('─' * 72)" -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('─' * 72) -ForegroundColor DarkCyan
}

function Invoke-Native {
    <#
    .SYNOPSIS
        运行原生命令并显式检查退出码。本库的基元。

    .PARAMETER AllowFailure
        允许非零退出码，由调用方处理。

    .PARAMETER PassThru
        返回退出码。默认不返回，否则 workflow 里每个裸调用都会多打印一行数字。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure,
        [switch]$PassThru,
        [string]$Activity = ''
    )

    $label = if ($Activity) { $Activity } else { "$FilePath $($Arguments -join ' ')" }
    Write-Host "  > $label" -ForegroundColor DarkGray

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # `| Out-Host` 是必需的：不接管道的话命令 stdout 会混进本函数返回值，
        # 调用方拿到的就是「一整段日志 + 退出码」而不是退出码。
        # Out-Host 只把输出送到控制台，不进成功流，$LASTEXITCODE 不受影响。
        & $FilePath @Arguments | Out-Host
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "命令失败 (exit $exitCode): $label"
    }

    if ($PassThru) { return $exitCode }
}

function Invoke-ScoopRetry {
    <#
    .SYNOPSIS
        安装 Scoop 包，带指数退避重试。

    .DESCRIPTION
        先整批装（scoop 只解析一次依赖图）；整批失败才降级逐包重试以定位失败项。

        不传 -k：那是 --no-cache，会让重试前的 cache rm 变成空操作。

    .PARAMETER ContinueOnError
        重试耗尽后跳过而非终止。仅用于非关键包，失败清单会以告警汇总。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Packages,
        [int]$MaxRetries = 3,
        [int]$BaseDelaySec = 10,
        [switch]$ContinueOnError
    )

    $Packages = @($Packages | Where-Object { $_ })
    if ($Packages.Count -eq 0) { return }

    # 快路径：整批安装
    $code = Invoke-Native -FilePath 'scoop' -Arguments (@('install', '-u') + $Packages) `
        -AllowFailure -PassThru -Activity "scoop install ($($Packages.Count) 个包)"
    if ($code -eq 0) {
        Write-Host "  [OK] $($Packages.Count) 个包全部安装成功" -ForegroundColor Green
        return
    }

    Write-Warning "整批安装失败 (exit $code)，降级为逐包重试以定位失败项"

    # 慢路径：逐包重试
    $failed = [System.Collections.Generic.List[string]]::new()

    foreach ($pkg in $Packages) {
        $ok = $false
        for ($attempt = 1; $attempt -le $MaxRetries -and -not $ok; $attempt++) {
            $code = Invoke-Native -FilePath 'scoop' -Arguments @('install', '-u', $pkg) -AllowFailure -PassThru
            if ($code -eq 0) { $ok = $true; break }

            Write-Warning "  $pkg : 第 $attempt/$MaxRetries 次失败 (exit $code)"
            if ($attempt -lt $MaxRetries) {
                $delay = $BaseDelaySec * [Math]::Pow(2, $attempt - 1)
                Write-Host "    ${delay}s 后重试 ..."
                # 清掉该包的下载缓存，确保重试时重新下载而不是复用半损坏的文件
                Invoke-Native -FilePath 'scoop' -Arguments @('cache', 'rm', $pkg) -AllowFailure
                Start-Sleep -Seconds $delay
            }
        }

        if ($ok) {
            Write-Host "  [OK] $pkg" -ForegroundColor Green
        } else {
            Write-Warning "  [FAIL] $pkg 重试 $MaxRetries 次后仍失败"
            $failed.Add($pkg)
        }
    }

    if ($failed.Count -gt 0) {
        $list = $failed -join ', '
        if ($ContinueOnError) {
            # ::warning:: 让失败出现在 Actions 的 annotations 面板，
            # 而不是淹没在几小时的构建日志里
            Write-Host "::warning title=Scoop 包安装失败::$($failed.Count) 个非关键包被跳过: $list"
        } else {
            Write-Host "::error title=Scoop 关键包安装失败::$list"
            throw "FATAL: 以下关键包安装失败: $list"
        }
    }
}

function Add-ScoopBucket {
    <#
    .SYNOPSIS
        注册 Scoop bucket，已存在则跳过（幂等）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Repo = ''
    )

    # 查目录而不是解析 `scoop bucket list` 的表格：整行子串匹配会把 Source URL
    # 也算进去（例如 URL 里含 "main"），造成「已注册」的误判。
    if (Test-Path "$env:SCOOP\buckets\$Name") {
        Write-Host "  [skip] bucket '$Name' 已注册" -ForegroundColor DarkGray
        return
    }

    $bucketArgs = @('bucket', 'add', $Name)
    if ($Repo) { $bucketArgs += $Repo }
    Invoke-Native -FilePath 'scoop' -Arguments $bucketArgs
}

function Install-PipPackages {
    <#
    .SYNOPSIS
        按 requirements.txt 安装 Python 依赖，并导出环境快照。

    .DESCRIPTION
        整批失败则逐包重装以定位。不做静默跳过：归档缺库比构建失败更糟，
        离线环境里没法补装。

    .PARAMETER LockFile
        环境快照输出路径。版本锁定在这里做，不在 requirements.txt 里手写。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PythonPath,
        [string]$RequirementsFile = 'requirements.txt',
        [string]$LockFile = 'D:\00PackageManager\requirements.lock'
    )

    Invoke-Native -FilePath $PythonPath -Arguments @('-m', 'pip', 'install', '--upgrade', 'pip')

    $code = Invoke-Native -FilePath $PythonPath `
        -Arguments @('-m', 'pip', 'install', '-r', $RequirementsFile) -AllowFailure -PassThru

    if ($code -ne 0) {
        Write-Warning "整批安装失败 (exit $code)，降级为逐包安装以定位失败项"

        $packages = Get-Content $RequirementsFile |
            Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') } |
            ForEach-Object { $_.Trim() }

        $failed = @()
        foreach ($pkg in $packages) {
            $c = Invoke-Native -FilePath $PythonPath `
                -Arguments @('-m', 'pip', 'install', $pkg) -AllowFailure -PassThru
            if ($c -ne 0) {
                Write-Warning "  [FAIL] $pkg"
                $failed += $pkg
            } else {
                Write-Host "  [OK] $pkg" -ForegroundColor Green
            }
        }

        if ($failed.Count -gt 0) {
            Write-Host "::error title=Python 库安装失败::$($failed -join ', ')"
            throw "FATAL: 以下 Python 库安装失败: $($failed -join ', ')"
        }
    }

    & $PythonPath -m pip freeze | Set-Content -Path $LockFile -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'pip freeze 失败，无法生成环境快照。' }
    Write-Host "  已写入 $LockFile（$((Get-Content $LockFile).Count) 个包）"
}

function Set-BuildEnv {
    <#
    .SYNOPSIS
        设置环境变量：当前进程 + 持久（User 作用域）。

    .DESCRIPTION
        包的 installer script 会读它（go 用 $env:GOPATH 决定往哪个 bin 写 PATH），
        所以必须在装包前生效。注册表不随归档走，还原侧由 restore.ps1 重设。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    Write-Host "  [env] $Name = $Value" -ForegroundColor DarkGray
}

function Get-LayerPackages {
    <#
    .SYNOPSIS
        取一个层里指定组的包，滤掉未定义组留下的 $null。

    .DESCRIPTION
        `@($def.Optional)` 在组不存在时得到的是 @($null) 而不是 @()，直接拼进数组
        会让包计数和批处理多出一个空元素。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Definition,
        [ValidateSet('Early', 'Required', 'Optional', 'All')]
        [string]$Group = 'All'
    )

    $groups = if ($Group -eq 'All') { @('Early', 'Required', 'Optional') } else { @($Group) }
    foreach ($g in $groups) {
        foreach ($pkg in @($Definition[$g])) {
            if ($pkg) { $pkg }
        }
    }
}

function Get-BuildPlan {
    <#
    .SYNOPSIS
        把变体展开成有序的层列表。

    .DESCRIPTION
        层与变体的定义都在 layers.psd1，这里只做展开和校验，workflow 不必知道
        哪个变体含哪些层。

    .OUTPUTS
        PSCustomObject — Variant / Layers（有序层名数组）/ Plan（原始数据）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Variant,
        [string]$PlanFile = $script:PlanFile
    )

    if (-not (Test-Path $PlanFile)) { throw "找不到层定义文件: $PlanFile" }
    $plan = Import-PowerShellDataFile -Path $PlanFile

    if (-not $plan.Variants.ContainsKey($Variant)) {
        $known = ($plan.Variants.Keys | Sort-Object) -join ', '
        throw "未知变体 '$Variant'。layers.psd1 里定义了: $known"
    }

    $layers = @($plan.Variants[$Variant])
    # '*' 是「全集」的逃生门：想加一个全家桶变体时写 @('*') 即可
    if ($layers -contains '*') { $layers = @($plan.Order) }

    foreach ($layer in $layers) {
        if (-not $plan.Layers.ContainsKey($layer)) {
            throw "变体 '$Variant' 引用了未定义的层 '$layer'"
        }
    }

    # 属性名刻意叫 LayerNames 而不是 Layers：raw psd1 数据里已经有 .Plan.Layers
    # （层定义表），两者含义不同，同名会让人写错（曾经把 .Layers 当成定义表用）
    [pscustomobject]@{
        Variant    = $Variant
        LayerNames = $layers
        Plan       = $plan
    }
}

function Install-ScoopLayer {
    <#
    .SYNOPSIS
        安装一个层里的所有包。

    .DESCRIPTION
        分组策略由 layers.psd1 决定：Early / Required fail-loud，Optional 只告警。

    .PARAMETER EarlyOnly
        只装 Early 组。setup-scoop 用它把引导包在 aria2 配置生效前装好；
        默认路径会把 Early 一起装（已装过，是 no-op）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Layer,
        [Parameter(Mandatory)]$Plan,
        [switch]$EarlyOnly
    )

    # -Plan 要的是 Get-BuildPlan 的返回值。这里显式检查形状，否则传错东西会在
    # 后面报「String 没有 ContainsKey」这种看不出所以然的错
    if (-not $Plan.Plan -or -not $Plan.Plan.Layers) {
        throw '-Plan 需要 Get-BuildPlan 的返回值（含 .Plan.Layers 层定义表）'
    }
    $definitions = $Plan.Plan.Layers
    if (-not $definitions.ContainsKey($Layer)) {
        throw "未定义的层 '$Layer'（layers.psd1 的 Layers 里没有它）"
    }

    $def = $definitions[$Layer]
    Write-Section "$Layer — $($def.Title)"

    # 持久环境变量必须在装包前生效：包的 installer script 可能读它
    if ($def.Env) {
        foreach ($key in @($def.Env.Keys)) {
            Set-BuildEnv -Name $key -Value $ExecutionContext.InvokeCommand.ExpandString($def.Env[$key])
        }
    }

    # 建目录同样要在装包前：包的 installer script 可能要往里写东西，
    # 也保证归档带得走这个空目录，还原后的 PATH 条目不悬空
    # 过滤 $null：@($def.MkDir) 在没有 MkDir 的层上是 @($null)，展开成空串会让
    # Test-Path 直接报错（和 Get-LayerPackages 里那个陷阱是同一个）
    foreach ($dir in @($def.MkDir | Where-Object { $_ })) {
        $path = $ExecutionContext.InvokeCommand.ExpandString($dir)
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Force -Path $path | Out-Null
            Write-Host "  [mkdir] $path" -ForegroundColor DarkGray
        }
    }

    $early = @(Get-LayerPackages $def -Group Early)
    if ($EarlyOnly) {
        if ($early.Count -eq 0) { Write-Host "  [skip] 本层没有 Early 组" -ForegroundColor DarkGray }
        else { Invoke-ScoopRetry -Packages $early }
        return
    }

    # Early 与 Required 合并成一批：scoop 只解析一次依赖图
    $failLoud = $early + @(Get-LayerPackages $def -Group Required)
    if ($failLoud.Count -gt 0) { Invoke-ScoopRetry -Packages $failLoud }

    $optional = @(Get-LayerPackages $def -Group Optional)
    if ($optional.Count -gt 0) { Invoke-ScoopRetry -ContinueOnError -Packages $optional }

    if ($def.Pin) {
        # 见 layers.psd1 文件头：多个包写同一个环境变量时，谁最后 reset 谁赢
        foreach ($pkg in @($def.Pin)) {
            Invoke-Native -FilePath 'scoop' -Arguments @('reset', $pkg)
        }
    }
}

function Write-BuildSummary {
    <#
    .SYNOPSIS
        把构建计划写进 GitHub Step Summary。

    .DESCRIPTION
        归档是不透明的 7z，构建完只剩一个文件名。摘要让「装了什么」留在 run 页面上。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $rows = foreach ($layer in $Plan.LayerNames) {
        $def = $Plan.Plan.Layers[$layer]
        $count = @(Get-LayerPackages $def).Count
        "| ``$layer`` | $($def.Title) | $count |"
    }

    $summary = @(
        "## Scoop Archive — ``$($Plan.Variant)``"
        ''
        '| 层 | 内容 | 包数 |'
        '|---|---|---|'
        $rows
    ) -join "`n"

    Write-Host "`n$summary"

    if ($env:GITHUB_STEP_SUMMARY) {
        $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
}

function Get-ScoopBucketList {
    <#
    .SYNOPSIS
        取该变体需要注册的 bucket 列表。

    .PARAMETER All
        忽略 Variants 限制返回全部。校验 job 用它把所有 bucket 克隆下来查 manifest。

    .OUTPUTS
        PSCustomObject[] — Name / Repo
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [switch]$All
    )

    foreach ($bucket in @($Plan.Plan.Buckets)) {
        if (-not $bucket) { continue }
        # Variants 是「只在这些变体注册」的白名单；-All 时忽略它
        if (-not $All -and $bucket.Variants -and $Plan.Variant -notin @($bucket.Variants)) { continue }
        [pscustomobject]@{ Name = $bucket.Name; Repo = [string]$bucket.Repo }
    }
}

function Write-ArchiveManifest {
    <#
    .SYNOPSIS
        把这次构建的「计划 vs 实际」写成 ARCHIVE.json，放进归档根目录。

    .DESCRIPTION
        ARCHIVE.json 记录变体、层、计划装的包、实际装了哪些、缺了哪些 —— 内网拿到
        归档时靠它知道里面有什么。

        「实际」以 $SCOOP\apps\<name> 目录是否存在为准，不解析 `scoop list`：
        目录就是随归档走的实体文件，也省掉解析表格的脆弱性。

    .OUTPUTS
        PSCustomObject — 写出的清单
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$Root = 'D:\00PackageManager'
    )

    $scoop = Join-Path $Root 'Scoop'
    $installed = @(
        Get-ChildItem (Join-Path $scoop 'apps') -Directory -ErrorAction Ignore |
            ForEach-Object Name
    )

    $planned = [ordered]@{}
    $missing = [System.Collections.Generic.List[string]]::new()
    $plannedCount = 0
    foreach ($layer in $Plan.LayerNames) {
        $pkgs = @(Get-LayerPackages $Plan.Plan.Layers[$layer])
        $planned[$layer] = $pkgs
        $plannedCount += $pkgs.Count
        foreach ($pkg in $pkgs) {
            if ($installed -notcontains $pkg.Split('/')[-1]) { $missing.Add($pkg) }
        }
    }

    $runUrl = $null
    if ($env:GITHUB_SERVER_URL) {
        $runUrl = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    }

    # 构建期新增的持久 PATH 条目。Add-Path 写的目录不随归档走，也不是 env_add_path，
    # `scoop reset` 不重建（go / uv / bun 都这样），不记下来还原后就用不了。
    # 用前后差集而不是解析 manifest：go 的 Add-Path 参数是变量间接引用，静态解析不出来。
    $extraPath = [System.Collections.Generic.List[string]]::new()
    $extraPathOutside = [System.Collections.Generic.List[string]]::new()
    $baselineFile = Join-Path $env:RUNNER_TEMP 'path-baseline.txt'
    if ($env:RUNNER_TEMP -and (Test-Path $baselineFile)) {
        $before = @((Get-Content $baselineFile -Raw) -split ';' | Where-Object { $_.Trim() })
        $after = @([Environment]::GetEnvironmentVariable('PATH', 'User') -split ';' | Where-Object { $_.Trim() })
        foreach ($entry in $after) {
            if ($before -contains $entry) { continue }
            $full = $entry.TrimEnd('\')
            if ($full.StartsWith($scoop, 'OrdinalIgnoreCase')) {
                # 存相对 $SCOOP 的路径：归档可能被还原到别的根目录
                $extraPath.Add($full.Substring($scoop.Length).TrimStart('\'))
            } else {
                $extraPathOutside.Add($full)
            }
        }
    } else {
        Write-Host "::warning title=缺少 PATH 基线::没找到 $baselineFile，无法采集 Add-Path 目录（应由 setup-scoop 写入）"
    }

    $manifest = [ordered]@{
        variant          = $Plan.Variant
        layers           = $Plan.Layers
        builtAt          = (Get-Date).ToUniversalTime().ToString('o')
        runId            = $env:GITHUB_RUN_ID
        runUrl           = $runUrl
        planned          = $planned
        installed        = @($installed | Sort-Object)
        missing          = @($missing)
        extraPath        = @($extraPath)
        extraPathOutside = @($extraPathOutside)
    }

    $path = Join-Path $Root 'ARCHIVE.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding utf8
    Write-Host "  已写入 $path（计划 $plannedCount 个包，$($installed.Count) 个已安装，缺 $($missing.Count) 个，额外 PATH 条目 $($extraPath.Count) 个）"

    if ($missing.Count -gt 0) {
        Write-Host "::warning title=归档缺包::$($missing.Count) 个计划内的包没有装上: $($missing -join ', ')"
    }
    if ($extraPathOutside.Count -gt 0) {
        Write-Host "::warning title=PATH 条目在归档外::$($extraPathOutside -join ', ') —— 还原脚本无法重建，需手工处理"
    }

    [pscustomobject]$manifest
}

# 校验相关的函数（Test-BuildPlan / Invoke-PlanValidation / manifest lint）在
# ValidateLib.ps1 —— 构建期用不到，不该让每个构建 step 都加载。
