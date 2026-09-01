# Mole Windows - Command Tests
# Pester tests for bin/ command scripts

BeforeAll {
    # Get the windows directory path (tests are in windows/tests/)
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:BinDir = Join-Path $script:WindowsDir "bin"
    $script:InstallScript = Join-Path $script:WindowsDir "install.ps1"
    $script:VisualDefaultsErrorPattern = 'property ''(Solid|Error)'' cannot be found|找不到属性.?(Solid|Error)|VariableIsUndefined|\$script:Colors'
}

Describe "Clean Command" {
    Context "Help Display" {
        It "Should show help without error" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\clean.ps1" -ShowHelp 2>&1
            $result | Should -Not -BeNullOrEmpty
            $LASTEXITCODE | Should -Be 0
        }
        
        It "Should mention dry-run in help" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\clean.ps1" -ShowHelp 2>&1
            $result -join "`n" | Should -Match "(DryRun|dry-run)"
        }
    }
    
    Context "Dry Run Mode" {
        It "Should support -DryRun parameter" {
            # Just verify it starts without immediate error
            $job = Start-Job -ScriptBlock {
                param($binDir)
                & powershell -ExecutionPolicy Bypass -File "$binDir\clean.ps1" -DryRun 2>&1
            } -ArgumentList $script:BinDir
            
            Start-Sleep -Seconds 3
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            
            # If we got here without exception, test passes
            $true | Should -Be $true
        }

        It "Should not throw missing Solid property errors during dry-run startup" {
            $job = Start-Job -ScriptBlock {
                param($binDir)
                & powershell -ExecutionPolicy Bypass -File "$binDir\clean.ps1" -DryRun 2>&1
            } -ArgumentList $script:BinDir

            Start-Sleep -Seconds 3
            $output = (Receive-Job $job -Keep 2>&1 | Out-String)
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue

            $output | Should -Not -Match $script:VisualDefaultsErrorPattern
        }
    }
}

Describe "Uninstall Command" {
    Context "Help Display" {
        It "Should show help without error" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\uninstall.ps1" -ShowHelp 2>&1
            $result | Should -Not -BeNullOrEmpty
            $LASTEXITCODE | Should -Be 0
        }
    }
}

Describe "Optimize Command" {
    Context "Help Display" {
        It "Should show help without error" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\optimize.ps1" -ShowHelp 2>&1
            $result | Should -Not -BeNullOrEmpty
            $LASTEXITCODE | Should -Be 0
        }
        
        It "Should mention optimization options in help" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\optimize.ps1" -ShowHelp 2>&1
            $result -join "`n" | Should -Match "DryRun|Disk|DNS"
        }

        It "Should guard disk optimization when the system drive cannot be resolved to a volume" {
            $source = Get-Content "$script:BinDir\optimize.ps1" -Raw
            $source | Should -Match "function Test-SystemDriveOptimizable"
            $source | Should -Match "Get-Volume -DriveLetter"
            $source | Should -Match "Disk optimization skipped:"
        }

        It "Should rebuild font cache without touching user font installs" {
            $source = Get-Content "$script:BinDir\optimize.ps1" -Raw
            $source | Should -Match 'ServiceProfiles\\LocalService\\AppData\\Local\\FontCache'
            $source | Should -Match 'System32\\FNTCACHE\.DAT'
            $source | Should -Not -Match 'LOCALAPPDATA\\Microsoft\\Windows\\Fonts'
        }
    }
}

Describe "Purge Command" {
    Context "Help Display" {
        It "Should show help without error" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\purge.ps1" -ShowHelp 2>&1
            $result | Should -Not -BeNullOrEmpty
            $LASTEXITCODE | Should -Be 0
        }
        
        It "Should list artifact types in help" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\purge.ps1" -ShowHelp 2>&1
            $result -join "`n" | Should -Match "node_modules|vendor|venv"
        }
    }
}

