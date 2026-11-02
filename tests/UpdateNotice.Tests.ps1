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
        # Pester 6 requires an explicit fallback for calls outside the filter.
        # Capture the cmdlet before mocking so forwarding cannot recurse.
        $script:RealUpdateJoinPath = Get-Command Join-Path -CommandType Cmdlet
        Mock Join-Path {
            param($Path, $ChildPath)
            & $script:RealUpdateJoinPath -Path $Path -ChildPath $ChildPath
        }
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

Describe 'Release highlights after mo update' {
    BeforeAll {
        $script:ReleaseBody = @(
            '<div align="center">', '### Changelog', '',
            '1. Browse complete large directories in Analyze: Full entry lists remain available.',
            '2. No duplicate WinMerge entry: Context-menu extensions are no longer listed.',
            '3. Stop waiting indefinitely: A wait longer than 30 minutes stops the batch.',
            '4. Tell same-named projects apart: mo purge shows project paths.',
            '5. Cleaner command output: Singular counts use the correct wording.',
            '', '### Translated changelog', '', '1. Translated title: translated detail.'
        ) -join "`r`n"
    }

    It 'Takes the first changelog titles, cut at the first colon, and stops at the next section' {
        $titles = @(Get-MoleReleaseHighlightTitles -Body $script:ReleaseBody -Limit 4)
        $titles | Should -Be @('Browse complete large directories in Analyze', 'No duplicate WinMerge entry', 'Stop waiting indefinitely', 'Tell same-named projects apart')
        @(Get-MoleReleaseHighlightTitles -Body (($script:ReleaseBody -split "`r`n")[0..4] -join "`n") -Limit 4) | Should -Be @('Browse complete large directories in Analyze', 'No duplicate WinMerge entry')
        @(Get-MoleReleaseHighlightTitles -Body "### Install`n1. Run the installer: once" -Limit 4).Count | Should -Be 0
    }

    It 'Prints the titles and the Windows release link for a published version' {
        Mock Test-MoleReleaseHighlightOutput { $true }
        Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = 'V1.41.0-windows'; body = $script:ReleaseBody } }
        Mock Write-Host { }
        Show-MoleReleaseHighlights -Version '1.41.0'
        Should -Invoke Invoke-RestMethod -Exactly 1 -ParameterFilter { $Uri -eq 'https://api.github.com/repos/tw93/Mole/releases/tags/V1.41.0-windows' -and $TimeoutSec -eq 3 }
        Should -Invoke Write-Host -Exactly 1 -ParameterFilter { "$Object" -eq "What's new in 1.41.0" }
        Should -Invoke Write-Host -Exactly 4 -ParameterFilter { "$Object" -like ('  ' + [char]0x2022 + ' *') }
        Should -Invoke Write-Host -Exactly 1 -ParameterFilter { "$Object" -eq '  https://github.com/tw93/Mole/releases/tag/V1.41.0-windows' }
    }

    It 'Prints nothing and never fails for <Case>' -ForEach @(
        @{ Case = 'redirected output'; Terminal = $false; Version = '1.41.0'; Fails = $false; Body = 'list' }
        @{ Case = 'a version that is not x.y.z'; Terminal = $true; Version = '1.41.0-dev'; Fails = $false; Body = 'list' }
        @{ Case = 'an unpublished tag or no network'; Terminal = $true; Version = '1.41.0'; Fails = $true; Body = 'list' }
        @{ Case = 'a body without the changelog list'; Terminal = $true; Version = '1.41.0'; Fails = $false; Body = 'none' }
    ) {
        $script:CaseFails = $Fails
        $script:CaseTerminal = $Terminal
        $script:CaseBody = if ($Body -eq 'list') { $script:ReleaseBody } else { "### Install`nRun the installer." }
        Mock Test-MoleReleaseHighlightOutput { $script:CaseTerminal }
        Mock Invoke-RestMethod { if ($script:CaseFails) { throw '404 Not Found' }; [pscustomobject]@{ body = $script:CaseBody } }
        Mock Write-Host { }
        { Show-MoleReleaseHighlights -Version $Version } | Should -Not -Throw
        Should -Invoke Write-Host -Exactly 0
        if (-not $Terminal -or $Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { Should -Invoke Invoke-RestMethod -Exactly 0 }
    }
}
