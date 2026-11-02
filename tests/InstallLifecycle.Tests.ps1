# Installer refresh, literal launcher arguments, and package-manager routing.
BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'install.ps1'), [ref]$null, [ref]$null)
    foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
        Set-Item -Path "function:script:$($definition.Name)" -Value (Get-Item "function:$($definition.Name)").ScriptBlock
    }
    . (Join-Path $script:RepoRoot 'lib\core\tui_binaries.ps1')
    $script:Colors = @{ Red=''; Green=''; Yellow=''; Blue=''; Cyan=''; Gray=''; NC='' }
}

Describe 'Source native tool refresh' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'bin'), (Join-Path $script:Root '.git') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'bin\analyze.exe') -Value 'old'
        Set-Content -LiteralPath (Join-Path $script:Root 'bin\status.exe') -Value 'old'
        Mock Get-Command { [pscustomobject]@{ Name='go' } } -ParameterFilter { $Name -eq 'go' }
        Mock Build-TuiBinary { Set-Content -LiteralPath $DestinationPath -Value 'current source'; $true }
        Mock Restore-PrebuiltTuiBinary { throw 'A source refresh must not silently use the older tagged binary' }
    }
    It 'Refreshes both existing tools from the current source' {
        Ensure-OptionalTuiTools -RootDir $script:Root 6>$null
        (Get-Content -LiteralPath (Join-Path $script:Root 'bin\analyze.exe') -Raw).Trim() | Should -Be 'current source'
        (Get-Content -LiteralPath (Join-Path $script:Root 'bin\status.exe') -Raw).Trim() | Should -Be 'current source'
        Should -Invoke Build-TuiBinary -Times 2 -Exactly
    }
    It 'Uses a verified prebuilt refresh when the local source matches the release' {
        Mock Test-TuiSourceMatchesRelease { $true }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'go' }
        Mock Restore-PrebuiltTuiBinary { Set-Content -LiteralPath $DestinationPath -Value 'verified release'; 'ok' }
        Ensure-OptionalTuiTools -RootDir $script:Root 6>$null
        (Get-Content -LiteralPath (Join-Path $script:Root 'bin\analyze.exe') -Raw).Trim() | Should -Be 'verified release'
        Should -Invoke Restore-PrebuiltTuiBinary -Times 2 -Exactly
        Should -Invoke Build-TuiBinary -Times 0
    }
    It 'Keeps old tools and fails when a current source build fails' {
        Mock Build-TuiBinary { $false }
        { Ensure-OptionalTuiTools -RootDir $script:Root 6>$null } | Should -Throw '*refresh*'
        (Get-Content -LiteralPath (Join-Path $script:Root 'bin\analyze.exe') -Raw).Trim() | Should -Be 'old'
    }
    It 'Does not claim a successful refresh when Go is unavailable' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'go' }
        { Ensure-OptionalTuiTools -RootDir $script:Root 6>$null } | Should -Throw '*Go*'
        (Get-Content -LiteralPath (Join-Path $script:Root 'bin\analyze.exe') -Raw).Trim() | Should -Be 'old'
    }
}

Describe 'Fresh source install without Go' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'bin'), (Join-Path $script:Root '.git') -Force | Out-Null
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'go' }
        Mock Restore-PrebuiltTuiBinary { throw 'A source refresh must not silently use the older tagged binary' }
    }
    It 'Warns instead of failing when no tool existed to keep' {
        { Ensure-OptionalTuiTools -RootDir $script:Root 6>$null 3>$null } | Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $script:Root 'bin\analyze.exe') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Root 'bin\status.exe') | Should -BeFalse
    }
    It 'Still fails when only one of two existing tools can be refreshed' {
        Set-Content -LiteralPath (Join-Path $script:Root 'bin\status.exe') -Value 'old'
        { Ensure-OptionalTuiTools -RootDir $script:Root 6>$null 3>$null } | Should -Throw '*status*'
        (Get-Content -LiteralPath (Join-Path $script:Root 'bin\status.exe') -Raw).Trim() | Should -Be 'old'
    }
}

