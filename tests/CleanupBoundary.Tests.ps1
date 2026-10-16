# Real file mutations below are restricted to Pester's temporary TestDrive.
BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . "$script:RepoRoot\lib\core\base.ps1"
    . "$script:RepoRoot\lib\core\log.ps1"
    . "$script:RepoRoot\lib\core\file_ops.ps1"
    . "$script:RepoRoot\lib\clean\dev.ps1"
    function Set-SectionActivity { }
}

Describe 'Cleanup physical boundaries' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root | Out-Null
        $script:SavedWhitelist = $script:Config.WhitelistFile
        $script:Config.WhitelistFile = Join-Path $script:Root 'whitelist.txt'
        Set-DryRunMode -Enabled $false
    }
    AfterEach {
        $script:Config.WhitelistFile = $script:SavedWhitelist
        Set-DryRunMode -Enabled $true
    }
    It 'Keeps the contents of a junction used as a cache root' {
        $target = Join-Path $script:Root 'target'
        New-Item -ItemType Directory -Path $target | Out-Null
        $sentinel = Join-Path $target 'keep.txt'
        Set-Content -LiteralPath $sentinel -Value 'keep'
        $link = Join-Path $script:Root 'cache'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Clear-DirectoryContents -Path $link
        Test-Path -LiteralPath $sentinel | Should -BeTrue
    }
    It 'Keeps a file reached through a junction ancestor' {
        $target = Join-Path $script:Root 'target'
        New-Item -ItemType Directory -Path $target | Out-Null
        $sentinel = Join-Path $target 'keep.txt'
        Set-Content -LiteralPath $sentinel -Value 'keep'
        $link = Join-Path $script:Root 'cache'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Remove-SafeItem -Path (Join-Path $link 'keep.txt') | Should -BeFalse
        Test-Path -LiteralPath $sentinel | Should -BeTrue
    }
    It 'Keeps an old file reached through a junction cleanup root' {
        $target = Join-Path $script:Root 'target'
        New-Item -ItemType Directory -Path $target | Out-Null
        $sentinel = Join-Path $target 'keep.txt'
        Set-Content -LiteralPath $sentinel -Value 'keep'
        (Get-Item -LiteralPath $sentinel).LastWriteTime = (Get-Date).AddDays(-30)
        $link = Join-Path $script:Root 'cache'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Remove-OldFiles -Path $link
        Test-Path -LiteralPath $sentinel | Should -BeTrue
    }
    It 'Keeps a replacement directory installed during sizing' {
        $script:Cache = Join-Path $script:Root 'cache'
        New-Item -ItemType Directory -Path $script:Cache | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Cache 'same.txt') -Value 'original'
        Mock Get-ValidatedTreeSize {
            Move-Item -LiteralPath $script:Cache -Destination (Join-Path $script:Root 'original')
            New-Item -ItemType Directory -Path $script:Cache | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Cache 'same.txt') -Value 'replacement'
            return 8
        }
        Remove-SafeItem -Path $script:Cache -Recurse | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $script:Cache 'same.txt') | Should -Be 'replacement'
    }
    It 'Keeps a deletion target when an existing whitelist cannot be read' {
        $cache = Join-Path $script:Root 'retained.txt'
        Set-Content -LiteralPath $cache -Value 'keep'
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value $cache
        Mock Get-Content { Write-Error 'Access denied' } -ParameterFilter {
            $LiteralPath -eq $script:Config.WhitelistFile -or $Path -eq $script:Config.WhitelistFile
        }
        Remove-SafeItem -Path $cache | Should -BeFalse
        Test-Path -LiteralPath $cache | Should -BeTrue
    }
    It 'Refuses unknown whitelist metadata rather than treating it as missing' {
        Mock Get-Item { throw [System.UnauthorizedAccessException]::new('denied') } -ParameterFilter {
            $LiteralPath -eq $script:Config.WhitelistFile
        }
        Test-SafePath -Path (Join-Path $script:Root 'cache.bin') | Should -BeFalse
    }
    It 'Reads a literal bracket-containing whitelist filename' {
        $script:Config.WhitelistFile = Join-Path $script:Root '[rules].txt'
        $cache = Join-Path $script:Root 'cache'
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value $cache
        Test-SafePath -Path (Join-Path $cache 'keep.txt') | Should -BeFalse
    }
    It 'Still removes an ordinary cache directory' {
        $cache = Join-Path $script:Root 'cache'
        New-Item -ItemType Directory -Path $cache | Out-Null
        Set-Content -LiteralPath (Join-Path $cache 'data.bin') -Value 'cache'
        Remove-SafeItem -Path $cache -Recurse | Should -BeTrue
        Test-Path -LiteralPath $cache | Should -BeFalse
    }
    It 'Reads the whitelist once for a whole tree, not once per child' {
        $tree = Join-Path $script:Root 'tree'
        New-Item -ItemType Directory -Path $tree | Out-Null
        1..12 | ForEach-Object { Set-Content -LiteralPath (Join-Path $tree "f$_.txt") -Value 'x' }
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value '# no exclusions'
        $script:WhitelistReads = 0
        Mock Get-Content { $script:WhitelistReads++; @('# no exclusions') } -ParameterFilter {
            $LiteralPath -eq $script:Config.WhitelistFile
        }
        (Get-SafeDirectoryTreeItems -Path $tree).Success | Should -BeTrue
        $script:WhitelistReads | Should -Be 1
    }
    It 'Still retains a whole tree when the whitelist cannot be read' {
        $tree = Join-Path $script:Root 'tree'
        New-Item -ItemType Directory -Path $tree | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'a.txt') -Value 'x'
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value '# present but unreadable'
        Mock Get-Content { Write-Error 'Access denied' } -ParameterFilter {
            $LiteralPath -eq $script:Config.WhitelistFile
        }
        (Get-SafeDirectoryTreeItems -Path $tree).Success | Should -BeFalse
    }
    It 'Protects children of a literal directory whitelist without covering a prefix sibling' {
        $cache = Join-Path $script:Root 'cache'
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value $cache
        Test-Whitelisted -Path (Join-Path $cache 'nested\data.bin') | Should -BeTrue
        Test-Whitelisted -Path (Join-Path $script:Root 'cache-other\data.bin') | Should -BeFalse
    }
}


