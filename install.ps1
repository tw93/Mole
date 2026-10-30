#!/usr/bin/env pwsh
# Mole Windows Installer
# Installs Mole Windows support to the system and adds to PATH

#Requires -Version 5.1
param(
    # %LOCALAPPDATA%\Mole is the Mole for Windows app's data folder, so new
    # installs never go there; see Uninstall-Mole for installs that already did.
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\mole-cli",
    [switch]$AddToPath,
    [switch]$CreateShortcut,
    [switch]$Uninstall,
    [switch]$Force,
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$script:InstallDirGiven = $PSBoundParameters.ContainsKey("InstallDir")

# ============================================================================
# Configuration
# ============================================================================

function Resolve-InstallInvocation {
    param(
        [string]$SourceDir,
        [string]$RequestedInstallDir,
        [switch]$RequestedAddToPath,
        [switch]$RequestedCreateShortcut
    )

    # v1.30.0 passed @("-InstallDir", $sourceDir, optional "-AddToPath")
    # through array splatting. PowerShell bound those values positionally, so
    # the path made AddToPath truthy and the optional marker became
    # CreateShortcut. Decode only that exact legacy shape for the first update
    # that pulls this installer while the old updater is still running.
    if ($RequestedInstallDir -ceq "-InstallDir") {
        return [PSCustomObject]@{
            InstallDir     = $SourceDir
            AddToPath      = $RequestedCreateShortcut.IsPresent
            CreateShortcut = $false
        }
    }

    return [PSCustomObject]@{
        InstallDir     = $RequestedInstallDir
        AddToPath      = $RequestedAddToPath.IsPresent
        CreateShortcut = $RequestedCreateShortcut.IsPresent
    }
}

$script:SourceDir = if ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $PSScriptRoot
}
$resolvedInvocation = Resolve-InstallInvocation `
    -SourceDir $script:SourceDir `
    -RequestedInstallDir $InstallDir `
    -RequestedAddToPath:$AddToPath `
    -RequestedCreateShortcut:$CreateShortcut
$InstallDir = $resolvedInvocation.InstallDir
$AddToPath = [switch]$resolvedInvocation.AddToPath
$CreateShortcut = [switch]$resolvedInvocation.CreateShortcut
$script:CoreDir = Join-Path $script:SourceDir "lib\core"
# "Mole" is the Mole for Windows app's Start menu entry; the CLI uses its own name.
$script:ShortcutName = "Mole CLI"

. (Join-Path $script:CoreDir "version.ps1")
$script:VERSION = Get-MoleVersionString -RootDir $script:SourceDir

# Colors (using [char]27 for PowerShell 5.1 compatibility)
$script:ESC = [char]27
$script:Colors = @{
    Red     = "$($script:ESC)[31m"
    Green   = "$($script:ESC)[32m"
    Yellow  = "$($script:ESC)[33m"
    Blue    = "$($script:ESC)[34m"
    Cyan    = "$($script:ESC)[36m"
    Gray    = "$($script:ESC)[90m"
    NC      = "$($script:ESC)[0m"
}

. (Join-Path $script:CoreDir "tui_binaries.ps1")

# ============================================================================
# Helpers
# ============================================================================

function Write-Info {
    param([string]$Message)
    $c = $script:Colors
    Write-Host "  $($c.Blue)INFO$($c.NC)  $Message"
}

function Write-Success {
    param([string]$Message)
    $c = $script:Colors
    Write-Host "  $($c.Green)OK$($c.NC)    $Message"
}

function Write-MoleWarning {
    param([string]$Message)
    $c = $script:Colors
    Write-Host "  $($c.Yellow)WARN$($c.NC)  $Message"
}

function Write-MoleError {
    param([string]$Message)
    $c = $script:Colors
    Write-Host "  $($c.Red)ERROR$($c.NC) $Message"
}