Describe 'Generated cmd launchers' {
    BeforeEach {
        $script:SourceDir = Join-Path $TestDrive "Bob's tools! & files"
        New-Item -ItemType Directory -Path $script:SourceDir -Force | Out-Null
        $script:VERSION = 'test'
        $script:InstallDir = $script:SourceDir
        $script:Force = $false
        $script:AddToPath = $false
        $script:CreateShortcut = $false
        Mock Ensure-OptionalTuiTools {}
        Mock Test-ProtectedInstallRoot { $false }
        @'
[Environment]::GetCommandLineArgs() | Out-Null
[System.IO.File]::WriteAllText($env:MOLE_TEST_CAPTURE, (ConvertTo-Json -InputObject @($args) -Compress))
exit 7
'@ | Set-Content -LiteralPath (Join-Path $script:SourceDir 'mole.ps1')
        Install-Mole 6>$null | Should -BeTrue
    }
    It 'Keeps a launcher symbolic-link target unchanged' -ForEach @('mo.cmd', 'mole.cmd') {
        $launcher = Join-Path $script:SourceDir $_
        $target = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N') + '.cmd')
        Set-Content -LiteralPath $target -Value 'external launcher'
        Remove-Item -LiteralPath $launcher -Force
        $null = New-Item -ItemType SymbolicLink -Path $launcher -Target $target -ErrorAction Stop
        try {
            { Install-Mole 6>$null } | Should -Throw '*linked install path*'
            Get-Content -LiteralPath $target | Should -Be 'external launcher'
        }
        finally { [System.IO.File]::Delete($launcher) }
    }
    It 'Returns the script exit code when removal deletes its running batch file' {
        @'
Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'mo.cmd') -Force
exit 7
'@ | Set-Content -LiteralPath (Join-Path $script:SourceDir 'mole.ps1')
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = $env:ComSpec
        $start.UseShellExecute = $false
        $start.Arguments = '/d /s /c ""' + (Join-Path $script:SourceDir 'mo.cmd') + '" remove"'
        $process = [System.Diagnostics.Process]::Start($start)
        $process.WaitForExit()
        $process.ExitCode | Should -Be 7
        $process.Dispose()
        (Join-Path $script:SourceDir 'mo.cmd') | Should -Not -Exist
    }
    It 'Preserves apostrophes, exclamation marks, spaces, metacharacters and long flags' {
        $capture = Join-Path $TestDrive 'literal-args.json'
        $saved = $env:MOLE_TEST_CAPTURE
        $env:MOLE_TEST_CAPTURE = $capture
        try {
            $start = New-Object System.Diagnostics.ProcessStartInfo
            $start.FileName = $env:ComSpec
            $start.UseShellExecute = $false
            $start.Arguments = '/d /s /c ""' + (Join-Path $script:SourceDir 'mo.cmd') + '" analyze "D:\Bob''s files! & notes" --dry-run "percent%value""'
            $process = [System.Diagnostics.Process]::Start($start)
            $process.WaitForExit()
            $process.ExitCode | Should -Be 7
            $process.Dispose()
            $actual = Get-Content -LiteralPath $capture -Raw | ConvertFrom-Json
            $actual.Count | Should -Be 4
            $actual[0] | Should -Be 'analyze'
            $actual[1] | Should -Be "D:\Bob's files! & notes"
            $actual[2] | Should -Be '--dry-run'
            $actual[3] | Should -Be 'percent%value'
        }
        finally { $env:MOLE_TEST_CAPTURE = $saved }
    }
    It 'Uses the PowerShell host that ran the installer' {
        $expectedHost = Get-InstallerPowerShellPath -ForBatch
        $expectedHost | Should -Match ([regex]::Escape($(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })) + '$')
        foreach ($name in @('mo.cmd', 'mole.cmd')) {
            $content = Get-Content -LiteralPath (Join-Path $script:SourceDir $name) -Raw
            $content | Should -Match ([regex]::Escape($expectedHost))
        }
    }
    It 'Keeps launchers on a PowerShell path that survives host updates' {
        if ($PSVersionTable.PSEdition -ne 'Core') {
            Get-InstallerPowerShellPath | Should -Be (Join-Path $PSHOME 'powershell.exe')
            return
        }
        # A Store pwsh runs from a versioned $PSHOME; the alias on PATH is stable.
        $aliasDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $aliasDir -Force | Out-Null
        $alias = Join-Path $aliasDir 'pwsh.exe'
        [System.IO.File]::WriteAllBytes($alias, [byte[]]@())
        $savedPath = $env:PATH
        try {
            $env:PATH = $aliasDir + ';' + $savedPath
            Get-InstallerPowerShellPath | Should -Be $alias
        }
        finally { $env:PATH = $savedPath }
    }

    It 'Starts both launchers through a non-ASCII pwsh PATH entry without searching the current directory' {
        # Windows PowerShell does not select pwsh; its existing host is the control.
        if ($PSVersionTable.PSEdition -ne 'Core') {
            Get-InstallerPowerShellPath | Should -Be (Join-Path $PSHOME 'powershell.exe')
            return
        }
        $aliasDir = Join-Path $TestDrive ('host-' + [char]0x5F20 + [char]0x4E09 + '!')
        $null = New-Item -ItemType Junction -Path $aliasDir -Target $PSHOME -ErrorAction Stop
        $savedPath = $env:PATH
        $savedCapture = $env:MOLE_TEST_CAPTURE
        $capture = Join-Path $TestDrive 'unicode-host-args.json'
        $shadowDir = Join-Path $TestDrive 'untrusted-working-folder'
        $null = New-Item -ItemType Directory -Path $shadowDir -Force
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\where.exe') -Destination (Join-Path $shadowDir 'pwsh.exe')
        try {
            $env:PATH = $aliasDir + ';' + $savedPath
            $env:MOLE_TEST_CAPTURE = $capture
            Get-InstallerPowerShellPath | Should -Be (Join-Path $aliasDir 'pwsh.exe')
            Install-Mole 6>$null | Should -BeTrue
            foreach ($name in @('mo.cmd', 'mole.cmd')) {
                $start = New-Object System.Diagnostics.ProcessStartInfo
                $start.FileName = $env:ComSpec
                $start.UseShellExecute = $false
                $start.WorkingDirectory = $shadowDir
                $start.Arguments = '/d /s /c ""' + (Join-Path $script:SourceDir $name) + '" --version"'
                $process = [System.Diagnostics.Process]::Start($start)
                try {
                    $process.WaitForExit()
                    $process.ExitCode | Should -Be 7
                }
                finally { $process.Dispose() }
                $actual = Get-Content -LiteralPath $capture -Raw | ConvertFrom-Json
                @($actual).Count | Should -Be 1
                ([string]$actual) | Should -Be '--version'
            }
        }
        finally {
            $env:PATH = $savedPath
            $env:MOLE_TEST_CAPTURE = $savedCapture
            [IO.Directory]::Delete($aliasDir, $false)
        }
    }

    It 'Starts both launchers with a portable host outside PATH under a non-ASCII profile' {
        if ($PSVersionTable.PSEdition -ne 'Core') {
            Get-InstallerPowerShellPath | Should -Be (Join-Path $PSHOME 'powershell.exe')
            return
        }
        $profile = Join-Path $TestDrive ('portable-' + [char]0x5F20 + [char]0x4E09 + '!')
        $null = New-Item -ItemType Directory -Path $profile -Force
        $hostDir = Join-Path $profile 'shell & %MOLE_MISSING_HOST_PART%'
        $null = New-Item -ItemType Junction -Path $hostDir -Target $PSHOME -ErrorAction Stop
        $script:PortableReviewHost = Join-Path $hostDir 'pwsh.exe'
        $script:ReviewJoinPath = Get-Command Join-Path -CommandType Cmdlet
        # Model a portable PSHOME without copying the whole runtime. The CMD
        # execution below still starts the real host through the Unicode path.
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'pwsh.exe' }
        Mock Join-Path {
            if ($Path -eq $PSHOME -and $ChildPath -eq 'pwsh.exe') { return $script:PortableReviewHost }
            & $script:ReviewJoinPath -Path $Path -ChildPath $ChildPath
        }
        $savedPath = $env:PATH
        $savedProfile = $env:USERPROFILE
        $savedCapture = $env:MOLE_TEST_CAPTURE
        try {
            $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
            $env:USERPROFILE = $profile
            $env:MOLE_TEST_CAPTURE = Join-Path $TestDrive 'portable-host-args.json'
            Get-InstallerPowerShellPath -ForBatch | Should -Be '%USERPROFILE%\shell & %%MOLE_MISSING_HOST_PART%%\pwsh.exe'
            Install-Mole 6>$null | Should -BeTrue
            foreach ($name in @('mo.cmd', 'mole.cmd')) {
                $start = New-Object System.Diagnostics.ProcessStartInfo
                $start.FileName = $env:ComSpec
                $start.UseShellExecute = $false
                $start.Arguments = '/d /s /c ""' + (Join-Path $script:SourceDir $name) + '" --version"'
                $process = [System.Diagnostics.Process]::Start($start)
                try {
                    $process.WaitForExit()
                    $process.ExitCode | Should -Be 7
                }
                finally { $process.Dispose() }
                $actual = Get-Content -LiteralPath $env:MOLE_TEST_CAPTURE -Raw | ConvertFrom-Json
                ([string]$actual) | Should -Be '--version'
            }
        }
        finally {
            $env:PATH = $savedPath
            $env:USERPROFILE = $savedProfile
            $env:MOLE_TEST_CAPTURE = $savedCapture
            [IO.Directory]::Delete($hostDir, $false)
        }
    }

    It 'Rejects an unrepresentable batch host before changing an installation' {
        $savedProfile = $env:USERPROFILE
        try {
            $env:USERPROFILE = Join-Path $TestDrive ('user-' + [char]0x5F20)
            $badHost = $env:USERPROFILE + '-sibling\pwsh.exe'
            { ConvertTo-MoleBatchPath -Path $badHost } | Should -Throw '*ASCII launcher*'
            $badHost = Join-Path $env:USERPROFILE ([string][char]0x4E09 + '\pwsh.exe')
            { ConvertTo-MoleBatchPath -Path $badHost } | Should -Throw '*ASCII launcher*'
            $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $script:SourceDir 'mo.cmd')))
            Mock Get-InstallerPowerShellPath { throw 'PowerShell host path cannot be stored in an ASCII launcher.' }
            { Install-Mole 6>$null } | Should -Throw '*ASCII launcher*'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $script:SourceDir 'mo.cmd'))) | Should -Be $before
            # The only refresh was BeforeEach's successful install.
            Should -Invoke Ensure-OptionalTuiTools -Times 1 -Exactly
            $script:InstallDir = Join-Path $TestDrive 'uncreated-install'
            { Install-Mole 6>$null } | Should -Throw '*ASCII launcher*'
            $script:InstallDir | Should -Not -Exist
        }
        finally { $env:USERPROFILE = $savedProfile }
    }
}

