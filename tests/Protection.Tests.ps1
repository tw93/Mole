# Mole Windows - protected path segments and user data clean must not touch

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir "lib"

    . "$script:LibDir\core\base.ps1"
    . "$script:LibDir\core\log.ps1"
    . "$script:LibDir\core\ui.ps1"
    . "$script:LibDir\core\file_ops.ps1"

    . "$script:LibDir\clean\user.ps1"
    . "$script:LibDir\clean\caches.ps1"
    . "$script:LibDir\clean\dev.ps1"
    . "$script:LibDir\clean\apps.ps1"
    . "$script:LibDir\clean\system.ps1"

    $env:MOLE_DRY_RUN = "1"
    Set-DryRunMode -Enabled $true
}

AfterAll {
    $env:MOLE_DRY_RUN = $null
    Set-DryRunMode -Enabled $false
    $script:MoleCleanPathGuard = $false
}

Describe "Protected path segments" {
    BeforeAll {
        $script:P = Join-Path $TestDrive "Users\tester"
        $script:Roaming = Join-Path $script:P "AppData\Roaming"
        $script:Local = Join-Path $script:P "AppData\Local"
        $script:Chrome = Join-Path $script:Local "Google\Chrome\User Data\Default"
    }

    AfterEach {
        $script:MoleCleanPathGuard = $false
    }

    It "Refuses Windows secret stores and the Start Menu for every command" {
        $script:MoleCleanPathGuard = $false
        $refused = @(
            "$script:Roaming\Microsoft\Credentials\ABCDEF"
            "$script:Local\Microsoft\Credentials"
            "$script:Roaming\Microsoft\Protect\S-1-5-21-1\key"
            "$script:Roaming\Microsoft\Crypto\RSA\S-1-5-21-1\k"
            "$script:Local\Microsoft\Vault\4BF4C442"
            "$script:Roaming\Microsoft\SystemCertificates\My\Certificates\c"
            "$script:Roaming\Microsoft\Windows\Start Menu\Programs\App.lnk"
            "$script:Roaming\microsoft\credentials\lower-case"
        )
        foreach ($path in $refused) {
            Test-SafePath -Path $path | Should -BeFalse -Because $path
        }
    }

    It "Refuses key, browser profile and transcript stores during clean" {
        $script:MoleCleanPathGuard = $true
        $refused = @(
            "$script:P\.ssh\id_ed25519"
            "$script:P\.SSH"
            "$script:P\.gnupg\private-keys-v1.d\k.key"
            "$script:P\.aws\cli\cache\token.json"
            "$script:P\.azure\logs\az.log"
            "$script:P\.kube\cache\discovery\x.json"
            "$script:P\.docker\config.json"
            "$script:Chrome\Login Data"
            "$script:Chrome\Network\Cookies"
            "$script:Chrome\Web Data"
            "$script:Chrome\Local Storage\leveldb\000003.log"
            "$script:Chrome\local storage"
            "$script:Chrome\Session Storage\x"
            "$script:Chrome\IndexedDB\https_example.com_0.indexeddb.leveldb\1.log"
            "$script:Chrome\Sessions\Session_1"
            "$script:Chrome\Local Extension Settings\abc\000001.log"
            "$script:Chrome\Sync Data\LevelDB\x"
            "$script:Roaming\Code\User\History\-1a2b\entries.json"
            "$script:P\.claude\projects\proj\session.jsonl"
            "$script:P\.claude\file-history\x"
            "$script:P\.claude\history.jsonl"
            "$script:P\.codex\sessions\2026\10\rollout.jsonl"
            "$script:P\.codex\archived_sessions\rollout.jsonl"
            "$script:P\.codex\history.jsonl"
        )
        foreach ($path in $refused) {
            Test-SafePath -Path $path | Should -BeFalse -Because $path
        }
    }

    It "Matches whole segments, not names that only start the same" {
        $script:MoleCleanPathGuard = $true
        $allowed = @(
            "$script:P\.awsome\cache\x"
            "$script:P\.sshd-cache\x"
            "$script:P\.claude\statsig\x"
            "$script:P\.codex\cache\x"
            "$script:Chrome\Cache\Cache_Data\f_000001"
            "$script:Chrome\CookiesBackup\x"
            "$script:Roaming\Microsoft\Cryptography\x"
            "$script:Roaming\Microsoft\VaultCache\x"
            "$script:Roaming\Code\CachedData\User\x"
        )
        foreach ($path in $allowed) {
            Test-SafePath -Path $path | Should -BeTrue -Because $path
        }
    }

    It "Leaves the clean-only segments to clean, so purge can remove node_modules\cookies" {
        $script:MoleCleanPathGuard = $false
        Test-SafePath -Path (Join-Path $TestDrive "project\node_modules\cookies\index.js") | Should -BeTrue
    }

    It "Turns the clean-only guard on in mo clean" {
        $source = Get-Content -Path (Join-Path $script:WindowsDir "bin\clean.ps1")
        $code = @($source | Where-Object { $_ -notmatch '^\s*#' })
        @($code | Where-Object { $_ -match '^\s*\$script:MoleCleanPathGuard\s*=\s*\$true\s*$' }).Count | Should -Be 1
    }
}

