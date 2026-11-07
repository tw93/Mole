# Cleanup target selection must preserve stores and Explorer presentation state.
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . "$root\lib\clean\user.ps1"
    . "$root\lib\clean\caches.ps1"
    . "$root\lib\clean\system.ps1"
    function Clear-Prefetch {}
    $script:SavedAppData = $env:APPDATA
    $script:SavedLocalAppData = $env:LOCALAPPDATA
    $env:APPDATA = Join-Path $TestDrive 'Roaming'
    $env:LOCALAPPDATA = Join-Path $TestDrive 'Local'
    foreach ($leaf in @('Cache', 'GPUCache', 'blob_storage', 'tmp')) {
        New-Item -ItemType Directory -Path "$env:APPDATA\Microsoft\Teams\$leaf" -Force | Out-Null
    }
    New-Item -ItemType Directory -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Force | Out-Null
    Set-Content "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_32.db" 'fixture'
    Set-Content "$env:LOCALAPPDATA\IconCache.db" 'fixture'
}

AfterAll {
    $env:APPDATA = $script:SavedAppData
    $env:LOCALAPPDATA = $script:SavedLocalAppData
}

Describe 'Conservative cleanup targets' {
    BeforeEach {
        Mock Clear-DirectoryContents {}
        Mock Remove-SafeItems {}
        Mock Remove-SafeItem { $true }
        Mock Clear-UserTempFiles {}
        Mock Clear-ErrorReports {}
        Mock Clear-UserLogs {}
        Mock Clear-Prefetch {}
    }

    It 'Keeps Teams <Leaf> while still cleaning its exact cache leaves' -TestCases @(
        @{ Leaf = 'blob_storage' }
        @{ Leaf = 'tmp' }
    ) {
        param($Leaf)
        Clear-AppCaches
        Should -Invoke Clear-DirectoryContents -Times 0 -Exactly -ParameterFilter { $Path -eq "$env:APPDATA\Microsoft\Teams\$Leaf" }
        Should -Invoke Clear-DirectoryContents -Times 1 -Exactly -ParameterFilter { $Path -eq "$env:APPDATA\Microsoft\Teams\Cache" }
        Should -Invoke Clear-DirectoryContents -Times 1 -Exactly -ParameterFilter { $Path -eq "$env:APPDATA\Microsoft\Teams\GPUCache" }
    }

    It 'Keeps Spotify offline stores during automatic cleanup' {
        foreach ($leaf in @('Data', 'Storage')) {
            New-Item -ItemType Directory -Path "$env:LOCALAPPDATA\Spotify\$leaf" -Force | Out-Null
        }
        Clear-AppCaches
        Should -Invoke Clear-DirectoryContents -Times 0 -Exactly -ParameterFilter { $Path -like '*\Spotify\*' }
        Should -Invoke Clear-DirectoryContents -Times 1 -Exactly -ParameterFilter { $Path -eq "$env:APPDATA\Microsoft\Teams\Cache" }
    }
    It 'Leaves Adobe caches to the Applications section so a run counts them once' {
        foreach ($dir in @("$env:APPDATA\Adobe\Common\Media Cache Files", "$env:LOCALAPPDATA\Adobe\Premiere\Cache")) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Clear-AppCaches
        Should -Invoke Clear-DirectoryContents -Times 0 -Exactly -ParameterFilter { $Description -eq 'Adobe cache' }
    }
    It 'Keeps Explorer thumbnails and icons during ordinary user cleanup' {
        Invoke-UserCleanup
        Should -Invoke Clear-UserTempFiles -Times 1 -Exactly
        Should -Invoke Clear-Prefetch -Times 0 -Exactly
        Should -Invoke Remove-SafeItems -Times 0 -Exactly
        Should -Invoke Remove-SafeItem -Times 0 -Exactly
    }
}


Describe 'Protected system cleanup does not disturb services' {
    BeforeEach {
        Mock Test-IsAdmin { $true }
        Mock Test-DryRunMode { $false }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Stop-Service {}
        Mock Start-Service {}
        Mock Restart-Service {}
        Mock Set-Service {}
        Mock Clear-DirectoryContents {}
        Mock Remove-OldFiles {}
        Mock Remove-SafeItems {}
        Mock Remove-SafeItem { $true }
        Mock Start-Process {}
    }
    It 'Never stops, starts or restarts FontCache or Windows Update during system cleanup' {
        Invoke-SystemCleanup
        Should -Invoke Stop-Service -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
        Should -Invoke Restart-Service -Times 0 -Exactly
        Should -Invoke Set-Service -Times 0 -Exactly
    }
}

Describe 'Game media scope' {
    BeforeAll { . "$(Split-Path -Parent $PSScriptRoot)\lib\clean\apps.ps1" }
    It 'Keeps generic captures while still selecting old game captures' {
        $savedProfile = $env:USERPROFILE
        $savedPrograms = ${env:ProgramFiles(x86)}
        try {
            $env:USERPROFILE = Join-Path $TestDrive 'media-profile'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'media-programs'
            $paths = @(
                "$env:USERPROFILE\Pictures\Screenshots\receipt.png",
                "$env:USERPROFILE\Videos\Screen Recordings\training.mp4",
                "$env:USERPROFILE\Videos\Captures\game.mp4",
                "$env:USERPROFILE\Videos\Captures\recent.mp4"
            )
            foreach ($path in $paths) {
                New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
                Set-Content -LiteralPath $path -Value 'fixture'
                (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-100)
                (Get-Item -LiteralPath $path).CreationTime = (Get-Date).AddDays(-100)
            }
            (Get-Item -LiteralPath $paths[3]).LastWriteTime = Get-Date
            (Get-Item -LiteralPath $paths[3]).CreationTime = Get-Date
            Mock Start-Section {}
            Mock Stop-Section {}
            Mock Remove-SafeItems {}
            Clear-GameMediaFiles -DaysOld 90
            Should -Invoke Remove-SafeItems -Exactly -Times 0 -ParameterFilter { @($Paths | Where-Object { $_ -like '*\Screenshots\*' -or $_ -like '*\Screen Recordings\*' }).Count -gt 0 }
            Should -Invoke Remove-SafeItems -Exactly -Times 1 -ParameterFilter { @($Paths).Count -eq 1 -and $Paths -contains "$env:USERPROFILE\Videos\Captures\game.mp4" }
        }
        finally { $env:USERPROFILE = $savedProfile; ${env:ProgramFiles(x86)} = $savedPrograms }
    }
}