Describe 'Quick installer host selection' {
    It 'Runs install.ps1 with the PowerShell host that is already running' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'quick-install.ps1'), [ref]$null, [ref]$null)
        $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-PowerShellCommand'
            }, $true)
        if (-not $definition) { throw 'Get-PowerShellCommand not found in quick-install.ps1' }
        . ([scriptblock]::Create($definition.Extent.Text))

        $exeName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        Get-PowerShellCommand | Should -Be (Join-Path $PSHOME $exeName)
    }
}

Describe 'Copied installation ownership' {
    BeforeEach {
        $script:SourceDir = Join-Path $TestDrive ('copy-source-' + [guid]::NewGuid().ToString('N'))
        $script:InstallDir = Join-Path $TestDrive ('copy-destination-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:SourceDir 'lib\core'), (Join-Path $script:SourceDir 'bin') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:SourceDir 'install.ps1') -Value '# installer'
        Set-Content -LiteralPath (Join-Path $script:SourceDir 'mole.ps1') -Value '# entry'
        Set-Content -LiteralPath (Join-Path $script:SourceDir 'lib\core\base.ps1') -Value '# core'
        $script:VERSION = 'test'
        $script:Force = $true
        $script:AddToPath = $false
        $script:CreateShortcut = $false
        Mock Ensure-OptionalTuiTools {}
        Mock Test-ProtectedInstallRoot { $false }
    }
    It 'Copies its installer so the installed remove command can run' {
        Install-Mole 6>$null | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $script:InstallDir 'install.ps1') | Should -Be '# installer'
    }
    It 'Installs into a pre-created empty destination' {
        New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
        Install-Mole 6>$null | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $script:InstallDir 'install.ps1') | Should -Be '# installer'
    }
    It 'Preserves unrelated files when force updating a shared install' {
        New-Item -ItemType Directory -Path (Join-Path $script:InstallDir 'bin'), (Join-Path $script:InstallDir 'lib\core') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:InstallDir 'mole.ps1') -Value '# old'
        Set-Content -LiteralPath (Join-Path $script:InstallDir 'lib\core\base.ps1') -Value '# old'
        Set-Content -LiteralPath (Join-Path $script:InstallDir 'bin\user-tool.exe') -Value 'mine'
        Install-Mole 6>$null | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $script:InstallDir 'bin\user-tool.exe') | Should -Be 'mine'
    }
    It 'Refuses a linked destination ancestor without modifying its target' {
        $outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        $link = Join-Path $TestDrive ('copy-link-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        try {
            $script:InstallDir = Join-Path $link 'mole'
            { Install-Mole 6>$null } | Should -Throw '*linked install path*'
            @(Get-ChildItem -LiteralPath $outside -Force).Count | Should -Be 0
        }
        finally { [System.IO.Directory]::Delete($link) }
    }
    It 'Refuses force merging into an unrelated directory' {
        New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:InstallDir 'notes.txt') -Value 'mine'
        Install-Mole 6>$null | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $script:InstallDir 'notes.txt') | Should -Be 'mine'
        Test-Path -LiteralPath (Join-Path $script:InstallDir 'mole.ps1') | Should -BeFalse
    }
}

