# =============================================================================
# layers.psd1 — 变体 / 层 / 包清单
#
# 「归档里到底有什么」的唯一事实来源。workflow 只负责编排，加包、改分类、调变体
# 都只动这个文件，不需要碰 YAML。
#
# 三个概念
# --------
# 层（Layer）     按用途划分的包集合。层与层之间不重复装包 —— 所以不同变体的归档
#                 可以叠加解压到同一个目录，互不覆盖。
# 变体（Variant） 用户能选到的构建目标。每个变体 = base + 一层，这是刻意的：
#                 要几个工具就构建对应变体，不必为了它们构建一个全家桶。
# 组（Group）     层内的包按失败策略分组，见下面各字段。
#
# 字段
# ----
#   Title     层显示名，用于日志与构建摘要
#   Early     引导包。它们自己要负责后续所有下载，必须在 aria2 配置生效前装好，
#             所以由 setup-scoop 提前单独装。Install-ScoopLayer 仍把它们算进本层
#             （重复安装是 no-op），这样「装完这一层」的语义是完整的。
#   Required  关键包，重试耗尽即终止构建
#   Optional  非关键包，重试耗尽只发 ::warning:: 告警并跳过
#   Env       持久环境变量，在装包前生效（包的 installer script 可能读它）
#   MkDir     需要在装包前建好的目录（Env 指向的路径）
#   Pin       装完后按顺序 `scoop reset`。用于给「多个包写同一个环境变量」定序：
#             JDK 都声明 env_set JAVA_HOME，谁最后 reset 谁赢；不定序的话结果由
#             `scoop reset *` 的字典序决定，liberica8 会排在最后。
#
# 加包之前先读 README 的「确认包在离线环境真能跑通」—— 「装上了」不等于「能用」。
# =============================================================================

