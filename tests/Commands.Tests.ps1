# Mole Windows - Command Tests
# Pester tests for bin/ command scripts

BeforeAll {
    # Get the windows directory path (tests are in windows/tests/)
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:BinDir = Join-Path $script:WindowsDir "bin"
    $script:InstallScript = Join-Path $script:WindowsDir "install.ps1"
    $script:VisualDefaultsErrorPattern = 'property ''(Solid|Error)'' cannot be found|\u627E\u4E0D\u5230\u5C5E\u6027.?(Solid|Error)|VariableIsUndefined|\$script:Colors'
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
        It "Completes a real dry run without deleting its candidate" {
            $profile = Join-Path $TestDrive "clean-profile"
            $temp = Join-Path $profile "AppData\Local\Temp"
            New-Item -ItemType Directory -Path $temp -Force | Out-Null
            $canary = Join-Path $temp "keep.tmp"
            Set-Content -LiteralPath $canary -Value "preview canary"
            (Get-Item -LiteralPath $canary).LastWriteTime = (Get-Date).AddDays(-30)
            $start = New-Object System.Diagnostics.ProcessStartInfo
            $start.FileName = (Get-Command powershell.exe -CommandType Application | Select-Object -First 1).Source
            $start.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $script:BinDir 'clean.ps1') + '" -DryRun'
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $start.EnvironmentVariables['USERPROFILE'] = $profile
            $start.EnvironmentVariables['LOCALAPPDATA'] = (Join-Path $profile 'AppData\Local')
            $start.EnvironmentVariables['APPDATA'] = (Join-Path $profile 'AppData\Roaming')
            foreach ($name in @('TEMP', 'TMP', 'SystemTemp')) { $start.EnvironmentVariables[$name] = $temp }
            $process = [System.Diagnostics.Process]::Start($start)
            try {
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                $process.WaitForExit(60000) | Should -BeTrue
                $process.ExitCode | Should -Be 0
                $output = $stdout.Result
                $output | Should -Match 'Dry run complete - no changes made'
                $output | Should -Not -Match $script:VisualDefaultsErrorPattern
                $stderr.Result | Should -BeNullOrEmpty
                Get-Content -LiteralPath $canary | Should -Be 'preview canary'
            }
            finally {
                if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
                $process.Dispose()
            }
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
# A system proxy on the test machine adds "-c http.proxy=..."; it is not part of the command.
while ($commandArgs.Count -ge 3 -and $commandArgs[0] -eq "-c") {
    $commandArgs = @($commandArgs[2..($commandArgs.Count - 1)])
}

$commandLine = $commandArgs -join " "
$global:LASTEXITCODE = 0
switch -Regex ($commandLine) {
    '^config --get https?\.proxy$' { $global:LASTEXITCODE = 1; break }
    '^status --porcelain --untracked-files=no$' { break }
    '^remote get-url origin$' { "https://github.com/tw93/Mole.git"; break }
    '^branch --show-current$' { "windows"; break }
    '^rev-parse --short HEAD$' { "abc123"; break }
    '^pull --ff-only --tags origin windows$' { Set-Content -LiteralPath ($env:MOLE_INSTALL_CAPTURE + '.git') -Value $commandLine; break }
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
                Get-Content -LiteralPath ($capturePath + ".git") | Should -Be "pull --ff-only --tags origin windows"
            }
            finally {
                $env:PATH = $originalPath
                $env:MOLE_INSTALL_CAPTURE = $originalCapture
            }
        }

        It "Should skip the installer only when the last refresh finished at this revision" {
            $fixtureRoot = Join-Path $TestDrive "unchanged-update-fixture"
            $fixtureBin = Join-Path $fixtureRoot "bin"
            $fakeTools = Join-Path $fixtureRoot "fake-tools"
            $capturePath = Join-Path $fixtureRoot "install-dir.txt"
            $fixtureUpdater = Join-Path $fixtureBin "update.ps1"
            $marker = Join-Path $fixtureRoot ".git\mole-refreshed-revision"

            New-Item -ItemType Directory -Path $fixtureBin, $fakeTools, (Join-Path $fixtureRoot ".git") -Force | Out-Null
            Copy-Item (Join-Path $script:BinDir "update.ps1") $fixtureUpdater

            @'
param(
    [string]$InstallDir,
    [switch]$AddToPath,
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$RemainingArguments
)

Add-Content -LiteralPath $env:MOLE_INSTALL_CAPTURE -Value "ran"
if ($env:MOLE_INSTALL_FAIL -eq "1") { exit 1 }
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
while ($commandArgs.Count -ge 3 -and $commandArgs[0] -eq "-c") {
    $commandArgs = @($commandArgs[2..($commandArgs.Count - 1)])
}

$commandLine = $commandArgs -join " "
$global:LASTEXITCODE = 0
switch -Regex ($commandLine) {
    '^config --get https?\.proxy$' { $global:LASTEXITCODE = 1; break }
    '^status --porcelain --untracked-files=no$' { break }
    '^remote get-url origin$' { "https://github.com/tw93/Mole.git"; break }
    '^branch --show-current$' { "windows"; break }
    '^rev-parse --short HEAD$' { if ($env:MOLE_FAKE_HEAD) { $env:MOLE_FAKE_HEAD } else { "abc123" }; break }
    '^rev-parse --git-path mole-refreshed-revision$' { ".git/mole-refreshed-revision"; break }
    '^pull --ff-only --tags origin windows$' { break }
    default {
        Write-Error "Unexpected git command: $commandLine"
        $global:LASTEXITCODE = 1
    }
}
'@ | Set-Content (Join-Path $fakeTools "git.ps1")

            $originalPath = $env:PATH
            $originalCapture = $env:MOLE_INSTALL_CAPTURE
            $originalFail = $env:MOLE_INSTALL_FAIL
            $originalHead = $env:MOLE_FAKE_HEAD
            try {
                $env:PATH = "$fakeTools;$originalPath"
                $env:MOLE_INSTALL_CAPTURE = $capturePath
                $env:MOLE_INSTALL_FAIL = $null
                $env:MOLE_FAKE_HEAD = $null

                # First unchanged pull with no marker refreshes and records the revision.
                & $fixtureUpdater
                $LASTEXITCODE | Should -Be 0
                @(Get-Content -LiteralPath $capturePath).Count | Should -Be 1
                Get-Content -LiteralPath $marker -Raw | Should -Be "abc123"

                # Same revision, launchers present: nothing is reinstalled.
                Set-Content -LiteralPath (Join-Path $fixtureRoot "mole.cmd") -Value "x"
                Set-Content -LiteralPath (Join-Path $fixtureRoot "mo.cmd") -Value "x"
                & $fixtureUpdater
                $LASTEXITCODE | Should -Be 0
                @(Get-Content -LiteralPath $capturePath).Count | Should -Be 1

                # A missing launcher is repaired even at the same revision.
                Remove-Item -LiteralPath (Join-Path $fixtureRoot "mo.cmd")
                & $fixtureUpdater
                $LASTEXITCODE | Should -Be 0
                @(Get-Content -LiteralPath $capturePath).Count | Should -Be 2
                Set-Content -LiteralPath (Join-Path $fixtureRoot "mo.cmd") -Value "x"

                # A failed refresh keeps no marker, so the next update tries again.
                Remove-Item -LiteralPath $marker
                $env:MOLE_INSTALL_FAIL = "1"
                & $fixtureUpdater
                $LASTEXITCODE | Should -Be 1
                $marker | Should -Not -Exist
                $env:MOLE_INSTALL_FAIL = $null
                & $fixtureUpdater
                $LASTEXITCODE | Should -Be 0
                @(Get-Content -LiteralPath $capturePath).Count | Should -Be 4
                Get-Content -LiteralPath $marker -Raw | Should -Be "abc123"

                # A failed refresh at a new revision drops the old marker too.
                $env:MOLE_FAKE_HEAD = "def456"
                $env:MOLE_INSTALL_FAIL = "1"
                & $fixtureUpdater
                $LASTEXITCODE | Should -Be 1
                $marker | Should -Not -Exist
                $env:MOLE_INSTALL_FAIL = $null
                & $fixtureUpdater
                $LASTEXITCODE | Should -Be 0
                @(Get-Content -LiteralPath $capturePath).Count | Should -Be 6
                Get-Content -LiteralPath $marker -Raw | Should -Be "def456"
            }
            finally {
                $env:MOLE_FAKE_HEAD = $originalHead
                $env:PATH = $originalPath
                $env:MOLE_INSTALL_CAPTURE = $originalCapture
                $env:MOLE_INSTALL_FAIL = $originalFail
            }
        }

        It "Should end a successful install with an explicit zero exit code" {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InstallScript, [ref]$tokens, [ref]$errors)
            $last = $ast.EndBlock.Statements[$ast.EndBlock.Statements.Count - 1]
            $last.Extent.Text | Should -Be "exit 0"
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

        It "Renders the full menu before waiting for input" {
            # Receive-Job also inspects Workflow adapters on Windows PowerShell
            # 5.1, whose unrelated persistence store can fail before menu output.
            $start = New-Object System.Diagnostics.ProcessStartInfo
            $start.FileName = 'powershell.exe'
            $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script:MolePath + '"'
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($start)
            try {
                $deadline = (Get-Date).AddSeconds(15)
                $output = ''
                $stderr = $process.StandardError.ReadToEndAsync()
                $line = $process.StandardOutput.ReadLineAsync()
                do {
                    if ($line.IsCompleted) {
                        if ($null -eq $line.Result) { break }
                        $output += $line.Result + "`n"
                        if ($output -match 'Q Quit') { break }
                        $line = $process.StandardOutput.ReadLineAsync()
                    }
                    else { Start-Sleep -Milliseconds 20 }
                } while ((Get-Date) -lt $deadline)
                $output | Should -Match 'Q Quit'
                $output | Should -Match 'Free up disk space'
                $output | Should -Not -Match $script:VisualDefaultsErrorPattern
            }
            finally {
                if (-not $process.HasExited) { $process.Kill() }
                $process.WaitForExit(5000) | Should -BeTrue
                if ($stderr.IsCompleted) { $stderr.Result | Should -Not -Match $script:VisualDefaultsErrorPattern }
                $process.Dispose()
            }
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
            $source | Should -Match "Could not prepare .*Install Go, or run"
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
