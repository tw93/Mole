# Rows synced from Mole for Windows and Mole CLI (macOS) on 2026-11-27: Cargo's
# download copies, owner guards on direct-delete developer rows, Epic webcache
# generations, Office and Drive temp guards, CrashDumps age under --system, and
# the Windows Installer wait before an MSI uninstall.
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . "$root\lib\clean\dev.ps1"
    . "$root\lib\clean\apps.ps1"
    . "$root\lib\clean\system.ps1"
    $source = Join-Path $root 'bin\uninstall.ps1'
    $script:UninstallAst = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
    foreach ($name in 'Test-MoleInstallerBusy', 'Wait-MoleInstallerIdle') {
        $definition = $script:UninstallAst.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if ($definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
    }
    $script:SavedLocalAppData = $env:LOCALAPPDATA
    $script:SavedAppData = $env:APPDATA
}

AfterAll {
    $env:LOCALAPPDATA = $script:SavedLocalAppData
    $env:APPDATA = $script:SavedAppData
}

Describe 'Cargo and rustup download copies' {
    It 'Leaves registry\cache and rustup downloads to their rows and whitelists the rest' {
        # Only the defaults: a whitelist file on the machine running the tests must not decide this.
        $savedWhitelist = $script:Config.WhitelistFile
        $script:Config.WhitelistFile = Join-Path $TestDrive 'no-whitelist.txt'
        try { $state = Get-WhitelistState }
        finally { $script:Config.WhitelistFile = $savedWhitelist }
        Test-Whitelisted -Path "$env:USERPROFILE\.cargo\registry\cache\index.crates.io-1\serde-1.0.crate" -State $state | Should -BeFalse
        Test-Whitelisted -Path "$env:USERPROFILE\.rustup\downloads\abc.partial" -State $state | Should -BeFalse
        foreach ($kept in "$env:USERPROFILE\.cargo\registry\src\index.crates.io-1\serde-1.0\lib.rs",
            "$env:USERPROFILE\.cargo\registry\index\cache\x", "$env:USERPROFILE\.cargo\git\checkouts\repo\HEAD",
            "$env:USERPROFILE\.cargo\bin\cargo.exe", "$env:USERPROFILE\.rustup\toolchains\stable\bin\rustc.exe") {
            Test-Whitelisted -Path $kept -State $state | Should -BeTrue -Because $kept
        }
    }
    It 'Cleans them only while no Rust tool runs and never touches git checkouts' {
        Mock Clear-MoleAppCache {}
        Mock Clear-DirectoryContents {}
        Clear-RustCaches
        Should -Invoke Clear-MoleAppCache -Times 1 -Exactly -ParameterFilter {
            $Path -like '*\.cargo\registry\cache' -and $Processes -contains 'cargo' -and $Processes -contains 'rustc'
        }
        Should -Invoke Clear-MoleAppCache -Times 1 -Exactly -ParameterFilter { $Path -like '*\.rustup\downloads' -and $Processes -contains 'cargo' }
        Should -Invoke Clear-MoleAppCache -Times 0 -Exactly -ParameterFilter { $Path -like '*\.cargo\git*' }
        Should -Invoke Clear-DirectoryContents -Times 0 -Exactly
    }
}

Describe 'Developer cache rows wait for their owner' {
    BeforeEach {
        $env:LOCALAPPDATA = Join-Path $TestDrive 'Local'
        $env:APPDATA = Join-Path $TestDrive 'Roaming'
        New-Item -ItemType Directory -Force -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio\17.0_ab\ComponentModelCache') | Out-Null
        Mock Clear-MoleAppCache {}
        Mock Clear-DirectoryContents {}
        Mock Invoke-MoleOwnerCacheCleanup {}
        Mock Get-MoleOwnerCachePath { Join-Path $TestDrive 'gomod' }
    }
    It 'Routes <Row> through the owner guard for <Owner>' -ForEach @(
        @{ Fn = 'Clear-NodeBuildCaches'; Row = 'node-gyp cache'; Owner = 'node' }
        @{ Fn = 'Clear-NodeBuildCaches'; Row = 'Electron cache'; Owner = 'node' }
        @{ Fn = 'Clear-NodeBuildCaches'; Row = 'TypeScript cache'; Owner = 'Code' }
        @{ Fn = 'Clear-GoCaches'; Row = 'Go module cache'; Owner = 'go' }
        @{ Fn = 'Clear-EditorCaches'; Row = 'Zed cache'; Owner = 'Zed' }
        @{ Fn = 'Clear-IdeCaches'; Row = 'Visual Studio cache'; Owner = 'devenv' }
    ) {
        $wantRow = $Row
        $wantOwner = $Owner
        & $Fn
        Should -Invoke Clear-MoleAppCache -Scope It -ParameterFilter { $Description -eq $wantRow -and $Processes -contains $wantOwner }
        Should -Invoke Clear-DirectoryContents -Scope It -Times 0 -Exactly -ParameterFilter { $Description -eq $wantRow }
    }
}

