<#
.SYNOPSIS
    ScoopArchive 还原脚本 —— 随归档发布，在目标机上以管理员身份运行。

.DESCRIPTION
    把 README 里那段手工还原步骤脚本化。自包含：归档里没有 .github/，不能依赖 ScoopLib。

      1. 设 SCOOP / GOPATH（用户级）
      2. 把 $SCOOP\shims 与 ARCHIVE.json 记录的额外 PATH 目录追加进用户级 PATH（幂等）
      3. scoop reset * / scoop cleanup *
      4. 跑 vcredist-aio 装齐 VC++ 运行库

    第 2 步里的「额外 PATH 目录」指 Add-Path 写死的那些（go / uv / bun）—— 它们记在
    注册表里，不随归档走，也不是 env_add_path，`scoop reset` 不会重建。

.PARAMETER Root
    归档解压后的根目录。默认取本脚本所在目录 —— 脚本就放在归档根。

.PARAMETER SkipNativeInstallers
    跳过 vcredist-aio。不想让还原脚本改系统组件时用。
#>
[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [switch]$SkipNativeInstallers
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host "`n$('─' * 72)" -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('─' * 72) -ForegroundColor DarkCyan
}

function Invoke-Native {
    <#
    .SYNOPSIS
        跑原生命令并显式检查退出码。

    .DESCRIPTION
        $ErrorActionPreference = 'Stop' 对原生命令无效 —— 失败只设置 $LASTEXITCODE，
        脚本会「绿色失败」。理由同构建端的 ScoopLib.ps1。
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )

    Write-Host "  > $FilePath $($Arguments -join ' ')" -ForegroundColor DarkGray
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments | Out-Host
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0 -and -not $AllowFailure) { throw "命令失败 (exit $code): $FilePath $($Arguments -join ' ')" }
    return $code
}

function Add-PersistentPath {
    <#
    .SYNOPSIS
        把目录追加进用户级 PATH，幂等。

    .DESCRIPTION
        写进注册表的是 %SCOOP%\<相对路径> 字面量而非绝对路径 —— 这样归档还原到
        任意根目录都成立。
    #>
    param([Parameter(Mandatory)][string[]]$Relative)

    $regPath = 'HKCU:\Environment'
    $current = (Get-ItemProperty -Path $regPath -Name PATH -ErrorAction Ignore).PATH
    if (-not $current) { $current = '' }

    $changed = $false
    foreach ($rel in $Relative) {
        $literal = '%SCOOP%\' + $rel.TrimStart('\')
        if ($current -notlike "*$literal*") {
            $current = $current.TrimEnd(';') + ';' + $literal
            $changed = $true
            Write-Host "  [path+] $literal" -ForegroundColor DarkGray
        }
    }
    if ($changed) { Set-ItemProperty -Path $regPath -Name PATH -Value $current.TrimStart(';') }
}

# ── 0. 前置检查 ────────────────────────────────────────────────────────────
$scoop = Join-Path $Root 'Scoop'
if (-not (Test-Path $scoop)) {
    throw "在 $Root 下找不到 Scoop 目录 —— 请把归档解压到目标路径后再运行本脚本，或用 -Root 指定。"
}
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '需要管理员权限：vcredist-aio 与 Set-ExecutionPolicy 都要提权。'
}

Write-Section "ScoopArchive 还原到 $Root"

# ── 1. 归档清单 ────────────────────────────────────────────────────────────
$manifest = $null
$manifestFile = Join-Path $Root 'ARCHIVE.json'
if (Test-Path $manifestFile) {
    $manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json
    Write-Host "  变体    : $($manifest.variant)"
    Write-Host "  层      : $($manifest.layers -join ', ')"
    Write-Host "  构建于  : $($manifest.builtAt)"
    if ($manifest.runUrl) { Write-Host "  构建记录: $($manifest.runUrl)" }
    Write-Host "  包      : 计划 $(($manifest.planned.PSObject.Properties | ForEach-Object { $_.Value.Count } | Measure-Object -Sum).Sum) 个，归档内 $($manifest.installed.Count) 个"
    if ($manifest.missing.Count -gt 0) {
        Write-Warning "归档缺了 $($manifest.missing.Count) 个计划内的包（构建时被跳过）: $($manifest.missing -join ', ')"
    }
} else {
    Write-Warning "没有 ARCHIVE.json —— 不是本工具产出的归档，跳过变体相关处理。"
}