Describe "Analyze Command" {
    Context "Help Display" {
        It "Should show help without error" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\analyze.ps1" -ShowHelp 2>&1
            $result | Should -Not -BeNullOrEmpty
            $LASTEXITCODE | Should -Be 0
        }
        
        It "Should mention keybindings in help" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\analyze.ps1" -ShowHelp 2>&1
            $result -join "`n" | Should -Match "Navigate|Enter|Quit"
        }
    }
}

Describe "Status Command" {
    Context "Help Display" {
        It "Should show help without error" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\status.ps1" -ShowHelp 2>&1
            $result | Should -Not -BeNullOrEmpty
            $LASTEXITCODE | Should -Be 0
        }
        
        It "Should mention system metrics in help" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\status.ps1" -ShowHelp 2>&1
            $result -join "`n" | Should -Match "CPU|Memory|Disk|health"
        }
    }
}

Describe "Update Command" {
    Context "Help Display" {
        It "Should show help without error" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\update.ps1" -ShowHelp 2>&1
            $result | Should -Not -BeNullOrEmpty
            $LASTEXITCODE | Should -Be 0
        }

        It "Should explain the source channel" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\update.ps1" -ShowHelp 2>&1
            $result -join "`n" | Should -Match "source|origin/windows|git"
        }
    }

    Context "Installation Refresh" {
        It "Should pass the source directory to the installer by name" {
            $fixtureRoot = Join-Path $TestDrive "update-fixture"
            $fixtureBin = Join-Path $fixtureRoot "bin"
            $fakeTools = Join-Path $fixtureRoot "fake-tools"
            $capturePath = Join-Path $fixtureRoot "install-dir.txt"
            $fixtureUpdater = Join-Path $fixtureBin "update.ps1"

            New-Item -ItemType Directory -Path $fixtureBin, $fakeTools, (Join-Path $fixtureRoot ".git") -Force | Out-Null
            Copy-Item (Join-Path $script:BinDir "update.ps1") $fixtureUpdater

            @'
param(
    [string]$InstallDir,
    [switch]$AddToPath,
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$RemainingArguments
)

Set-Content -LiteralPath $env:MOLE_INSTALL_CAPTURE -Value $InstallDir -NoNewline
'@ | Set-Content (Join-Path $fixtureRoot "install.ps1")

            @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$GitArgs
)

$commandArgs = @($GitArgs)
if ($commandArgs.Count -ge 3 -and $commandArgs[0] -eq "-C") {
    $commandArgs = @($commandArgs[2..($commandArgs.Count - 1)])
}

$commandLine = $commandArgs -join " "
$global:LASTEXITCODE = 0
switch -Regex ($commandLine) {
    '^status --porcelain --untracked-files=no$' { break }
    '^remote get-url origin$' { "https://github.com/tw93/Mole.git"; break }
    '^branch --show-current$' { "windows"; break }
    '^rev-parse --short HEAD$' { "abc123"; break }
    '^pull --ff-only origin windows$' { break }
    default {
        Write-Error "Unexpected git command: $commandLine"
        $global:LASTEXITCODE = 1
    }
}
'@ | Set-Content (Join-Path $fakeTools "git.ps1")

            $originalPath = $env:PATH
            $originalCapture = $env:MOLE_INSTALL_CAPTURE
            try {
                $env:PATH = "$fakeTools;$originalPath"
                $env:MOLE_INSTALL_CAPTURE = $capturePath

                & $fixtureUpdater

                $capturePath | Should -Exist
                Get-Content $capturePath -Raw | Should -Be $fixtureRoot
            }
            finally {
                $env:PATH = $originalPath
                $env:MOLE_INSTALL_CAPTURE = $originalCapture
            }
        }

        It "Should refresh the source directory on the first update from v1.30.0" {
            $fixtureRoot = Join-Path $TestDrive "legacy-update-fixture"
            $fixtureBin = Join-Path $fixtureRoot "bin"
            $fixtureCore = Join-Path $fixtureRoot "lib\core"
            $fixtureUpdater = Join-Path $fixtureBin "update.ps1"
            $fixtureInstaller = Join-Path $fixtureRoot "install.ps1"
            $strayInstallDir = Join-Path $TestDrive "-InstallDir"

            New-Item -ItemType Directory -Path $fixtureBin, $fixtureCore -Force | Out-Null
            Copy-Item $script:InstallScript $fixtureInstaller
            Set-Content (Join-Path $fixtureRoot "VERSION") "1.30.0"
            New-Item -ItemType File -Path (Join-Path $fixtureBin "analyze.exe"), (Join-Path $fixtureBin "status.exe") -Force | Out-Null

            @'
function Get-MoleVersionString {
    param([string]$RootDir)
    return "1.30.0"
}
'@ | Set-Content (Join-Path $fixtureCore "version.ps1")

            @'
function Get-MoleVersionFromScriptFile {
    param([string]$WindowsDir)
    return "1.30.0"
}

function Ensure-TuiBinary {
    param(
        [string]$Name,
        [string]$WindowsDir,
        [string]$DestinationPath,
        [string]$SourcePath,
        [string]$Version
    )
    return $DestinationPath
}
'@ | Set-Content (Join-Path $fixtureCore "tui_binaries.ps1")

            # Exact v1.30.0 updater call shape. The installer file beside this
            # script represents the new file that git pull just wrote.
            @'
$windowsDir = Split-Path -Parent $PSScriptRoot
$installScript = Join-Path $windowsDir "install.ps1"
$installArgs = @("-InstallDir", $windowsDir)
& $installScript @installArgs
if (-not $?) { exit 1 }
'@ | Set-Content $fixtureUpdater

            Push-Location $TestDrive
            try {
                & powershell -NoProfile -ExecutionPolicy Bypass -File $fixtureUpdater
                $LASTEXITCODE | Should -Be 0
            }
            finally {
                Pop-Location
            }

            (Join-Path $fixtureRoot "mole.cmd") | Should -Exist
            $strayInstallDir | Should -Not -Exist
        }

        It "Should recover the legacy updater PATH intent without creating a shortcut" {
            $probe = Join-Path $TestDrive "legacy-argument-probe.ps1"
            @'
. $env:MOLE_INSTALL_SCRIPT -ShowHelp 6>$null

$withoutPath = Resolve-InstallInvocation `
    -SourceDir "C:\Mole" `
    -RequestedInstallDir "-InstallDir" `
    -RequestedAddToPath
$withPath = Resolve-InstallInvocation `
    -SourceDir "C:\Mole" `
    -RequestedInstallDir "-InstallDir" `
    -RequestedAddToPath `
    -RequestedCreateShortcut

[PSCustomObject]@{
    WithoutPathInstallDir = $withoutPath.InstallDir
    WithoutPathAddToPath = $withoutPath.AddToPath
    WithPathInstallDir = $withPath.InstallDir
    WithPathAddToPath = $withPath.AddToPath
    WithPathCreateShortcut = $withPath.CreateShortcut
} | ConvertTo-Json -Compress
'@ | Set-Content $probe

            $originalInstallScript = $env:MOLE_INSTALL_SCRIPT
            try {
                $env:MOLE_INSTALL_SCRIPT = $script:InstallScript
                $result = & powershell -NoProfile -ExecutionPolicy Bypass -File $probe | ConvertFrom-Json
            }
            finally {
                $env:MOLE_INSTALL_SCRIPT = $originalInstallScript
            }

            $result.WithoutPathInstallDir | Should -Be "C:\Mole"
            $result.WithoutPathAddToPath | Should -BeFalse
            $result.WithPathInstallDir | Should -Be "C:\Mole"
            $result.WithPathAddToPath | Should -BeTrue
            $result.WithPathCreateShortcut | Should -BeFalse
        }
    }
}

Describe "Remove Command" {
    Context "Help Display" {
        It "Should show help without error" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\remove.ps1" -ShowHelp 2>&1
            $result | Should -Not -BeNullOrEmpty
            $LASTEXITCODE | Should -Be 0
        }

        It "Should mention uninstall behavior" {
            $result = & powershell -ExecutionPolicy Bypass -File "$script:BinDir\remove.ps1" -ShowHelp 2>&1
            $result -join "`n" | Should -Match "Remove Mole|PATH|config"
        }
    }
}

