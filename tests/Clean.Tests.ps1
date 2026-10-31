# Mole Windows - Cleanup Module Tests
# Pester tests for lib/clean functionality

BeforeAll {
    # Get the windows directory path (tests are in windows/tests/)
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir "lib"
    
    # Import core modules first
    . "$script:LibDir\core\base.ps1"
    . "$script:LibDir\core\log.ps1"
    . "$script:LibDir\core\ui.ps1"
    . "$script:LibDir\core\file_ops.ps1"
    
    # Import cleanup modules
    . "$script:LibDir\clean\user.ps1"
    . "$script:LibDir\clean\caches.ps1"
    . "$script:LibDir\clean\dev.ps1"
    . "$script:LibDir\clean\apps.ps1"
    . "$script:LibDir\clean\system.ps1"
    
    # Enable dry-run mode for all tests
    $env:MOLE_DRY_RUN = "1"
    Set-DryRunMode -Enabled $true
}

AfterAll {
    $env:MOLE_DRY_RUN = $null
    Set-DryRunMode -Enabled $false
}

Describe "User Cleanup Module" {
    Context "Clear-UserTempFiles" {
        It "Should have Clear-UserTempFiles function" {
            Get-Command Clear-UserTempFiles -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should run without error in dry-run mode" {
            { Clear-UserTempFiles } | Should -Not -Throw
        }
    }
    
    Context "Clear-OldDownloads" {
        It "Should have Clear-OldDownloads function" {
            Get-Command Clear-OldDownloads -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Clear-RecycleBin" {
        It "Should have Clear-RecycleBin function" {
            Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Invoke-UserCleanup" {
        It "Should have main user cleanup function" {
            Get-Command Invoke-UserCleanup -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Cache Cleanup Module" {
    Context "Browser Cache Functions" {
        It "Should have Clear-BrowserCaches function" {
            Get-Command Clear-BrowserCaches -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should run browser cache cleanup without error" {
            { Clear-BrowserCaches } | Should -Not -Throw
        }
    }
    
    Context "Application Cache Functions" {
        It "Should have Clear-AppCaches function" {
            Get-Command Clear-AppCaches -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Developer Tools Cleanup Module" {
    Context "Node.js Cleanup" {
        It "Should have npm cache cleanup function" {
            Get-Command Clear-NpmCache -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Python Cleanup" {
        It "Should have Python cache cleanup function" {
            Get-Command Clear-PythonCaches -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Go Cleanup" {
        It "Should have Go cache cleanup function" {
            Get-Command Clear-GoCaches -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "mise Cleanup" {
        It "Should have mise cache cleanup function" {
            Get-Command Clear-MiseCache -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Rust Cleanup" {
        It "Should have Rust cache cleanup function" {
            Get-Command Clear-RustCaches -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Docker Cleanup" {
        It "Should have Docker cache cleanup function" {
            Get-Command Clear-DockerCaches -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Invoke-DevToolsCleanup" {
        It "Should have main dev tools cleanup function" {
            Get-Command Invoke-DevToolsCleanup -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should run without error in dry-run mode" {
            { Invoke-DevToolsCleanup } | Should -Not -Throw
        }
    }
}

Describe "Bounded developer cache scans" {
    BeforeEach {
        $script:SavedDevProfile = $env:USERPROFILE
        $script:DevHome = Join-Path $TestDrive ("devhome-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path (Join-Path $script:DevHome ".m2\repository\group"), (Join-Path $script:DevHome ".stack\snapshots\pkg") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:DevHome ".m2\repository\group\artifact.jar.lastUpdated") -Value "marker"
        Set-Content -LiteralPath (Join-Path $script:DevHome ".m2\repository\group\artifact.jar") -Value "kept"
        Set-Content -LiteralPath (Join-Path $script:DevHome ".stack\snapshots\pkg\download.tmp") -Value "temp"
        Set-Content -LiteralPath (Join-Path $script:DevHome ".stack\snapshots\pkg\download.tar.gz") -Value "kept"
        $env:USERPROFILE = $script:DevHome
        $script:CollectedPaths = New-Object System.Collections.Generic.List[string]
        Mock Remove-SafeItems {
            param($Paths, $Description)
            foreach ($path in @($Paths)) { $script:CollectedPaths.Add($path) }
        }
    }
    AfterEach {
        $env:USERPROFILE = $script:SavedDevProfile
    }
    It "Keeps the Stack candidate set while bounding the scan" {
        Clear-HaskellCaches
        $script:CollectedPaths | Should -Contain (Join-Path $script:DevHome ".stack\snapshots\pkg\download.tmp")
        $script:CollectedPaths | Should -Not -Contain (Join-Path $script:DevHome ".stack\snapshots\pkg\download.tar.gz")
    }
    It "Removes nothing when a bounded scan is incomplete" {
        Mock Get-FilesWithinBudget { @{ Files = @(); Complete = $false } }
        Clear-HaskellCaches
        $script:CollectedPaths.Count | Should -Be 0
    }
    It "Does not walk the Maven repository the default whitelist protects" {
        # The default whitelist covers everything under ~\.m2\repository, so a
        # .lastUpdated scan there could only spend its 15-second budget.
        $real = Join-Path $script:SavedDevProfile ".m2\repository\group\artifact.jar.lastUpdated"
        Test-SafePath -Path $real | Should -BeFalse
        Mock Get-FilesWithinBudget { @{ Files = @(); Complete = $true } }
        Invoke-DevToolsCleanup
        Should -Invoke Get-FilesWithinBudget -Times 0 -ParameterFilter { $Root -like "*\.m2\*" }
        Test-Path -LiteralPath (Join-Path $script:DevHome ".m2\repository\group\artifact.jar.lastUpdated") | Should -BeTrue
    }
    It "Reports a small tree as completely enumerated" {
        $scan = Get-FilesWithinBudget -Root (Join-Path $script:DevHome ".m2\repository") -Filter "*.lastUpdated" -TimeoutSeconds 15
        $scan.Complete | Should -Be $true
        @($scan.Files).Count | Should -Be 1
    }
}

Describe "Game media enumeration" {
    BeforeEach {
        $script:SavedMediaProfile = $env:USERPROFILE
        $script:MediaHome = Join-Path $TestDrive ("mediahome-" + [guid]::NewGuid().ToString("N"))
        $script:MediaRoot = Join-Path $script:MediaHome "Videos\ShadowPlay"
        New-Item -ItemType Directory -Path $script:MediaRoot -Force | Out-Null
        $oldFile = Join-Path $script:MediaRoot "clip.mp4"
        $oldPhoto = Join-Path $script:MediaRoot "photo.JPG"
        $keptFile = Join-Path $script:MediaRoot "notes.txt"
        Set-Content -LiteralPath $oldFile -Value "video"
        Set-Content -LiteralPath $oldPhoto -Value "photo"
        Set-Content -LiteralPath $keptFile -Value "notes"
        foreach ($path in @($oldFile, $oldPhoto, $keptFile)) {
            (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-120)
        }
        $env:USERPROFILE = $script:MediaHome
        $script:MediaPaths = New-Object System.Collections.Generic.List[string]
        Mock Remove-SafeItems {
            param($Paths, $Description)
            foreach ($path in @($Paths)) { $script:MediaPaths.Add($path) }
        }
    }
    AfterEach {
        $env:USERPROFILE = $script:SavedMediaProfile
    }
    It "Removes only old media files from each root's single enumeration" {
        Clear-GameMediaFiles -DaysOld 90
        $script:MediaPaths | Should -Contain (Join-Path $script:MediaRoot "clip.mp4")
        $script:MediaPaths | Should -Contain (Join-Path $script:MediaRoot "photo.JPG")
        $script:MediaPaths | Should -Not -Contain (Join-Path $script:MediaRoot "notes.txt")
    }
}

Describe "Apps Cleanup Module" {
    Context "Orphan Detection" {
        It "Should have Find-OrphanedAppData function" {
            Get-Command Find-OrphanedAppData -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should have Clear-OrphanedAppData function" {
            Get-Command Clear-OrphanedAppData -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Specific App Cleanup" {
        It "Should have Clear-OfficeCache function" {
            Get-Command Clear-OfficeCache -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
        
        It "Should have Clear-AdobeData function" {
            Get-Command Clear-AdobeData -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Invoke-AppCleanup" {
        It "Should have main app cleanup function" {
            Get-Command Invoke-AppCleanup -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "System Cleanup Module" {
    Context "System Temp" {
        It "Should have Clear-SystemTempFiles function" {
            Get-Command Clear-SystemTempFiles -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Windows Logs" {
        It "Should have Clear-WindowsLogs function" {
            Get-Command Clear-WindowsLogs -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Memory Dumps" {
        It "Should have Clear-MemoryDumps function" {
            Get-Command Clear-MemoryDumps -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Admin Requirements" {
        It "Should check for admin when needed" {
            # System cleanup should handle non-admin gracefully
            { Clear-SystemTempFiles } | Should -Not -Throw
        }
    }
    
    Context "Invoke-SystemCleanup" {
        It "Should have main system cleanup function" {
            Get-Command Invoke-SystemCleanup -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Cleanup accounting" {
    BeforeEach {
        $script:SavedLocalAppData = $env:LOCALAPPDATA
        $script:SavedUserProfile = $env:USERPROFILE
        $script:SavedAppData = $env:APPDATA
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Reset-CleanupStats
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocalAppData
        $env:USERPROFILE = $script:SavedUserProfile
        $env:APPDATA = $script:SavedAppData
    }

    It "Writes nothing to the pipeline from the bulk helpers" {
        $dir = Join-Path $script:Root "cache"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path (Join-Path $dir "a.tmp") -Value "x"
        $old = Join-Path $dir "b.tmp"
        Set-Content -Path $old -Value "x"
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-30)

        @(Clear-DirectoryContents -Path $dir -Description "Test cache").Count | Should -Be 0
        @(Remove-SafeItems -Paths @($old) -Description "Test items").Count | Should -Be 0
        @(Remove-OldFiles -Path $dir -DaysOld 7 -Description "Test old").Count | Should -Be 0
    }

    It "Counts what a dry run would remove" {
        $dir = Join-Path $script:Root "cache"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path (Join-Path $dir "a.tmp") -Value ("x" * 4096)
        Set-Content -Path (Join-Path $dir "b.tmp") -Value ("x" * 4096)

        Clear-DirectoryContents -Path $dir -Description "Test cache"

        $stats = Get-CleanupStats
        $stats.FilesCleaned | Should -Be 2
        $stats.TotalSizeKB | Should -BeGreaterThan 0
        Test-Path (Join-Path $dir "a.tmp") | Should -BeTrue
    }

    It "Lists every path a dry run would remove in the preview file" {
        $dir = Join-Path $script:Root "cache"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir "a.tmp"
        Set-Content -Path $file -Value "x"
        $script:ExportListFile = Join-Path $script:Root "clean-list.txt"
        try {
            Clear-DirectoryContents -Path $dir -Description "Test cache"
            $lines = Get-Content $script:ExportListFile
            $lines | Should -Contain "# Test cache"
            $lines | Should -Contain $file
        }
        finally {
            Remove-Variable -Name ExportListFile -Scope Script -ErrorAction SilentlyContinue
        }
    }

    It "Counts each crash dump and error report once" {
        $env:LOCALAPPDATA = Join-Path $script:Root "AppData\Local"
        $env:USERPROFILE = $script:Root
        $wer = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\WER\ReportArchive\AppCrash_1"
        $dumps = Join-Path $env:LOCALAPPDATA "CrashDumps"
        New-Item -ItemType Directory -Path $wer, $dumps -Force | Out-Null
        Set-Content -Path (Join-Path $wer "Report.wer") -Value "report"
        Set-Content -Path (Join-Path $dumps "app.dmp") -Value "dump"

        foreach ($path in @($wer, (Join-Path $wer "Report.wer"), (Join-Path $dumps "app.dmp"))) {
            (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-10)
            (Get-Item -LiteralPath $path).CreationTime = (Get-Date).AddDays(-10)
        }
        Clear-ErrorReports

        # One complete old report plus one dump.
        (Get-CleanupStats).FilesCleaned | Should -Be 2
    }

    It "Never hands ~/.gitconfig.lock to a delete helper" {
        $env:USERPROFILE = $script:Root
        $env:APPDATA = Join-Path $script:Root "AppData\Roaming"
        $env:LOCALAPPDATA = Join-Path $script:Root "AppData\Local"
        Set-Content -Path (Join-Path $script:Root ".gitconfig.lock") -Value "lock"
        Mock Remove-SafeItem { $true }
        Mock Remove-SafeItems { }

        Clear-GitCaches

        Should -Invoke Remove-SafeItem -Times 0 -ParameterFilter { $Path -like "*.gitconfig.lock" }
        Should -Invoke Remove-SafeItems -Times 0 -ParameterFilter { @($Paths) -like "*.gitconfig.lock" }
    }
}

Describe "Junctions and symbolic links" {
    BeforeEach {
        Set-DryRunMode -Enabled $false
        Reset-CleanupStats
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $script:Target = Join-Path $script:Root "linked-source"
        New-Item -ItemType Directory -Path $script:Target -Force | Out-Null
        Set-Content -Path (Join-Path $script:Target "keep-me.txt") -Value ("x" * 4096)
    }

    AfterEach {
        Set-DryRunMode -Enabled $true
    }

    It "Removes a folder holding a junction without touching the junction's target" {
        $artifact = Join-Path $script:Root "project\node_modules"
        New-Item -ItemType Directory -Path $artifact -Force | Out-Null
        Set-Content -Path (Join-Path $artifact "index.js") -Value "x"
        New-Item -ItemType Junction -Path (Join-Path $artifact "linked-pkg") -Target $script:Target | Out-Null

        Remove-SafeItem -Path $artifact -Description "node_modules" -Recurse 6>$null | Should -BeTrue

        Test-Path $artifact | Should -BeFalse
        Test-Path (Join-Path $script:Target "keep-me.txt") | Should -BeTrue
    }

    It "Removes only the link when the path itself is a junction" {
        $link = Join-Path $script:Root "node_modules"
        New-Item -ItemType Junction -Path $link -Target $script:Target | Out-Null

        Remove-SafeItem -Path $link -Description "node_modules" -Recurse 6>$null | Should -BeTrue

        Test-Path $link | Should -BeFalse
        Test-Path (Join-Path $script:Target "keep-me.txt") | Should -BeTrue
    }

    It "Does not count a junction's target in the size" {
        $folder = Join-Path $script:Root "cache"
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -Path (Join-Path $folder "own.bin") -Value "abc"
        New-Item -ItemType Junction -Path (Join-Path $folder "linked") -Target $script:Target | Out-Null

        Get-PathSize -Path $folder | Should -BeLessThan 100
    }
}

Describe "Owner cache accounting" {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $script:Root 'gone.bin'), (New-Object byte[] 4096))
        [IO.File]::WriteAllBytes((Join-Path $script:Root 'kept.bin'), (New-Object byte[] 2048))
        Reset-CleanupStats
        Set-DryRunMode -Enabled $false
        $script:ExportListFile = Join-Path $TestDrive 'owner-preview.txt'
        Mock Get-MoleOwnerCachePath { $script:Root }
        Mock Invoke-MoleOwnerProcess { [pscustomobject]@{ Output = '' } }
    }
    AfterEach {
        Set-DryRunMode -Enabled $true
        Remove-Variable ExportListFile -Scope Script -ErrorAction SilentlyContinue
    }
    It "Exports the owner root without claiming the whole store will be pruned" {
        Set-DryRunMode -Enabled $true
        Invoke-MoleOwnerCacheCleanup -Name fixture -Query @('path') -Arguments @('prune') -Description 'Fixture cache'
        Get-Content $script:ExportListFile | Should -Contain $script:Root
        $stats = Get-CleanupStats
        $stats.OwnerCleanups | Should -Be 1
        $stats.TotalSizeKB | Should -Be 0
        Should -Invoke Invoke-MoleOwnerProcess -Times 0 -Exactly
    }
    It "Measures only the space removed by a successful partial prune" {
        Mock Invoke-MoleOwnerProcess {
            Remove-Item -LiteralPath (Join-Path $script:Root 'gone.bin')
            [pscustomobject]@{ Output = '' }
        }
        Invoke-MoleOwnerCacheCleanup -Name fixture -Query @('path') -Arguments @('prune') -Description 'Fixture cache'
        $stats = Get-CleanupStats
        $stats.OwnerCleanups | Should -Be 1
        $stats.TotalSizeKB | Should -Be 4
        $stats.FilesCleaned | Should -Be 1
        Test-Path (Join-Path $script:Root 'kept.bin') | Should -BeTrue
    }
    It "Does not report bytes for an unchanged cache" {
        Invoke-MoleOwnerCacheCleanup -Name fixture -Query @('path') -Arguments @('prune') -Description 'Fixture cache'
        (Get-CleanupStats).TotalSizeKB | Should -Be 0
        (Get-CleanupStats).OwnerCleanups | Should -Be 1
    }
    It "Shows the bytes a prune removed on its row, and no size when nothing went" {
        $script:Rows = @()
        Mock Write-Success { $script:Rows += $Message }
        Mock Invoke-MoleOwnerProcess {
            Remove-Item -LiteralPath (Join-Path $script:Root 'gone.bin')
            [pscustomobject]@{ Output = '' }
        }
        Invoke-MoleOwnerCacheCleanup -Name fixture -Query @('path') -Arguments @('prune') -Description 'Fixture cache'
        Mock Invoke-MoleOwnerProcess { [pscustomobject]@{ Output = '' } }
        Invoke-MoleOwnerCacheCleanup -Name fixture -Query @('path') -Arguments @('prune') -Description 'Fixture cache'
        @($script:Rows).Count | Should -Be 2
        $script:Rows[0] | Should -Match '^Fixture cache .*\(4KB\)'
        $script:Rows[1] | Should -Be 'Fixture cache'
    }
    It "Handles an empty owner cache without a missing Sum property" {
        Remove-Item -LiteralPath (Join-Path $script:Root 'gone.bin'), (Join-Path $script:Root 'kept.bin')
        { Invoke-MoleOwnerCacheCleanup -Name fixture -Query @('path') -Arguments @('prune') -Description 'Fixture cache' } | Should -Not -Throw
        (Get-CleanupStats).TotalSizeKB | Should -Be 0
    }
    It "Does not assume an unmeasurable post-cleanup tree is empty" {
        $script:WalkCount = 0
        Mock Get-SafeDirectoryTreeItems {
            $script:WalkCount++
            if ($script:WalkCount -eq 1) {
                return @{ Success = $true; Items = @(Get-ChildItem -LiteralPath $script:Root | ForEach-Object {
                    $_ | Add-Member -NotePropertyName MolePathSnapshot -NotePropertyValue (Get-MolePathSnapshot $_.FullName) -PassThru
                }) }
            }
            return @{ Success = $false; Items = @() }
        }
        Invoke-MoleOwnerCacheCleanup -Name fixture -Query @('path') -Arguments @('prune') -Description 'Fixture cache'
        (Get-CleanupStats).TotalSizeKB | Should -Be 0
        (Get-CleanupStats).OwnerCleanups | Should -Be 1
    }
    It "Does not count a failed owner command" {
        Mock Invoke-MoleOwnerProcess { $null }
        Invoke-MoleOwnerCacheCleanup -Name fixture -Query @('path') -Arguments @('prune') -Description 'Fixture cache'
        (Get-CleanupStats).OwnerCleanups | Should -Be 0
        (Get-CleanupStats).TotalSizeKB | Should -Be 0
    }
    It "Keeps owner-only activity out of the already-clean summary" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:WindowsDir 'bin\clean.ps1'), [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-CleanupSummary' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        Mock Get-FreeSpace { '10 GB' }
        Invoke-MoleOwnerCacheCleanup -Name fixture -Query @('path') -Arguments @('prune') -Description 'Fixture cache'
        $output = Show-CleanupSummary -Stats (Get-CleanupStats) -IsDryRun $false 6>&1 | Out-String
        $output | Should -Not -Match 'already clean'
        $output | Should -Match 'Tool cache cleanup completed'
    }
}

Describe 'Review regressions: owner log and summary' {
    BeforeEach {
        Reset-CleanupStats
        Set-DryRunMode -Enabled $false
        Mock Get-MoleOwnerCachePath { 'C:\cache' }
        Mock Test-SafePath { $true }
        Mock Get-MolePathSnapshot { @{ Path = 'C:\cache' } }
        Mock Test-MolePathSnapshot { $true }
        Mock Get-SafeDirectoryTreeItems { @{ Success = $true; Items = @() } }
        Mock Invoke-MoleOwnerProcess { [pscustomobject]@{ Output = '' } }
        Mock Write-MoleOperation { }
        Mock Write-Success { }
        Mock Set-SectionActivity { }
    }
    It 'Records a successful owner command without claiming a file removal' {
        Invoke-MoleOwnerCacheCleanup -Name npm -Query @('config','get','cache') -Arguments @('cache','clean','--force') -Description 'npm cache'
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'OWNER' -and $Path -eq 'C:\cache' -and $Detail -eq 'npm cache clean --force' }
    }
    It 'Records a failed owner command as incomplete' {
        Mock Invoke-MoleOwnerProcess { $null }
        Invoke-MoleOwnerCacheCleanup -Name npm -Query @('path') -Arguments @('cache','clean','--force') -Description 'npm cache'
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'FAILED' -and $Detail -eq 'npm cache clean --force: incomplete' }
    }
    It 'Records that a timed-out owner command was killed' {
        Mock Invoke-MoleOwnerProcess {
            if ($null -ne $Outcome) { $Outcome.Reason = 'timed out after 120s; process tree 42 stopped with taskkill /T /F' }
            $null
        }
        Invoke-MoleOwnerCacheCleanup -Name npm -Query @('path') -Arguments @('cache','clean','--force') -Description 'npm cache'
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter {
            $Action -eq 'FAILED' -and $Detail -eq 'npm cache clean --force: incomplete; timed out after 120s; process tree 42 stopped with taskkill /T /F'
        }
    }
    It 'Does not record an owner preview' {
        Set-DryRunMode -Enabled $true
        Mock Add-DryRunListEntries { }
        Invoke-MoleOwnerCacheCleanup -Name npm -Query @('path') -Arguments @('cache','clean','--force') -Description 'npm cache'
        Should -Invoke Write-MoleOperation -Times 0 -Exactly
    }
    It 'Uses one item count and no protection tutorial in a dry-run summary' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:WindowsDir 'bin\clean.ps1'), [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-CleanupSummary' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        Mock Get-FreeSpace { '10 GB' }
        Mock Show-SummaryBlock { Write-Output ($Details -join "`n") }
        $script:ExportListFile = 'fixture-list.txt'
        $output = Show-CleanupSummary -Stats @{ TotalSizeKB = 4; FilesCleaned = 2; TotalItems = 1; OwnerCleanups = 0 } -IsDryRun $true | Out-String
        $output | Should -Match 'Potential space:.*Items: 2'
        $output | Should -Not -Match 'Categories:|--whitelist'
    }
    It 'Says Removed with one item count after a real cleanup' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:WindowsDir 'bin\clean.ps1'), [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-CleanupSummary' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        Mock Get-FreeSpace { '10 GB' }
        Mock Show-SummaryBlock { Write-Output ($Details -join "`n") }
        $output = Show-CleanupSummary -Stats @{ TotalSizeKB = 4; FilesCleaned = 2; TotalItems = 1; OwnerCleanups = 0 } -IsDryRun $false | Out-String
        $output | Should -Match 'Removed:.*\| Items: 2'
        $output | Should -Not -Match 'Tracked cleanup|Items cleaned'
    }
}

Describe 'Owner process timeout' {
    It 'Says when it stops an owner process tree that ran past its timeout' {
        $outcome = @{}
        $result = Invoke-MoleOwnerProcess -Name 'powershell' -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -TimeoutSeconds 1 -Outcome $outcome
        $result | Should -BeNullOrEmpty
        $outcome.Reason | Should -Match '^timed out after 1s; process tree \d+ stopped with taskkill /T /F$'
    }
}

Describe 'Owner cancellation evidence' {
    It 'Reports <Expected> without inventing a stopped process tree' -ForEach @(
        @{ Finished = $true; ExitCode = 5; Expected = 'taskkill exit code 5; process tree termination unverified' },
        @{ Finished = $false; ExitCode = 0; Expected = 'taskkill timed out; process tree termination unverified' }
    ) {
        $script:FakeProcessIndex = 0
        $script:FakeOwner = [pscustomobject]@{
            StartInfo = $null; Id = 42; HasExited = $false; ExitCode = 0
            StandardOutput = [IO.StringReader]::new(''); StandardError = [IO.StringReader]::new('')
            Finished = $false; Disposed = $false; Killed = $false
        }
        $script:FakeStopper = [pscustomobject]@{
            StartInfo = [Diagnostics.ProcessStartInfo]::new(); Id = 43; HasExited = $Finished; ExitCode = $ExitCode
            StandardOutput = [IO.StringReader]::new(''); StandardError = [IO.StringReader]::new('')
            Finished = $Finished; Disposed = $false; Killed = $false
        }
        foreach ($fake in @($script:FakeOwner, $script:FakeStopper)) {
            $fake | Add-Member ScriptMethod Start { $true }
            $fake | Add-Member ScriptMethod WaitForExit { param($milliseconds) $this.Finished }
            $fake | Add-Member ScriptMethod Kill { $this.Killed = $true }
            $fake | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        }
        Mock Get-Command { [pscustomobject]@{ Source = 'fixture.exe' } } -ParameterFilter { $Name -eq 'fixture-owner' }
        Mock New-Object {
            $script:FakeProcessIndex++
            if ($script:FakeProcessIndex -eq 1) { return $script:FakeOwner }
            return $script:FakeStopper
        } -ParameterFilter { $TypeName -eq 'Diagnostics.Process' }
        Mock New-Object { [Diagnostics.ProcessStartInfo]::new() } -ParameterFilter { $TypeName -eq 'Diagnostics.ProcessStartInfo' }
        $outcome = @{}
        Invoke-MoleOwnerProcess -Name 'fixture-owner' -Arguments @() -TimeoutSeconds 1 -Outcome $outcome | Should -BeNullOrEmpty
        $outcome.Reason | Should -Be "timed out after 1s; $Expected"
        $outcome.Reason | Should -Not -Match 'stopped with taskkill'
        $script:FakeOwner.Killed | Should -BeTrue
        $script:FakeOwner.Disposed | Should -BeTrue
        $script:FakeStopper.Disposed | Should -BeTrue
    }
}