@{
    # 层的安装顺序。base 必须第一：它的解包器（innounp / dark）是后续包的前提。
    Order = @(
        'base'
        'codeql'
        'python'
        'agent'
        'dev'
        'pentest'
        're'
        'apps'
        'apps-plus'
    )

    Layers = @{
        base = @{
            Title = '基础运行时与 CLI 工具集'
            # 这 4 个要负责后续所有下载，由 setup-scoop 在 aria2 配置生效前先装
            Early = @('aria2', 'sudo', 'git', '7zip')
            # 解包器与运行库放 Required：后续包的安装依赖前者解包。
            #
            # vcredist-aio 的 manifest 把安装器本身声明成了 bin，所以 vcredist-aio.exe
            # 会留在 $dir 里不被清理 —— 也就随归档一起走，还原后直接跑 `vcredist-aio`
            # 即可离线装齐所有 VC++ 运行时。它替换了原先的 vcredist2010/2012/2013/2022
            # 四个包：那些包没有 bin 声明，安装器会被 cleanup 删掉，归档里只剩一条
            # 「已安装」的假记录。
            Required = @('innounp', 'dark', 'vcredist-aio')
            Optional = @(
                # 文本处理与编辑器
                'biome', 'jq', 'yq', 'vim', 'helix', 'gawk', 'grep', 'sed', 'less', 'touch', 'which',
                # 编码、网络与传输
                'curl', 'base64', 'cacert', 'openssl-lts-light', 'netcat', 'lrzsz', 'trzsz',
                # 文件与目录导航
                'fd', 'fzf', 'eza', 'zoxide',
                # shell 环境
                'starship', 'fastfetch', 'nu',
                # 开发协作
                'gh',
                # 拼写检查
                'autocorrect'
            )
        }

        codeql = @{
            Title = 'JDK 矩阵与静态代码分析'
            # JDK 矩阵：8 / 11 / 17 三个 LTS + 当前 feature release。
            # 不要加非 LTS 版本（如 16）：它们被下一个版本取代后更新就停了，
            # checkver 再也查不到新东西，等于把一个不再打补丁的 JDK 打包进归档。
            Required = @(
                'liberica8-full-jdk', 'liberica11-full-jdk', 'liberica17-full-jdk',
                'liberica-full-jdk', 'gradle', 'maven', 'jenv', 'codeql'
            )
            # 4 个 JDK 都写 env_set JAVA_HOME，必须显式定序（见文件头 Pin 说明）。
            # 选 17：CodeQL 支持它，且不会因为 feature release 太新而跑不起来。
            Pin = @('liberica17-full-jdk')
        }

        python = @{
            Title = 'Python 开发环境'
            # python 的 env_add_path = Scripts, .；uv 是 Rust 原生二进制。
            # 两者 PATH 都由 scoop 托管，`scoop reset` 会重新应用
            Required = @('python', 'uv')
        }

        agent = @{
            Title = 'Node.js 与 AI Coding Agents'
            # 四个 agent 都用 scoop 原生包而非 npm 全局安装：它们是自包含二进制，
            # 且 shim 落在 $SCOOP\shims，还原后开箱可用。npm 全局装的可执行文件在
            # $SCOOP\npm-global，那不是 scoop 托管的目录，`scoop reset *` 不会把
            # 它加回 PATH。
            #
            # 带 main/ 前缀的包：ktools（第三方 AI / 安全工具 bucket）大概率也有
            # 同名包，裸名安装的结果取决于 bucket 遍历顺序。
            Required = @(
                'nodejs-lts', 'pnpm', 'bun',
                'main/claude-code', 'main/codex', 'main/pi-coding-agent', 'main/opencode',
                'main/ripgrep', 'main/rtk'
            )
        }

        dev = @{
            Title = '开发工具链与 IDE'
            # go 的 manifest 用 Add-Path 把 $env:GOPATH\bin（缺省 %USERPROFILE%\go\bin）
            # 写进持久用户 PATH。那个目录在归档之外，而且它不是 env_add_path，
            # `scoop reset` 不会重建它 —— 还原后 go install 的产物全丢。
            # 所以装 go 之前先把 GOPATH 指到 scoop 目录内。
            # 注意：注册表里的环境变量不随归档走，还原后要重设（见 README 还原步骤）。
            Env = @{ 'GOPATH' = '$env:SCOOP\gopath' }
            MkDir = @('$env:SCOOP\gopath\bin')
            Required = @(
                # C/C++ 工具链。ninja 是 cmake 在没有 VS generator 时的首选生成器。
                # 用 mingw-winlibs（WinLibs 构建）而不是 gcc（nuwen 构建）：版本更新、
                # 附带的库更全，Rust GNU 工具链要链接到它。
                'mingw-winlibs', 'cmake', 'make', 'ninja',
                # Rust：只装 rustup-gnu。
                #   不要装 rust / rust-msvc —— 两者 manifest 除 checkver 块外完全相同，
                #   是同一个 MSI 装两遍，且都声明 bin\rustc.exe|rustdoc.exe|cargo.exe，
                #   shim 直接冲突。
                #   也不要装 rustup-msvc —— 它和 rust/rust-msvc 的 notes 都要求
                #   MSVC Build Tools + Windows SDK，而那套东西在 main/extras/versions/
                #   nonportable 四个 bucket 里都不存在，还原后 cargo build 到链接必失败。
                #   rustup-gnu 默认 --default-host x86_64-pc-windows-gnu，链接走已装的
                #   mingw gcc，全程离线可用。
                'rustup-gnu',
                # Go
                'go',
                # Ruby 及其原生扩展工具链（ruby 的 notes 要求先装 msys2）
                'msys2', 'ruby',
                # .NET
                'dotnet-sdk-lts', 'dotnet3-sdk', 'nuget',
                # 包管理与代码质量
                'yarn', 'git-lfs', 'hadolint', 'shellcheck', 'lefthook',
                'chromedriver', 'chsrc', 'colortool',
                # 容器与编排
                'kubectl', 'etcd',
                # IDE 自带的 JDK。不要用 liberica16 —— 非 LTS，2021-09 就被 17 取代，
                # 更新停在 16.0.2。21 是当前企业主流 LTS，且不与 codeql 层的矩阵重复。
                'liberica21-full-jdk', 'extras/idea', 'extras/sublime-text'
            )
            Pin = @('liberica21-full-jdk')
        }

        pentest = @{
            Title = 'Web 与内网渗透'
            Required = @(
                # 信息收集与资产测绘
                'anew', 'fofax', 'ksubdomain', 'netspy', 'pdtm',
                # 扫描与爬虫
                'crawlergo', 'main/ffuf', 'fscan', 'gogo', 'rad',
                # 口令与横向
                'spray', 'zombie', 'blueteamtools', 'hashcat', 'Ldap-admin', 'sshpass',
                # 凭据与密钥扫描
                'trufflehog',
                # Web 代理与 TLS
                # burp-suite-pro-np 是 -np（nonportable）包，安装器写 Program Files，
                # 归档只带 D:\00PackageManager，所以它不进归档 —— 见 README
                #「不要加装到系统目录的包」。
                'burp-suite-pro-np', 'sslscan', 'osv-scanner'
            )
        }

        re = @{
            Title = '逆向工程与样本取证'
            Required = @(
                # 反汇编与反编译（dnspy / ilspy 都是 .NET 方向）
                'ghidra', 'radare2', 'cutter', 'dnspy', 'ilspy',
                # 移动端
                'apktool', 'jadx',
                # 动态调试与 PE 分析
                'x64dbg', 'pe-bear', 'openark',
                # 样本与取证
                'yara', 'exiftool', 'upx', 'uniextract2'
            )
        }

        apps = @{
            Title = '常用桌面软件'
            # 整层走 Optional：单个 GUI 应用失败不该作废整轮构建，失败清单会以
            # ::warning:: 出现在 Actions 的 annotations 面板。
            #
            # keepassxc 与 RPC 插件必须成对可用（插件在、本体缺失时 keepassrpc 不可用）。
            # 跟着本层策略走意味着可能只剩一半 —— 要严格保证就把这两个挪到 Required。
            Optional = @(
                # 终端与字体（nerd-fonts bucket，缺字体则图标和电力线字形显示成方块）
                'versions/wezterm-nightly', 'FiraCode-NF', 'JetBrainsMono-NF',
                # 浏览器与网络
                'googlechrome', 'firefox', 'clash-verge-rev',
                # 文档与阅读
                'obsidian', 'sumatrapdf', 'honeyview', 'pandoc', 'vscode',
                # 图片与视频
                'vlc', 'snipaste', 'picgo',
                # 系统工具
                'sysinternals', 'TrafficMonitor', 'SpaceSniffer', 'dupeGuru', 'renamer',
                'nircmd', 'scoop-search', 'everything-cli',
                # 密码与加密
                'keepassxc', 'keepass-plugin-keepassrpc', 'gpg'
            )
        }

        'apps-plus' = @{
            Title = '增强桌面软件'
            # 同 apps 层，整层 Optional
            Optional = @(
                # 媒体处理
                'imagemagick', 'ffmpeg', 'xmlnotepad', 'masscode',
                # 云存储客户端
                's3browser', 'oss-browser',
                # 虚拟化与远程
                'rufus', 'vncviewer',
                # 开发向桌面工具
                'sourcegit', 'ssh-config', 'onefetch',
                # 文档与文献
                'zotero', 'office-tool-plus',
                # 桌面增强
                'powertoys'
            )
        }
    }

    # bucket 注册表。setup-scoop 按变体注册，校验 job 用 -All 全部克隆下来查 manifest。
    # Repo 显式写全：scoop 内置的 known-buckets 表能解析这些名字，但校验 job 要自己
    # 克隆，写全比在两边各猜一次 URL 可靠。nerd-fonts 不是官方 bucket。
    # `main` 不在这里 —— 它是 scoop 自带的。
    Buckets = @(
        @{ Name = 'extras';      Repo = 'https://github.com/ScoopInstaller/Extras' }
        @{ Name = 'versions';    Repo = 'https://github.com/ScoopInstaller/Versions' }
        @{ Name = 'nirsoft';     Repo = 'https://github.com/ScoopInstaller/Nirsoft' }
        @{ Name = 'java';        Repo = 'https://github.com/ScoopInstaller/Java' }
        @{ Name = 'nonportable'; Repo = 'https://github.com/ScoopInstaller/Nonportable' }
        @{ Name = 'nerd-fonts';  Repo = 'https://github.com/matthewjberger/scoop-nerd-fonts' }
        @{ Name = 'ktools';      Repo = 'https://github.com/kenyon-wong/ktools' }
        # r-bucket 只在 codeql / python 变体注册。
        # 注意：目前计划里没有任何包来自它（92 个 manifest 全是 R 相关），等于每次
        # codeql / python 构建白克隆一次。要么补上真正要用的 R 包，要么删掉这一行。
        @{ Name = 'r-bucket';    Repo = 'https://github.com/cderv/r-bucket.git'
           Variants = @('codeql', 'python') }
    )

    # 变体 → 层组合。目前每个变体都是 base + 一层（见 README）。
    # 想加一个全家桶变体时写 @('*')，Get-BuildPlan 会展开成 Order 全集；
    # 记得同时把变体名加进 workflow 的 options 列表。
    Variants = @{
        'base'      = @('base')
        'codeql'    = @('base', 'codeql')
        'python'    = @('base', 'python')
        'agent'     = @('base', 'agent')
        'dev'       = @('base', 'dev')
        'pentest'   = @('base', 'pentest')
        're'        = @('base', 're')
        'apps'      = @('base', 'apps')
        'apps-plus' = @('base', 'apps-plus')
    }
}
