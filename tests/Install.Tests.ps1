# Mole Windows - installer uninstall tests
# %LOCALAPPDATA%\Mole is also the Mole for Windows app's data folder, so
# removing the CLI must never take that app's files with it.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $installScript = Join-Path $script:WindowsDir "install.ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
    foreach ($name in @("Assert-InstallPhysicalPath", "Get-NormalizedPath", "Test-ProtectedInstallRoot", "Get-MoleInstallEntries", "Get-MoleInstallNestedFiles", "Remove-MoleNestedFiles", "Remove-MoleConfigEntry", "Test-MoleInstallDir", "Uninstall-Mole")) {
        $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
        if (-not $definition) { throw "$name not found in install.ps1" }
        . ([scriptblock]::Create($definition.Extent.Text))
        Set-Item -Path "function:script:$name" -Value (Get-Item "function:$name").ScriptBlock
    }

    function Write-Info { param($Message) }
    function Write-Success { param($Message) }
    function Write-MoleWarning { param($Message) }
    function Write-MoleError { param($Message) }
    function Write-MoleDryRun { param($Message) }
    function Remove-FromUserPath { param($Directory, [switch]$DryRun) }
    function Remove-StartMenuShortcut { param($InstallDir, [switch]$DryRun) $true }

    function New-CliTree {
        param([string]$Root)
        New-Item -ItemType Directory -Path (Join-Path $Root "lib\core"), (Join-Path $Root "bin"), (Join-Path $Root ".git") -Force | Out-Null
        Set-Content -Path (Join-Path $Root "mole.ps1") -Value "#"
        Set-Content -Path (Join-Path $Root "lib\core\base.ps1") -Value "#"
        Set-Content -Path (Join-Path $Root "mo.cmd") -Value "@echo off"
        Set-Content -Path (Join-Path $Root "VERSION") -Value "1.30.0"
    }
}