Describe 'Tree walk snapshots' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path "$script:Root\a\b\c", "$script:Root\d" -Force | Out-Null
        'x' | Set-Content "$script:Root\a\f.txt"
        'x' | Set-Content "$script:Root\a\b\c\deep.txt"
        New-Item -ItemType Junction -Path "$script:Root\link" -Target "$script:Root\d" | Out-Null
    }
    It 'Binds every item to the same chain a fresh snapshot of its path would' {
        $items = @(Get-TreeItemsNoFollow -Path $script:Root)
        $items.Count | Should -BeGreaterThan 5
        foreach ($item in $items) {
            $fresh = Get-MolePathSnapshot -Path $item.FullName -AllowLeafLink
            $bound = $item.MolePathSnapshot
            $bound.Path | Should -Be $fresh.Path
            $bound.AllowLeafLink | Should -Be $fresh.AllowLeafLink
            @($bound.Entries.Keys | Sort-Object) | Should -Be @($fresh.Entries.Keys | Sort-Object) -Because $item.FullName
            foreach ($key in $fresh.Entries.Keys) { $bound.Entries[$key] | Should -Be $fresh.Entries[$key] -Because $key }
        }
    }
    It 'Binds the root once and each child from its parent instead of reopening every ancestor' {
        $script:RealSnapshot = ${function:Get-MolePathSnapshot}
        $script:SnapshotCalls = 0
        Mock Get-MolePathSnapshot {
            $script:SnapshotCalls++
            & $script:RealSnapshot -Path $Path -AllowLeafLink:$AllowLeafLink
        }
        $items = @(Get-TreeItemsNoFollow -Path $script:Root)
        $items.Count | Should -BeGreaterThan 5
        # The root once, plus the recheck of each directory entered; no call per child.
        $entered = 1 + @($items | Where-Object { $_.PSIsContainer -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 }).Count
        $script:SnapshotCalls | Should -Be (1 + $entered)
    }
    It 'Lists a junction as a link and does not walk into it' {
        $items = @(Get-TreeItemsNoFollow -Path $script:Root)
        @($items | Where-Object { $_.FullName -like "$script:Root\link*" }).Count | Should -Be 1
    }
    It 'Fails the recheck when a directory is replaced after the walk' {
        $items = @(Get-TreeItemsNoFollow -Path $script:Root)
        $target = $items | Where-Object { $_.FullName -eq "$script:Root\a\b\c\deep.txt" }
        Test-MolePathSnapshot $target.MolePathSnapshot | Should -BeTrue
        Rename-Item "$script:Root\a\b" 'b-old'
        New-Item -ItemType Directory -Path "$script:Root\a\b\c" -Force | Out-Null
        'x' | Set-Content "$script:Root\a\b\c\deep.txt"
        Test-MolePathSnapshot $target.MolePathSnapshot | Should -BeFalse
    }
}