Describe "Clean leaves user data alone" {
    BeforeAll {
        $script:Saved = @{
            USERPROFILE  = $env:USERPROFILE
            APPDATA      = $env:APPDATA
            LOCALAPPDATA = $env:LOCALAPPDATA
            TEMP         = $env:TEMP
            TMP          = $env:TMP
        }

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $env:USERPROFILE = Join-Path $root "Users\tester"
        $env:APPDATA = Join-Path $env:USERPROFILE "AppData\Roaming"
        $env:LOCALAPPDATA = Join-Path $env:USERPROFILE "AppData\Local"
        $env:TEMP = Join-Path $env:LOCALAPPDATA "Temp"
        $env:TMP = $env:TEMP
        $old = (Get-Date).AddDays(-200)

        function New-OldFile {
            param([string]$Path)
            New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
            Set-Content -Path $Path -Value ("x" * 2048)
            (Get-Item -LiteralPath $Path).LastWriteTime = $old
            (Get-Item -LiteralPath $Path).CreationTime = $old
            (Get-Item -LiteralPath $Path).CreationTime = $old
        }

        $dropbox = Join-Path $root "Dropbox"
        # Folders clean used to empty or prune that hold user data.
        $script:UserData = @(
            "$env:APPDATA\Zoom\data"
            "$env:APPDATA\Microsoft\Teams\IndexedDB"
            "$env:APPDATA\Microsoft\Teams\Local Storage"
            "$env:APPDATA\Microsoft\Teams\databases"
            "$env:APPDATA\Microsoft\Windows\Recent"
            "$env:LOCALAPPDATA\Microsoft\Office\16.0\OfficeFileCache"
            "$env:LOCALAPPDATA\Microsoft\Office\15.0\OfficeFileCache"
            "$env:LOCALAPPDATA\Microsoft\Outlook\RoamCache"
            "$env:LOCALAPPDATA\Microsoft\OneDrive\logs"
            "$dropbox\.dropbox.cache"
            "$env:USERPROFILE\.aws"
            "$env:USERPROFILE\.azure"
            "$env:USERPROFILE\.kube"
            "$env:APPDATA\jupyter\runtime"
            "$env:USERPROFILE\.hex\packages"
            "$env:USERPROFILE\.cabal\packages"
            "$env:USERPROFILE\.cabal\store"
            "$env:USERPROFILE\.stack\programs"
        )
        $files = @(
            "$env:APPDATA\Zoom\data\zoomus.enc.db"
            "$env:APPDATA\Microsoft\Teams\IndexedDB\https_teams.microsoft.com_0.indexeddb.leveldb\000003.log"
            "$env:APPDATA\Microsoft\Teams\Local Storage\leveldb\000003.log"
            "$env:APPDATA\Microsoft\Teams\databases\Databases.db"
            "$env:APPDATA\Microsoft\Windows\Recent\report.docx.lnk"
            "$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations\5f7b5f1e01b83767.automaticDestinations-ms"
            "$env:LOCALAPPDATA\Microsoft\Office\16.0\OfficeFileCache\FSD-1.FSD"
            "$env:LOCALAPPDATA\Microsoft\Office\15.0\OfficeFileCache\FSD-1.FSD"
            "$env:LOCALAPPDATA\Microsoft\Outlook\RoamCache\Stream_Autocomplete_0.dat"
            "$env:LOCALAPPDATA\Microsoft\OneDrive\logs\Personal\general.keystore"
            "$env:LOCALAPPDATA\Microsoft\OneDrive\logs\SyncDiagnostics.log"
            "$dropbox\.dropbox.cache\unsynced.bin"
            "$env:USERPROFILE\.aws\cli\cache\assumed-role.json"
            "$env:USERPROFILE\.azure\logs\az.log"
            "$env:USERPROFILE\.kube\cache\discovery\x.json"
            "$env:APPDATA\jupyter\runtime\kernel-1.json"
            "$env:USERPROFILE\.hex\packages\hexpm\phoenix\mix.exs"
            "$env:USERPROFILE\.cabal\packages\hackage.haskell.org\aeson\aeson.tar.gz"
            "$env:USERPROFILE\.cabal\store\ghc-9.4.7\aeson-2.1.2.1\cabal-hash.txt"
            "$env:USERPROFILE\.stack\programs\x86_64-windows\ghc-9.4.7\bin\ghc.exe"
            "$env:USERPROFILE\memory.dmp"
            "$env:USERPROFILE\install.log"
            # Kept rows, the positive control that the run below lists what it would clean.
            "$env:APPDATA\Microsoft\Teams\Cache\data_0"
            "$env:APPDATA\Microsoft\Teams\GPUCache\data_1"
            "$env:LOCALAPPDATA\CrashDumps\app.exe.1234.dmp"
            "$env:APPDATA\gcloud\logs\gcloud.log"
        )
        foreach ($file in $files) {
            New-OldFile -Path $file
        }
        # The Hex and Stack rows pruned top-level folders by their own age.
        Get-ChildItem -Path "$env:USERPROFILE\.hex\packages" -Directory | ForEach-Object { $_.LastWriteTime = $old }
        Get-ChildItem -Path "$env:USERPROFILE\.stack\programs" -Directory | ForEach-Object { $_.LastWriteTime = $old }
        Get-ChildItem -Path "$env:USERPROFILE\.cabal\store" -Directory | ForEach-Object { $_.LastWriteTime = $old }
        New-Item -ItemType Directory -Path "$env:LOCALAPPDATA\Dropbox" -Force | Out-Null
        @{ personal = @{ path = $dropbox } } | ConvertTo-Json | Set-Content -Path "$env:LOCALAPPDATA\Dropbox\info.json"

        # The segment guard is off here, so these assertions are about the rows themselves.
        $script:MoleCleanPathGuard = $false
        $script:ExportListFile = Join-Path $root "clean-list.txt"
        Reset-CleanupStats

        & {
            Invoke-UserCleanup -TempDaysOld 7 -LogDaysOld 7
            Clear-AppCaches
            Invoke-AppCleanup
            Clear-PythonCaches
            Clear-CloudCliCaches
            Clear-ElixirCaches
            Clear-HaskellCaches
        } 6>$null

        $script:Listed = @()
        if (Test-Path $script:ExportListFile) {
            $script:Listed = @(Get-Content -Path $script:ExportListFile | Where-Object { $_ -and -not $_.StartsWith("#") })
        }
        $script:Stats = Get-CleanupStats
    }

    AfterAll {
        foreach ($name in $script:Saved.Keys) {
            Set-Item -Path "env:$name" -Value $script:Saved[$name]
        }
        Remove-Variable -Name ExportListFile -Scope Script -ErrorAction SilentlyContinue
    }

    It "Lists the cache rows it keeps" {
        $script:Listed | Should -Contain "$env:APPDATA\Microsoft\Teams\Cache\data_0"
        $script:Listed | Should -Contain "$env:APPDATA\Microsoft\Teams\GPUCache\data_1"
        $script:Listed | Should -Contain "$env:LOCALAPPDATA\CrashDumps\app.exe.1234.dmp"
        $script:Listed | Should -Contain "$env:APPDATA\gcloud\logs\gcloud.log"
    }

    It "Never offers <_>" -ForEach @(
        "Zoom\data", "Teams\IndexedDB", "Teams\Local Storage", "Teams\databases", "Windows\Recent",
        "Office\16.0\OfficeFileCache", "Office\15.0\OfficeFileCache", "Outlook\RoamCache", "OneDrive\logs",
        ".dropbox.cache", ".aws", ".azure", ".kube", "jupyter\runtime", ".hex\packages", ".cabal\packages",
        ".cabal\store", ".stack\programs"
    ) {
        $leaf = $_
        $dir = @($script:UserData | Where-Object { $_.EndsWith("\$leaf") })[0]
        $dir | Should -Not -BeNullOrEmpty
        @($script:Listed | Where-Object { $_ -eq $dir -or $_.StartsWith("$dir\") }) | Should -BeNullOrEmpty
    }

    It "Never offers dumps or logs at the profile root" {
        $script:Listed | Should -Not -Contain "$env:USERPROFILE\memory.dmp"
        $script:Listed | Should -Not -Contain "$env:USERPROFILE\install.log"
    }

    It "Counts exactly the paths it lists" {
        $script:Stats.FilesCleaned | Should -Be $script:Listed.Count
    }
}
