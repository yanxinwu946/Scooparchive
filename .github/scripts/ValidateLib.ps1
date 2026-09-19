# =============================================================================
# ValidateLib.ps1 — 构建计划的静态校验
#
# 独立于构建：这里不装任何东西，只读 layers.psd1 和各 bucket 的 manifest。
#
# 存在的理由
# ----------
# 没有它，一个包名打错、一个 -np 包混进来、一个变体忘了加进 workflow 的 options，
# 都只能在 350 分钟的构建跑到最后才发现 —— 或者更糟，构建「成功」但归档缺包。
# 这里把 README「确认包在离线环境真能跑通」那份人工清单变成秒级的断言。
#
# 与 ScoopLib 的分工
# ------------------
#   ScoopLib.ps1    读计划 + 装包（构建期用）
#   ValidateLib.ps1 读计划 + 校验（校验 job 用，不装包）
# 校验需要 Get-BuildPlan / Get-LayerPackages，所以点源 ScoopLib 拿它们。
#
# 用法
# ----
#     . "$env:GITHUB_WORKSPACE\.github\scripts\ValidateLib.ps1"
#     if (-not (Invoke-PlanValidation -BucketRoot $root -WorkflowFile $wf)) { throw '校验失败' }
# =============================================================================

. (Join-Path $PSScriptRoot 'ScoopLib.ps1')

