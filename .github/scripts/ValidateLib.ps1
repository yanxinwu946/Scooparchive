# =============================================================================
# ValidateLib.ps1 — 构建计划的静态校验（只读，不装任何东西）
#
# 把 README「确认包在离线环境真能跑通」那份人工清单变成秒级断言。没有它，包名打错
# 或混进一个 -np 包，只能在几十分钟的构建跑到最后才发现。
#
# 用法：. "$env:GITHUB_WORKSPACE\.github\scripts\ValidateLib.ps1"
#       Invoke-PlanValidation -BucketRoot $root -WorkflowFile $wf
# =============================================================================

. (Join-Path $PSScriptRoot 'ScoopLib.ps1')

function Test-BuildPlan {
    <#
    .SYNOPSIS
        静态校验：包是否存在、有没有歧义、manifest 有没有踩离线归档的坑。

    .DESCRIPTION
        Errors    结构性错误，包根本装不上 —— 调用方应直接失败
        Warnings  已知的坑，大概率是真问题
        Notes     仅供参考的提示（suggest 等），不该淹没有效信号

    .PARAMETER BucketRoot
        本地 bucket 目录，子目录名即 bucket 名（含 main，它是 scoop 自带的）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$BucketRoot
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()

    # 索引：bucket → manifest 名集合。只扫 <bucket>/bucket/ —— scoop 的查找路径就是它，
    # deprecated/ 只在「已安装」分支才回退，全新安装找不到
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

    foreach ($layer in $Plan.LayerNames) {
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

            # 裸名必须在唯一一个 bucket 里 —— 多个都有时 scoop 取哪个取决于遍历顺序
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

        # 1. PATH 写到归档外（go / uv / bun 的 Add-Path 不是 env_add_path，scoop reset 不重建）
        if ($script -match 'Add-Path') {
            $warnings.Add("'$pkg'：installer script 用 Add-Path 写持久 PATH —— 不是 env_add_path，scoop reset 不会重建，还原后要手工补")
        }

        # 2. 装到系统目录。例外：安装器被声明成 bin 时文件留在 $dir 里随归档走
        #    （vcredist-aio 就是），那是「还原后手工跑一次」，不是「只剩假记录」
        if ($script -match 'RunAs|msiexec|is_admin|require_admin' -or $pkg -like '*-np') {
            $installerName = Get-ManifestInstallerName -Manifest $m
            if ($installerName -and (Get-ManifestBinNames -Manifest $m) -contains $installerName) {
                $notes.Add("'$pkg'：写系统目录，但安装器被声明成 bin —— 文件随归档走，还原后手工执行 $installerName")
            } else {
                $warnings.Add("'$pkg'：安装器写系统目录（Program Files / 注册表），归档覆盖不到 —— 还原后只剩「已安装」记录")
            }
        }

        # 3. 依赖与建议。scoop 会自动补装 depends，所以 depends 不在计划里不是缺陷，
        #    只是「归档会多出计划外的包」。suggest 按定义是可选，当警告只会制造噪声。
        foreach ($d in @(Get-ManifestPackageRefs -Manifest $m -Field 'depends')) {
            if ($planNames -notcontains $d) {
                $notes.Add("'$pkg'：depends 里有 '$d'，不在计划里 —— scoop 会自动补装它，归档会多出这个包")
            }
        }
        foreach ($s in @(Get-ManifestPackageRefs -Manifest $m -Field 'suggest')) {
            if (-not (Test-PackageSuggestionSatisfied -Suggestion $s -PlannedNames $planNames)) {
                $notes.Add("'$pkg'：manifest suggest '$s'，计划里没有能对上的包")
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
        workflow_dispatch 的 options 是静态的，没法从 psd1 生成，只能手工同步 ——
        这是这套设计里唯一躲不掉的重复，用一条断言钉住它。

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
        结构性错误以 ::error:: 报出并返回 $false；Warnings / Notes 只进 Step Summary。

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

        $summary.Add("| ``$variant`` | $($buildPlan.LayerNames -join ' + ') | $($result.Resolved.Count) | $($result.Errors.Count) | $($result.Warnings.Count) | $($result.Notes.Count) |")

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
        只看会执行的字段，不看 notes —— notes 是自由文本，提到 msiexec 属正常描述。
        整行注释也要剥掉：python 的 manifest 有一行注释提到 'msiexec /a'，不剥会误报。
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
        字段有三种写法：字符串、字符串数组、{ 包名 = 架构数组 } 的对象。
        不能直接 .PSObject.Properties.Name 一把梭 —— 字段是字符串时那返回的是字符串
        自身的属性（Length…），会变成假依赖。

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

function Test-PackageSuggestionSatisfied {
    <#
    .SYNOPSIS
        判断 manifest 的 suggest 值是否已被计划里的某个包满足。

    .DESCRIPTION
        suggest 的值常常是描述而不是包名（'JDK' / 'Node.js' / 'Everything'），
        直接按名字比对会一路误报。这里放宽到：归一化后互为子串，或描述里的长词
        出现在某个包名里。

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Suggestion,
        [Parameter(Mandatory)][string[]]$PlannedNames
    )

    $normalize = { param($s) ($s -replace '[^a-zA-Z0-9]', '').ToLowerInvariant() }
    $target = & $normalize $Suggestion
    if (-not $target) { return $true }

    $normalizedNames = @($PlannedNames | ForEach-Object { & $normalize $_ } | Where-Object { $_ })

    foreach ($n in $normalizedNames) {
        # 描述是包名的一部分（'jdk' ⊂ 'liberica21fulljdk'）—— 安全方向，不限长度
        if ($n.Contains($target)) { return $true }
        # 包名是描述的一部分（'vim' ⊂ 'vimtutor'）—— 限长度，否则短名会乱命中
        if ($n.Length -ge 4 -and $target.Contains($n)) { return $true }
    }

    foreach ($token in @($Suggestion -split '[^a-zA-Z0-9]+' | Where-Object { $_.Length -ge 4 })) {
        $t = $token.ToLowerInvariant()
        foreach ($n in $normalizedNames) {
            if ($n.Contains($t)) { return $true }
        }
    }

    return $false
}

function Get-ManifestInstallerName {
    <#
    .SYNOPSIS
        取 manifest 里安装器落地后的文件名。

    .DESCRIPTION
        scoop 用 url 的 `#/name` 片段给下载文件重命名。url 可能在顶层，也可能在
        architecture.<arch> 下。

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
        bin 有三种写法：字符串、字符串数组、[别名, 目标] 的数组数组。统一拍平。
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
