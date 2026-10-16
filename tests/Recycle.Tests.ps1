BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . "$root\lib\core\file_ops.ps1"
}

Describe 'Recoverable uninstall leftovers' {
    BeforeEach {
        Set-DryRunMode $false
        Reset-CleanupStats
        $script:Source = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Destination = $script:Source + '-recycled'
        New-Item -ItemType Directory $script:Source | Out-Null
        Set-Content (Join-Path $script:Source 'fixture.txt') 'fixture'
        Mock Remove-SafeDirectoryTree { throw 'Permanent deletion must not run' }
        Mock Write-Warning {}
    }

    AfterEach { Set-DryRunMode $false }

    It 'Routes an accepted directory only to the recycle operation' {
        Mock Move-MoleItemToRecycleBin { Move-Item -LiteralPath $Path -Destination $script:Destination }
        Remove-SafeItem -Path $script:Source -Recurse -Recycle | Should -Be $true
        Test-Path $script:Source | Should -Be $false
        (Get-CleanupStats).TotalSizeKB | Should -Be 0
        Test-Path (Join-Path $script:Destination 'fixture.txt') | Should -Be $true
        Should -Invoke Move-MoleItemToRecycleBin -Times 1 -Exactly
        Should -Invoke Remove-SafeDirectoryTree -Times 0 -Exactly
    }

    It 'Keeps leftovers and reports no cleaned items when recycling fails' {
        Mock Move-MoleItemToRecycleBin { throw 'Recycle Bin unavailable or cancelled' }
        Remove-SafeItem -Path $script:Source -Recurse -Recycle | Should -Be $false
        Test-Path (Join-Path $script:Source 'fixture.txt') | Should -Be $true
        (Get-CleanupStats).FilesCleaned | Should -Be 0
        Should -Invoke Write-Warning -Times 1 -Exactly
        Should -Invoke Remove-SafeDirectoryTree -Times 0 -Exactly
    }

    It 'Previews without calling the shell or permanent deletion' {
        Mock Move-MoleItemToRecycleBin { throw 'Dry run must not recycle' }
        Set-DryRunMode $true
        Remove-SafeItem -Path $script:Source -Recurse -Recycle | Should -Be $true
        Test-Path $script:Source | Should -Be $true
        Should -Invoke Move-MoleItemToRecycleBin -Times 0 -Exactly
        Should -Invoke Remove-SafeDirectoryTree -Times 0 -Exactly
    }

    It 'Honors a whitelisted root before recycling' {
        Mock Test-Whitelisted { $Path -eq $script:Source }
        Mock Move-MoleItemToRecycleBin { throw 'Whitelisted root must stay' }
        Remove-SafeItem -Path $script:Source -Recurse -Recycle | Should -Be $false
        Test-Path $script:Source | Should -Be $true
        Should -Invoke Move-MoleItemToRecycleBin -Times 0 -Exactly
    }

    It 'Keeps a replaced root after sizing' {
        Mock Move-MoleItemToRecycleBin { throw 'Replacement must not be recycled' }
        Mock Get-ValidatedTreeSize {
            Move-Item -LiteralPath $script:Source -Destination $script:Destination
            New-Item -ItemType Directory $script:Source | Out-Null
            Set-Content (Join-Path $script:Source 'replacement.txt') 'keep'
            return 7
        }
        Remove-SafeItem -Path $script:Source -Recurse -Recycle | Should -Be $false
        Test-Path (Join-Path $script:Source 'replacement.txt') | Should -Be $true
        Test-Path (Join-Path $script:Destination 'fixture.txt') | Should -Be $true
        Should -Invoke Move-MoleItemToRecycleBin -Times 0 -Exactly
        Should -Invoke Remove-SafeDirectoryTree -Times 0 -Exactly
    }

    It 'Rechecks newly added protected children after sizing (dry run: <DryRun>)' -TestCases @(@{ DryRun = $false }, @{ DryRun = $true }) {
        param($DryRun)
        Set-DryRunMode $DryRun
        Mock Test-Whitelisted { $Path -eq (Join-Path $script:Source 'keep.txt') }
        Mock Get-ValidatedTreeSize {
            Set-Content (Join-Path $script:Source 'keep.txt') 'keep'
            return 7
        }
        Remove-SafeItem -Path $script:Source -Recurse -Recycle | Should -Be $false
        Test-Path (Join-Path $script:Source 'keep.txt') | Should -Be $true
        (Get-CleanupStats).FilesCleaned | Should -Be 0
        Should -Invoke Remove-SafeDirectoryTree -Times 0 -Exactly
    }
}
