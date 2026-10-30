BeforeAll {
    $script:SavedDryRun = $env:MOLE_DRY_RUN
    $script:ProjectRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:ProjectRoot 'lib\core\update_check.ps1')
    function Get-CachePath { $TestDrive }
    function Test-MoleInteractiveOutput { $false }
}

AfterAll { $env:MOLE_DRY_RUN = $script:SavedDryRun }

Describe 'Automatic update notices' {
    BeforeEach {
        $env:MOLE_DRY_RUN = $null
        $script:CacheFile = Join-Path $TestDrive 'update-check.json'
        $script:Context = @{ Path = $script:CacheFile; Key = 'fixture|1.9.0|Source'; Version = '1.9.0'; Method = 'Source' }
        $script:State = @{ Schema = 1; Key = $script:Context.Key; CheckedTicks = [DateTime]::UtcNow.Ticks; Interval = 86400; Latest = '1.10.0' }
        Write-MoleUpdateState -Path $script:CacheFile -State $script:State
    }

    It 'Selects published Windows stable tags numerically, never names or macOS latest' {
        Mock Invoke-RestMethod {
            @(
                @{ tag_name = 'V9.99.0'; draft = $false; prerelease = $false },
                @{ tag_name = 'V1.99.0-windows'; draft = $true; prerelease = $false },
                @{ tag_name = 'V1.98.0-windows'; draft = $false; prerelease = $true },
                @{ tag_name = 'V1.97.0-beta-windows'; draft = $false; prerelease = $false },
                @{ tag_name = 'V1.9.0-windows'; draft = $false; prerelease = $false },
                @{ tag_name = 'V1.10.0-windows'; name = 'Horizon'; draft = $false; prerelease = $false }
            )
        }
        Get-MoleAvailableVersion -Method Source | Should -Be '1.10.0'
        Should -Invoke Invoke-RestMethod -Exactly 1 -ParameterFilter { $Uri -eq 'https://api.github.com/repos/tw93/Mole/releases?per_page=100' -and $TimeoutSec -eq 10 }
    }

    It 'Reads Scoop version from its published manifest' {
        Mock Invoke-RestMethod { @{ version = '1.8.0' } }
        Get-MoleAvailableVersion -Method Scoop | Should -Be '1.8.0'
        Should -Invoke Invoke-RestMethod -Exactly 1 -ParameterFilter { $Uri -like '*ScoopInstaller/Main/*/bucket/mole.json' }
    }

    It 'Reads winget published version directories and ignores preview entries' {
        Mock Invoke-RestMethod { @(@{ type = 'dir'; name = '1.9.0' }, @{ type = 'dir'; name = '1.10.0' }, @{ type = 'dir'; name = '1.11.0-beta' }, @{ type = 'file'; name = '9.0.0' }) }
        Get-MoleAvailableVersion -Method winget | Should -Be '1.10.0'
    }

    It 'Uses the channel-specific update action for <Method>' -ForEach @(
        @{ Method = 'Source'; Action = 'run mo update' },
        @{ Method = 'winget'; Action = 'run winget upgrade tw93.MoleCLI' },
        @{ Method = 'Scoop'; Action = 'run scoop update mole' },
        @{ Method = 'Portable'; Action = 'download https://github.com/tw93/Mole/releases/tag/V1.10.0-windows' }
    ) {
        $script:Context.Method = $Method
        Get-MoleUpdateNotice -Context $script:Context | Should -Be "Update 1.10.0 available, $Action"
    }

    It 'Never advertises an equal, older, prerelease or invalid version <Latest>' -ForEach @(
        @{ Latest = '1.9.0' }, @{ Latest = '1.8.9' }, @{ Latest = '1.10.0-beta' }, @{ Latest = "1.10.0`nrun something" }
    ) {
        $script:State.Latest = $Latest
        Write-MoleUpdateState -Path $script:CacheFile -State $script:State
        Get-MoleUpdateNotice -Context $script:Context | Should -BeNullOrEmpty
    }

    It 'Invalidates notices for a changed installation, version or channel' {
        $script:Context.Key = 'other|1.10.0|Scoop'
        Get-MoleUpdateNotice -Context $script:Context | Should -BeNullOrEmpty
    }

    It 'Ignores corrupt cache data without affecting the command' {
        [IO.File]::WriteAllText($script:CacheFile, '{broken')
        { Show-MoleUpdateNotice -Context $script:Context } | Should -Not -Throw
        Get-MoleUpdateNotice -Context $script:Context | Should -BeNullOrEmpty
    }

    It 'Suppresses expired and future-dated notices' {
        foreach ($days in @(-2, 1)) {
            $script:State.CheckedTicks = [DateTime]::UtcNow.AddDays($days).Ticks
            Write-MoleUpdateState -Path $script:CacheFile -State $script:State
            Get-MoleUpdateNotice -Context $script:Context | Should -BeNullOrEmpty
        }
    }

    It 'Does not perform network work while reading a fresh cached notice' {
        Mock Invoke-RestMethod { throw 'unexpected network request' }
        $script:State.Key = 'fixture|1.9.0|Source'
        $context = Start-MoleUpdateCheck -RootDir fixture -Version '1.9.0' -Method Source
        Get-MoleUpdateNotice -Context $context | Should -Match '1.10.0'
        Should -Invoke Invoke-RestMethod -Exactly 0
    }

    It 'Starts update lookup with the current PowerShell host' {
        $root = Join-Path $TestDrive ('worker-' + [guid]::NewGuid().ToString('N'))
        $module = Join-Path $root 'lib\core\update_check.ps1'
        New-Item -ItemType Directory -Path (Split-Path $module) -Force | Out-Null
        # No network: the worker writes only inside this test's owned tree.
        Set-Content -LiteralPath $module -Value 'function Invoke-MoleUpdateLookup { param($Path,$Key,$Method) [IO.File]::WriteAllText($Path + ".host", $PSHOME) }'
        Mock Join-Path { throw 'Windows PowerShell path is blocked' } -ParameterFilter {
            $Path -eq $env:SystemRoot -and $ChildPath -eq 'System32\WindowsPowerShell\v1.0\powershell.exe'
        }
        $previousError = if ($Error.Count) { $Error[0] } else { $null }
        $context = Start-MoleUpdateCheck -RootDir $root -Version '1.9.0' -Method Source
        $startupError = 'no captured startup error'
        if ($Error.Count -and -not [object]::ReferenceEquals($previousError, $Error[0])) {
            $failure = $Error[0]
            $startupError = '{0}: {1} (line {2})' -f $failure.Exception.GetType().FullName, $failure.Exception.Message, $failure.InvocationInfo.ScriptLineNumber
        }
        $context | Should -Not -BeNullOrEmpty -Because $startupError
        $marker = $context.Path + '.host'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $marker) -and $clock.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 50 }
        Get-Content -LiteralPath $marker -Raw | Should -Be $PSHOME
    }

    It 'Keeps a failed lookup quiet and retains its one-hour retry interval' {
        $script:State.Interval = 3600
        $script:State.Latest = ''
        Write-MoleUpdateState -Path $script:CacheFile -State $script:State
        Mock Invoke-RestMethod { throw 'offline' }
        { Invoke-MoleUpdateLookup -Path $script:CacheFile -Key $script:Context.Key -Method Source } | Should -Not -Throw
        (Read-MoleUpdateState -Path $script:CacheFile -Key $script:Context.Key).Interval | Should -Be 3600
        Get-MoleUpdateNotice -Context $script:Context | Should -BeNullOrEmpty
    }

    It 'Caches a successful lookup for a day' {
        Mock Get-MoleAvailableVersion { '1.11.0' }
        Invoke-MoleUpdateLookup -Path $script:CacheFile -Key $script:Context.Key -Method Source
        $state = Read-MoleUpdateState -Path $script:CacheFile -Key $script:Context.Key
        $state.Interval | Should -Be 86400
        $state.Latest | Should -Be '1.11.0'
    }

    It 'Never enables automatic checks for redirected commands' {
        Mock Test-MoleInteractiveOutput { $false }
        Test-MoleUpdateNoticeAllowed -CommandName clean -Arguments @() | Should -BeFalse
    }

    It 'Allows an interactive menu and ordinary clean command' {
        Mock Test-MoleInteractiveOutput { $true }
        # This predicate does not substitute a redirected stderr for a terminal.
        if (-not [Console]::IsErrorRedirected) {
            Test-MoleUpdateNoticeAllowed -CommandName '' -Arguments @() | Should -BeTrue
            Test-MoleUpdateNoticeAllowed -CommandName clean -Arguments @() | Should -BeTrue
        }
        else {
            Test-MoleUpdateNoticeAllowed -CommandName clean -Arguments @() | Should -BeFalse
        }
    }

    It 'Keeps an environment-selected preview read-only' {
        Mock Test-MoleInteractiveOutput { $true }
        $env:MOLE_DRY_RUN = '1'
        Test-MoleUpdateNoticeAllowed -CommandName clean -Arguments @() | Should -BeFalse
    }

    It 'Keeps automation, previews and explicit update paths quiet for <CommandName> <Argument>' -ForEach @(
        @{ CommandName = 'status'; Argument = '--json' },
        @{ CommandName = 'status'; Argument = '--ndjson' },
        @{ CommandName = 'status'; Argument = '--watch=3' },
        @{ CommandName = 'clean'; Argument = '--help' },
        @{ CommandName = 'clean'; Argument = '--dry-run' },
        @{ CommandName = 'clean'; Argument = '--whitelist' },
        @{ CommandName = 'update'; Argument = '' },
        @{ CommandName = 'remove'; Argument = '' },
        @{ CommandName = 'history'; Argument = '--json' }
    ) {
        Mock Test-MoleInteractiveOutput { $true }
        Test-MoleUpdateNoticeAllowed -CommandName $CommandName -Arguments @($Argument) | Should -BeFalse
    }
}