function Test-BuildPlan {
    <#
    .SYNOPSIS
        静态校验：包是否存在、有没有歧义、manifest 有没有踩离线归档的坑。

    .DESCRIPTION
        三类结果：
          Errors    结构性错误，包根本装不上 —— 调用方应直接失败
          Warnings  已知的坑，大概率是真问题 —— 报告但不阻塞（有些是有意为之）
          Notes     仅供参考的提示（manifest 的 suggest 等）—— 不阻塞也不该淹没有效信号

    .PARAMETER BucketRoot
        本地 bucket 目录，子目录名即 bucket 名（含 main —— 它是 scoop 自带的，
        不在 layers.psd1 的 Buckets 表里）。

    .OUTPUTS
        PSCustomObject — Errors / Warnings / Notes / Resolved
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$BucketRoot
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()

    # 索引：bucket → manifest 名集合。
    # 只扫 <bucket>/bucket/ —— scoop 的 manifest 查找就是这个路径，deprecated/
    # 只在「已安装」分支才回退，全新安装找不到（见 README）。
    $index = @{}
    foreach ($dir in Get-ChildItem $BucketRoot -Directory -ErrorAction Ignore) {
        $manifestDir = Join-Path $dir.FullName 'bucket'
        if (-not (Test-Path $manifestDir)) { continue }
        $index[$dir.Name] = @(
            Get-ChildItem $manifestDir -Filter *.json -ErrorAction Ignore | ForEach-Object BaseName
        )
    }
    if ($index.Count -eq 0) { throw "在 $BucketRoot 下没找到任何 bucket（期望 <bucket>\bucket\*.json）" }

    # 每个包解析到唯一一个 manifest 路径
    $resolved = [ordered]@{}
    $seenInLayer = @{}

    foreach ($layer in $Plan.Layers) {
        foreach ($pkg in @(Get-LayerPackages $Plan.Plan.Layers[$layer])) {
            if ($seenInLayer.ContainsKey($pkg)) {
                $warnings.Add("层间重复：'$pkg' 同时在 '$($seenInLayer[$pkg])' 和 '$layer'（叠加归档会重复装）")
            } else {
                $seenInLayer[$pkg] = $layer
            }

            if ($pkg -like '*/*') {
                $bucketName, $name = $pkg.Split('/', 2)
                if (-not $index.ContainsKey($bucketName)) {
                    $errors.Add("'$pkg'：bucket '$bucketName' 不存在（$($index.Keys -join ', ')）")
                } elseif ($index[$bucketName] -notcontains $name) {
                    $errors.Add("'$pkg'：$bucketName bucket 里没有 '$name'")
                } else {
                    $resolved[$pkg] = Join-Path $BucketRoot "$bucketName\bucket\$name.json"
                }
                continue
            }

            # 裸名必须在唯一一个 bucket 里 —— 多个 bucket 都有时，scoop 取哪个
            # 取决于遍历顺序（README：包名要带 bucket 前缀）
            $hits = @($index.Keys | Where-Object { $index[$_] -contains $pkg } | Sort-Object)
            if ($hits.Count -eq 0) {
                $errors.Add("'$pkg'：任何 bucket 里都没有这个名字")
            } elseif ($hits.Count -gt 1) {
                $errors.Add("'$pkg'：多个 bucket 都有（$($hits -join ', ')），裸名安装结果取决于遍历顺序 —— 加 bucket 前缀")
            } else {
                $resolved[$pkg] = Join-Path $BucketRoot "$($hits[0])\bucket\$pkg.json"
            }
        }
    }

    # manifest lint
    $planNames = @($resolved.Keys | ForEach-Object { $_.Split('/')[-1] })
    $byContent = @{}

    foreach ($pkg in $resolved.Keys) {
        $path = $resolved[$pkg]
        try { $m = Get-Content $path -Raw | ConvertFrom-Json }
        catch { $errors.Add("'$pkg'：manifest 解析失败（$path）：$($_.Exception.Message)"); continue }

        $script = Get-ManifestScriptText -Manifest $m

        # 1. PATH 写到归档外面（go / uv / bun 都是：Add-Path 写持久用户 PATH，
        #    不是 env_add_path，scoop reset 不会重建）
        if ($script -match 'Add-Path') {
            $warnings.Add("'$pkg'：installer script 用 Add-Path 写持久 PATH —— 不是 env_add_path，scoop reset 不会重建，还原后要手工补")
        }

        # 2. 装到系统目录。README 记的例外：安装器被声明成 bin 时文件会留在 $dir 里
        #    随归档走（vcredist-aio 就是），那是「还原后手工跑一次」，不是「只剩假记录」。
        if ($script -match 'RunAs|msiexec|is_admin|require_admin' -or $pkg -like '*-np') {
            $installerName = Get-ManifestInstallerName -Manifest $m
            if ($installerName -and (Get-ManifestBinNames -Manifest $m) -contains $installerName) {
                $notes.Add("'$pkg'：写系统目录，但安装器被声明成 bin —— 文件随归档走，还原后手工执行 $installerName")
            } else {
                $warnings.Add("'$pkg'：安装器写系统目录（Program Files / 注册表），归档覆盖不到 —— 还原后只剩「已安装」记录")
            }
        }

        # 3. 依赖与建议。scoop 会自动补装 depends（scoop-install.ps1 的
        #    Get-Dependency），所以 depends 不在计划里不是缺陷，只是「归档会多出
        #    计划外的包」的提示。suggest 按定义是可选，同样是提示 —— 把它当警告
        #    只会制造噪声（helix / starship / dotnet-sdk 都 suggest vcredist）。
        foreach ($d in @(Get-ManifestPackageRefs -Manifest $m -Field 'depends')) {
            if ($planNames -notcontains $d) {
                $notes.Add("'$pkg'：depends 里有 '$d'，不在计划里 —— scoop 会自动补装它，归档会多出这个包")
            }
        }
        foreach ($s in @(Get-ManifestPackageRefs -Manifest $m -Field 'suggest')) {
            if ($planNames -notcontains $s) {
                $notes.Add("'$pkg'：manifest suggest '$s'，不在计划里（可选）")
            }
        }

        # 4. 同一个包装了两遍（不同包名、相同 url+hash）—— rust / rust-msvc 那类
        $key = "$($m.url)|$($m.hash)"
        if ($m.url -and $m.hash) {
            if ($byContent.ContainsKey($key)) {
                $warnings.Add("'$pkg' 与 '$($byContent[$key])' 的 url+hash 完全相同 —— 疑似同一个包装了两遍")
            } else {
                $byContent[$key] = $pkg
            }
        }
    }

    [pscustomobject]@{
        Errors   = @($errors)
        Warnings = @($warnings)
        Notes    = @($notes)
        Resolved = $resolved
    }
}

