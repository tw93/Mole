# Real sinks run only inside Pester's isolated fixture tree.
BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . "$repo\lib\clean\caches.ps1"
    . "$repo\lib\clean\dev.ps1"
    . "$repo\lib\clean\user.ps1"
    . "$repo\lib\clean\apps.ps1"
    . "$repo\lib\clean\system.ps1"
    $script:SavedCacheEnvironment = @{}
    foreach ($name in @('USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'MO_NO_OPLOG')) {
        $script:SavedCacheEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $script:SavedCacheWhitelist = $script:Config.WhitelistFile
    $script:SavedCacheGuard = $script:MoleCleanPathGuard
    $script:SavedCacheDryRun = $script:MoleDryRunMode
    function New-CacheFile([string]$Path) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        [IO.File]::WriteAllText($Path, 'cache fixture')
        return $Path
    }
}
AfterAll {
    foreach ($name in $script:SavedCacheEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:SavedCacheEnvironment[$name])
    }
    $script:Config.WhitelistFile = $script:SavedCacheWhitelist
    $script:MoleCleanPathGuard = $script:SavedCacheGuard
    $script:MoleDryRunMode = $script:SavedCacheDryRun
}

Describe 'Application cache boundaries' {
    BeforeEach {
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0,8))
        $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'Local'
        $env:APPDATA = Join-Path $env:USERPROFILE 'Roaming'
        $env:MO_NO_OPLOG = '1'
        $script:Config.WhitelistFile = Join-Path $env:USERPROFILE 'whitelist.txt'
        $script:ExportListFile = Join-Path $env:USERPROFILE 'preview.txt'
        $script:MoleCleanPathGuard = $true
        Set-DryRunMode -Enabled $false
        Reset-CleanupStats
        Mock Get-Process { @() }
        Mock Invoke-MoleOwnerCacheCleanup {}
        Mock Start-Section {}
        Mock Stop-Section {}
    }

    It 'Keeps both VS Code cleanup entries guarded for <Owner> in preview <Preview>' -ForEach @(
        @{Owner='Code';Preview=$false}, @{Owner='Code';Preview=$true},
        @{Owner='Code - Insiders';Preview=$false}, @{Owner='Code - Insiders';Preview=$true},
        @{Owner='unknown';Preview=$false}, @{Owner='unknown';Preview=$true}
    ) {
        $code = New-CacheFile "$env:APPDATA\Code\Cache\entry"
        $insiders = New-CacheFile "$env:APPDATA\Code - Insiders\Cache\entry"
        $cpp = New-CacheFile "$env:LOCALAPPDATA\Microsoft\vscode-cpptools\entry"
        if ($Owner -eq 'unknown') { Mock Get-Process { throw 'incomplete inventory' } }
        else { Mock Get-Process { [pscustomobject]@{ProcessName=$Owner} } }
        Set-DryRunMode -Enabled $Preview
        Clear-AppCaches
        Clear-EditorCaches
        $kept = if ($Owner -eq 'Code - Insiders') { $insiders } else { $code }
        Test-Path -LiteralPath $kept | Should -BeTrue
        Test-Path -LiteralPath $cpp | Should -BeTrue
        if (Test-Path -LiteralPath $script:ExportListFile) {
            Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Not -Match ([regex]::Escape($kept))
            Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Not -Match ([regex]::Escape($cpp))
        }
        if ($Owner -eq 'unknown') { Test-Path -LiteralPath $insiders | Should -BeTrue }
    }

    It 'Cleans both VS Code channels when their owners are idle' {
        $code = New-CacheFile "$env:APPDATA\Code\Cache\entry"
        $insiders = New-CacheFile "$env:APPDATA\Code - Insiders\Cache\entry"
        Clear-AppCaches
        Clear-EditorCaches
        Test-Path -LiteralPath $code | Should -BeFalse
        Test-Path -LiteralPath $insiders | Should -BeFalse
    }

    It 'Cleans only the measured Vesktop disk caches and retains profile state' {
        $root = "$env:APPDATA\vesktop"
        $caches = @(foreach ($leaf in @('Cache','Code Cache','GPUCache')) { New-CacheFile "$root\sessionData\$leaf\entry" })
        $state = @(foreach ($leaf in @('settings\settings.json','sessionData\Local Storage\entry','sessionData\Network\Cookies','sessionData\Shared Dictionary\entry','vencordFiles\plugin.js')) { New-CacheFile "$root\$leaf" })
        Clear-AppCaches
        foreach ($file in $caches) { Test-Path -LiteralPath $file | Should -BeFalse }
        foreach ($file in $state) { Test-Path -LiteralPath $file | Should -BeTrue }
    }

    It 'Cleans the measured <Name> leaves and keeps the state beside them' -ForEach @(
        @{ Name='Trae'; Root='APPDATA'; Base='Trae'; Caches=@('Cache','Code Cache','GPUCache','CachedData','DawnGraphiteCache','DawnWebGPUCache'); State=@('User\settings.json','Local Storage\leveldb\x','Session Storage\x','logs\s1\main.log') }
        @{ Name='Qoder'; Root='APPDATA'; Base='Qoder'; Caches=@('Cache','Code Cache','GPUCache','CachedData'); State=@('User\settings.json','Backups\x') }
        @{ Name='Kiro'; Root='APPDATA'; Base='Kiro'; Caches=@('Cache','Code Cache','GPUCache'); State=@('User\settings.json') }
        @{ Name='Discord PTB'; Root='APPDATA'; Base='discordptb'; Caches=@('Cache','Code Cache','GPUCache','DawnGraphiteCache','DawnWebGPUCache','ShaderCache','GrShaderCache'); State=@('Local Storage\leveldb\x','1.0.1229\modules\x') }
        @{ Name='QQ'; Root='APPDATA'; Base='QQ'; Caches=@('Cache','Code Cache'); State=@('global\nt_data\x','Local Storage\x') }
        @{ Name='Feishu'; Root='APPDATA'; Base='LarkShell'; Caches=@('aha\users\global\profile_global\Cache','aha\users\global\profile_global\DawnWebGPUCache','ShaderCache','GraphiteDawnCache'); State=@('aha\users\global\profile_global\Login Data','sdk_storage\x','aha\users\1234\profile\Cache\x') }
        @{ Name='CapCut'; Root='LOCALAPPDATA'; Base='CapCut\User Data'; Caches=@('CEF\Cache\Cache','CEF\Cache\DawnCache','CEF\ShaderCache'); State=@('Cache\effect\model.bin','Projects\draft\draft.json','CEF\Cache\Local Storage\x') }
        @{ Name='Chrome Beta'; Root='LOCALAPPDATA'; Base='Google\Chrome Beta\User Data'; Caches=@('Default\Cache','Default\DawnGraphiteCache','Profile 1\Code Cache','GrShaderCache'); State=@('Default\Cookies','Default\Local Storage\x','Default\Service Worker\CacheStorage\x') }
        @{ Name='360 Chrome'; Root='LOCALAPPDATA'; Base='360Chrome\Chrome\User Data'; Caches=@('Default\Cache','GraphiteDawnCache'); State=@('Default\Bookmarks','v3update\x') }
    ) {
        $base = Join-Path ([Environment]::GetEnvironmentVariable($Root)) $Base
        $caches = @(foreach ($leaf in $Caches) { New-CacheFile (Join-Path $base "$leaf\entry") })
        $state = @(foreach ($leaf in $State) { New-CacheFile (Join-Path $base $leaf) })
        Clear-BrowserCaches
        Clear-AppCaches
        foreach ($file in $caches) { Test-Path -LiteralPath $file | Should -BeFalse }
        foreach ($file in $state) { Test-Path -LiteralPath $file | Should -BeTrue }
    }

    It 'Keeps the new app caches while their owner runs or is unknown: <Owner>' -ForEach @(
        @{ Owner='Trae'; Path='Trae\Cache\entry' }, @{ Owner='Feishu'; Path='LarkShell\ShaderCache\entry' },
        @{ Owner='Qoder'; Path='Qoder\CachedData\entry' }, @{ Owner='Qoder IDE'; Path='Qoder\Cache\entry' },
        @{ Owner='Lark'; Path='LarkInternational\GraphiteDawnCache\entry' }, @{ Owner='CodeBuddy'; Path='CodeBuddy\GPUCache\entry' },
        @{ Owner='DiscordCanary'; Path='discordcanary\GPUCache\entry' }, @{ Owner='unknown'; Path='Kiro\Cache\entry' }
    ) {
        $cache = New-CacheFile (Join-Path $env:APPDATA $Path)
        if ($Owner -eq 'unknown') { Mock Get-Process { throw 'incomplete inventory' } }
        else { $script:RunningOwner = $Owner; Mock Get-Process { [pscustomobject]@{ProcessName=$script:RunningOwner} } }
        foreach ($preview in @($true, $false)) {
            Set-DryRunMode -Enabled $preview
            Clear-AppCaches
            Test-Path -LiteralPath $cache | Should -BeTrue
        }
    }

    It 'A running <Owner> keeps the <Path> cache' -ForEach @(
        @{ Owner='msedge'; Path='Microsoft\Edge Dev\User Data\Default\Cache\entry' }
        @{ Owner='msedge'; Path='Microsoft\Edge Beta\User Data\GrShaderCache\entry' }
        @{ Owner='chrome'; Path='Google\Chrome SxS\User Data\Default\DawnWebGPUCache\entry' }
        @{ Owner='quark'; Path='Quark\User Data\Default\Cache\entry' }
        @{ Owner='360chrome'; Path='360Chrome\Chrome\User Data\GraphiteDawnCache\entry' }
        @{ Owner='JianyingPro'; Path='JianyingPro\User Data\CEF\Cache\Cache\entry' }
    ) {
        $cache = New-CacheFile (Join-Path $env:LOCALAPPDATA $Path)
        $script:RunningOwner = $Owner
        Mock Get-Process { [pscustomobject]@{ProcessName=$script:RunningOwner} }
        Clear-BrowserCaches
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
    }

    It 'Takes only week-old top-level app log files' {
        $old = New-CacheFile "$env:LOCALAPPDATA\Tencent\Wemeet\logs\old.log"
        $recent = New-CacheFile "$env:LOCALAPPDATA\Tencent\Wemeet\logs\today.log"
        $data = New-CacheFile "$env:LOCALAPPDATA\Tencent\Wemeet\Global\Data\db.sqlite"
        $wsl = New-CacheFile "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx"
        (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-10)
        (Get-Item -LiteralPath $data).LastWriteTime = (Get-Date).AddDays(-10)
        (Get-Item -LiteralPath $wsl).LastWriteTime = (Get-Date).AddDays(-10)
        Clear-AppCaches
        Test-Path -LiteralPath $old | Should -BeFalse
        foreach ($file in @($recent, $data, $wsl)) { Test-Path -LiteralPath $file | Should -BeTrue }
    }

    It 'Keeps Vesktop caches for <Owner> in preview <Preview>' -ForEach @(
        @{Owner='vesktop';Preview=$false}, @{Owner='vesktop';Preview=$true},
        @{Owner='unknown';Preview=$false}, @{Owner='unknown';Preview=$true}
    ) {
        $cache = New-CacheFile "$env:APPDATA\vesktop\sessionData\Cache\entry"
        if ($Owner -eq 'unknown') { Mock Get-Process { throw 'incomplete inventory' } }
        else { Mock Get-Process { [pscustomobject]@{ProcessName='vesktop'} } }
        Set-DryRunMode -Enabled $Preview
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        Test-Path -LiteralPath $script:ExportListFile | Should -BeFalse
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Rechecks Vesktop after sizing in preview <Preview>' -ForEach @(@{Preview=$true},@{Preview=$false}) {
        $cache = New-CacheFile "$env:APPDATA\vesktop\sessionData\Cache\package\entry"
        $script:VesktopStarted = $false
        Mock Get-Process { if ($script:VesktopStarted) { [pscustomobject]@{ProcessName='vesktop'} } }
        Mock Get-ValidatedTreeSize { $script:VesktopStarted = $true; return 13 }
        Set-DryRunMode -Enabled $Preview
        Clear-AppCaches
        Should -Invoke Get-ValidatedTreeSize -Times 1 -Exactly
        Test-Path -LiteralPath $cache | Should -BeTrue
        Test-Path -LiteralPath $script:ExportListFile | Should -BeFalse
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Keeps an unavailable Bun cache for a running or unknown owner: <Owner>' -ForEach @(
        @{Owner='bun'}, @{Owner='bunx'}, @{Owner='unknown'}
    ) {
        $cache = New-CacheFile "$env:USERPROFILE\.bun\install\cache\entry"
        Mock Invoke-MoleOwnerProcess { $null }
        if ($Owner -eq 'unknown') { Mock Get-Process { throw 'incomplete inventory' } }
        else { Mock Get-Process { [pscustomobject]@{ProcessName=$Owner} } }
        foreach ($preview in @($true,$false)) {
            Set-DryRunMode -Enabled $preview
            Clear-NpmCache
            Test-Path -LiteralPath $cache | Should -BeTrue
            (Get-CleanupStats).FilesCleaned | Should -Be 0
        }
    }

    It 'Cleans the default Bun cache only when Bun is unavailable and idle' {
        $cache = New-CacheFile "$env:USERPROFILE\.bun\install\cache\entry"
        Mock Invoke-MoleOwnerProcess { $null }
        Clear-NpmCache
        Test-Path -LiteralPath $cache | Should -BeFalse
    }

    It 'Keeps recent error reports and dumps in preview and real cleanup' {
        $old = New-CacheFile "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive\old\Report.wer"
        $recent = New-CacheFile "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive\recent\Report.wer"
        $oldDump = New-CacheFile "$env:LOCALAPPDATA\CrashDumps\old.dmp"
        $recentDump = New-CacheFile "$env:LOCALAPPDATA\CrashDumps\recent.dmp"
        foreach ($path in @($old, (Split-Path $old), $oldDump)) {
            (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-10)
            (Get-Item -LiteralPath $path).CreationTime = (Get-Date).AddDays(-10)
        }
        Set-DryRunMode -Enabled $true
        Clear-ErrorReports -DaysOld 7
        Test-Path -LiteralPath $old | Should -BeTrue
        $preview = Get-Content -LiteralPath $script:ExportListFile -Raw
        $preview | Should -Match 'old'
        $preview | Should -Not -Match 'recent'
        Set-DryRunMode -Enabled $false
        Clear-ErrorReports -DaysOld 7
        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath $oldDump | Should -BeFalse
        Test-Path -LiteralPath $recent | Should -BeTrue
        Test-Path -LiteralPath $recentDump | Should -BeTrue
    }

    It 'Keeps an old report directory with a recently written attachment' {
        $report = New-CacheFile "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue\old\Report.wer"
        $fresh = New-CacheFile "$(Split-Path $report)\attachment.dmp"
        foreach ($path in @($report, (Split-Path $report))) {
            (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-10)
            (Get-Item -LiteralPath $path).CreationTime = (Get-Date).AddDays(-10)
        }
        Clear-ErrorReports
        Test-Path -LiteralPath $report | Should -BeTrue
        Test-Path -LiteralPath $fresh | Should -BeTrue
    }

    It 'Keeps a report that receives an attachment after sizing' {
        $report = New-CacheFile "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive\old\Report.wer"
        foreach ($path in @($report, (Split-Path $report))) {
            (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-10)
            (Get-Item -LiteralPath $path).CreationTime = (Get-Date).AddDays(-10)
        }
        $script:ReportAttachment = "$(Split-Path $report)\new.dmp"
        Mock Get-ValidatedTreeSize {
            [IO.File]::WriteAllText($script:ReportAttachment, 'new diagnostic')
            return 10
        }
        Clear-ErrorReports
        Test-Path -LiteralPath $report | Should -BeTrue
        Test-Path -LiteralPath $script:ReportAttachment | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Cleans Sublime Local and existing Roaming caches only while the owner is idle' {
        $local = New-CacheFile "$env:LOCALAPPDATA\Sublime Text\Cache\entry"
        $roaming = New-CacheFile "$env:APPDATA\Sublime Text\Cache\entry"
        $settings = New-CacheFile "$env:APPDATA\Sublime Text\Packages\User\settings"
        Mock Get-Process { [pscustomobject]@{ProcessName='sublime_text'} }
        Clear-EditorCaches
        Test-Path -LiteralPath $local | Should -BeTrue
        Test-Path -LiteralPath $roaming | Should -BeTrue
        Mock Get-Process { @() }
        Clear-EditorCaches
        Test-Path -LiteralPath $local | Should -BeFalse
        Test-Path -LiteralPath $roaming | Should -BeFalse
        Test-Path -LiteralPath $settings | Should -BeTrue
    }

    It 'Keeps Adobe media caches for <Owner> in preview <Preview>' -ForEach @(
        @{Owner='Adobe Premiere Pro';Preview=$false}, @{Owner='Adobe Premiere Pro';Preview=$true},
        @{Owner='AfterFX';Preview=$false}, @{Owner='AfterFX';Preview=$true},
        @{Owner='Adobe Media Encoder';Preview=$false}, @{Owner='Adobe Media Encoder';Preview=$true},
        @{Owner='Adobe Audition';Preview=$false}, @{Owner='Adobe Audition';Preview=$true},
        @{Owner='Audition';Preview=$false}, @{Owner='Audition';Preview=$true},
        @{Owner='unknown';Preview=$false}, @{Owner='unknown';Preview=$true}
    ) {
        $media = New-CacheFile "$env:APPDATA\Adobe\Common\Media Cache Files\clip.cache"
        $peak = New-CacheFile "$env:APPDATA\Adobe\Common\Peak Files\clip.pek"
        if ($Owner -eq 'unknown') { Mock Get-Process { throw 'incomplete inventory' } }
        else { Mock Get-Process { [pscustomobject]@{ProcessName=$Owner} } }
        Set-DryRunMode -Enabled $Preview
        Clear-AdobeData
        foreach ($file in @($media,$peak)) { Test-Path -LiteralPath $file | Should -BeTrue }
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Rechecks Adobe owners after sizing in preview <Preview>' -ForEach @(
        @{Preview=$false}, @{Preview=$true}
    ) {
        $media = New-CacheFile "$env:APPDATA\Adobe\Common\Media Cache Files\clip\entry.cache"
        $script:AdobeStarted = $false
        Mock Get-Process { if ($script:AdobeStarted) { [pscustomobject]@{ProcessName='AfterFX'} } }
        Mock Get-ValidatedTreeSize { $script:AdobeStarted = $true; return 10 }
        Set-DryRunMode -Enabled $Preview
        Clear-AdobeData
        $script:AdobeStarted | Should -BeTrue
        Test-Path -LiteralPath $media | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Cleans idle Adobe media and peak caches while retaining Team Projects' {
        $media = New-CacheFile "$env:APPDATA\Adobe\Common\Media Cache Files\clip.cache"
        $peak = New-CacheFile "$env:APPDATA\Adobe\Common\Peak Files\clip.pek"
        $state = New-CacheFile "$env:APPDATA\Adobe\Common\Team Projects Cache\project.db"
        Clear-AdobeData
        Test-Path -LiteralPath $media | Should -BeFalse
        Test-Path -LiteralPath $peak | Should -BeFalse
        Test-Path -LiteralPath $state | Should -BeTrue
    }

    It 'Keeps Yarn Berry dependencies beside the idle Classic cache' {
        $berry = New-CacheFile "$env:USERPROFILE\.yarn\cache\dependency.zip"
        $global = New-CacheFile "$env:USERPROFILE\.yarn\berry\cache\dependency.zip"
        $windowsGlobal = New-CacheFile "$env:LOCALAPPDATA\Yarn\Berry\cache\dependency.zip"
        $classic = New-CacheFile "$env:LOCALAPPDATA\Yarn\Cache\entry"
        Mock Invoke-MoleOwnerProcess { $null }
        Clear-NpmCache
        Test-Path -LiteralPath $berry | Should -BeTrue
        Test-Path -LiteralPath $global | Should -BeTrue
        Test-Path -LiteralPath $windowsGlobal | Should -BeTrue
        Test-Path -LiteralPath $classic | Should -BeFalse
    }

    It 'Keeps Yarn Classic for <Owner> in preview <Preview>' -ForEach @(
        @{Owner='node';Preview=$false}, @{Owner='node';Preview=$true},
        @{Owner='unknown';Preview=$false}, @{Owner='unknown';Preview=$true}
    ) {
        $classic = New-CacheFile "$env:LOCALAPPDATA\Yarn\Cache\entry"
        Mock Invoke-MoleOwnerProcess { $null }
        if ($Owner -eq 'unknown') { Mock Get-Process { throw 'incomplete inventory' } }
        else { Mock Get-Process { [pscustomobject]@{ProcessName=$Owner} } }
        Set-DryRunMode -Enabled $Preview
        Clear-NpmCache
        Test-Path -LiteralPath $classic | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Rechecks Yarn Classic owners after sizing in preview <Preview>' -ForEach @(
        @{Preview=$false}, @{Preview=$true}
    ) {
        $classic = New-CacheFile "$env:LOCALAPPDATA\Yarn\Cache\package\entry"
        Mock Invoke-MoleOwnerProcess { $null }
        $script:NodeStarted = $false
        Mock Get-Process { if ($script:NodeStarted) { [pscustomobject]@{ProcessName='node'} } }
        Mock Get-ValidatedTreeSize { $script:NodeStarted = $true; return 10 }
        Set-DryRunMode -Enabled $Preview
        Clear-NpmCache
        $script:NodeStarted | Should -BeTrue
        Test-Path -LiteralPath $classic | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Protects named Berry stores at the shared clean sink including parent sweeps' {
        $project = New-CacheFile "$env:USERPROFILE\project\.yarn\cache\dependency.zip"
        $global = New-CacheFile "$env:USERPROFILE\.yarn\berry\cache\dependency.zip"
        $windowsGlobal = New-CacheFile "$env:LOCALAPPDATA\Yarn\Berry\cache\dependency.zip"
        $neighbor = New-CacheFile "$env:USERPROFILE\project\.yarn\cache-backup\entry"
        $berryNeighbor = New-CacheFile "$env:USERPROFILE\.yarn\berry\cache-backup\entry"
        foreach ($file in @($project,$global,$windowsGlobal)) {
            Remove-SafeItem -Path $file | Should -BeFalse
            Test-Path -LiteralPath $file | Should -BeTrue
        }
        Remove-SafeItem -Path "$env:USERPROFILE\project\.yarn" -Recurse | Should -BeFalse
        Remove-SafeItem -Path "$env:USERPROFILE\.yarn" -Recurse | Should -BeFalse
        Remove-SafeItem -Path "$env:LOCALAPPDATA\Yarn\Berry" -Recurse | Should -BeFalse
        Remove-SafeItem -Path $neighbor | Should -BeTrue
        Remove-SafeItem -Path $berryNeighbor | Should -BeTrue
        $script:MoleCleanPathGuard = $false
        Remove-SafeItem -Path $project | Should -BeTrue
    }

    It 'Keeps Adobe Team Projects state beside rebuildable media caches' {
        $state = New-CacheFile "$env:APPDATA\Adobe\Common\Team Projects Cache\project.db"
        $media = New-CacheFile "$env:APPDATA\Adobe\Common\Media Cache Files\clip.cache"
        Set-DryRunMode -Enabled $true
        Clear-AdobeData
        Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Not -Match 'Team Projects Cache'
        Set-DryRunMode -Enabled $false
        Clear-AdobeData
        Test-Path -LiteralPath $state | Should -BeTrue
        Test-Path -LiteralPath $media | Should -BeFalse
    }

    It 'Protects Team Projects state at the shared clean sink including parent sweeps' {
        $state = New-CacheFile "$env:APPDATA\Adobe\Common\Team Projects Cache\project.db"
        $neighbor = New-CacheFile "$env:APPDATA\Adobe\Common\Team Projects Cache Backup\entry"
        Remove-SafeItem -Path "$env:APPDATA\Adobe\Common" -Recurse | Should -BeFalse
        Remove-SafeItem -Path $state | Should -BeFalse
        Test-Path -LiteralPath $state | Should -BeTrue
        Remove-SafeItem -Path $neighbor | Should -BeTrue
    }

    It 'Keeps Poetry virtualenvs while cleaning its two disposable children' {
        $root = "$env:LOCALAPPDATA\pypoetry\Cache"
        $venv = New-CacheFile "$root\virtualenvs\project\Scripts\python.exe"
        $artifact = New-CacheFile "$root\artifacts\a.whl"
        $cache = New-CacheFile "$root\cache\repo\entry"
        Set-DryRunMode -Enabled $true
        Clear-PythonCaches
        Test-Path -LiteralPath $artifact | Should -BeTrue
        Test-Path -LiteralPath $venv | Should -BeTrue
        Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Not -Match 'virtualenvs'
        Set-DryRunMode -Enabled $false
        Clear-PythonCaches
        Test-Path -LiteralPath $venv | Should -BeTrue
        Test-Path -LiteralPath $artifact | Should -BeFalse
        Test-Path -LiteralPath $cache | Should -BeFalse
    }

    It 'Keeps offline CacheStorage beside an eligible Slack disk cache' {
        $offline = New-CacheFile "$env:APPDATA\Slack\Service Worker\CacheStorage\offline"
        $cache = New-CacheFile "$env:APPDATA\Slack\Cache\entry"
        Clear-AppCaches
        Test-Path -LiteralPath $offline | Should -BeTrue
        Test-Path -LiteralPath $cache | Should -BeFalse
    }

    It 'Cleans every Chromium profile for <Brand> and preserves offline data' -ForEach @(
        @{Brand='Chrome'; Relative='Google\Chrome\User Data'},
        @{Brand='Edge'; Relative='Microsoft\Edge\User Data'},
        @{Brand='Brave'; Relative='BraveSoftware\Brave-Browser\User Data'},
        @{Brand='Vivaldi'; Relative='Vivaldi\User Data'}
    ) {
        $root = Join-Path $env:LOCALAPPDATA $Relative
        $files = @(foreach ($profile in @('Default','Profile 2','Profile [work]')) {
            foreach ($leaf in @('Cache','Code Cache','GPUCache')) { New-CacheFile "$root\$profile\$leaf\entry" }
        })
        $offline = New-CacheFile "$root\Default\Service Worker\CacheStorage\offline"
        $cookie = New-CacheFile "$root\Profile 2\Cookies"
        Clear-BrowserCaches
        foreach ($file in $files) { Test-Path -LiteralPath $file | Should -BeFalse }
        Test-Path -LiteralPath $offline | Should -BeTrue
        Test-Path -LiteralPath $cookie | Should -BeTrue
    }

    It 'Uses Firefox local caches and keeps its roaming profile stores' {
        $cache = New-CacheFile "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\p.default\cache2\entry"
        $shader = New-CacheFile "$env:APPDATA\Mozilla\Firefox\Profiles\p.default\shader-cache\entry"
        $profile = New-CacheFile "$env:APPDATA\Mozilla\Firefox\Profiles\p.default\cache2\kept"
        Clear-BrowserCaches
        Test-Path -LiteralPath $cache | Should -BeFalse
        Test-Path -LiteralPath $shader | Should -BeFalse
        Test-Path -LiteralPath $profile | Should -BeTrue
    }

    It 'Cleans exact application caches for <Folder> and keeps authored state' -ForEach @(
        @{Folder='Cursor'}, @{Folder='Windsurf'}, @{Folder='obsidian'}, @{Folder='Notion'}
    ) {
        $cache = New-CacheFile "$env:APPDATA\$Folder\Code Cache\entry"
        $state = New-CacheFile "$env:APPDATA\$Folder\User\workspaceStorage\state"
        $offline = New-CacheFile "$env:APPDATA\$Folder\Service Worker\CacheStorage\offline"
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeFalse
        Test-Path -LiteralPath $state | Should -BeTrue
        Test-Path -LiteralPath $offline | Should -BeTrue
    }

    It 'Allows only new Teams WebView disk-cache leaves within Packages' {
        $root = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        $kept = @(
            (New-CacheFile "$root\Default\IndexedDB\state"),
            (New-CacheFile "$root\Default\CacheStorage\offline"),
            (New-CacheFile "$root\Cache\entry"),
            (New-CacheFile "$env:LOCALAPPDATA\Packages\Other_app\LocalCache\Default\Cache\entry")
        )
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeFalse
        foreach ($file in $kept) { Test-Path -LiteralPath $file | Should -BeTrue; Test-SafePath $file | Should -BeFalse }
        $script:MoleCleanPathGuard = $false
        Test-SafePath "$root\Default\Cache" | Should -BeFalse
    }

    It 'Honors an explicit Packages whitelist even for Teams cache leaves' {
        $cache = New-CacheFile "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Cache\entry"
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value "$env:LOCALAPPDATA\Packages\*"
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Keeps caches when the owner runs or its process probe fails for <Unknown>' -ForEach @(@{Unknown=$false},@{Unknown=$true}) {
        $cache = New-CacheFile "$env:APPDATA\Cursor\Cache\entry"
        if ($Unknown) { Mock Get-Process { throw 'unavailable' } }
        else { Mock Get-Process { [pscustomobject]@{ProcessName='Cursor'} } }
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Rechecks the owner after sizing in dry-run <Dry>' -ForEach @(@{Dry=$true},@{Dry=$false}) {
        Set-DryRunMode -Enabled $Dry
        $cache = New-CacheFile "$env:APPDATA\Cursor\Cache\nested\entry"
        $script:CacheOwnerStarted = $false
        Mock Get-Process { if ($script:CacheOwnerStarted) { [pscustomobject]@{ProcessName='Cursor'} } }
        Mock Get-ValidatedTreeSize { $script:CacheOwnerStarted = $true; return 13 }
        Clear-AppCaches
        Should -Invoke Get-ValidatedTreeSize -Times 1 -Exactly
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
        Test-Path -LiteralPath $script:ExportListFile | Should -BeFalse
    }

    It 'Preserves protected stores even when passed to the shared sink directly' {
        $files = @(
            (New-CacheFile "$env:LOCALAPPDATA\pypoetry\Cache\virtualenvs\project\python.exe"),
            (New-CacheFile "$env:APPDATA\Slack\Service Worker\CacheStorage\offline")
        )
        $ordinary = New-CacheFile "$env:APPDATA\Slack\Cache\entry"
        Remove-SafeItems -Paths ($files + @($ordinary))
        foreach ($file in $files) { Test-Path -LiteralPath $file | Should -BeTrue }
        Test-Path -LiteralPath $ordinary | Should -BeFalse
    }

    It 'Records a last-moment busy owner as skipped with no reclaimed files' {
        $cache = New-CacheFile "$env:APPDATA\Cursor\Cache\nested\entry"
        $script:OwnerProbeCalls = 0
        Mock Get-Process {
            $script:OwnerProbeCalls++
            if ($script:OwnerProbeCalls -ge 3) { [pscustomobject]@{ProcessName='Cursor'} }
        }
        Mock Write-MoleOperation {}
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'SKIPPED' }
        Should -Invoke Write-MoleOperation -Times 0 -Exactly -ParameterFilter { $Action -eq 'REMOVED' -or $Action -eq 'FAILED' }
    }

    It 'Supports Opera root and profile caches in both app-data locations' {
        $files = @(foreach ($root in @($env:APPDATA,$env:LOCALAPPDATA)) {
            New-CacheFile "$root\Opera Software\Opera Stable\Cache\entry"
            New-CacheFile "$root\Opera Software\Opera Stable\Default\Code Cache\entry"
        })
        Clear-BrowserCaches
        foreach ($file in $files) { Test-Path -LiteralPath $file | Should -BeFalse }
    }

    It 'Keeps locked new Teams caches and cleans them after the lock closes' {
        $root = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        $lock = New-CacheFile "$root\lockfile"
        $handle = [IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { Clear-AppCaches; Test-Path -LiteralPath $cache | Should -BeTrue }
        finally { $handle.Dispose() }
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeFalse
        Test-Path -LiteralPath $lock | Should -BeTrue
    }

    It 'Never follows a linked browser profile and still cleans a real profile' {
        $root = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        $outside = New-CacheFile "$env:USERPROFILE\outside\Cache\kept"
        $link = Join-Path $root 'Profile 2'
        New-Item -ItemType Junction -Path $link -Target (Join-Path $env:USERPROFILE 'outside') | Out-Null
        try {
            Clear-BrowserCaches
            Test-Path -LiteralPath $outside | Should -BeTrue
            Test-Path -LiteralPath $cache | Should -BeFalse
        }
        finally { [IO.Directory]::Delete($link,$false) }
    }

    It 'Discards all discovered profiles when one profile is unreadable' {
        $root = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        $unreadable = New-CacheFile "$root\Profile 2\Cache\entry"
        $other = New-CacheFile "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache\entry"
        $script:RealCacheGetItem = Get-Command Get-Item -CommandType Cmdlet
        Mock Get-Item { & $script:RealCacheGetItem -LiteralPath $LiteralPath -Force -ErrorAction Stop }
        Mock Get-Item { throw 'access denied' } -ParameterFilter { $LiteralPath -like '*\Google\Chrome\User Data\Profile 2' }
        Clear-BrowserCaches
        Should -Invoke Get-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*\Google\Chrome\User Data\Profile 2' }
        Test-Path -LiteralPath $cache | Should -BeTrue
        Test-Path -LiteralPath $unreadable | Should -BeTrue
        Test-Path -LiteralPath $other | Should -BeFalse
    }

    It 'Discards an oversized profile enumeration instead of cleaning a partial list' {
        $root = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        foreach ($n in 1..128) { New-Item -ItemType Directory -Path "$root\Profile $n" | Out-Null }
        Clear-BrowserCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Preserves all files in dry-run and lists only disposable cache paths' {
        $cache = New-CacheFile "$env:APPDATA\Cursor\Cache\entry"
        $offline = New-CacheFile "$env:APPDATA\Cursor\Service Worker\CacheStorage\offline"
        Set-DryRunMode -Enabled $true
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        Test-Path -LiteralPath $offline | Should -BeTrue
        Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Match ([regex]::Escape($cache))
        Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Not -Match 'CacheStorage'
        (Get-CleanupStats).FilesCleaned | Should -Be 1
    }
}