Describe 'JetBrains caches and index' {
    It 'Cleans caches and index while no IDE runs and keeps Local History whitelisted' {
        $env:LOCALAPPDATA = Join-Path $TestDrive 'JbLocal'
        $env:APPDATA = Join-Path $TestDrive 'JbRoaming'
        $ide = Join-Path $env:LOCALAPPDATA 'JetBrains\IntelliJIdea2026.2'
        New-Item -ItemType Directory -Force -Path (Join-Path $ide 'caches'), (Join-Path $ide 'index'), (Join-Path $ide 'LocalHistory'), (Join-Path $ide 'log') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $env:APPDATA 'JetBrains\IntelliJIdea2026.2\caches') | Out-Null
        Mock Clear-MoleAppCache {}
        Mock Clear-DirectoryContents {}
        Clear-IdeCaches
        Should -Invoke Clear-MoleAppCache -Times 1 -Exactly -ParameterFilter { $Path -eq (Join-Path $ide 'caches') -and $Processes -contains 'idea64' }
        Should -Invoke Clear-MoleAppCache -Times 1 -Exactly -ParameterFilter { $Path -eq (Join-Path $ide 'index') -and $Processes -contains 'rider64' }
        Should -Invoke Clear-MoleAppCache -Times 0 -Exactly -ParameterFilter { $Path -like '*\LocalHistory' -or $Path -like '*\log' -or $Path -like "$env:APPDATA*" }
        Should -Invoke Clear-DirectoryContents -Times 0 -Exactly -ParameterFilter { $Path -like '*JetBrains*' }
    }
    It 'Whitelists Local History and Toolbox, not caches or index, under the JetBrains system folder' {
        $savedWhitelist = $script:Config.WhitelistFile
        $script:Config.WhitelistFile = Join-Path $TestDrive 'no-whitelist.txt'
        try { $state = Get-WhitelistState }
        finally { $script:Config.WhitelistFile = $savedWhitelist }
        $ide = Join-Path $script:SavedLocalAppData 'JetBrains\IntelliJIdea2026.2'
        Test-Whitelisted -Path (Join-Path $ide 'LocalHistory\changes.storageData') -State $state | Should -BeTrue
        Test-Whitelisted -Path (Join-Path $ide 'caches\content.dat') -State $state | Should -BeFalse
        Test-Whitelisted -Path (Join-Path $ide 'index\x') -State $state | Should -BeFalse
        # Toolbox's folder holds the IDEs it installed, so uninstalling Toolbox never recycles it.
        Test-Whitelisted -Path (Join-Path $script:SavedLocalAppData 'JetBrains\Toolbox\apps\IDEA-U') -State $state | Should -BeTrue
    }
}

Describe 'Epic Games webcache generations' {
    It 'Offers every webcache folder once and skips a linked one' {
        $env:LOCALAPPDATA = Join-Path $TestDrive 'EpicLocal'
        $saved = Join-Path $env:LOCALAPPDATA 'EpicGamesLauncher\Saved'
        New-Item -ItemType Directory -Force -Path (Join-Path $saved 'webcache'), (Join-Path $saved 'webcache_4147'), (Join-Path $saved 'Config') | Out-Null
        $outside = Join-Path $TestDrive 'EpicOutside'
        New-Item -ItemType Directory -Force -Path $outside | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $saved 'webcache_linked') -Target $outside | Out-Null
        Mock Clear-MoleAppCache {}
        Mock Clear-MoleOwnerLogs {}
        Clear-GamingPlatformCaches
        Should -Invoke Clear-MoleAppCache -Times 1 -Exactly -ParameterFilter { $Path -eq (Join-Path $saved 'webcache') }
        Should -Invoke Clear-MoleAppCache -Times 1 -Exactly -ParameterFilter { $Path -eq (Join-Path $saved 'webcache_4147') -and $Processes -contains 'EpicGamesLauncher' }
        Should -Invoke Clear-MoleAppCache -Times 0 -Exactly -ParameterFilter { $Path -like '*\Config' }
        Should -Invoke Clear-MoleAppCache -Times 0 -Exactly -ParameterFilter { $Path -like '*\webcache_linked' }
    }
}