function Test-VariantConsistency {
    <#
    .SYNOPSIS
        校验 workflow 的 workflow_dispatch options 与 layers.psd1 的 Variants 是否一致。

    .DESCRIPTION
        workflow_dispatch 的选项列表是静态的，没法从 psd1 生成，只能手工同步。这是
        这套设计里唯一躲不掉的重复，所以用一条断言钉住它：加了变体却忘了改 options
        （或反过来），校验立刻失败，而不是等有人触发构建时才发现。

    .OUTPUTS
        System.String — 不一致项；无输出表示一致
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanFile,
        [Parameter(Mandatory)][string]$WorkflowFile
    )

    $plan = Import-PowerShellDataFile -Path $PlanFile
    $yaml = Get-Content $WorkflowFile -Raw

    # 只取 options: 下面连续的 "- xxx" 行。用 [ \t] 而不是 \s —— \s 会跨空行一路
    # 吞到后面 step 的 `- name:` 去
    $block = [regex]::Match($yaml, '(?m)^[ \t]*options:[ \t]*\r?\n((?:[ \t]*-[ \t]*\S+[ \t]*(?:#.*)?\r?\n)+)')
    if (-not $block.Success) {
        return "$WorkflowFile 里找不到 workflow_dispatch 的 options 列表"
    }

    $declared = @([regex]::Matches($block.Groups[1].Value, '(?m)^[ \t]*-[ \t]*(\S+)') |
        ForEach-Object { $_.Groups[1].Value })
    $defined = @($plan.Variants.Keys)

    foreach ($v in $declared) {
        if ($defined -notcontains $v) { "workflow 声明了变体 '$v'，layers.psd1 的 Variants 里没有" }
    }
    foreach ($v in $defined) {
        if ($declared -notcontains $v) { "layers.psd1 定义了变体 '$v'，workflow 的 options 里没有" }
    }
}

function Invoke-PlanValidation {
    <#
    .SYNOPSIS
        校验所有变体：结构、包是否存在、manifest 有没有踩离线归档的坑。

    .DESCRIPTION
        校验 job 的编排。结构性错误以 ::error:: annotation 报出并让调用方失败；
        Warnings / Notes 只进 Step Summary，不阻塞 —— 有些坑是有意为之的。

    .OUTPUTS
        System.Boolean — $true 表示没有结构性错误
    #>
    [CmdletBinding()]
    param(
        [string]$PlanFile = $script:PlanFile,
        [Parameter(Mandatory)][string]$BucketRoot,
        [string]$WorkflowFile
    )

    $ok = $true
    $summary = [System.Collections.Generic.List[string]]::new()
    $detail = [System.Collections.Generic.List[string]]::new()

    $summary.Add('## 变体校验')
    $summary.Add('')
    $summary.Add('| 变体 | 层 | 包 | Errors | Warnings | Notes |')
    $summary.Add('|---|---|---|---|---|---|')

    # workflow 的 options 与 psd1 的 Variants 必须一一对应
    if ($WorkflowFile) {
        $drift = @(Test-VariantConsistency -PlanFile $PlanFile -WorkflowFile $WorkflowFile)
        foreach ($d in $drift) {
            Write-Host "::error title=变体定义不一致::$d"
            $ok = $false
        }
    }

    $plan = Import-PowerShellDataFile -Path $PlanFile
    foreach ($variant in $plan.Variants.Keys) {
        $buildPlan = Get-BuildPlan -Variant $variant -PlanFile $PlanFile
        $result = Test-BuildPlan -Plan $buildPlan -BucketRoot $BucketRoot

        $summary.Add("| ``$variant`` | $($buildPlan.Layers -join ' + ') | $($result.Resolved.Count) | $($result.Errors.Count) | $($result.Warnings.Count) | $($result.Notes.Count) |")

        foreach ($e in $result.Errors) {
            Write-Host "::error title=校验失败 [$variant]::$e"
            $ok = $false
        }
        foreach ($w in $result.Warnings) {
            Write-Host "::warning title=[$variant]::$w"
        }

        if ($result.Errors.Count + $result.Warnings.Count + $result.Notes.Count -gt 0) {
            $detail.Add("### ``$variant``")
            foreach ($e in $result.Errors)   { $detail.Add("- ❌ $e") }
            foreach ($w in $result.Warnings) { $detail.Add("- ⚠️ $w") }
            foreach ($n in $result.Notes)    { $detail.Add("- ℹ️ $n") }
            $detail.Add('')
        }
    }

    $summary.Add('')
    $summary.AddRange($detail)

    $text = $summary -join "`n"
    Write-Host "`n$text"
    if ($env:GITHUB_STEP_SUMMARY) {
        $text | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }

    return $ok
}