Describe 'Native cache-owner process evidence' {
    It 'Detects the current process and accepts a nonexistent owner without mocks' {
        $current = Get-Process -Id $PID
        Test-MoleCacheOwnerIdle -Names @($current.ProcessName) | Should -BeFalse
        Test-MoleCacheOwnerIdle -Names @('mole-fixture-' + [guid]::NewGuid().ToString('N')) | Should -BeTrue
    }
}

Describe 'Delivery Optimization files' {
    BeforeEach {
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0,8))
        $env:MO_NO_OPLOG = '1'
        $script:Config.WhitelistFile = Join-Path $env:USERPROFILE 'whitelist.txt'
        New-Item -ItemType Directory -Path $env:USERPROFILE -Force | Out-Null
        $script:ExportListFile = Join-Path $env:USERPROFILE 'preview.txt'
        Set-DryRunMode -Enabled $false
        Reset-CleanupStats
        Mock Write-MoleOperation {}
        $script:DoRoot = 'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
        $script:DoFiles = @(
            [pscustomobject]@{ FileId='aa11'; Status=1; IsPinned=$false; FileSizeInCache=1048576 }
            [pscustomobject]@{ FileId='bb22'; Status=2; IsPinned=$false; FileSizeInCache=2097152 }
            [pscustomobject]@{ FileId='cc33'; Status=0; IsPinned=$false; FileSizeInCache=4194304 }
            [pscustomobject]@{ FileId='dd44'; Status=3; IsPinned=$false; FileSizeInCache=4194304 }
            [pscustomobject]@{ FileId='ee55'; Status=1; IsPinned=$true; FileSizeInCache=4194304 }
            [pscustomobject]@{ FileId="ff66' OR 1=1"; Status=1; IsPinned=$false; FileSizeInCache=4194304 }
        )
        $script:DoDeleted = New-Object 'System.Collections.Generic.List[string]'
        Mock Get-CimInstance { @($script:DoFiles | Where-Object { -not $script:DoDeleted.Contains($_.FileId) }) } -ParameterFilter { $ClassName -eq 'MSFT_DeliveryOptimizationFile' }
        Mock Get-CimInstance { [pscustomobject]@{ WorkingDirectory = $script:DoRoot } } -ParameterFilter { $ClassName -eq 'MSFT_DeliveryOptimizationExtendedConfig' }
        Mock Invoke-CimMethod { $script:DoDeleted.Add($Arguments.fileId) }
    }

    It 'Asks the service to delete only finished, unpinned files and counts what it no longer lists' {
        Clear-DeliveryOptimizationFiles
        Should -Invoke Invoke-CimMethod -Times 2 -Exactly
        Should -Invoke Invoke-CimMethod -Times 2 -Exactly -ParameterFilter { $Arguments.deletePinned -eq $false -and $Arguments.fileId -in @('aa11', 'bb22') }
        (Get-CleanupStats).TotalSizeKB | Should -Be 3072
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'OWNER' -and $Path -eq $script:DoRoot }
    }

    It 'Counts nothing the service still lists after its delete' {
        Mock Invoke-CimMethod { }
        Clear-DeliveryOptimizationFiles
        (Get-CleanupStats).TotalSizeKB | Should -Be 0
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'FAILED' }
    }

    It 'Previews the finished files without asking the service to delete' {
        Set-DryRunMode -Enabled $true
        Clear-DeliveryOptimizationFiles
        Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        (Get-CleanupStats).TotalSizeKB | Should -Be 3072
        Get-Content -LiteralPath $script:ExportListFile | Should -Contain $script:DoRoot
    }

    It 'Keeps everything when the provider does not answer' {
        Mock Get-CimInstance { throw 'provider unavailable' } -ParameterFilter { $ClassName -eq 'MSFT_DeliveryOptimizationFile' }
        Clear-DeliveryOptimizationFiles
        Should -Invoke Invoke-CimMethod -Times 0 -Exactly
    }

    It 'Keeps everything when the user whitelists a folder inside the cache root' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value "$script:DoRoot\Downloads"
        Clear-DeliveryOptimizationFiles
        Should -Invoke Invoke-CimMethod -Times 0 -Exactly
    }

    It 'Leaves files the provider describes in another shape' {
        $script:DoFiles = @(
            [pscustomobject]@{ FileId='aa11'; Status='Complete'; IsPinned=$false; FileSizeInCache=1048576 }
            [pscustomobject]@{ FileId='bb22'; Status=1; IsPinned=$null; FileSizeInCache=1048576 }
        )
        { Clear-DeliveryOptimizationFiles } | Should -Not -Throw
        Should -Invoke Invoke-CimMethod -Times 0 -Exactly
    }

    It 'Keeps everything when the user whitelists the cache root' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value $script:DoRoot
        Clear-DeliveryOptimizationFiles
        Should -Invoke Invoke-CimMethod -Times 0 -Exactly
    }

    Context 'wildcard rows that may reach the cache, checked against a fixture tree' {
        BeforeEach {
            $script:DoBase = Join-Path $TestDrive ('do' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $script:DoRoot = Join-Path $script:DoBase 'NetworkService\DeliveryOptimization\Cache'
            New-Item -ItemType Directory -Path (Join-Path $script:DoRoot 'Downloads') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:DoRoot 'ab') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:DoRoot 'ab\payload') -Value 'x'
            Set-Content -LiteralPath (Join-Path $script:DoRoot 'x') -Value 'x'
        }

        It 'Keeps everything when the row matches an entry on disk in preview <Preview>: <Pattern>' -ForEach @(
            @{ Pattern = '{base}\*\DeliveryOptimization\Cache\x'; Preview = $false }
            @{ Pattern = '{root}\a*'; Preview = $false }
            @{ Pattern = '*\DeliveryOptimization\*'; Preview = $false }
            @{ Pattern = '{base}\*\DeliveryOptimization\Cache\Downloads'; Preview = $false }
            @{ Pattern = '{base}\*\DeliveryOptimization\Cache\Downloads'; Preview = $true }
            @{ Pattern = '*\DeliveryOptimization\Cache\??*'; Preview = $false }
            @{ Pattern = '*\DeliveryOptimization\Cache\??*'; Preview = $true }
            @{ Pattern = '*\DeliveryOptimization\Cache\[a-z]*\payload'; Preview = $false }
            @{ Pattern = '*\DeliveryOptimization\Cache\[a-z]*\payload'; Preview = $true }
            @{ Pattern = '{base}\Net?orkService'; Preview = $false }
        ) {
            Set-DryRunMode -Enabled $Preview
            Set-Content -LiteralPath $script:Config.WhitelistFile -Value $Pattern.Replace('{base}', $script:DoBase).Replace('{root}', $script:DoRoot)
            Clear-DeliveryOptimizationFiles
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
            (Get-CleanupStats).TotalSizeKB | Should -Be 0
        }

        It 'Still clears when the row matches nothing in the tree in preview <Preview>: <Pattern>' -ForEach @(
            @{ Pattern = '*\node_modules'; Preview = $false }
            @{ Pattern = '*\node_modules'; Preview = $true }
            @{ Pattern = '{base}\*\DeliveryOptimization\Cache\missing'; Preview = $false }
            @{ Pattern = '*.iso'; Preview = $false }
        ) {
            Set-DryRunMode -Enabled $Preview
            Set-Content -LiteralPath $script:Config.WhitelistFile -Value $Pattern.Replace('{base}', $script:DoBase)
            Clear-DeliveryOptimizationFiles
            (Get-CleanupStats).TotalSizeKB | Should -Be 3072
            if (-not $Preview) { Should -Invoke Invoke-CimMethod -Times 2 -Exactly }
        }

        It 'Keeps everything when the tree cannot be read' {
            Remove-Item -LiteralPath $script:DoBase -Recurse -Force
            Set-Content -LiteralPath $script:Config.WhitelistFile -Value '*\node_modules'
            Clear-DeliveryOptimizationFiles
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        }

        It 'Keeps everything when the tree holds a link' {
            $target = Join-Path $script:DoBase 'elsewhere'
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            New-Item -ItemType Junction -Path (Join-Path $script:DoRoot 'link') -Target $target | Out-Null
            Set-Content -LiteralPath $script:Config.WhitelistFile -Value '*\node_modules'
            Clear-DeliveryOptimizationFiles
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        }

        It 'Keeps everything when the walk does not finish' {
            Mock Get-TreeItemsNoFollow { throw 'Cleanup walk timed out' }
            Set-Content -LiteralPath $script:Config.WhitelistFile -Value '*\node_modules'
            Clear-DeliveryOptimizationFiles
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        }
    }

    It 'Still clears when an unrelated wildcard row is whitelisted' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value "$env:USERPROFILE\Downloads\*.iso"
        Clear-DeliveryOptimizationFiles
        Should -Invoke Invoke-CimMethod -Times 2 -Exactly
    }

    It 'Still clears beside an unrelated partial directory wildcard' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value 'C:\Unrelated*\Cache\*'
        Clear-DeliveryOptimizationFiles
        Should -Invoke Invoke-CimMethod -Times 2 -Exactly
    }

    It 'Keeps everything when protection appears right before the delete' {
        $script:DoWhitelistReads = 0
        Mock Get-WhitelistState {
            $script:DoWhitelistReads++
            @{ RetainAll = ($script:DoWhitelistReads -gt 1); Patterns = @(); Roots = @(); Prefixes = @(); Wild = @() }
        }
        Clear-DeliveryOptimizationFiles
        $script:DoWhitelistReads | Should -BeGreaterThan 1
        Should -Invoke Invoke-CimMethod -Times 0 -Exactly
    }

    It 'Leaves a file whose size the provider reports in another shape' {
        $script:DoFiles = @([pscustomobject]@{ FileId='aa11'; Status=1; IsPinned=$false; FileSizeInCache='1 MB' })
        { Clear-DeliveryOptimizationFiles } | Should -Not -Throw
        Should -Invoke Invoke-CimMethod -Times 0 -Exactly
    }
}