Describe "install.ps1 -Uninstall" {
    BeforeEach {
        $script:SavedLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
        $script:USERPROFILE_SAVED = $env:USERPROFILE
        $env:USERPROFILE = Join-Path $TestDrive "profile-without-config"
        $script:InstallDirGiven = $true
        $script:SourceDir = $null
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocalAppData
        $env:USERPROFILE = $script:USERPROFILE_SAVED
    }

    It "Never removes a config folder recursively when it gained an entry after the listing" {
        $dir = Join-Path $TestDrive ("config-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir "late.txt") -Value "x"
        $item = Get-Item -LiteralPath $dir -Force
        Mock Get-ChildItem { @() }
        Mock Remove-Item {} -ParameterFilter { Test-Path -LiteralPath $LiteralPath -PathType Container }

        { Remove-MoleConfigEntry -Item $item } | Should -Throw
        Should -Invoke Remove-Item -Times 0 -Exactly -ParameterFilter { Test-Path -LiteralPath $LiteralPath -PathType Container }
        Test-Path -LiteralPath (Join-Path $dir "late.txt") | Should -BeTrue
    }

    It "Keeps the Mole for Windows app's files when the CLI shares its folder" {
        $shared = Join-Path $env:LOCALAPPDATA "Mole"
        New-CliTree -Root $shared
        Set-Content -Path (Join-Path $shared "license.dat") -Value "license"
        New-Item -ItemType Directory -Path (Join-Path $shared "backups") -Force | Out-Null
        $InstallDir = $shared

        Uninstall-Mole | Should -BeTrue

        Test-Path (Join-Path $shared "license.dat") | Should -BeTrue
        Test-Path (Join-Path $shared "backups") | Should -BeTrue
        Test-Path (Join-Path $shared "mole.ps1") | Should -BeFalse
        Test-Path (Join-Path $shared "lib") | Should -BeFalse
        Test-Path (Join-Path $shared ".git") | Should -BeFalse
    }

    It "Keeps unrelated files inside common install directories and Git metadata" {
        $shared = Join-Path $env:LOCALAPPDATA "Tools"
        New-CliTree -Root $shared
        Set-Content -LiteralPath (Join-Path $shared "bin\user-tool.exe") -Value "mine"
        Set-Content -LiteralPath (Join-Path $shared "lib\user-library.txt") -Value "mine"
        Set-Content -LiteralPath (Join-Path $shared ".git\config") -Value "user repository"
        $InstallDir = $shared
        Uninstall-Mole | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $shared "bin\user-tool.exe") | Should -Be "mine"
        Get-Content -LiteralPath (Join-Path $shared "lib\user-library.txt") | Should -Be "mine"
        Get-Content -LiteralPath (Join-Path $shared ".git\config") | Should -Be "user repository"
        Test-Path -LiteralPath (Join-Path $shared "lib\core\base.ps1") | Should -BeFalse
    }

    It "Keeps a Git worktree pointer when removing Mole files" {
        $own = Join-Path $env:LOCALAPPDATA "worktree"
        New-CliTree -Root $own
        [System.IO.Directory]::Delete((Join-Path $own ".git"))
        Set-Content -LiteralPath (Join-Path $own ".git") -Value "gitdir: elsewhere"
        $InstallDir = $own
        Uninstall-Mole | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $own ".git") | Should -Be "gitdir: elsewhere"
        Test-Path -LiteralPath (Join-Path $own "mole.ps1") | Should -BeFalse
    }

    It "Keeps a linked install directory and the files outside it" {
        $outside = Join-Path $env:LOCALAPPDATA "outside"
        New-CliTree -Root $outside
        $link = Join-Path $env:LOCALAPPDATA "linked"
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        try {
            $InstallDir = $link
            { Uninstall-Mole } | Should -Throw '*linked install path*'
            Test-Path -LiteralPath (Join-Path $outside "mole.ps1") | Should -BeTrue
        }
        finally { [System.IO.Directory]::Delete($link) }
    }

    It "Removes the docs screenshots Mole ships and the folders they leave empty" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\mole-cli"
        New-CliTree -Root $own
        foreach ($file in Get-MoleInstallNestedFiles) {
            $path = Join-Path $own $file
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            Set-Content -Path $path -Value "png"
        }
        $InstallDir = $own

        Uninstall-Mole | Should -BeTrue

        Test-Path $own | Should -BeFalse
    }

    It "Keeps a docs folder that holds the user's own files" {
        $shared = Join-Path $env:LOCALAPPDATA "Tools"
        New-CliTree -Root $shared
        New-Item -ItemType Directory -Path (Join-Path $shared "docs\img") -Force | Out-Null
        Set-Content -Path (Join-Path $shared "docs\img\mole-windows.png") -Value "png"
        Set-Content -Path (Join-Path $shared "docs\notes.md") -Value "mine"
        $InstallDir = $shared

        Uninstall-Mole | Should -BeTrue

        Test-Path (Join-Path $shared "docs\notes.md") | Should -BeTrue
        Test-Path (Join-Path $shared "docs\img") | Should -BeFalse
        Test-Path (Join-Path $shared "mole.ps1") | Should -BeFalse
    }

    It "Knows every top-level entry and docs file the repository ships" {
        $known = @(Get-MoleInstallEntries)
        $nested = @(Get-MoleInstallNestedFiles)
        $roots = @($nested | ForEach-Object { ($_ -split '\\')[0] } | Select-Object -Unique)
        foreach ($entry in @(Get-ChildItem -LiteralPath $script:WindowsDir -Force)) {
            ($known -contains $entry.Name -or $roots -contains $entry.Name) | Should -BeTrue -Because "$($entry.Name) must be removable by mo remove"
        }
        foreach ($root in $roots) {
            $base = Join-Path $script:WindowsDir $root
            foreach ($file in @(Get-ChildItem -LiteralPath $base -Recurse -File -Force)) {
                $relative = $file.FullName.Substring($script:WindowsDir.TrimEnd('\').Length + 1)
                $nested | Should -Contain $relative
            }
        }
    }

    It "Removes a folder that holds only the CLI" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\mole-cli"
        New-CliTree -Root $own
        $InstallDir = $own

        Uninstall-Mole | Should -BeTrue

        Test-Path $own | Should -BeFalse
    }

    It "Removes the Mole cache with the install and keeps linked targets" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\mole-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $cache = Join-Path $env:USERPROFILE ".cache\mole"
        New-Item -ItemType Directory -Path (Join-Path $cache "old") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $cache "old\nested.txt") -Value "cache"
        $outside = Join-Path $TestDrive ("outside-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside "keep.txt") -Value "mine"
        $null = New-Item -ItemType Junction -Path (Join-Path $cache "linked") -Target $outside
        try {
            Uninstall-Mole | Should -BeTrue

            Test-Path -LiteralPath $cache | Should -BeFalse
            Get-Content -LiteralPath (Join-Path $outside "keep.txt") | Should -Be "mine"
        }
        finally {
            $link = Join-Path $cache "linked"
            if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) }
        }
    }

    It 'Keeps the cache when its ancestor is a junction' {
        $own = Join-Path $env:LOCALAPPDATA 'Programs\mole-cli'
        New-CliTree -Root $own
        $InstallDir = $own
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $env:USERPROFILE -Force | Out-Null
        $outside = Join-Path $TestDrive ('cache-target-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $outside 'mole') -Force | Out-Null
        $kept = Join-Path $outside 'mole\keep.txt'
        Set-Content -LiteralPath $kept -Value 'keep'
        $link = Join-Path $env:USERPROFILE '.cache'
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        try {
            Uninstall-Mole | Should -BeTrue
            Get-Content -LiteralPath $kept | Should -Be 'keep'
        }
        finally { [IO.Directory]::Delete($link, $false) }
    }

    It "Records the cache removal in the operation log" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\mole-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE ".cache\mole") -Force | Out-Null
        $global:UninstallOps = @()
        function global:Write-MoleOperation {
            param($Action, $Path, $Detail)
            $global:UninstallOps += "$Action $Path $Detail"
        }
        try {
            Uninstall-Mole | Should -BeTrue
        }
        finally {
            Remove-Item function:global:Write-MoleOperation -ErrorAction SilentlyContinue
        }
        ($global:UninstallOps -join "`n") | Should -Match 'REMOVED .*\.cache\\mole cache'
    }

    It "Keeps the Mole cache when the folder is not a Mole install" {
        $other = Join-Path $env:LOCALAPPDATA "NotMole"
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        $InstallDir = $other
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $cache = Join-Path $env:USERPROFILE ".cache\mole"
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $cache "keep.txt") -Value "cache"

        Uninstall-Mole | Should -BeFalse

        Test-Path -LiteralPath (Join-Path $cache "keep.txt") | Should -BeTrue
    }

    It "Keeps the operation log when the user removes the config files" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\mole-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $config = Join-Path $env:USERPROFILE ".config\mole"
        New-Item -ItemType Directory -Path (Join-Path $config "cache") -Force | Out-Null
        foreach ($name in @("operations.log", "operations.log.old", "whitelist.txt", "mole_debug_session.log", "cache\apps.json")) {
            Set-Content -LiteralPath (Join-Path $config $name) -Value $name
        }
        Mock Read-Host { "y" }

        Uninstall-Mole | Should -BeTrue

        Get-Content -LiteralPath (Join-Path $config "operations.log") | Should -Be "operations.log"
        Get-Content -LiteralPath (Join-Path $config "operations.log.old") | Should -Be "operations.log.old"
        @(Get-ChildItem -LiteralPath $config -Force | ForEach-Object Name | Sort-Object) | Should -Be @("operations.log", "operations.log.old")
    }

    It "Removes the config folder when it holds no operation log" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\mole-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $config = Join-Path $env:USERPROFILE ".config\mole"
        New-Item -ItemType Directory -Path $config -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $config "whitelist.txt") -Value "x"
        Mock Read-Host { "y" }

        Uninstall-Mole | Should -BeTrue

        Test-Path -LiteralPath $config | Should -BeFalse
    }

    It "Removes an unlocked native launcher through the PowerShell entrypoint" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\mole-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        Set-Content -LiteralPath (Join-Path $own 'mo.exe') -Value 'fixture'

        Uninstall-Mole | Should -BeTrue

        Test-Path -LiteralPath $own | Should -BeFalse
    }

    It "Refuses a locked native launcher before changing any install files or PATH" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\mole's cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $exe = Join-Path $own 'mo.exe'
        Set-Content -LiteralPath $exe -Value 'locked fixture'
        Mock Remove-FromUserPath {}
        Mock Remove-StartMenuShortcut { $true }
        Mock Write-Info {}
        $expectedCommand = "Close other Mole sessions, then run in PowerShell: & '" + (Join-Path $own 'mole.ps1').Replace("'", "''") + "' remove"
        $handle = [IO.File]::Open($exe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            Uninstall-Mole | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $own 'lib\core\base.ps1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $own 'VERSION') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $own 'mo.cmd') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $own 'mole.ps1') | Should -BeTrue
            Should -Invoke Remove-FromUserPath -Times 0 -Exactly
            Should -Invoke Remove-StartMenuShortcut -Times 0 -Exactly
            Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -eq $expectedCommand }
        }
        finally { $handle.Dispose() }
    }

    It "Keeps config behind a junction at <LinkedPart>" -TestCases @(
        @{ LinkedPart = 'mole' }
        @{ LinkedPart = '.config' }
    ) {
        param($LinkedPart)
        $own = Join-Path $env:LOCALAPPDATA "Programs\mole-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $outside = Join-Path $env:LOCALAPPDATA "outside"
        New-Item -ItemType Directory -Path $outside, $env:USERPROFILE -Force | Out-Null
        if ($LinkedPart -eq 'mole') {
            New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE '.config') -Force | Out-Null
            $link = Join-Path $env:USERPROFILE '.config\mole'
            $sentinel = Join-Path $outside 'keep.txt'
        }
        else {
            New-Item -ItemType Directory -Path (Join-Path $outside 'mole') -Force | Out-Null
            $link = Join-Path $env:USERPROFILE '.config'
            $sentinel = Join-Path $outside 'mole\keep.txt'
        }
        Set-Content -LiteralPath $sentinel -Value 'keep'
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        Mock Read-Host { 'y' }
        try {
            Uninstall-Mole | Should -BeTrue
            Get-Content -LiteralPath $sentinel | Should -Be 'keep'
            Test-Path -LiteralPath $link | Should -BeTrue
        }
        finally {
            if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) }
        }
    }

    It "Unlinks a junction in the config folder and keeps its target's files" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\mole-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $config = Join-Path $env:USERPROFILE ".config\mole"
        New-Item -ItemType Directory -Path (Join-Path $config "cache") -Force | Out-Null
        $outside = Join-Path $env:LOCALAPPDATA "outside"
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside "keep.txt") -Value "keep"
        $link = Join-Path $config "linked"
        $nested = Join-Path $config "cache\linked"
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        $null = New-Item -ItemType Junction -Path $nested -Target $outside
        Mock Read-Host { "y" }

        try {
            Uninstall-Mole | Should -BeTrue

            Get-Content -LiteralPath (Join-Path $outside "keep.txt") | Should -Be "keep"
            Test-Path -LiteralPath $link | Should -BeFalse
            Test-Path -LiteralPath $nested | Should -BeFalse
            Test-Path -LiteralPath $config | Should -BeFalse
        }
        finally {
            foreach ($path in @($link, $nested)) {
                if (Test-Path -LiteralPath $path) { [System.IO.Directory]::Delete($path) }
            }
        }
    }

    It "Removes nothing from a folder that is not a Mole install" {
        $appData = Join-Path $env:LOCALAPPDATA "Mole"
        New-Item -ItemType Directory -Path $appData -Force | Out-Null
        Set-Content -Path (Join-Path $appData "license.dat") -Value "license"
        Set-Content -Path (Join-Path $appData "VERSION") -Value "app"
        $InstallDir = $appData

        Uninstall-Mole | Should -BeFalse

        Test-Path (Join-Path $appData "license.dat") | Should -BeTrue
        Test-Path (Join-Path $appData "VERSION") | Should -BeTrue
    }

    It "Never falls back to %LOCALAPPDATA%\Mole when the install folder is gone" {
        $appData = Join-Path $env:LOCALAPPDATA "Mole"
        New-Item -ItemType Directory -Path $appData -Force | Out-Null
        Set-Content -Path (Join-Path $appData "license.dat") -Value "license"
        $InstallDir = Join-Path $env:LOCALAPPDATA "Programs\mole-cli"

        Uninstall-Mole | Should -BeTrue

        Test-Path (Join-Path $appData "license.dat") | Should -BeTrue
    }

    Context "Previews removal through the real uninstall path" {
        BeforeAll {
            function New-RemovalFixture {
                param([string]$Layout)
                $root = if ($Layout -eq "shared") { Join-Path $env:LOCALAPPDATA "Tools" } else { Join-Path $env:LOCALAPPDATA "Programs\mole-cli" }
                New-CliTree -Root $root
                foreach ($file in Get-MoleInstallNestedFiles) {
                    $path = Join-Path $root $file
                    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                    Set-Content -LiteralPath $path -Value "shipped"
                }
                if ($Layout -eq "shared") {
                    Set-Content -LiteralPath (Join-Path $root "bin\user-tool.exe") -Value "mine"
                    Set-Content -LiteralPath (Join-Path $root "notes.txt") -Value "mine"
                    Set-Content -LiteralPath (Join-Path $root ".git\config") -Value "user repository"
                }
                $cache = Join-Path $env:USERPROFILE ".cache\mole"
                New-Item -ItemType Directory -Path (Join-Path $cache "old") -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $cache "old\nested.txt") -Value "cache"
                $config = Join-Path $env:USERPROFILE ".config\mole"
                New-Item -ItemType Directory -Path (Join-Path $config "cache") -Force | Out-Null
                foreach ($name in @("operations.log", "whitelist.txt", "cache\apps.json")) {
                    Set-Content -LiteralPath (Join-Path $config $name) -Value $name
                }
                return $root
            }

            # Every path below the roots with each file's size and write time;
            # folders count by name only. The host may write under AppData.
            function Get-FixtureState {
                param([string[]]$Roots)
                $state = foreach ($root in $Roots) {
                    if (-not (Test-Path -LiteralPath $root)) { continue }
                    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force)) {
                        # Relative to the root: TestDrive itself sits under AppData\Local\Temp.
                        if ($item.FullName.Substring($root.Length) -match '^\\AppData(\\|$)') { continue }
                        if ($item.PSIsContainer) { $item.FullName }
                        else { "$($item.FullName)|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)" }
                    }
                }
                return @($state | Sort-Object)
            }

            function Get-PreviewRemovals {
                param([string[]]$Lines)
                return @(foreach ($line in $Lines) {
                        if ($line -match '^(?:On y, w|W)ould remove(?: directory| cache| config)?: (.+)$') { $Matches[1] }
                    })
            }
        }

        BeforeEach {
            # Spell the fixture roots the way listings do, so preview paths and
            # listed paths compare equal whether or not the host expands 8.3 names.
            $base = (Get-Item -LiteralPath $TestDrive -Force).FullName
            $env:LOCALAPPDATA = Join-Path $base ([guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
            $env:USERPROFILE = Join-Path $base ([guid]::NewGuid().ToString("N"))
            $global:MolePreviewLines = New-Object System.Collections.Generic.List[string]
            Mock Write-Info { $global:MolePreviewLines.Add([string]$Message) }
            Mock Write-Success { $global:MolePreviewLines.Add([string]$Message) }
            Mock Write-MoleWarning { $global:MolePreviewLines.Add([string]$Message) }
            Mock Write-MoleError { $global:MolePreviewLines.Add([string]$Message) }
            Mock Write-MoleDryRun { $global:MolePreviewLines.Add([string]$Message) }
            Mock Remove-FromUserPath {}
            Mock Remove-StartMenuShortcut { $true }
            Mock Read-Host { throw "Read-Host was called in a dry run" }
        }

        AfterAll {
            Remove-Variable -Name MolePreviewLines -Scope Global -ErrorAction SilentlyContinue
        }

        It "Changes nothing, asks nothing and logs nothing in a <Layout> folder" -ForEach @(
            @{ Layout = "shared" }
            @{ Layout = "own" }
        ) {
            $InstallDir = New-RemovalFixture -Layout $Layout
            $roots = @($env:LOCALAPPDATA, $env:USERPROFILE)
            $before = Get-FixtureState -Roots $roots
            $global:DryRunOps = @()
            function global:Write-MoleOperation {
                param($Action, $Path, $Detail)
                $global:DryRunOps += "$Action $Path"
            }
            try {
                Uninstall-Mole -DryRun | Should -BeTrue
            }
            finally {
                Remove-Item function:global:Write-MoleOperation -ErrorAction SilentlyContinue
            }

            ((Get-FixtureState -Roots $roots) -join "`n") | Should -BeExactly ($before -join "`n")
            Should -Invoke Read-Host -Times 0 -Exactly
            @($global:DryRunOps).Count | Should -Be 0
            Should -Invoke Remove-FromUserPath -Times 1 -Exactly -ParameterFilter { $DryRun }
            Should -Invoke Remove-FromUserPath -Times 0 -Exactly -ParameterFilter { -not $DryRun }
            Should -Invoke Remove-StartMenuShortcut -Times 1 -Exactly -ParameterFilter { $DryRun }
            Should -Invoke Remove-StartMenuShortcut -Times 0 -Exactly -ParameterFilter { -not $DryRun }
            $global:MolePreviewLines | Should -Contain "Would ask: Remove config files? (y/N)"
            $global:MolePreviewLines | Should -Contain "Dry run complete - no changes made"
        }

        It "Names every path the real run then removes from a <Layout> folder" -ForEach @(
            @{ Layout = "shared" }
            @{ Layout = "own" }
        ) {
            $InstallDir = New-RemovalFixture -Layout $Layout
            $roots = @($env:LOCALAPPDATA, $env:USERPROFILE)
            Uninstall-Mole -DryRun | Should -BeTrue
            $preview = @($global:MolePreviewLines)
            $named = @(Get-PreviewRemovals -Lines $preview)
            $named.Count | Should -BeGreaterThan 0
            $before = @(Get-FixtureState -Roots $roots | ForEach-Object { ($_ -split '\|')[0] })

            Mock Read-Host { "y" }
            Uninstall-Mole | Should -BeTrue
            $after = @(Get-FixtureState -Roots $roots | ForEach-Object { ($_ -split '\|')[0] })

            $removed = @($before | Where-Object { $after -notcontains $_ })
            $removed.Count | Should -BeGreaterThan 0
            foreach ($path in $removed) {
                $covered = @($named | Where-Object { $path -eq $_ -or $path.StartsWith($_ + "\", [StringComparison]::OrdinalIgnoreCase) })
                $covered.Count | Should -BeGreaterThan 0 -Because "the preview must name $path or a folder holding it"
            }
            foreach ($path in $named) {
                Test-Path -LiteralPath $path | Should -BeFalse -Because "the preview said $path would be removed"
            }
            foreach ($line in $preview) {
                if ($line -match '^Would keep \d+ item\(s\) Mole did not install: (.+)$') {
                    foreach ($name in ($Matches[1] -split ', ')) {
                        Test-Path -LiteralPath (Join-Path $InstallDir $name) | Should -BeTrue -Because "the preview said $name would be kept"
                    }
                }
                if ($line -match '^On y, would keep: (.+)$') {
                    foreach ($name in ($Matches[1] -split ', ')) {
                        Test-Path -LiteralPath (Join-Path $env:USERPROFILE ".config\mole\$name") | Should -BeTrue -Because "the preview said $name would be kept"
                    }
                }
            }
            if ($Layout -eq "shared") {
                $keptLine = @($preview | Where-Object { $_ -like "Would keep * item(s) Mole did not install: *" })
                $keptLine.Count | Should -Be 1
                $keptNames = @(($keptLine[0] -split ": ", 2)[1] -split ", ")
                $keptNames.Count | Should -Be 3
                foreach ($name in @(".git", "bin", "notes.txt")) { $keptNames | Should -Contain $name }
            }
            else {
                $preview | Should -Contain "Would remove directory: $InstallDir"
            }
        }

        It "Names the refusal for a folder that is not a Mole install and changes nothing" {
            $appData = Join-Path $env:LOCALAPPDATA "Mole"
            New-Item -ItemType Directory -Path $appData -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $appData "license.dat") -Value "license"
            Set-Content -LiteralPath (Join-Path $appData "VERSION") -Value "app"
            New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE ".cache\mole") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $env:USERPROFILE ".cache\mole\keep.txt") -Value "cache"
            $InstallDir = $appData
            $roots = @($env:LOCALAPPDATA, $env:USERPROFILE)
            $before = Get-FixtureState -Roots $roots

            Uninstall-Mole -DryRun | Should -BeFalse

            ((Get-FixtureState -Roots $roots) -join "`n") | Should -BeExactly ($before -join "`n")
            $global:MolePreviewLines | Should -Contain "DRY RUN MODE - No changes will be made"
            $global:MolePreviewLines | Should -Contain "$appData is not a Mole install (no mole.ps1); nothing was removed"
            Should -Invoke Remove-FromUserPath -Times 0 -Exactly
            Should -Invoke Read-Host -Times 0 -Exactly
        }
    }
}