Describe 'Office and Google Drive temp files' {
    BeforeEach {
        $env:LOCALAPPDATA = Join-Path $TestDrive 'TmpLocal'
        $env:APPDATA = Join-Path $TestDrive 'TmpRoaming'
        # The callback runs while the row's scope is alive, as the real sink calls it.
        $script:OwnerNames = @()
        $script:Idle = $null
        Mock Test-MoleCacheOwnerIdle { $script:OwnerNames += $Names; $true }
        Mock Remove-SafeItems { $script:Idle = & $CanRemove }
        Mock Clear-DirectoryContents {}
        Mock Remove-OldFiles {}
    }
    It 'Takes Drive temp files only, held while Drive runs' {
        $drive = Join-Path $env:LOCALAPPDATA 'Google\DriveFS'
        New-Item -ItemType Directory -Force -Path (Join-Path $drive 'cache.tmp') | Out-Null
        Set-Content -LiteralPath (Join-Path $drive 'upload.tmp') -Value 'x'
        Clear-GoogleDriveCache
        Should -Invoke Remove-SafeItems -Times 1 -Exactly -ParameterFilter {
            @($Paths).Count -eq 1 -and $Paths[0] -like '*\upload.tmp' -and $null -ne $CanRemove
        }
        $script:Idle | Should -BeTrue
        $script:OwnerNames | Should -Contain 'GoogleDriveFS'
    }
    It 'Holds Office temp files while an Office app runs' {
        $word = Join-Path $env:APPDATA 'Microsoft\Word'
        New-Item -ItemType Directory -Force -Path $word | Out-Null
        Set-Content -LiteralPath (Join-Path $word '~WRL0001.tmp') -Value 'x'
        Clear-OfficeCache
        Should -Invoke Remove-SafeItems -Times 1 -Exactly -ParameterFilter { $null -ne $CanRemove }
        $script:Idle | Should -BeTrue
        foreach ($app in 'WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK') { $script:OwnerNames | Should -Contain $app }
    }
}

Describe 'System cleanup and crash dumps' {
    It 'Leaves CrashDumps to the aged user rule' {
        $env:LOCALAPPDATA = Join-Path $TestDrive 'DumpLocal'
        $dumps = Join-Path $env:LOCALAPPDATA 'CrashDumps'
        New-Item -ItemType Directory -Force -Path $dumps | Out-Null
        Set-Content -LiteralPath (Join-Path $dumps 'app.exe.1.dmp') -Value 'fresh'
        Mock Test-IsAdmin { $true }
        Mock Clear-WindowsLogs {}
        Mock Clear-InstallerCache {}
        Mock Clear-NvidiaDriverInstallers {}
        Mock Clear-DeliveryOptimizationFiles {}
        Mock Clear-DirectoryContents {}
        Mock Remove-SafeItems {}
        Invoke-SystemCleanup
        Should -Invoke Clear-DirectoryContents -Times 0 -Exactly -ParameterFilter { $Path -like '*\CrashDumps' }
    }
}

Describe 'Windows Installer wait before an MSI uninstall' {
    It 'Reads a held installer mutex as busy and a missing one as idle' {
        $name = 'Local\mole-msi-test-' + [guid]::NewGuid().ToString('N')
        Test-MoleInstallerBusy -Name $name | Should -BeFalse
        $held = [Threading.Mutex]::new($false, $name)
        try { Test-MoleInstallerBusy -Name $name | Should -BeTrue }
        finally { $held.Dispose() }
        Test-MoleInstallerBusy -Name $name | Should -BeFalse
    }
    It 'Polls until the installer is idle' {
        $script:BusyCalls = 0
        Mock Test-MoleInstallerBusy { $script:BusyCalls++; $script:BusyCalls -le 2 }
        Mock Start-Sleep {}
        Wait-MoleInstallerIdle -PollMilliseconds 1
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }
    It 'Waits only before an MSI launch, right before the uninstaller runs' {
        $calls = $script:UninstallAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Wait-MoleInstallerIdle'
        }, $true)
        @($calls).Count | Should -Be 1
        $guard = $calls[0].Parent
        while ($guard -and $guard -isnot [Management.Automation.Language.IfStatementAst]) { $guard = $guard.Parent }
        $guard | Should -Not -BeNullOrEmpty
        $guard.Clauses[0].Item1.Extent.Text | Should -Match "Get-MoleProperty \`$launch 'Kind'\) -eq 'msi'"
    }
}