function Get-ManifestScriptText {
    <#
    .SYNOPSIS
        把 manifest 里所有会执行脚本的字段拼成一段文本，供 lint 正则扫描。

    .DESCRIPTION
        只看会执行的字段，不看 notes —— notes 是给人读的自由文本，里面提到
        msiexec / Add-Path 属于正常描述，扫它只会制造误报。

        整行注释也要剥掉：python 的 manifest 里有一行
        `# appendpath.msi ... causes 'msiexec /a' to fail`，不剥就会误报「装到系统目录」。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Manifest)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($field in 'pre_install', 'post_install', 'pre_uninstall', 'post_uninstall', 'installer', 'uninstaller') {
        $value = $Manifest.$field
        if (-not $value) { continue }

        $lines = if ($value -is [string]) { @($value) }
                 elseif ($value.script) { @($value.script) }
                 else { @() }

        foreach ($line in $lines) {
            $text = [string]$line
            if ($text.TrimStart().StartsWith('#')) { continue }
            $parts.Add($text)
        }
    }
    $parts -join "`n"
}

function Get-ManifestPackageRefs {
    <#
    .SYNOPSIS
        取 manifest 里 depends / suggest 字段引用的包名。

    .DESCRIPTION
        这两个字段有三种写法：字符串、字符串数组、以及 { 包名 = 架构数组 } 的对象。
        不能直接用 .PSObject.Properties.Name 一把梭 —— 字段是字符串时那样返回的是
        字符串自身的属性（Length / IsReadOnly …），会变成假依赖。
        openssl-lts-light 的 depends 就是字符串，踩到过。

    .OUTPUTS
        System.String — 包名，可能多个
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][ValidateSet('depends', 'suggest')][string]$Field
    )

    $value = $Manifest.$Field
    if (-not $value) { return }

    if ($value -is [string]) { return $value }

    # 数组形式：逐项取，忽略非字符串项（可能是按架构嵌套的对象）
    if ($value -isnot [System.Management.Automation.PSCustomObject]) {
        foreach ($item in @($value)) {
            if ($item -is [string]) { $item }
        }
        return
    }

    # 对象形式：键是包名。scoop 允许 depends 按架构嵌套，架构名不是包名。
    foreach ($p in $value.PSObject.Properties) {
        if ($p.Name -notin @('64bit', '32bit', 'arm64')) { $p.Name }
    }
}

function Get-ManifestInstallerName {
    <#
    .SYNOPSIS
        取 manifest 里安装器落地后的文件名。

    .DESCRIPTION
        scoop 用 url 的 `#/name` 片段给下载文件重命名（vcredist-aio 的 url 结尾是
        `#/vcredist-aio.exe`）。url 可能写在顶层，也可能写在 architecture.<arch> 下。

    .OUTPUTS
        System.String — 文件名；取不到时返回 $null
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Manifest)

    $urls = @($Manifest.url)
    foreach ($arch in @($Manifest.architecture.PSObject.Properties)) {
        $urls += @($arch.Value.url)
    }
    foreach ($u in $urls) {
        if ($u -and $u -match '#/([^#]+)$') { return $Matches[1] }
    }
    return $null
}

function Get-ManifestBinNames {
    <#
    .SYNOPSIS
        取 manifest 的 bin 声明里的可执行文件名。

    .DESCRIPTION
        bin 有三种写法：字符串、字符串数组、以及 [别名, 目标] 的数组数组
        （helix 是 `{hx.exe, hx.exe helix}`）。这里统一拍平成文件名集合。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Manifest)

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($Manifest.bin)) {
        $first = if ($entry -is [array]) { $entry[0] } else { $entry }
        if ($first) { $names.Add(([string]$first).Split('\')[-1]) }
    }
    $names
}