Describe 'Package manager update without Git' {
    It 'Prints the winget command before requiring Git' {
        $root = Join-Path $TestDrive 'Microsoft\WinGet\Packages\tw93.MoleCLI_fixture'
        New-Item -ItemType Directory -Path (Join-Path $root 'bin') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'bin\update.ps1') -Destination (Join-Path $root 'bin\update.ps1')
        Set-Content -LiteralPath (Join-Path $root 'install.ps1') -Value '# fixture'
        $saved = $env:PATH
        try {
            $env:PATH = ''
            $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'bin\update.ps1') 2>&1
            ($output -join "`n") | Should -Match 'winget upgrade tw93\.MoleCLI'
            ($output -join "`n") | Should -Not -Match 'Git is not installed'
        }
        finally { $env:PATH = $saved }
    }
}

Describe 'Release source equivalence' {
    AfterEach {
        # Git marks loose objects read-only; Pester 5.7 cannot remove those files.
        # Restore attributes only in this test's own object store before teardown.
        if ($script:SourceFixture) {
            $objects = Join-Path $script:SourceFixture '.git\objects'
            if (Test-Path -LiteralPath $objects) {
                Get-ChildItem -LiteralPath $objects -Recurse -File -Force | ForEach-Object {
                    $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                }
            }
        }
    }
    BeforeEach {
        $script:SourceFixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:SourceFixture 'cmd\analyze') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:SourceFixture 'cmd\analyze\main.go') -Value 'package main'
        Set-Content -LiteralPath (Join-Path $script:SourceFixture 'go.mod') -Value 'module fixture'
        Set-Content -LiteralPath (Join-Path $script:SourceFixture 'go.sum') -Value ''
        & git init --quiet $script:SourceFixture
        & git -C $script:SourceFixture add .
        # Build a fixture commit directly; do not invoke repository submission hooks.
        $tree = & git -C $script:SourceFixture write-tree
        $commit = & git -C $script:SourceFixture -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree $tree -m fixture
        $LASTEXITCODE | Should -Be 0
        & git -C $script:SourceFixture update-ref HEAD $commit
        & git -C $script:SourceFixture update-ref refs/tags/V9.9.9-windows $commit
    }
    It 'Accepts the released source even when unrelated files differ' {
        Set-Content -LiteralPath (Join-Path $script:SourceFixture 'README.md') -Value 'local documentation'
        Test-TuiSourceMatchesRelease -WindowsDir $script:SourceFixture -Name analyze -Version '9.9.9' | Should -BeTrue
    }
    It 'Refuses an inherited Git index override instead of inspecting another index' {
        $saved = $env:GIT_INDEX_FILE
        try {
            $env:GIT_INDEX_FILE = Join-Path $script:SourceFixture '.git\index'
            Test-TuiSourceMatchesRelease -WindowsDir $script:SourceFixture -Name analyze -Version '9.9.9' | Should -BeFalse
        }
        finally { $env:GIT_INDEX_FILE = $saved }
    }
    It 'Refuses source modifications, untracked compilation units and missing tags' {
        Test-TuiSourceMatchesRelease -WindowsDir $script:SourceFixture -Name analyze -Version '9.9.8' | Should -BeFalse
        $extra = Join-Path $script:SourceFixture 'cmd\analyze\extra.go'
        Set-Content -LiteralPath $extra -Value 'package main'
        Test-TuiSourceMatchesRelease -WindowsDir $script:SourceFixture -Name analyze -Version '9.9.9' | Should -BeFalse
        Remove-Item -LiteralPath $extra
        Add-Content -LiteralPath (Join-Path $script:SourceFixture 'cmd\analyze\main.go') -Value '// changed'
        Test-TuiSourceMatchesRelease -WindowsDir $script:SourceFixture -Name analyze -Version '9.9.9' | Should -BeFalse
    }
}

