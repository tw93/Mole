# The releases AI command-line tools keep beside the one they run. Every layout
# here is the one Windows showed after installing an older release and updating
# it: Claude Code 2.1.311 to 2.1.327, Codex 0.168.0 to 0.170.0, Cursor Agent
# 2026.11.05 to 2026.11.17, Copilot CLI 1.0.111 to 1.0.114.
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . "$root\lib\core\base.ps1"
    . "$root\lib\core\log.ps1"
    . "$root\lib\core\ui.ps1"
    . "$root\lib\core\file_ops.ps1"
    . "$root\lib\clean\dev.ps1"

    $script:SavedProfile = $env:USERPROFILE
    $script:SavedLocal = $env:LOCALAPPDATA
    $script:SavedCodexDir = $env:CODEX_INSTALL_DIR
    $script:SavedNoOpLog = $env:MO_NO_OPLOG
    $script:SavedWhitelist = $script:Config.WhitelistFile
    $script:SavedPathGuard = $script:MoleCleanPathGuard
    # Nothing here reaches the developer's own operation log or whitelist, and
    # removals run under the clean path guard as mo clean does.
    $env:MO_NO_OPLOG = '1'
    $script:Config.WhitelistFile = Join-Path $TestDrive 'whitelist.txt'
    $script:MoleCleanPathGuard = $true
    # GetTempPath can be an 8.3 spelling (C:\Users\RUNNER~1); junction targets
    # come back long, so every fixture is built under the long spelling.
    $script:Drive = (Resolve-MoleExistingPathInfo -Path $TestDrive).Path

    function New-Fixture {
        param([string]$Path, [int]$Bytes = 16)
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
    }

    function Set-Junction {
        param([string]$Link, [string]$Target)
        if (Test-Path -LiteralPath $Link) { [IO.Directory]::Delete($Link) }
        New-Item -ItemType Directory -Path (Split-Path -Parent $Link) -Force | Out-Null
        New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
    }

    function New-Machine {
        $base = Join-Path $script:Drive ([guid]::NewGuid().ToString('N'))
        $env:USERPROFILE = Join-Path $base 'Users\tw'
        $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'AppData\Local'
        $env:CODEX_INSTALL_DIR = $null
        $script:Claude = "$env:USERPROFILE\.local\share\claude\versions"
        $script:Bin = "$env:USERPROFILE\.local\bin"
        $script:Codex = "$env:USERPROFILE\.codex\packages\standalone"
        $script:CodexOld = "$script:Codex\releases\0.168.0-aarch64-pc-windows-msvc"
        $script:CodexNew = "$script:Codex\releases\0.170.0-aarch64-pc-windows-msvc"
        $script:Cursor = "$env:LOCALAPPDATA\cursor-agent"
        $script:CursorOld = "$script:Cursor\versions\2026.11.05-86047df"
        $script:CursorNew = "$script:Cursor\versions\2026.11.17-f532c45"
        $script:Copilot = "$env:LOCALAPPDATA\copilot\pkg\win32-arm64"

        # Claude Code: single-file versions, the launcher a copy of the newest, and the launcher the update renamed.
        New-Fixture "$script:Claude\2.1.311" 30
        New-Fixture "$script:Claude\2.1.327" 40
        New-Fixture "$script:Bin\claude.exe" 40
        New-Fixture "$script:Bin\claude.exe.old.1795003367309.2484" 30
        # Codex: current a junction to the live release, auto-update-version naming it.
        New-Fixture "$script:CodexOld\bin\codex.exe"
        New-Fixture "$script:CodexNew\bin\codex.exe"
        Set-Junction "$script:Codex\current" $script:CodexNew
        Set-Content -LiteralPath "$script:Codex\auto-update-version" -Value '0.170.0-aarch64-pc-windows-msvc' -NoNewline
        New-Fixture "$script:Codex\install.lock" 0
        # Cursor Agent: launcher scripts beside versions named by date and commit.
        New-Fixture "$script:Cursor\cursor-agent.ps1"
        New-Fixture "$script:CursorOld\node.exe"
        New-Fixture "$script:CursorNew\node.exe"
        # Copilot: unpacked releases with their completion marker.
        foreach ($v in @('1.0.111', '1.0.114')) {
            New-Fixture "$script:Copilot\$v\copilot.exe"
            New-Fixture "$script:Copilot\$v\.extraction-complete" 0
        }
    }

    function Get-Offered { @(Get-MoleAiCliOldReleases | ForEach-Object { $_.Path } | Sort-Object) }
}