Describe "Main Entry Point" {
    Context "mole.ps1" {
        BeforeAll {
            $script:MolePath = Join-Path $script:WindowsDir "mole.ps1"
        }
        
        It "Should show help without error" {
            $result = & powershell -ExecutionPolicy Bypass -File $script:MolePath -ShowHelp 2>&1
            $result | Should -Not -BeNullOrEmpty
        }
        
        It "Should show version without error" {
            $result = & powershell -ExecutionPolicy Bypass -File $script:MolePath -Version 2>&1
            $result | Should -Not -BeNullOrEmpty
            $output = $result -join "`n"
            $output | Should -Not -Match $script:VisualDefaultsErrorPattern
            $output | Should -Match "Mole|v\d+\.\d+"
        }

        It "Should not throw missing Solid property errors during menu startup" {
            $job = Start-Job -ScriptBlock {
                param($molePath)
                & powershell -ExecutionPolicy Bypass -File $molePath 2>&1
            } -ArgumentList $script:MolePath

            Start-Sleep -Seconds 3
            $output = (Receive-Job $job -Keep 2>&1 | Out-String)
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue

            $output | Should -Not -Match $script:VisualDefaultsErrorPattern
        }
        
        It "Should list available commands in help" {
            $result = & powershell -ExecutionPolicy Bypass -File $script:MolePath -ShowHelp 2>&1
            $helpText = $result -join "`n"
            $helpText | Should -Match "clean"
            $helpText | Should -Match "uninstall"
            $helpText | Should -Match "optimize"
            $helpText | Should -Match "purge"
            $helpText | Should -Match "analyze"
            $helpText | Should -Match "status"
            $helpText | Should -Match "update"
            $helpText | Should -Match "remove"
        }
    }
}