Describe "User PATH removal preview" {
    BeforeAll {
        $installScript = Join-Path $script:WindowsDir "install.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Remove-FromUserPath"
            }, $true)
        $text = $definition.Extent.Text -replace '^function Remove-FromUserPath', 'function Remove-PathUnderTest'
        . ([scriptblock]::Create($text))
        Set-Item -Path "function:script:Remove-PathUnderTest" -Value (Get-Item "function:Remove-PathUnderTest").ScriptBlock
    }

    It "Names the entry it would remove and leaves the user PATH unchanged" {
        # This reads the real user PATH; without the switch the function would rewrite it.
        (Get-Command Remove-PathUnderTest).Parameters.ContainsKey("DryRun") | Should -BeTrue
        Mock Write-MoleDryRun {}
        Mock Write-Success {}
        Mock Write-MoleError {}
        $before = [Environment]::GetEnvironmentVariable("PATH", "User")
        $absent = Join-Path $TestDrive "not-on-path"
        $entry = "$before" -split ";" | Where-Object { $_ } | Select-Object -First 1

        try {
            Remove-PathUnderTest -Directory $absent -DryRun | Should -BeTrue
            if ($entry) { Remove-PathUnderTest -Directory $entry -DryRun | Should -BeTrue }
        }
        finally {
            # A broken gate must not cost the test machine a PATH entry: put the
            # value back before the assertion below reports the change.
            $after = [Environment]::GetEnvironmentVariable("PATH", "User")
            $script:PathChangedByPreview = ($after -cne $before)
            if ($script:PathChangedByPreview) { [Environment]::SetEnvironmentVariable("PATH", $before, "User") }
        }
        $script:PathChangedByPreview | Should -BeFalse -Because "a preview must not write the user PATH"

        [Environment]::GetEnvironmentVariable("PATH", "User") | Should -BeExactly $before
        Should -Invoke Write-Success -Times 0 -Exactly
        Should -Invoke Write-MoleError -Times 0 -Exactly
        Should -Invoke Write-MoleDryRun -Times 0 -Exactly -ParameterFilter { $Message -eq "Would remove from PATH: $absent" }
        if ($entry) {
            Should -Invoke Write-MoleDryRun -Times 1 -Exactly -ParameterFilter { $Message -eq "Would remove from PATH: $entry" }
        }
    }
}

