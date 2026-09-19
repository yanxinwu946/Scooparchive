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
    Order = @('base', 'codeql', 'jvm', 'dotnet', 'python', 'agent', 'dev', 'pentest', 're', 'apps', 'apps-plus')

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

        jvm = @{
            Title = 'JDK 运行时'
            # 给 IDE / apktool / jadx 这类「PATH 上有个 java 就行」的工具用。
            # codeql 层的 8/11/17/27 是给代码扫描的版本矩阵，用途不同，不并进来。
            Required = @('liberica21-full-jdk')
            # 和 codeql 层叠加时两个层都写 JAVA_HOME，定序避免结果依赖字典序
            Pin = @('liberica21-full-jdk')
        }

        dotnet = @{
            Title = '.NET 运行时'
            # 用 SDK 而不是 versions/windowsdesktop-runtime-*：后者是 MSI，装完写
            # Program Files，安装器不留档（无 bin 声明），归档里只剩假记录。
            # SDK 是可移植 zip，且 Windows 版自带 Microsoft.WindowsDesktop.App。
            Required = @('dotnet-sdk-lts')
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
                # .NET SDK 由 dotnet 层提供
                'dotnet3-sdk', 'nuget',
                'yarn', 'git-lfs', 'hadolint', 'shellcheck', 'lefthook',
                'chromedriver', 'chsrc', 'colortool',
                'kubectl', 'etcd',
                # IDE 要的 JDK 由 jvm 层提供
                'extras/idea', 'extras/sublime-text'
            )
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
                # apktool / jadx 要的 java 由 jvm 层提供
                # 用 dnspyex 不用 dnspy：后者的 manifest 自己写着不再维护、
                # 建议改用 dnspyex（6.1.8 vs 6.6.0）。注意 dnspyex 只把
                # dnSpy.Console.exe 声明成 bin，GUI 没有 shim（只能从 apps 目录起）
                'radare2', 'cutter', 'dnspyex', 'ilspy',
                'apktool', 'jadx',
                # dnspyex / ilspy 要的 .NET 运行时由 dotnet 层提供
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
                # nircmd 在 main 和 nirsoft 里都有（同一个二进制），带前缀保证确定性。
                # nirsoft 版声明 bin（shim 落在 $SCOOP\shims）且有 persist，更适合归档
                'nirsoft/nircmd', 'scoop-search', 'everything-cli',
                # 不放 keepass-plugin-keepassrpc：它是 KeePass 2.x 的插件，而这里装的是
                # keepassxc（另一个产品，自带浏览器集成），插件用不上，还会让 scoop
                # 顺着它的 depends 自动补装 keepass。要 KeePass+RPC 就把 keepassxc
                # 换成 extras/keepass 并加回插件。
                'keepassxc', 'gpg'
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
        # 曾经为 codeql / python 注册 r-bucket，但计划里没有任何包来自它（92 个
        # manifest 全是 R 相关），每次构建白克隆一次。要用 R 时再加回来。
    )

    # 变体 → 层。大多是 base + 一层；需要共用运行时的（dev / re 要 JDK）叠上 jvm。
    # 全家桶写 @('*') 会展开成 Order 全集，但要记得同时把变体名加进 workflow 的
    # options（校验 job 会断言这件事）
    Variants = @{
        'base'      = @('base')
        'codeql'    = @('base', 'codeql')
        'python'    = @('base', 'python')
        'agent'     = @('base', 'agent')
        'dev'       = @('base', 'jvm', 'dotnet', 'dev')
        'pentest'   = @('base', 'pentest')
        're'        = @('base', 'jvm', 'dotnet', 're')
        'apps'      = @('base', 'apps')
        'apps-plus' = @('base', 'apps-plus')
    }
}