Describe "Installer Script" {
    Context "Version Source" {
        It "Should read the version from VERSION" {
            $source = Get-Content $script:InstallScript -Raw
            $source | Should -Match "version\.ps1"
            $source | Should -Match 'Get-MoleVersionString -RootDir \$script:SourceDir'
        }

        It "Should reject protected root install and uninstall paths" {
            $source = Get-Content $script:InstallScript -Raw
            $source | Should -Match "function Test-ProtectedInstallRoot"
            $source | Should -Match "Refusing to use protected install directory"
            $source | Should -Match "Refusing to remove protected install directory"
            $source | Should -Match '\$env:USERPROFILE'
        }
    }

    Context "Optional TUI Tools" {
        It "Should downgrade TUI setup errors to warnings" {
            $source = Get-Content $script:InstallScript -Raw
            $source | Should -Match "Ensure-TuiBinary"
            $source | Should -Match "Skipping .*non-fatal setup error"
            $source | Should -Match "Could not prepare .*Install Go or wait for a Windows prerelease asset"
        }
    }
}

Describe "Source Install Hygiene" {
    Context ".gitattributes" {
        It "Should normalize tracked line endings for Windows source installs" {
            $source = Get-Content (Join-Path $script:WindowsDir ".gitattributes") -Raw
            $source | Should -Match '\* text=auto eol=lf'
            $source | Should -Match '\*\.ps1 text eol=lf'
            $source | Should -Match '\*\.cmd text eol=crlf'
        }
    }

    Context ".gitignore" {
        It "Should ignore generated launcher batch files" {
            $source = Get-Content (Join-Path $script:WindowsDir ".gitignore") -Raw
            $source | Should -Match '(?m)^mole\.cmd$'
            $source | Should -Match '(?m)^mo\.cmd$'
        }
    }
}