Describe "Start menu shortcut removal" {
    BeforeAll {
        $installScript = Join-Path $script:WindowsDir "install.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Remove-StartMenuShortcut"
            }, $true)
        $text = $definition.Extent.Text -replace '^function Remove-StartMenuShortcut', 'function Remove-ShortcutUnderTest'
        . ([scriptblock]::Create($text))
        Set-Item -Path "function:script:Remove-ShortcutUnderTest" -Value (Get-Item "function:Remove-ShortcutUnderTest").ScriptBlock

        function New-TestShortcut {
            param([string]$Path, [string]$Target, [string]$Arguments)
            $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
            $shortcut.TargetPath = $Target
            $shortcut.Arguments = $Arguments
            $shortcut.Save()
        }
    }

    It "Removes this install's shortcut and keeps the Mole for Windows app's" {
        $programs = Join-Path $TestDrive "Programs"
        New-Item -ItemType Directory -Path $programs -Force | Out-Null
        $install = Join-Path $TestDrive "mole-cli"
        New-TestShortcut -Path (Join-Path $programs "Mole.lnk") -Target (Join-Path $TestDrive "Tw93.Mole\Mole.exe") -Arguments ""
        New-TestShortcut -Path (Join-Path $programs "Mole CLI.lnk") -Target "powershell.exe" -Arguments "-NoExit -ExecutionPolicy Bypass -File `"$install\mole.ps1`""

        Remove-ShortcutUnderTest -InstallDir $install -ProgramsPath $programs | Should -BeTrue

        Test-Path (Join-Path $programs "Mole.lnk") | Should -BeTrue
        Test-Path (Join-Path $programs "Mole CLI.lnk") | Should -BeFalse
    }

    It "Removes a 1.30.0 Mole.lnk that starts this install" {
        $programs = Join-Path $TestDrive "Programs-legacy"
        New-Item -ItemType Directory -Path $programs -Force | Out-Null
        $install = Join-Path $TestDrive "legacy-install"
        New-TestShortcut -Path (Join-Path $programs "Mole.lnk") -Target "powershell.exe" -Arguments "-NoExit -ExecutionPolicy Bypass -File `"$install\mole.ps1`""

        Remove-ShortcutUnderTest -InstallDir $install -ProgramsPath $programs | Should -BeTrue

        Test-Path (Join-Path $programs "Mole.lnk") | Should -BeFalse
    }

    It "Names this install's shortcut in a dry run and keeps it" {
        $programs = Join-Path $TestDrive "Programs-preview"
        New-Item -ItemType Directory -Path $programs -Force | Out-Null
        $install = Join-Path $TestDrive "preview-install"
        $shortcut = Join-Path $programs "Mole CLI.lnk"
        New-TestShortcut -Path $shortcut -Target "powershell.exe" -Arguments "-NoExit -ExecutionPolicy Bypass -File `"$install\mole.ps1`""
        Mock Write-MoleDryRun {}

        Remove-ShortcutUnderTest -InstallDir $install -ProgramsPath $programs -DryRun | Should -BeTrue

        Test-Path -LiteralPath $shortcut | Should -BeTrue
        Should -Invoke Write-MoleDryRun -Times 1 -Exactly -ParameterFilter { $Message -eq "Would remove shortcut: $shortcut" }
    }
}
