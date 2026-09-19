# =============================================================================
# layers.psd1 — 变体 / 层 / 包清单
#
# 「归档里有什么」的唯一事实来源。workflow 只做编排，加包、改分类、调变体都只动
# 这个文件。层与层之间不重复装包，所以不同变体的归档可以叠加解压到同一目录。
#
# 字段
#   Title     层显示名（日志与构建摘要用）
#   Early     引导包，必须在 aria2 配置生效前装好，由 setup-scoop 提前装
#   Required  关键包，失败即终止
#   Optional  非关键包，失败只告警
#   Env       持久环境变量，装包前生效
#   MkDir     装包前要建好的目录
#   Pin       装完后按顺序 scoop reset，给写同一个环境变量的多个包定序
# =============================================================================

@{
    # base 必须第一：它的解包器是后续包的前提
    Order = @('base', 'codeql', 'python', 'agent', 'dev', 'pentest', 're', 'apps', 'apps-plus')

    Layers = @{
        base = @{
            Title = '基础运行时与 CLI 工具集'
            Early = @('aria2', 'sudo', 'git', '7zip')
            # vcredist-aio 把安装器声明成了 bin，所以 exe 随归档走，还原后跑一次即可
            Required = @('innounp', 'dark', 'vcredist-aio')
            Optional = @(
                'biome', 'jq', 'yq', 'vim', 'helix', 'gawk', 'grep', 'sed', 'less', 'touch', 'which',
                'curl', 'base64', 'cacert', 'openssl-lts-light', 'netcat', 'lrzsz', 'trzsz',
                'fd', 'fzf', 'eza', 'zoxide', 'starship', 'fastfetch', 'nu', 'gh', 'autocorrect'
            )
        }

        codeql = @{
            Title = 'JDK 矩阵与静态代码分析'
            # 只用 LTS：非 LTS 被下个版本取代后更新就停了，等于把不再打补丁的 JDK 打进归档
            Required = @(
                'liberica8-full-jdk', 'liberica11-full-jdk', 'liberica17-full-jdk',
                'liberica-full-jdk', 'gradle', 'maven', 'jenv', 'codeql'
            )
            # 4 个 JDK 都写 env_set JAVA_HOME，不定序的话结果由 scoop reset * 的字典序决定
            Pin = @('liberica17-full-jdk')
        }

        python = @{
            Title = 'Python 开发环境'
            Required = @('python', 'uv')
        }

        agent = @{
            Title = 'Node.js 与 AI Coding Agents'
            # agent 用 scoop 原生包而非 npm 全局：shim 落在 $SCOOP\shims，还原后开箱可用；
            # npm 全局装在 $SCOOP\npm-global，不是 scoop 托管目录，scoop reset 不管它。
            # 带 main/ 前缀的几个是因为 ktools 大概率有同名包，裸名取决于 bucket 遍历顺序
            Required = @(
                'nodejs-lts', 'pnpm', 'bun',
                'main/claude-code', 'main/codex', 'main/pi-coding-agent', 'main/opencode',
                'main/ripgrep', 'main/rtk'
            )
        }

        dev = @{
            Title = '开发工具链与 IDE'
            # go 用 Add-Path 把 $env:GOPATH\bin 写进持久 PATH（缺省 %USERPROFILE%\go\bin，
            # 在归档外）。先把 GOPATH 指到归档内，注册表那部分由 restore.ps1 补
            Env = @{ 'GOPATH' = '$env:SCOOP\gopath' }
            MkDir = @('$env:SCOOP\gopath\bin')
            Required = @(
                # ninja：没有 VS generator 时 cmake 的唯一可用生成器
                'mingw-winlibs', 'cmake', 'make', 'ninja',
                # rust 只用 rustup-gnu（默认 gnu host，链接走 mingw gcc）。
                # rust / rust-msvc / rustup-msvc 都是 msvc host，而 MSVC Build Tools
                # 在任何一个 bucket 里都没有，装了 cargo build 到链接阶段必失败
                'rustup-gnu',
                'go',
                # ruby 的原生扩展要 msys2
                'msys2', 'ruby',
                'dotnet-sdk-lts', 'dotnet3-sdk', 'nuget',
                'yarn', 'git-lfs', 'hadolint', 'shellcheck', 'lefthook',
                'chromedriver', 'chsrc', 'colortool',
                'kubectl', 'etcd',
                # IDE 带的 JDK。不用 liberica16（非 LTS，2021-09 就被 17 取代）
                'liberica21-full-jdk', 'extras/idea', 'extras/sublime-text'
            )
            Pin = @('liberica21-full-jdk')
        }

        pentest = @{
            Title = 'Web 与内网渗透'
            Required = @(
                # 信息收集
                'anew', 'fofax', 'ksubdomain', 'netspy', 'pdtm',
                # 扫描与爬虫
                'crawlergo', 'main/ffuf', 'fscan', 'gogo', 'rad',
                # 口令与横向
                'spray', 'zombie', 'blueteamtools', 'hashcat', 'Ldap-admin', 'sshpass',
                # 凭据与密钥扫描
                'trufflehog',
                # burp-suite-pro-np 是 -np 包，安装器写 Program Files，不进归档
                'burp-suite-pro-np', 'sslscan', 'osv-scanner'
            )
        }

        re = @{
            Title = '逆向工程与样本取证'
            Required = @(
                # 不放 ghidra：它的 manifest 自己 suggest JDK，而本层不带 JDK，装了起不来。
                # 要 Ghidra 就把 re 和 dev（带 liberica21）叠加还原。
                'radare2', 'cutter', 'dnspy', 'ilspy',
                'apktool', 'jadx',
                'x64dbg', 'pe-bear', 'openark',
                'yara', 'exiftool', 'upx', 'uniextract2'
            )
        }

        apps = @{
            Title = '常用桌面软件'
            # 整层 Optional：单个 GUI 应用失败不该作废整轮构建
            Optional = @(
                'versions/wezterm-nightly', 'FiraCode-NF', 'JetBrainsMono-NF',
                'googlechrome', 'firefox', 'clash-verge-rev',
                'obsidian', 'sumatrapdf', 'honeyview', 'pandoc', 'vscode',
                'vlc', 'snipaste', 'picgo',
                'sysinternals', 'TrafficMonitor', 'SpaceSniffer', 'dupeGuru', 'renamer',
                'nircmd', 'scoop-search', 'everything-cli',
                'keepassxc', 'keepass-plugin-keepassrpc', 'gpg'
            )
        }

        'apps-plus' = @{
            Title = '增强桌面软件'
            Optional = @(
                'imagemagick', 'ffmpeg', 'xmlnotepad', 'masscode',
                's3browser', 'oss-browser',
                'rufus', 'vncviewer',
                'sourcegit', 'ssh-config', 'onefetch',
                'zotero', 'office-tool-plus',
                'powertoys'
            )
        }
    }

    # bucket 注册表。setup-scoop 按变体注册，校验 job 用 -All 全部克隆来查 manifest。
    # Repo 写全是因为校验 job 要自己克隆，比两边各猜一次 URL 可靠。main 不在表里。
    Buckets = @(
        @{ Name = 'extras';      Repo = 'https://github.com/ScoopInstaller/Extras' }
        @{ Name = 'versions';    Repo = 'https://github.com/ScoopInstaller/Versions' }
        @{ Name = 'nirsoft';     Repo = 'https://github.com/ScoopInstaller/Nirsoft' }
        @{ Name = 'java';        Repo = 'https://github.com/ScoopInstaller/Java' }
        @{ Name = 'nonportable'; Repo = 'https://github.com/ScoopInstaller/Nonportable' }
        @{ Name = 'nerd-fonts';  Repo = 'https://github.com/matthewjberger/scoop-nerd-fonts' }
        @{ Name = 'ktools';      Repo = 'https://github.com/kenyon-wong/ktools' }
        # 只在 codeql / python 注册。但计划里没有任何包来自它（92 个 manifest 全是 R
        # 相关），等于每次构建白克隆一次 —— 要么补上真正要用的 R 包，要么删掉这行
        @{ Name = 'r-bucket';    Repo = 'https://github.com/cderv/r-bucket.git'
           Variants = @('codeql', 'python') }
    )

    # 变体 → 层。每个变体都是 base + 一层。全家桶写 @('*') 会展开成 Order 全集，
    # 但要记得同时把变体名加进 workflow 的 options（校验 job 会断言这件事）
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