AfterAll {
    $env:USERPROFILE = $script:SavedProfile
    $env:LOCALAPPDATA = $script:SavedLocal
    $env:CODEX_INSTALL_DIR = $script:SavedCodexDir
    $env:MO_NO_OPLOG = $script:SavedNoOpLog
    $script:Config.WhitelistFile = $script:SavedWhitelist
    $script:MoleCleanPathGuard = $script:SavedPathGuard
}

Describe 'AI CLI old releases' {
    BeforeEach {
        New-Machine
        Set-DryRunMode -Enabled $false
        Mock Test-MoleFilesInUse { $false }
    }

    It 'Offers each tool''s superseded releases and keeps the ones it runs' {
        $offered = Get-Offered
        $expected = @(
            "$script:Bin\claude.exe.old.1795003367309.2484"
            "$script:Claude\2.1.311"
            $script:CodexOld
            $script:CursorOld
            "$script:Copilot\1.0.111"
        ) | Sort-Object
        $offered | Should -Be $expected
    }

    It 'Compares versions by number, not text' {
        Compare-MoleVersionName '1.0.114' '1.0.9' | Should -Be 1
        Compare-MoleVersionName '2026.11.05' '2026.11.17' | Should -Be -1
        Compare-MoleVersionName '0.170.0' '0.170.0' | Should -Be 0
    }

    It 'Keeps the Codex release current points at and offers nothing without a current junction' {
        Set-Junction "$script:Codex\current" $script:CodexOld
        Remove-Item -LiteralPath "$script:Codex\auto-update-version"
        Get-Offered | Should -Not -Contain $script:CodexOld

        [IO.Directory]::Delete("$script:Codex\current")
        (Get-Offered | Where-Object { $_ -like "$script:Codex*" }) | Should -BeNullOrEmpty
    }

    It 'Keeps the release the Codex launcher on PATH runs, and offers nothing when that launcher cannot be read' {
        $visible = "$env:LOCALAPPDATA\Programs\OpenAI\Codex\bin"
        Set-Junction $visible "$script:CodexOld\bin"
        Get-Offered | Should -Not -Contain $script:CodexOld

        Set-Junction $visible "$script:CodexNew\bin"
        Get-Offered | Should -Contain $script:CodexOld

        $elsewhere = Join-Path $script:Drive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path "$elsewhere\bin" -Force | Out-Null
        Set-Junction $visible "$elsewhere\bin"
        Get-Offered | Should -Not -Contain $script:CodexOld
    }

    It 'Offers no Codex release while an install runs or CODEX_INSTALL_DIR moves its launcher' {
        New-Item -ItemType Directory -Path "$script:Codex\install.lock.d" | Out-Null
        Get-Offered | Should -Not -Contain $script:CodexOld
        Remove-Item -LiteralPath "$script:Codex\install.lock.d"

        $held = [IO.File]::Open("$script:Codex\install.lock", 'Open', 'ReadWrite', 'None')
        try { Get-Offered | Should -Not -Contain $script:CodexOld }
        finally { $held.Dispose() }
        Get-Offered | Should -Contain $script:CodexOld

        $env:CODEX_INSTALL_DIR = 'D:\Tools\Codex'
        Get-Offered | Should -Not -Contain $script:CodexOld
    }

    It 'Only a folder named and built as a Codex release is one' {
        New-Fixture "$script:Codex\releases\backup\bin\codex.exe"
        New-Fixture "$script:Codex\releases\latest\bin\codex.exe"
        New-Fixture "$script:Codex\releases\.staging.1\bin\codex.exe"
        New-Fixture "$script:Codex\releases\0.169.0-aarch64-pc-windows-msvc\codex-package.json"
        $offered = Get-Offered
        $offered | Should -Contain $script:CodexOld
        $offered | Where-Object { $_ -match 'backup|latest|staging|0\.169\.0' } | Should -BeNullOrEmpty
    }

    It 'Keeps every Cursor folder of the newest date and offers nothing while an update is staged or both name forms exist' {
        New-Fixture "$script:Cursor\versions\2026.11.17-aaaaaaa\node.exe"
        $offered = @(Get-Offered | Where-Object { $_ -like "$script:Cursor*" })
        $offered | Should -Be @($script:CursorOld)

        New-Fixture "$script:Cursor\versions\2026.11.17-01-02-03-bbbbbbb\node.exe"
        (Get-Offered | Where-Object { $_ -like "$script:Cursor*" }) | Should -BeNullOrEmpty
        Remove-Item -LiteralPath "$script:Cursor\versions\2026.11.17-01-02-03-bbbbbbb" -Recurse

        New-Fixture "$script:Cursor\versions\2026.11.18-ccccccc.new\node.exe"
        (Get-Offered | Where-Object { $_ -like "$script:Cursor*" }) | Should -BeNullOrEmpty
        Remove-Item -LiteralPath "$script:Cursor\versions\2026.11.18-ccccccc.new" -Recurse

        Remove-Item -LiteralPath "$script:Cursor\cursor-agent.ps1"
        (Get-Offered | Where-Object { $_ -like "$script:Cursor*" }) | Should -BeNullOrEmpty
    }

    It 'Keeps the newest complete Copilot release and never an incomplete one' {
        New-Fixture "$script:Copilot\1.0.115\copilot.exe"
        $offered = Get-Offered
        $offered | Should -Contain "$script:Copilot\1.0.111"
        $offered | Should -Not -Contain "$script:Copilot\1.0.114"
        $offered | Should -Not -Contain "$script:Copilot\1.0.115"
    }

    It 'Keeps the Claude version the launcher copies, and offers nothing without a launcher or during an install' {
        # claude install 2.1.311 copied the older one back.
        New-Fixture "$script:Bin\claude.exe" 30
        Get-Offered | Should -Not -Contain "$script:Claude\2.1.311"
        Get-Offered | Should -Not -Contain "$script:Claude\2.1.327"

        New-Fixture "$script:Bin\claude.exe" 40
        New-Fixture "$env:USERPROFILE\.local\state\claude\locks\2.1.330.lock" 0
        (Get-Offered | Where-Object { $_ -like "$env:USERPROFILE\.local\*" }) | Should -BeNullOrEmpty
        Remove-Item -LiteralPath "$env:USERPROFILE\.local\state\claude\locks\2.1.330.lock"

        # An update renamed the running launcher and then failed to write the new one.
        Remove-Item -LiteralPath "$script:Bin\claude.exe"
        (Get-Offered | Where-Object { $_ -like "$env:USERPROFILE\.local\*" }) | Should -BeNullOrEmpty
    }

    It 'A home reached through a link offers nothing' {
        $moved = Join-Path $script:Drive ([guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $script:Cursor -Destination $moved
        Set-Junction $script:Cursor $moved
        (Get-Offered | Where-Object { $_ -like "$script:Cursor*" }) | Should -BeNullOrEmpty
    }

    It 'A release with no program file, or one the Restart Manager cannot answer for, counts as in use' {
        New-Fixture "$script:Copilot\1.0.112\index.js"
        Test-MoleAiReleaseInUse -Path "$script:Copilot\1.0.112" | Should -BeNullOrEmpty
        Test-MoleAiReleaseInUse -Path $script:CursorOld | Should -BeFalse

        Mock Test-MoleFilesInUse { $null }
        Test-MoleAiReleaseInUse -Path $script:CursorOld | Should -BeNullOrEmpty
    }

    It 'Removes the superseded releases and nothing it still runs' {
        Mock Test-MoleFilesInUse { $true } -ParameterFilter { @($Paths) -contains "$script:CursorOld\node.exe" }
        Clear-AiCliOldVersions
        foreach ($gone in @("$script:Claude\2.1.311", "$script:Bin\claude.exe.old.1795003367309.2484", $script:CodexOld, "$script:Copilot\1.0.111")) {
            Test-Path -LiteralPath $gone | Should -BeFalse -Because $gone
        }
        foreach ($kept in @("$script:CursorOld\node.exe", "$script:Claude\2.1.327", "$script:Bin\claude.exe", "$script:CodexNew\bin\codex.exe",
                "$script:CursorNew\node.exe", "$script:Copilot\1.0.114\copilot.exe", "$script:Codex\auto-update-version")) {
            Test-Path -LiteralPath $kept | Should -BeTrue -Because $kept
        }
    }

    It 'The removal asks again and keeps a release that became current between the scan and the delete' {
        $script:GuardAnswers = @{}
        Mock Remove-SafeItem {
            if ($Path -eq $script:CodexOld) {
                Set-Junction "$script:Codex\current" $script:CodexOld
                Remove-Item -LiteralPath "$script:Codex\auto-update-version"
            }
            $script:GuardAnswers[$Path] = & $Guard $Path
            $true
        }
        Clear-AiCliOldVersions
        $script:GuardAnswers[$script:CodexOld] | Should -BeFalse
        $script:GuardAnswers["$script:Copilot\1.0.111"] | Should -BeTrue
    }

    It 'A dry run removes nothing' {
        Set-DryRunMode -Enabled $true
        try { Clear-AiCliOldVersions }
        finally { Set-DryRunMode -Enabled $false }
        foreach ($kept in @("$script:Claude\2.1.311", "$script:Bin\claude.exe.old.1795003367309.2484", $script:CodexOld, $script:CursorOld, "$script:Copilot\1.0.111")) {
            Test-Path -LiteralPath $kept | Should -BeTrue -Because $kept
        }
    }

    It 'Keeps a release that became the one in use since the scan' {
        Test-MoleAiReleaseStillOld -Path $script:CodexOld | Should -BeTrue
        Set-Junction "$script:Codex\current" $script:CodexOld
        Remove-Item -LiteralPath "$script:Codex\auto-update-version"
        Test-MoleAiReleaseStillOld -Path $script:CodexOld | Should -BeFalse
    }
}

Describe 'Restart Manager probe' {
    It 'Names a running exe, also after it was renamed, and frees it once it exits' {
        $folder = Join-Path $script:Drive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $exe = Join-Path $folder 'release.exe'
        $idle = Join-Path $folder 'idle.dll'
        Copy-Item -LiteralPath "$env:SystemRoot\System32\PING.EXE" -Destination $exe
        [IO.File]::WriteAllBytes($idle, [byte[]](1, 2, 3))
        $process = Start-Process -FilePath $exe -ArgumentList '-n 60 127.0.0.1' -WindowStyle Hidden -PassThru
        try {
            Start-Sleep -Milliseconds 500
            Test-MoleFilesInUse -Paths @($exe) | Should -BeTrue
            Test-MoleFilesInUse -Paths @($idle, $exe) | Should -BeTrue
            Test-MoleFilesInUse -Paths @($idle) | Should -BeFalse
            $renamed = "$exe.old.1"
            Move-Item -LiteralPath $exe -Destination $renamed
            Test-MoleFilesInUse -Paths @($renamed) | Should -BeTrue
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit(10000) | Out-Null
            $process.Dispose()
            Start-Sleep -Milliseconds 200
            Test-MoleFilesInUse -Paths @($renamed) | Should -BeFalse
        }
        finally {
            try { if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force } } catch { }
        }
    }
}