# ── 2. 环境变量 ────────────────────────────────────────────────────────────
Write-Section '设置环境变量'

[Environment]::SetEnvironmentVariable('SCOOP', $scoop, 'User')
$env:SCOOP = $scoop
Write-Host "  SCOOP = $scoop"

# go 的 GOPATH：构建时指到了归档内，否则 go install 的产物落在 %USERPROFILE%\go。
# 只在归档确实带了 gopath 目录时设，避免给没装 go 的变体留垃圾变量。
$gopath = Join-Path $scoop 'gopath'
if (Test-Path $gopath) {
    [Environment]::SetEnvironmentVariable('GOPATH', $gopath, 'User')
    $env:GOPATH = $gopath
    Write-Host "  GOPATH = $gopath"
}

# ── 3. PATH ────────────────────────────────────────────────────────────────
Write-Section '追加 PATH'

$relative = @('shims')
if (Test-Path $gopath) { $relative += 'gopath\bin' }
if ($manifest -and $manifest.extraPath) { $relative += @($manifest.extraPath) }
if ($manifest -and $manifest.extraPathOutside) {
    Write-Warning "以下 PATH 条目在归档之外，无法重建，需要手工处理:`n    $($manifest.extraPathOutside -join "`n    ")"
}

Add-PersistentPath -Relative ($relative | Select-Object -Unique)

# 当前会话刷新，否则紧接着的 scoop 命令找不到
$env:PATH = @(
    ($relative | Select-Object -Unique | ForEach-Object { Join-Path $scoop $_ }),
    $env:PATH
) -join ';'

# ── 4. 重建 scoop 环境 ─────────────────────────────────────────────────────
Write-Section '重建 shim 与环境变量'

Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

if (-not (Get-Command scoop -ErrorAction Ignore)) {
    throw "PATH 里仍然找不到 scoop —— 检查 $scoop\shims\scoop.cmd 是否存在。"
}

# `scoop reset *` 重放每个包的 env_add_path / env_set 并重建 shim
Invoke-Native -FilePath 'scoop' -Arguments @('reset', '*')
# 安装期的旧版本会一起进归档，清掉
Invoke-Native -FilePath 'scoop' -Arguments @('cleanup', '*')

# ── 5. 离线收尾 ────────────────────────────────────────────────────────────
Write-Section '离线收尾'

if ($SkipNativeInstallers) {
    Write-Host '  [skip] 按 -SkipNativeInstallers 跳过 vcredist-aio'
} elseif (Get-Command 'vcredist-aio' -ErrorAction Ignore) {
    # 安装器被声明成了 bin，所以 vcredist-aio.exe 随归档走；它写系统目录，只能还原后跑
    Invoke-Native -FilePath 'vcredist-aio' -Arguments @('/ai', '/gm2')
} else {
    Write-Warning '没找到 vcredist-aio —— VC++ 运行库未安装，依赖它的程序可能起不来。'
}

if ($manifest -and $manifest.layers -contains 'dev') {
    # 需要联网下载 MSYS2 包，离线环境跑不了，所以只提示不自动执行
    Write-Host "`n  提示：dev 变体的 ruby 原生扩展还需要把 MSYS2 接进去（需要联网）：" -ForegroundColor Yellow
    Write-Host '      ridk install 3' -ForegroundColor Yellow
}

Write-Section '完成'
Write-Host '  验证：scoop list 应列出归档内的所有包；scoop checkup 可查环境问题。'