Describe 'Whitelist state matches the per-pattern rule' {
    BeforeEach {
        $script:SavedWhitelist = $script:Config.WhitelistFile
        $script:Config.WhitelistFile = Join-Path $TestDrive 'state-whitelist.txt'
    }
    AfterEach { $script:Config.WhitelistFile = $script:SavedWhitelist }
    It 'Agrees with Test-WhitelistPattern for every pattern shape' {
        $user = @(
            'C:\Data\Cache', 'C:\Data\Tail\', 'C:\Data\*\tmp', 'C:\Data\[a]b', 'C:\Data\a?c',
            'C:\Data\back`tick', 'c:\data\MIXED case', '# a comment', '', '   C:\Data\Padded   '
        )
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value $user
        $paths = @(
            'C:\Data\Cache', 'C:\Data\Cache\', 'C:\Data\Cache\child.bin', 'C:\Data\Cache-other\child.bin',
            'C:\Data\Tail', 'C:\Data\Tail\x', 'C:\Data\Tailor', 'C:\Data\one\tmp', 'C:\Data\one\two\tmp',
            'C:\Data\ab', 'C:\Data\[a]b', 'C:\Data\abc', 'C:\Data\a-c', 'C:\Data\back`tick', 'C:\Data\backtick',
            'C:\DATA\mixed CASE\x', 'C:\Data\Padded\x', 'C:\Data\Unrelated', 'D:\Data\Cache'
        )
        $state = Get-WhitelistState
        $reference = @($script:DefaultWhitelistPatterns | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) }) +
            @('C:\Data\Cache', 'C:\Data\Tail\', 'C:\Data\*\tmp', 'C:\Data\[a]b', 'C:\Data\a?c', 'C:\Data\back`tick',
              'c:\data\MIXED case', 'C:\Data\Padded')
        foreach ($path in $paths) {
            $expected = $false
            foreach ($pattern in $reference) {
                if (Test-WhitelistPattern -Path $path -Pattern $pattern) { $expected = $true; break }
            }
            (Test-Whitelisted -Path $path -State $state) | Should -Be $expected -Because $path
            (Test-Whitelisted -Path $path) | Should -Be $expected -Because "$path without a prepared state"
        }
        # The comparison must have both outcomes, or it proves nothing.
        @($paths | Where-Object { Test-Whitelisted -Path $_ -State $state }).Count | Should -BeGreaterThan 5
        @($paths | Where-Object { -not (Test-Whitelisted -Path $_ -State $state) }).Count | Should -BeGreaterThan 3
    }
}

Describe 'Literal bracket whitelist paths' {
    It 'Protects the exact bracket path and its children without matching siblings' {
        $root = Join-Path $TestDrive '[demo]\cache'
        Test-WhitelistPattern $root $root | Should -BeTrue
        Test-WhitelistPattern ($root + '\keep.txt') $root | Should -BeTrue
        Test-WhitelistPattern ($root + '-other\keep.txt') $root | Should -BeFalse
        Test-WhitelistPattern (Join-Path $TestDrive 'other\cache') (Join-Path $TestDrive '*\cache') | Should -BeTrue
    }
}

Describe 'Owner cache cleanup whitelist' {
    BeforeAll {
        function npm { }
        function pnpm { }
        function pip { }
        function go { }
        function mise { }
        function docker { }
        # Resolution is a read-only probe; the fallback lets the old implementation
        # run so each assertion observes its mutation instead of a missing command.
        if (-not (Get-Command Get-MoleOwnerCachePath -ErrorAction SilentlyContinue)) {
            function Get-MoleOwnerCachePath { param($Name,$Arguments) $null }
        }
    }
    BeforeEach {
        $script:OwnerRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:OwnerRoot | Out-Null
        $script:SavedOwnerWhitelist = $script:Config.WhitelistFile
        $script:SavedOwnerLocal = $env:LOCALAPPDATA
        $script:SavedOwnerProfile = $env:USERPROFILE
        $script:SavedOwnerApp = $env:APPDATA
        $script:SavedOwnerGo = $env:GOPATH
        $script:SavedOwnerMise = $env:MISE_CACHE_DIR
        $env:LOCALAPPDATA = $script:OwnerRoot
        $env:USERPROFILE = $script:OwnerRoot
        $env:APPDATA = $script:OwnerRoot
        $env:GOPATH = $script:OwnerRoot
        $script:Config.WhitelistFile = Join-Path $script:OwnerRoot 'whitelist.txt'
        $script:OwnerCache = Join-Path $script:OwnerRoot 'cache'
        New-Item -ItemType Directory -Path $script:OwnerCache | Out-Null
        $env:MISE_CACHE_DIR = $script:OwnerCache
        New-Item -ItemType Directory -Path (Join-Path $script:OwnerRoot 'pnpm\store') -Force | Out-Null
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value $script:OwnerCache
        Mock Get-MoleOwnerCachePath { $script:OwnerCache }
        Mock Invoke-MoleOwnerProcess { [pscustomobject]@{ Output = '' } }
        Mock npm { $global:LASTEXITCODE=0 }
        Mock pnpm { $global:LASTEXITCODE=0 }
        Mock pip { $global:LASTEXITCODE=0 }
        Mock go { $global:LASTEXITCODE=0 }
        Mock mise { $global:LASTEXITCODE=0; $script:OwnerCache }
        Mock docker { $global:LASTEXITCODE=0 }
        Set-DryRunMode -Enabled $false
    }
    AfterEach {
        $script:Config.WhitelistFile = $script:SavedOwnerWhitelist
        $env:LOCALAPPDATA = $script:SavedOwnerLocal
        $env:USERPROFILE = $script:SavedOwnerProfile
        $env:APPDATA = $script:SavedOwnerApp
        $env:GOPATH = $script:SavedOwnerGo
        $env:MISE_CACHE_DIR = $script:SavedOwnerMise
        Set-DryRunMode -Enabled $true
    }
    It 'Does not invoke npm or pnpm mutations for a whitelisted resolved root' {
        Clear-NpmCache
        Should -Invoke Invoke-MoleOwnerProcess -Times 0
        Should -Invoke npm -Times 0 -ParameterFilter { $args -contains 'clean' }
        Should -Invoke pnpm -Times 0 -ParameterFilter { $args -contains 'prune' }
    }
    It 'Does not invoke pip purge for a whitelisted resolved root' {
        Clear-PythonCaches
        Should -Invoke Invoke-MoleOwnerProcess -Times 0
        Should -Invoke pip -Times 0 -ParameterFilter { $args -contains 'purge' }
    }
    It 'Does not invoke go clean for a whitelisted resolved root' {
        Clear-GoCaches
        Should -Invoke Invoke-MoleOwnerProcess -Times 0
        Should -Invoke go -Times 0 -ParameterFilter { $args -contains 'clean' }
    }
    It 'Does not invoke mise clear for a whitelisted resolved root' {
        Clear-MiseCache
        Should -Invoke Invoke-MoleOwnerProcess -Times 0
        Should -Invoke mise -Times 0 -ParameterFilter { $args -contains 'clear' }
    }
    It 'Runs an owner for a known unprotected ordinary cache' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value '# no exclusions'
        Invoke-MoleOwnerCacheCleanup -Name 'npm' -Query @('config','get','cache') -Arguments @('cache','clean','--force') -Description 'fixture'
        Should -Invoke Invoke-MoleOwnerProcess -Times 1 -ParameterFilter { $TimeoutSeconds -eq 120 }
    }
    It 'Keeps a cache containing a specifically whitelisted child' {
        $child = Join-Path $script:OwnerCache 'keep.txt'
        Set-Content -LiteralPath $child -Value 'keep'
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value $child
        Invoke-MoleOwnerCacheCleanup -Name 'npm' -Query @('config','get','cache') -Arguments @('cache','clean','--force') -Description 'fixture'
        Should -Invoke Invoke-MoleOwnerProcess -Times 0
    }
    It 'Keeps a cache when its owner cannot resolve the root' {
        Mock Get-MoleOwnerCachePath { $null }
        Clear-NpmCache
        Should -Invoke Invoke-MoleOwnerProcess -Times 0
    }
    It 'Preserves Gradle transaction locks' {
        $lock = Join-Path $env:USERPROFILE '.gradle\caches\build-cache-1\build-cache-1.lock'
        New-Item -ItemType Directory -Path (Split-Path -Parent $lock) -Force | Out-Null
        Set-Content -LiteralPath $lock -Value 'lock'
        Clear-JvmCaches
        Test-Path -LiteralPath $lock | Should -BeTrue
    }
    It 'Keeps Docker builders whose mutation cannot be mapped to whitelist paths' {
        Clear-DockerCaches
        Should -Invoke docker -Times 0
        Should -Invoke Invoke-MoleOwnerProcess -Times 0
    }
}

Describe 'Bounded owner process execution' {
    BeforeEach {
        $script:ProcessFixture = Join-Path $TestDrive ('owner tools ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ProcessFixture | Out-Null
        $script:OwnerCommand = Join-Path $script:ProcessFixture 'fixture.cmd'
    }
    It 'Captures an actual read-only owner response with a spaced executable path' {
        Set-Content -LiteralPath $script:OwnerCommand -Encoding ASCII -Value @('@echo off', 'echo fixture-cache-root', 'exit /b 0')
        $result = Invoke-MoleOwnerProcess -Name $script:OwnerCommand -Arguments @('query')
        $result.Output | Should -Be 'fixture-cache-root'
    }
    It 'Rejects an actual nonzero owner exit even when stdout looks like a path' {
        Set-Content -LiteralPath $script:OwnerCommand -Encoding ASCII -Value @('@echo off', 'echo C:\looks-like-a-cache', 'exit /b 9')
        Invoke-MoleOwnerProcess -Name $script:OwnerCommand -Arguments @('query') | Should -BeNullOrEmpty
    }
    It 'Bounds a slow owner and terminates its sleeping child' {
        $owner = Join-Path $script:ProcessFixture 'sleep.ps1'
        # Record the child PID in its parent, before the child's PowerShell
        # startup. CI can exhaust a short budget before a cold child runs code.
        Set-Content -LiteralPath $owner -Encoding ASCII -Value @(
            '$child = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList "-NoProfile -NonInteractive -Command Start-Sleep -Seconds 60" -PassThru',
            'Set-Content -LiteralPath (Join-Path $PSScriptRoot "child.pid") -Value @($child.Id, $child.StartTime.ToUniversalTime().Ticks)',
            '$child.WaitForExit()'
        )
        $pidFile = Join-Path $script:ProcessFixture 'child.pid'
        $timer = [Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-MoleOwnerProcess -Name $owner -Arguments @() -TimeoutSeconds 10 | Should -BeNullOrEmpty
            $timer.Stop()
            $timer.Elapsed.TotalSeconds | Should -BeLessThan 20
            Test-Path -LiteralPath $pidFile | Should -BeTrue
            $childId = [int](@(Get-Content -LiteralPath $pidFile)[0])
            Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
        finally {
            if (Test-Path -LiteralPath $pidFile) {
                # Only the process created by this fixture is eligible for cleanup.
                $receipt = @(Get-Content -LiteralPath $pidFile)
                $remaining = Get-Process -Id ([int]$receipt[0]) -ErrorAction SilentlyContinue
                if ($remaining -and $remaining.StartTime.ToUniversalTime().Ticks -eq [long]$receipt[1]) {
                    $remaining.Kill()
                }
            }
        }
    }
}