function Get-NormalizedPath {
    param([string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-SamePath {
    param(
        [string]$PathA,
        [string]$PathB
    )

    return (Get-NormalizedPath -Path $PathA) -eq (Get-NormalizedPath -Path $PathB)
}

function Test-ProtectedInstallRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }

    try {
        $normalizedPath = Get-NormalizedPath -Path $Path
    }
    catch {
        return $true
    }

    $protectedRoots = @(
        $env:USERPROFILE
        [Environment]::GetFolderPath("UserProfile")
        $env:LOCALAPPDATA
        (Join-Path $env:LOCALAPPDATA "Programs")
        $env:APPDATA
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        $env:ProgramData
        "$env:SystemDrive\"
        "$env:WINDIR"
        "$env:SYSTEMROOT"
    )

    foreach ($root in $protectedRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        try {
            if ($normalizedPath -eq (Get-NormalizedPath -Path $root)) {
                return $true
            }
        }
        catch {
            continue
        }
    }

    return $false
}

# Installer copies and removals never follow a junction, including ancestors.
function Assert-InstallPhysicalPath {
    param([string]$Path)

    $current = [System.IO.Path]::GetFullPath($Path)
    while ($current) {
        try {
            $attributes = [System.IO.File]::GetAttributes($current)
            if ($attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Refusing linked install path: $current"
            }
        }
        catch {
            $errorObject = $_.Exception
            while ($errorObject.InnerException) { $errorObject = $errorObject.InnerException }
            if (($errorObject.HResult -band 0xffff) -notin @(2, 3)) { throw }
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Copy-MoleInstallEntry {
    param([string]$Source, [string]$Destination)

    Assert-InstallPhysicalPath -Path $Source
    Assert-InstallPhysicalPath -Path $Destination
    $item = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        if (-not (Test-Path -LiteralPath $Destination)) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
        foreach ($child in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
            Copy-MoleInstallEntry -Source $child.FullName -Destination (Join-Path $Destination $child.Name)
        }
    }
    else {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
    }
}

function Show-Banner {
    $c = $script:Colors
    Write-Host ""
    Write-Host "  $($c.Cyan)Mole CLI for Windows$($c.NC)"
    Write-Host "  $($c.Gray)Deep clean and optimize your PC. https://mole.fit/windows$($c.NC)"
    Write-Host ""
}

function Show-InstallerHelp {
    Show-Banner

    $c = $script:Colors
    Write-Host "  $($c.Green)USAGE:$($c.NC)"
    Write-Host ""
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1 [options]"
    Write-Host ""
    Write-Host "  $($c.Green)OPTIONS:$($c.NC)"
    Write-Host ""
    Write-Host "    $($c.Cyan)-InstallDir <path>$($c.NC)   Installation directory"
    Write-Host "                         Default: $env:LOCALAPPDATA\Programs\mole-cli"
    Write-Host ""
    Write-Host "    $($c.Cyan)-AddToPath$($c.NC)           Add Mole to user PATH"
    Write-Host ""
    Write-Host "    $($c.Cyan)-CreateShortcut$($c.NC)      Create Start Menu shortcut"
    Write-Host ""
    Write-Host "    $($c.Cyan)-Uninstall$($c.NC)           Remove Mole from system"
    Write-Host ""
    Write-Host "    $($c.Cyan)-Force$($c.NC)               Overwrite existing installation"
    Write-Host ""
    Write-Host "    $($c.Cyan)-ShowHelp$($c.NC)            Show this help message"
    Write-Host ""
    Write-Host "  $($c.Green)EXAMPLES:$($c.NC)"
    Write-Host ""
    Write-Host "    $($c.Gray)# Install with defaults$($c.NC)"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1"
    Write-Host ""
    Write-Host "    $($c.Gray)# Install and add to PATH$($c.NC)"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1 -AddToPath"
    Write-Host ""
    Write-Host "    $($c.Gray)# Custom install location$($c.NC)"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallDir C:\Tools\Mole -AddToPath"
    Write-Host ""
    Write-Host "    $($c.Gray)# Full installation$($c.NC)"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1 -AddToPath -CreateShortcut"
    Write-Host ""
    Write-Host "    $($c.Gray)# Uninstall$($c.NC)"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall"
    Write-Host ""
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-ToUserPath {
    param([string]$Directory)

    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")

    if ($currentPath -split ";" | Where-Object { $_ -eq $Directory }) {
        Write-Info "Already in PATH: $Directory"
        return $true
    }

    $newPath = if ($currentPath) { "$currentPath;$Directory" } else { $Directory }

    try {
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Success "Added to PATH: $Directory"

        # Update current session
        $env:PATH = "$env:PATH;$Directory"
        return $true
    }
    catch {
        Write-MoleError "Failed to update PATH: $_"
        return $false
    }
}

function Remove-FromUserPath {
    param([string]$Directory)

    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")

    if (-not $currentPath) {
        return $true
    }

    $paths = $currentPath -split ";" | Where-Object { $_ -ne $Directory -and $_ -ne "" }
    $newPath = $paths -join ";"

    try {
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Success "Removed from PATH: $Directory"
        return $true
    }
    catch {
        Write-MoleError "Failed to update PATH: $_"
        return $false
    }
}

function New-StartMenuShortcut {
    param(
        [string]$TargetPath,
        [string]$ShortcutName,
        [string]$Description
    )

    $startMenuPath = [Environment]::GetFolderPath("StartMenu")
    $programsPath = Join-Path $startMenuPath "Programs"
    $shortcutPath = Join-Path $programsPath "$ShortcutName.lnk"

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$TargetPath`""
        $shortcut.Description = $Description
        $shortcut.WorkingDirectory = Split-Path -Parent $TargetPath
        $shortcut.Save()

        Write-Success "Created shortcut: $shortcutPath"
        return $true
    }
    catch {
        Write-MoleError "Failed to create shortcut: $_"
        return $false
    }
}

# Removes the Start menu shortcut this install created: "Mole CLI.lnk", or
# "Mole.lnk" from 1.30.0, and only when it starts this install's mole.ps1.
# A "Mole.lnk" that points anywhere else belongs to the Mole for Windows app.
function Remove-StartMenuShortcut {
    param(
        [string]$InstallDir,
        [string]$ProgramsPath = (Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs")
    )

    $moleScript = Join-Path $InstallDir "mole.ps1"
    $shell = New-Object -ComObject WScript.Shell
    foreach ($name in @("Mole CLI", "Mole")) {
        $shortcutPath = Join-Path $ProgramsPath "$name.lnk"
        if (-not (Test-Path -LiteralPath $shortcutPath)) {
            continue
        }
        $arguments = $shell.CreateShortcut($shortcutPath).Arguments
        if (-not $arguments -or $arguments.IndexOf($moleScript, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }
        try {
            Remove-Item -LiteralPath $shortcutPath -Force
            Write-Success "Removed shortcut: $shortcutPath"
        }
        catch {
            Write-MoleError "Failed to remove shortcut: $_"
            return $false
        }
    }
    return $true
}

# ============================================================================
# Install
# ============================================================================

function Ensure-OptionalTuiTools {
    param([string]$RootDir)

    Write-Info "Ensuring optional TUI tools..."

    $tools = @(
        @{ Name = "analyze"; Output = "bin\analyze.exe"; Source = "./cmd/analyze/" },
        @{ Name = "status"; Output = "bin\status.exe"; Source = "./cmd/status/" }
    )

    $version = Get-MoleVersionFromScriptFile -WindowsDir $RootDir
    $refreshSourceTools = Test-Path -LiteralPath (Join-Path $RootDir ".git")
    $failedTools = @()

    foreach ($tool in $tools) {
        $destination = Join-Path $RootDir $tool.Output
        $hadExisting = Test-Path -LiteralPath $destination
        try {
            $binPath = Ensure-TuiBinary -Name $tool.Name -WindowsDir $RootDir -DestinationPath $destination -SourcePath $tool.Source -Version $version -Refresh:$refreshSourceTools
        }
        catch {
            Write-MoleWarning "Skipping $($tool.Name).exe after a non-fatal setup error: $_"
            $binPath = $null
        }
        if ($binPath) {
            Write-Success "Ready: $($tool.Name).exe"
        }
        else {
            Write-MoleWarning "Could not prepare $($tool.Name).exe. Install Go, or run mo update later to fetch the release build."
            # Only a tool that stays at an older build is a failed refresh; with
            # nothing installed yet, the command fetches the release on first use.
            if ($hadExisting) { $failedTools += $tool.Name }
        }
    }
    if ($refreshSourceTools -and $failedTools.Count -gt 0) {
        throw "Could not refresh $($failedTools -join ', ') from this source. Install Go and rerun this installer. Existing tools were kept."
    }
}

function Install-Mole {
    Write-Info "Installing Mole v$script:VERSION..."
    Write-Host ""

    if (Test-ProtectedInstallRoot -Path $InstallDir) {
        Write-MoleError "Refusing to use protected install directory: $InstallDir"
        return $false
    }

    Assert-InstallPhysicalPath -Path $InstallDir
    $inPlaceInstall = Test-SamePath -PathA $script:SourceDir -PathB $InstallDir
    if (-not $inPlaceInstall -and (Test-Path -LiteralPath $InstallDir) -and
        @(Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction Stop).Count -gt 0 -and
        -not (Test-MoleInstallDir -Path $InstallDir)) {
        Write-MoleError "Refusing to merge into a directory not owned by this install: $InstallDir"
        return $false
    }

    # Check if already installed
    if ((Test-Path $InstallDir) -and -not $Force -and -not $inPlaceInstall) {
        Write-MoleError "Mole is already installed at: $InstallDir"
        Write-Host ""
        Write-Host "  Use -Force to overwrite or -Uninstall to remove first"
        Write-Host ""
        return $false
    }

    # Create install directory
    if (-not (Test-Path $InstallDir)) {
        try {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
            Write-Success "Created directory: $InstallDir"
        }
        catch {
            Write-MoleError "Failed to create directory: $_"
            return $false
        }
    }

    if ($inPlaceInstall) {
        Write-Info "Using in-place source installation in: $InstallDir"
    }
    else {
        # Copy files
        Write-Info "Copying files..."

        $filesToCopy = @(
            # VERSION travels with the install: without it every command falls
            # back to the compiled-in default and reports a stale version.
            "VERSION"
            "mole.ps1"
            "install.ps1"
            "go.mod"
            "go.sum"
            "bin"
            "lib"
            "cmd"
        )

        foreach ($item in $filesToCopy) {
            $src = Join-Path $script:SourceDir $item
            $dst = Join-Path $InstallDir $item

            if (Test-Path $src) {
                try {
                    Copy-MoleInstallEntry -Source $src -Destination $dst
                    Write-Success "Copied: $item"
                }
                catch {
                    Write-MoleError "Failed to copy $item`: $_"
                    return $false
                }
            }
        }
    }

    # Create scripts and tests directories if they don't exist
    $extraDirs = @("scripts", "tests")
    foreach ($dir in $extraDirs) {
        $dirPath = Join-Path $InstallDir $dir
        if (-not (Test-Path $dirPath)) {
            New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
        }
    }

    Write-Host ""
    Ensure-OptionalTuiTools -RootDir $InstallDir

    # Pass native arguments to -File, never interpolate them into PowerShell
    # source. Expand the invocation before ending the self-removing batch.
    $batchContent = @'
@echo off
setlocal DisableDelayedExpansion
(goto) 2>nul & "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -NoLogo -NoProfile -File "%~dp0mole.ps1" %*
'@
    $batchPath = Join-Path $InstallDir "mole.cmd"
    Assert-InstallPhysicalPath -Path $batchPath
    Set-Content -LiteralPath $batchPath -Value $batchContent -Encoding ASCII
    Write-Success "Created launcher: mole.cmd"
    
    # Also create 'mo' alias
    $moPath = Join-Path $InstallDir "mo.cmd"
    Assert-InstallPhysicalPath -Path $moPath
    Set-Content -LiteralPath $moPath -Value $batchContent -Encoding ASCII
    Write-Success "Created launcher: mo.cmd (short alias)"

    # Add to PATH if requested
    if ($AddToPath) {
        Write-Host ""
        if (-not (Add-ToUserPath -Directory $InstallDir)) {
            return $false
        }
    }

    # Create shortcut if requested
    if ($CreateShortcut) {
        Write-Host ""
        $targetPath = Join-Path $InstallDir "mole.ps1"
        if (-not (New-StartMenuShortcut -TargetPath $targetPath -ShortcutName $script:ShortcutName -Description "Windows System Maintenance Toolkit")) {
            return $false
        }
    }

    Write-Host ""
    Write-Success "Mole installed successfully!"
    Write-Host ""
    Write-Host "  Location: $InstallDir"
    Write-Host ""

    if ($AddToPath) {
        Write-Host "  Run 'mo' or 'mole' from any terminal to start"
    }
    else {
        Write-Host "  Run the following to start:"
        Write-Host "    & `"$InstallDir\mole.ps1`""
        Write-Host ""
        Write-Host "  Or add to PATH with:"
        Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1 -AddToPath"
    }

    Write-Host ""
    Write-Host "  Run 'mo update' to pull the latest source from the windows branch"
    Write-Host ""
    return $true
}

# ============================================================================
# Uninstall
# ============================================================================

# Top-level entries a Mole CLI install can hold: the repository tree, files
# older releases shipped, git metadata and the launchers this script writes.
# Anything else in the folder belongs to someone else and is kept.
function Get-MoleInstallEntries {
    return @(
        ".editorconfig", ".git", ".gitattributes", ".github", ".gitignore", ".golangci.yml", ".shellcheckrc",
        "AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", "CONTRIBUTORS.svg", "ISSUE-343-SUMMARY.md", "LICENSE", "Makefile",
        "README.md", "README_CN.md", "README_DE.md", "README_FR.md", "README_JA.md", "README_KR.md", "README_RU.md", "README_TW.md",
        "README_UA.md", "RELEASE.md", "SECURITY.md", "SECURITY_AUDIT.md", "SYNC.md", "TRADEMARK.md", "VERSION",
        "bin", "cmd", "go.mod", "go.sum", "install.ps1", "lib", "mo.cmd", "mo.exe", "mole.cmd", "mole.ps1",
        "packaging", "quick-install.ps1", "scripts", "tests"
    )
}

# Exact shipped files, not directory names, establish removal scope. Keep
# unknown files in shared folders and Git metadata; prune only empty folders.
function Get-MoleInstallNestedFiles {
    return @(
        ".github\FUNDING.yml"
        ".github\ISSUE_TEMPLATE\bug_report.md"
        ".github\ISSUE_TEMPLATE\config.yml"
        ".github\ISSUE_TEMPLATE\feature_request.md"
        ".github\dependabot.yml"
        ".github\workflows\check.yml"
        ".github\workflows\release-windows.yml"
        ".github\workflows\test.yml"
        ".github\workflows\update-contributors.yml"
        "bin\analyze.exe"
        "bin\analyze.ps1"
        "bin\clean.ps1"
        "bin\history.ps1"
        "bin\optimize.ps1"
        "bin\purge.ps1"
        "bin\remove.ps1"
        "bin\status.exe"
        "bin\status.ps1"
        "bin\uninstall.ps1"
        "bin\update.ps1"
        "cmd\analyze\cleanable.go"
        "cmd\analyze\cleanable_test.go"
        "cmd\analyze\cli.go"
        "cmd\analyze\constants.go"
        "cmd\analyze\delete.go"
        "cmd\analyze\directory_browsing_test.go"
        "cmd\analyze\format.go"
        "cmd\analyze\format_test.go"
        "cmd\analyze\heap.go"
        "cmd\analyze\json.go"
        "cmd\analyze\json_test.go"
        "cmd\analyze\lifecycle_test.go"
        "cmd\analyze\live_config.go"
        "cmd\analyze\live_scan.go"
        "cmd\analyze\live_update_test.go"
        "cmd\analyze\main_other.go"
        "cmd\analyze\main_windows.go"
        "cmd\analyze\model.go"
        "cmd\analyze\oplog.go"
        "cmd\analyze\oplog_test.go"
        "cmd\analyze\overview.go"
        "cmd\analyze\platform_other.go"
        "cmd\analyze\platform_windows.go"
        "cmd\analyze\protect_windows.go"
        "cmd\analyze\recycle_guard_windows.go"
        "cmd\analyze\scanner.go"
        "cmd\analyze\update.go"
        "cmd\analyze\view.go"
        "cmd\analyze\view_test.go"
        "cmd\analyze\windows_test.go"
        "cmd\mo\main.go"
        "cmd\mo\main_test.go"
        "cmd\status\battery_windows_test.go"
        "cmd\status\collection.go"
        "cmd\status\diagnosis.go"
        "cmd\status\main.go"
        "cmd\status\main_test.go"
        "cmd\status\metrics.go"
        "cmd\status\metrics_health.go"
        "cmd\status\metrics_health_test.go"
        "cmd\status\metrics_other.go"
        "cmd\status\metrics_test.go"
        "cmd\status\metrics_windows.go"
        "cmd\status\platform_names.go"
        "cmd\status\prefs.go"
        "cmd\status\prefs_lock_other.go"
        "cmd\status\prefs_lock_windows.go"
        "cmd\status\prefs_test.go"
        "cmd\status\process_watch.go"
        "cmd\status\process_watch_test.go"
        "cmd\status\proxy_privacy_test.go"
        "cmd\status\testhelpers_test.go"
        "cmd\status\units.go"
        "cmd\status\usage_test.go"
        "cmd\status\view.go"
        "cmd\status\view_test.go"
        "cmd\status\watch.go"
        "cmd\status\watch_test.go"
        "cmd\status\windows_logic_test.go"
        "docs\development-pitfalls.md"
        "docs\development-record.md"
        "docs\incidents.md"
        "docs\img\analyze-windows.png"
        "docs\img\clean-windows.png"
        "docs\img\mole-windows.png"
        "docs\img\optimize-windows.png"
        "docs\img\status-windows.png"
        "docs\img\uninstall-windows.png"
        "lib\clean\apps.ps1"
        "lib\clean\caches.ps1"
        "lib\clean\cache_guard.ps1"
        "lib\clean\dev.ps1"
        "lib\clean\system.ps1"
        "lib\clean\user.ps1"
        "lib\core\base.ps1"
        "lib\core\common.ps1"
        "lib\core\file_ops.ps1"
        "lib\core\history.ps1"
        "lib\core\log.ps1"
        "lib\core\tui_binaries.ps1"
        "lib\core\ui.ps1"
        "lib\core\update_check.ps1"
        "lib\core\version.ps1"
        "packaging\README.md"
        "packaging\scoop\mole.json"
        "packaging\winget\tw93.MoleCLI.installer.yaml"
        "packaging\winget\tw93.MoleCLI.locale.en-US.yaml"
        "packaging\winget\tw93.MoleCLI.yaml"
        "scripts\build-msi.ps1"
        "scripts\build-release.ps1"
        "scripts\build.ps1"
        "scripts\check_incidents.py"
        "scripts\e2e_windows.py"
        "scripts\mole-installer.wxs"
        "scripts\new-release-zip.ps1"
        "scripts\render-packaging.ps1"
        "scripts\risk_tier.py"
        "scripts\sign-release.ps1"
        "scripts\test.ps1"
        "scripts\write-checksums.ps1"
        "tests\Clean.Tests.ps1"
        "tests\CleanupBoundary.Tests.ps1"
        "tests\CleanupTargets.Tests.ps1"
        "tests\AppCacheSafety.Tests.ps1"
        "tests\Commands.Tests.ps1"
        "tests\Core.Tests.ps1"
        "tests\DryRun.Tests.ps1"
        "tests\DryRunEnvironment.Tests.ps1"
        "tests\e2e_harness_test.py"
        "tests\GitProxy.Tests.ps1"
        "tests\History.Tests.ps1"
        "tests\Install.Tests.ps1"
        "tests\InstallLifecycle.Tests.ps1"
        "tests\Optimize.Tests.ps1"
        "tests\Protection.Tests.ps1"
        "tests\PurgeBoundary.Tests.ps1"
        "tests\Recycle.Tests.ps1"
        "tests\Release.Tests.ps1"
        "tests\review_gates_test.py"
        "tests\Router.Tests.ps1"
        "tests\TestRunner.Tests.ps1"
        "tests\UI.Tests.ps1"
        "tests\Uninstall.Tests.ps1"
        "tests\UninstallWait.Tests.ps1"
        "tests\UpdateNotice.Tests.ps1"
    )
}

function Remove-MoleNestedFiles {
    param([string]$InstallPath, [string]$Root)

    $files = @(Get-MoleInstallNestedFiles | Where-Object { $_.StartsWith("$Root\", [StringComparison]::OrdinalIgnoreCase) })
    $folders = @($Root)
    Assert-InstallPhysicalPath -Path (Join-Path $InstallPath $Root)
    foreach ($file in $files) {
        $path = Join-Path $InstallPath $file
        Assert-InstallPhysicalPath -Path $path
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
        $folder = Split-Path -Parent $file
        while ($folder) {
            if ($folders -notcontains $folder) { $folders += $folder }
            $folder = Split-Path -Parent $folder
        }
    }
    # Deepest first, and only folders left empty.
    foreach ($folder in @($folders | Sort-Object { $_.Length } -Descending)) {
        $path = Join-Path $InstallPath $folder
        if ((Test-Path -LiteralPath $path -PathType Container) -and
            @(Get-ChildItem -LiteralPath $path -Force).Count -eq 0) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
}

function Test-MoleInstallDir {
    param([string]$Path)

    return (Test-Path -LiteralPath (Join-Path $Path "mole.ps1")) -and
        (Test-Path -LiteralPath (Join-Path $Path "lib\core\base.ps1"))
}

# Removes one entry of the config folder without following links: a junction or
# symbolic link is unlinked itself, never recursed into, so its target survives.
# Windows PowerShell 5.1's Remove-Item -Recurse deletes a linked directory's
# target contents.
function Remove-MoleConfigEntry {
    param([System.IO.FileSystemInfo]$Item)

    if ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        if ($Item.Attributes -band [System.IO.FileAttributes]::Directory) {
            [System.IO.Directory]::Delete($Item.FullName, $false)
        }
        else {
            [System.IO.File]::Delete($Item.FullName)
        }
        return
    }
    if ($Item.Attributes -band [System.IO.FileAttributes]::Directory) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Item.FullName -Force -ErrorAction Stop)) {
            Remove-MoleConfigEntry -Item $child
        }
        # Never recursive: an entry added since the listing fails the removal
        # instead of Remove-Item offering to delete it.
        if ($Item.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            $Item.Attributes = $Item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
        }
        [System.IO.Directory]::Delete($Item.FullName, $false)
        return
    }
    Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction Stop
}

function Uninstall-Mole {
    Write-Info "Uninstalling Mole..."
    Write-Host ""

    # Without -InstallDir, remove the install this script belongs to. There is
    # no fallback to %LOCALAPPDATA%\Mole: that is the Mole for Windows app's
    # data folder, and 1.30.0 removed it whole.
    $installPath = if ($script:InstallDirGiven) { $InstallDir } else { $script:SourceDir }

    if (-not (Test-Path -LiteralPath $installPath)) {
        Write-MoleWarning "Mole is not installed at $installPath"
        return $true
    }

    if (Test-ProtectedInstallRoot -Path $installPath) {
        Write-MoleError "Refusing to remove protected install directory: $installPath"
        return $false
    }

    if (-not (Test-MoleInstallDir -Path $installPath)) {
        Write-MoleError "$installPath is not a Mole install (no mole.ps1); nothing was removed"
        return $false
    }

    Assert-InstallPhysicalPath -Path $installPath

    # A running native launcher cannot be deleted on Windows. Check before
    # changing PATH, shortcuts or any files, rather than leaving half an install.
    $nativeLauncher = Join-Path $installPath 'mo.exe'
    if (Test-Path -LiteralPath $nativeLauncher) {
        try {
            Assert-InstallPhysicalPath -Path $nativeLauncher
            $handle = [IO.File]::Open($nativeLauncher, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $handle.Dispose()
        }
        catch {
            Write-MoleError "Cannot remove mo.exe while it is inaccessible or a Mole command runs through it, this one included: $nativeLauncher"
            $removeScript = (Join-Path $installPath 'mole.ps1').Replace("'", "''")
            Write-Info "Close other Mole sessions, then run in PowerShell: & '$removeScript' remove"
            return $false
        }
    }

    # Remove from PATH
    $null = Remove-FromUserPath -Directory $installPath

    # Remove shortcut
    $null = Remove-StartMenuShortcut -InstallDir $installPath

    # Remove only what Mole installed; another app may share the folder
    # (Mole for Windows keeps its license and settings in %LOCALAPPDATA%\Mole).
    $known = Get-MoleInstallEntries
    $nestedRoots = @(Get-MoleInstallNestedFiles | ForEach-Object { ($_ -split '\\')[0] } | Select-Object -Unique)
    $kept = @()
    foreach ($entry in @(Get-ChildItem -LiteralPath $installPath -Force)) {
        if ($entry.Name -eq ".git" -and -not $entry.PSIsContainer) {
            $kept += $entry.Name
            continue
        }
        if ($nestedRoots -contains $entry.Name -or ($entry.PSIsContainer -and $known -contains $entry.Name)) {
            try {
                Remove-MoleNestedFiles -InstallPath $installPath -Root $entry.Name
            }
            catch {
                Write-MoleError "Failed to remove $($entry.FullName): $_"
                return $false
            }
            if (Test-Path -LiteralPath $entry.FullName) { $kept += $entry.Name }
            continue
        }
        if ($known -notcontains $entry.Name) {
            $kept += $entry.Name
            continue
        }
        try {
            Assert-InstallPhysicalPath -Path $entry.FullName
            Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop
        }
        catch {
            Write-MoleError "Failed to remove $($entry.FullName): $_"
            return $false
        }
    }

    if ($kept.Count -eq 0) {
        try {
            Remove-Item -LiteralPath $installPath -Force -ErrorAction Stop
            Write-Success "Removed directory: $installPath"
        }
        catch {
            Write-MoleError "Failed to remove directory: $_"
            return $false
        }
    }
    else {
        Write-Success "Removed Mole from: $installPath"
        Write-MoleWarning "Kept $($kept.Count) item(s) Mole did not install: $($kept -join ', ')"
    }

    # The cache folder is Mole-owned and rebuildable, like the macOS CLI's
    # ~/.cache/mole: downloaded tool binaries and scan caches, never
    # user-authored state. A linked cache root is kept rather than followed.
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $cachePath = Join-Path $env:USERPROFILE ".cache\mole"
        if (Test-Path -LiteralPath $cachePath) {
            try {
                Assert-InstallPhysicalPath -Path $cachePath
                $cacheRoot = Get-Item -LiteralPath $cachePath -Force -ErrorAction Stop
                if ($cacheRoot.PSIsContainer -and
                    -not ($cacheRoot.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    Remove-MoleConfigEntry -Item $cacheRoot
                    if (Get-Command Write-MoleOperation -ErrorAction SilentlyContinue) {
                        Write-MoleOperation -Action "REMOVED" -Path $cachePath -Detail "cache"
                    }
                    Write-Success "Removed cache: $cachePath"
                }
            }
            catch {
                Write-MoleWarning "Kept cache: $cachePath ($($_.Exception.Message))"
            }
        }
    }

    # Remove config directory if different from install
    $configDir = Join-Path $env:USERPROFILE ".config\mole"
    if (Test-Path $configDir) {
        Write-Info "Found config directory: $configDir"
        $response = Read-Host "  Remove config files? (y/N)"
        if ($response -eq "y" -or $response -eq "Y") {
            # operations.log is the record of what Mole removed; support reads it after
            # a report, so it outlives the CLI along with its rotated copy.
            try {
                # Checking children cannot protect a linked config root or ancestor:
                # enumeration would already have followed it into another directory.
                Assert-InstallPhysicalPath -Path $configDir
                $kept = @()
                foreach ($item in @(Get-ChildItem -LiteralPath $configDir -Force -ErrorAction Stop)) {
                    Assert-InstallPhysicalPath -Path $configDir
                    if ($item.Name -like 'operations.log*') { $kept += $item.Name; continue }
                    Remove-MoleConfigEntry -Item $item
                }
                if ($kept.Count -eq 0) {
                    Remove-Item -LiteralPath $configDir -Force -ErrorAction Stop
                    Write-Success "Removed config: $configDir"
                }
                else {
                    Write-Success "Removed config: $configDir (kept $($kept -join ', '))"
                }
            }
            catch {
                Write-MoleWarning "Failed to remove config: $_"
            }
        }
    }

    Write-Host ""
    Write-Success "Mole uninstalled successfully!"
    Write-Host ""
    return $true
}

# ============================================================================
# Main
# ============================================================================

function Main {
    if ($ShowHelp) {
        Show-InstallerHelp
        return
    }

    Show-Banner

    if ($Uninstall) {
        $ok = Uninstall-Mole
    }
    else {
        $ok = Install-Mole
    }

    if (-not $ok) {
        exit 1
    }
}

# Run
try {
    Main
}
catch {
    Write-Host ""
    Write-Host "  $($script:Colors.Red)ERROR$($script:Colors.NC) Installation failed: $_"
    Write-Host ""
    exit 1
}