Describe 'NVIDIA driver installers' {
    BeforeEach {
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0,8))
        $env:MO_NO_OPLOG = '1'
        $script:Config.WhitelistFile = Join-Path $env:USERPROFILE 'whitelist.txt'
        $script:SavedSystemDrive = $env:SystemDrive
        $env:SystemDrive = Join-Path $env:USERPROFILE 'drive'
        $script:MoleCleanPathGuard = $true
        Set-DryRunMode -Enabled $false
        Reset-CleanupStats
        Mock Test-IsAdmin { $true }
        $script:NvidiaProcesses = @([pscustomobject]@{ ExecutablePath = "$env:WINDIR\explorer.exe" }, [pscustomobject]@{ ExecutablePath = $null })
        Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Process' } { $script:NvidiaProcesses }
        function Set-Age([string]$Path, [int]$Days) {
            foreach ($item in @(Get-Item -LiteralPath $Path -Force) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
                $item.LastWriteTime = (Get-Date).AddDays(-$Days); $item.CreationTime = (Get-Date).AddDays(-$Days)
            }
        }
    }
    AfterEach { $env:SystemDrive = $script:SavedSystemDrive }

    It 'Removes only week-old version folders and never the rest of the NVIDIA folder' {
        $root = Join-Path $env:SystemDrive 'NVIDIA'
        $old = New-CacheFile "$root\DisplayDriver\560.94\Win11_x64\setup.exe"
        $fresh = New-CacheFile "$root\DisplayDriver\581.57\Win11_x64\setup.exe"
        $mixed = New-CacheFile "$root\DisplayDriver\572.16\Win11_x64\setup.exe"
        $other = New-CacheFile "$root\GameReady\notes.txt"
        Set-Age "$root\DisplayDriver\560.94" 30
        Set-Age "$root\DisplayDriver\572.16" 30
        (Get-Item -LiteralPath $mixed).LastWriteTime = Get-Date
        Set-Age "$root\GameReady" 30
        Clear-NvidiaDriverInstallers
        Test-Path -LiteralPath "$root\DisplayDriver\560.94" | Should -BeFalse
        foreach ($file in @($fresh, $mixed, $other)) { Test-Path -LiteralPath $file | Should -BeTrue }
        Test-Path -LiteralPath "$root\DisplayDriver" | Should -BeTrue
    }

    It 'Keeps every version folder while a process runs from the folder or the process list is unknown: <Case>' -ForEach @(
        @{ Case = 'installer running' }, @{ Case = 'unknown' }, @{ Case = 'empty' }
    ) {
        $root = Join-Path $env:SystemDrive 'NVIDIA'
        $file = New-CacheFile "$root\DisplayDriver\560.94\Win11_x64\setup.exe"
        Set-Age "$root\DisplayDriver\560.94" 30
        $script:NvidiaSetup = $file
        switch ($Case) {
            'unknown' { Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Process' } { throw 'incomplete inventory' } }
            'empty' { Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Process' } { @() } }
            default { $script:NvidiaProcesses += [pscustomobject]@{ ExecutablePath = $script:NvidiaSetup } }
        }
        Clear-NvidiaDriverInstallers
        Test-Path -LiteralPath $file | Should -BeTrue
    }

    It 'Keeps the folder when an installer starts from it after the first check' {
        $root = Join-Path $env:SystemDrive 'NVIDIA'
        $file = New-CacheFile "$root\DisplayDriver\560.94\Win11_x64\setup.exe"
        Set-Age "$root\DisplayDriver\560.94" 30
        $script:NvidiaSetup = $file
        $script:NvidiaCalls = 0
        Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Process' } {
            $script:NvidiaCalls++
            if ($script:NvidiaCalls -gt 1) { [pscustomobject]@{ ExecutablePath = $script:NvidiaSetup } }
            else { [pscustomobject]@{ ExecutablePath = "$env:WINDIR\explorer.exe" } }
        }
        Clear-NvidiaDriverInstallers
        $script:NvidiaCalls | Should -BeGreaterThan 1
        Test-Path -LiteralPath $file | Should -BeTrue
    }

    It 'Keeps a version folder that changes after sizing' {
        $root = Join-Path $env:SystemDrive 'NVIDIA'
        $file = New-CacheFile "$root\DisplayDriver\560.94\setup.exe"
        Set-Age "$root\DisplayDriver\560.94" 30
        $script:Touched = $false
        Mock Get-ValidatedTreeSize { if (-not $script:Touched) { $script:Touched = $true; (Get-Item -LiteralPath $file).LastWriteTime = Get-Date }; return 13 }
        Clear-NvidiaDriverInstallers
        Test-Path -LiteralPath $file | Should -BeTrue
    }
}