Describe 'Native build replacement' {
    BeforeEach {
        $script:BuildRoot = Join-Path $TestDrive ('source with spaces ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:BuildRoot -Force | Out-Null
        $script:BuildDestination = Join-Path $script:BuildRoot 'analyze.exe'
        Set-Content -LiteralPath $script:BuildDestination -Value 'old'
        Mock Start-Process {
            $ArgumentList[2] | Should -Match '^".*"$'
            Set-Content -LiteralPath $ArgumentList[2].Trim('"') -Value 'new'
            [pscustomobject]@{ ExitCode = 0 }
        }
    }
    It 'Replaces the binary only after a successful build with empty logs' {
        Build-TuiBinary -Name analyze -WindowsDir $script:BuildRoot -DestinationPath $script:BuildDestination -SourcePath './cmd/analyze/' 6>$null | Should -BeTrue
        (Get-Content -LiteralPath $script:BuildDestination -Raw).Trim() | Should -Be 'new'
        @(Get-ChildItem -LiteralPath $script:BuildRoot -Force).Count | Should -Be 1
    }
    It 'Preserves the existing binary after a failed build' {
        Mock Start-Process {
            Set-Content -LiteralPath $ArgumentList[2].Trim('"') -Value 'incomplete'
            [pscustomobject]@{ ExitCode = 1 }
        }
        Build-TuiBinary -Name analyze -WindowsDir $script:BuildRoot -DestinationPath $script:BuildDestination -SourcePath './cmd/analyze/' 6>$null | Should -BeFalse
        (Get-Content -LiteralPath $script:BuildDestination -Raw).Trim() | Should -Be 'old'
        @(Get-ChildItem -LiteralPath $script:BuildRoot -Force).Count | Should -Be 1
    }
}

Describe 'Native File launcher routing' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'lib\core\update_check.ps1')
        function Test-MoleInteractiveOutput { $false }
        $entryAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'mole.ps1'), [ref]$null, [ref]$null)
        $main = $entryAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Main' }, $true)
        . ([scriptblock]::Create(($main.Extent.Text -replace '^function Main', 'function Invoke-RootRouting')))
        function Initialize-Mole {}
        function Show-Version {}
        function Show-MainHelp {}
        function Show-MainMenu { return $null }
        function Clear-MoleScreen {}
        function Invoke-MoleCommand { param($CommandName, $Arguments) }
    }
    BeforeEach {
        $script:Command = ''
        $script:CommandArgs = $null
        $script:MoleExitCode = 0
        $script:ShowHelp = $false
        $script:Version = $false
        Mock Initialize-Mole {}
        Mock Show-Version {}
        Mock Show-MainHelp {}
        Mock Show-MainMenu { return $null }
        Mock Clear-MoleScreen {}
        Mock Invoke-MoleCommand {}
    }
    It 'Handles root long help passed through remaining arguments' {
        $script:CommandArgs = @('--help')
        Invoke-RootRouting
        Should -Invoke Show-MainHelp -Times 1 -Exactly
        Should -Invoke Show-MainMenu -Times 0
    }
    It 'Forwards a bound short help switch to the selected command' {
        $script:Command = 'analyze'
        $script:ShowHelp = $true
        Invoke-RootRouting
        Should -Invoke Invoke-MoleCommand -Times 1 -Exactly -ParameterFilter { $CommandName -eq 'analyze' -and $Arguments -contains '--help' }
        Should -Invoke Show-MainHelp -Times 0
    }
    It 'Keeps a command-local version flag in the child arguments' {
        $script:Command = 'status'
        $script:Version = $true
        Invoke-RootRouting
        Should -Invoke Invoke-MoleCommand -Times 1 -Exactly -ParameterFilter { $CommandName -eq 'status' -and $Arguments -contains '--version' }
        Should -Invoke Show-Version -Times 0
    }
    It 'Keeps root short help and version working' {
        $script:ShowHelp = $true
        Invoke-RootRouting
        Should -Invoke Show-MainHelp -Times 1 -Exactly
        $script:ShowHelp = $false
        $script:Version = $true
        Invoke-RootRouting
        Should -Invoke Show-Version -Times 1 -Exactly
    }
    It 'Keeps command dry-run flags in the child arguments' {
        $script:Command = 'clean'
        $script:CommandArgs = @('--dry-run')
        Invoke-RootRouting
        Should -Invoke Invoke-MoleCommand -Times 1 -Exactly -ParameterFilter { $CommandName -eq 'clean' -and $Arguments -contains '--dry-run' }
    }
}

Describe 'Review regressions: first native launch' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root '.git') -Force | Out-Null
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'go' }
        Mock Test-TuiSourceMatchesRelease { $false }
        Mock Restore-PrebuiltTuiBinary { 'ok' }
    }
    It 'Does not download a different release for missing <_>' -ForEach @('analyze','status') {
        $result = Ensure-TuiBinary -Name $_ -WindowsDir $script:Root -DestinationPath (Join-Path $script:Root "$_.exe") -SourcePath "./cmd/$_" -Version '1.34.0'
        $result | Should -BeNullOrEmpty
        Should -Invoke Restore-PrebuiltTuiBinary -Times 0 -Exactly
    }
    It 'Allows the release binary when the source is equivalent' {
        Mock Test-TuiSourceMatchesRelease { $true }
        Ensure-TuiBinary -Name analyze -WindowsDir $script:Root -DestinationPath (Join-Path $script:Root 'analyze.exe') -SourcePath './cmd/analyze' -Version '1.34.0' | Should -Not -BeNullOrEmpty
        Should -Invoke Restore-PrebuiltTuiBinary -Times 1 -Exactly
    }
}
