# Mole Windows - Core Module Tests
# Pester tests for lib/core functionality

BeforeAll {
    # Get the windows directory path (tests are in windows/tests/)
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir "lib"
    $script:VersionFile = Join-Path $script:WindowsDir "VERSION"

    # Import core modules
    . "$script:LibDir\core\base.ps1"
    . "$script:LibDir\core\log.ps1"
    . "$script:LibDir\core\ui.ps1"
    . "$script:LibDir\core\file_ops.ps1"
    . "$script:LibDir\core\version.ps1"
    . "$script:LibDir\core\tui_binaries.ps1"
}

Describe "Base Module" {
    Context "Color Definitions" {
        It "Should define color codes" {
            $script:Colors | Should -Not -BeNullOrEmpty
            $script:Colors.Cyan | Should -Not -BeNullOrEmpty
            $script:Colors.Green | Should -Not -BeNullOrEmpty
            $script:Colors.Red | Should -Not -BeNullOrEmpty
            $script:Colors.NC | Should -Not -BeNullOrEmpty
        }

        It "Should define icon set" {
            $script:Icons | Should -Not -BeNullOrEmpty
            $script:Icons.Success | Should -Not -BeNullOrEmpty
            $script:Icons.Error | Should -Not -BeNullOrEmpty
            $script:Icons.Warning | Should -Not -BeNullOrEmpty
            $script:Icons.Solid | Should -Not -BeNullOrEmpty
            $script:Icons.Admin | Should -Not -BeNullOrEmpty
            $script:Icons.Trash | Should -Not -BeNullOrEmpty
        }

        It "Should expose the full icon table in Windows PowerShell" {
            $basePath = (Join-Path $script:LibDir "core\base.ps1").Replace("'", "''")
            $psCommand = "& { . '$basePath'; `$icons = Get-MoleDefaultIcons; [pscustomobject]@{ Count = `$icons.Count; HasSolid = `$icons.ContainsKey('Solid'); HasAdmin = `$icons.ContainsKey('Admin'); HasSuccess = `$icons.ContainsKey('Success') } | ConvertTo-Json -Compress }"
            $result = & powershell -NoProfile -ExecutionPolicy Bypass -Command $psCommand
            $iconInfo = $result | ConvertFrom-Json

            $iconInfo.Count | Should -Be 15
            $iconInfo.HasSolid | Should -Be $true
            $iconInfo.HasAdmin | Should -Be $true
            $iconInfo.HasSuccess | Should -Be $true
        }
    }

    Context "Visual Defaults Initialization" {
        BeforeEach {
            $script:OriginalColors = $script:Colors.Clone()
            $script:OriginalIcons = $script:Icons.Clone()
        }

        AfterEach {
            $script:Colors = $script:OriginalColors.Clone()
            $script:Icons = $script:OriginalIcons.Clone()
        }

        It "Should initialize missing visual tables under strict mode" {
            Remove-Variable -Name Colors -Scope Script -ErrorAction SilentlyContinue
            Remove-Variable -Name Icons -Scope Script -ErrorAction SilentlyContinue

            { Initialize-MoleVisualDefaults } | Should -Not -Throw
            $script:Colors.Cyan | Should -Not -BeNullOrEmpty
            $script:Colors.Green | Should -Not -BeNullOrEmpty
            $script:Icons.Solid | Should -Not -BeNullOrEmpty
            $script:Icons.Trash | Should -Not -BeNullOrEmpty
        }

        It "Should preserve existing values while filling missing defaults" {
            $script:Colors = @{ Cyan = "custom-cyan" }
            $script:Icons = @{ Solid = "*" }

            Initialize-MoleVisualDefaults

            $script:Colors.Cyan | Should -Be "custom-cyan"
            $script:Colors.Green | Should -Not -BeNullOrEmpty
            $script:Icons.Solid | Should -Be "*"
            $script:Icons.Admin | Should -Not -BeNullOrEmpty
        }

        It "Should restore missing icon entries on demand" {
            $script:Icons = @{ Solid = "*" }

            (Get-MoleIcon -Name "Error") | Should -Not -BeNullOrEmpty
            $script:Icons.Error | Should -Not -BeNullOrEmpty
            $script:Icons.Solid | Should -Be "*"
        }
    }

    Context "Test-IsAdmin" {
        It "Should return a boolean" {
            $result = Test-IsAdmin
            $result | Should -BeOfType [bool]
        }
    }

    Context "Get-WindowsVersion" {
        It "Should return version info" {
            $result = Get-WindowsVersion
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Not -BeNullOrEmpty
            $result.Version | Should -Not -BeNullOrEmpty
            $result.Build | Should -Not -BeNullOrEmpty
        }
    }

    Context "Get-FreeSpace" {
        It "Should return free space string" {
            $result = Get-FreeSpace
            $result | Should -Not -BeNullOrEmpty
            # Format is like "100.00GB" or "50.5MB" (no space between number and unit)
            $result | Should -Match "\d+(\.\d+)?(B|KB|MB|GB|TB)"
        }

        It "Should accept drive parameter" {
            $result = Get-FreeSpace -Drive "C:"
            $result | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "File Operations Module" {
    BeforeAll {
        # Create temp test directory
        $script:TestDir = Join-Path $env:TEMP "mole_test_$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
    }

    AfterAll {
        # Cleanup test directory
        if (Test-Path $script:TestDir) {
            Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Format-ByteSize" {
        It "Should format bytes correctly" {
            # Actual format: no space, uses N0/N1/N2 formatting
            Format-ByteSize -Bytes 0 | Should -Be "0B"
            Format-ByteSize -Bytes 1024 | Should -Be "1KB"
            Format-ByteSize -Bytes 1048576 | Should -Be "1.0MB"
            Format-ByteSize -Bytes 1073741824 | Should -Be "1.00GB"
        }

        It "Should handle large numbers" {
            Format-ByteSize -Bytes 1099511627776 | Should -Be "1.00TB"
        }
    }

    Context "Get-PathSize" {
        BeforeEach {
            # Create test file
            $testFile = Join-Path $script:TestDir "testfile.txt"
            "Hello World" | Set-Content -Path $testFile
        }

        It "Should return size for file" {
            $testFile = Join-Path $script:TestDir "testfile.txt"
            $result = Get-PathSize -Path $testFile
            $result | Should -BeGreaterThan 0
        }

        It "Should return size for directory" {
            $result = Get-PathSize -Path $script:TestDir
            $result | Should -BeGreaterThan 0
        }

        It "Should return 0 for non-existent path" {
            $result = Get-PathSize -Path "C:\NonExistent\Path\12345"
            $result | Should -Be 0
        }
    }

    Context "Test-ProtectedPath" {
        It "Should protect Windows directory" {
            Test-ProtectedPath -Path "C:\Windows" | Should -Be $true
            Test-ProtectedPath -Path "C:\Windows\System32" | Should -Be $true
        }

        It "Should protect Windows Defender paths" {
            Test-ProtectedPath -Path "C:\Program Files\Windows Defender" | Should -Be $true
            Test-ProtectedPath -Path "C:\ProgramData\Microsoft\Windows Defender" | Should -Be $true
        }

        It "Should not protect temp directories" {
            Test-ProtectedPath -Path $env:TEMP | Should -Be $false
        }
    }

    Context "Test-SafePath" {
        It "Should return false for protected paths" {
            Test-SafePath -Path "C:\Windows" | Should -Be $false
            Test-SafePath -Path "C:\Windows\System32" | Should -Be $false
        }

        It "Should return true for safe paths" {
            Test-SafePath -Path $env:TEMP | Should -Be $true
        }

        It "Should return false for empty paths" {
            # Test-SafePath has mandatory path parameter, so empty/null throws
            # But internally it should handle empty strings gracefully
            { Test-SafePath -Path "" } | Should -Throw
        }
    }

    Context "Remove-SafeItem" {
        BeforeEach {
            $script:TestFile = Join-Path $script:TestDir "safe_remove_test.txt"
            "Test content" | Set-Content -Path $script:TestFile
        }

        It "Should remove file successfully" {
            $result = Remove-SafeItem -Path $script:TestFile
            $result | Should -Be $true
            Test-Path $script:TestFile | Should -Be $false
        }

        It "Should respect DryRun mode" {
            $env:MOLE_DRY_RUN = "1"
            try {
                # Reset the module's DryRun state
                Set-DryRunMode -Enabled $true
                $result = Remove-SafeItem -Path $script:TestFile
                $result | Should -Be $true
                Test-Path $script:TestFile | Should -Be $true  # File should still exist
            }
            finally {
                $env:MOLE_DRY_RUN = $null
                Set-DryRunMode -Enabled $false
            }
        }

        It "Should not remove protected paths" {
            $result = Remove-SafeItem -Path "C:\Windows\System32"
            $result | Should -Be $false
        }
    }
}

Describe "Logging Module" {
    Context "Write-Log Functions" {
        It "Should have Write-Info function" {
            { Write-Info "Test message" } | Should -Not -Throw
        }

        It "Should have Write-Success function" {
            { Write-Success "Test message" } | Should -Not -Throw
        }

        It "Should have Write-MoleWarning function" {
            # Note: The actual function is Write-MoleWarning
            { Write-MoleWarning "Test message" } | Should -Not -Throw
        }

        It "Should have Write-MoleError function" {
            # Note: The actual function is Write-MoleError
            { Write-MoleError "Test message" } | Should -Not -Throw
        }

        It "Should log errors even when the icon table is partial" {
            $originalIcons = $script:Icons.Clone()

            try {
                $script:Icons = @{ Solid = "*" }
                { Write-MoleError "Test message" } | Should -Not -Throw
                $script:Icons.Error | Should -Not -BeNullOrEmpty
            }
            finally {
                $script:Icons = $originalIcons
            }
        }
    }

    Context "Section Functions" {
        It "Should start and stop sections without error" {
            { Start-Section -Title "Test Section" } | Should -Not -Throw
            { Stop-Section } | Should -Not -Throw
        }
    }
}

Describe "UI Module" {
    Context "Show-Banner" {
        It "Should display banner without error" {
            { Show-Banner } | Should -Not -Throw
        }
    }

    Context "Show-Header" {
        It "Should display header without error" {
            { Show-Header -Title "Test Header" } | Should -Not -Throw
        }

        It "Should accept subtitle parameter" {
            { Show-Header -Title "Test" -Subtitle "Subtitle" } | Should -Not -Throw
        }
    }

    Context "Show-Summary" {
        It "Should display summary without error" {
            { Show-Summary -SizeBytes 1024 -ItemCount 5 } | Should -Not -Throw
        }
    }

    Context "Read-Confirmation" {
        It "Should have Read-Confirmation function" {
            Get-Command Read-Confirmation -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Version Helpers" {
    Context "Shared VERSION Source" {
        It "Should read the version from VERSION" {
            $expected = (Get-Content $script:VersionFile -Raw).Trim()
            Get-MoleVersionString -RootDir $script:WindowsDir | Should -Be $expected
        }

        It "Should keep TUI release lookup aligned with VERSION" {
            $expected = (Get-Content $script:VersionFile -Raw).Trim()
            Get-MoleVersionFromScriptFile -WindowsDir $script:WindowsDir | Should -Be $expected
        }
    }
}
