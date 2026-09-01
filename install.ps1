#!/usr/bin/env pwsh
# Mole Windows Installer
# Installs Mole Windows support to the system and adds to PATH

#Requires -Version 5.1
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Mole",
    [switch]$AddToPath,
    [switch]$CreateShortcut,
    [switch]$Uninstall,
    [switch]$Force,
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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
    if ($RequestedInstallDir -ceq "-InstallDir" -and $RequestedAddToPath.IsPresent) {
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
$script:ShortcutName = "Mole"

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

function Show-Banner {
    $c = $script:Colors
    Write-Host ""
    Write-Host "  $($c.Cyan)MOLE$($c.NC)"
    Write-Host "  $($c.Gray)Windows System Maintenance$($c.NC)"
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
    Write-Host "                         Default: $env:LOCALAPPDATA\Mole"
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

function Remove-StartMenuShortcut {
    param([string]$ShortcutName)

    $startMenuPath = [Environment]::GetFolderPath("StartMenu")
    $programsPath = Join-Path $startMenuPath "Programs"
    $shortcutPath = Join-Path $programsPath "$ShortcutName.lnk"

    if (Test-Path $shortcutPath) {
        try {
            Remove-Item $shortcutPath -Force
            Write-Success "Removed shortcut: $shortcutPath"
            return $true
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

    foreach ($tool in $tools) {
        $destination = Join-Path $RootDir $tool.Output
        try {
            $binPath = Ensure-TuiBinary -Name $tool.Name -WindowsDir $RootDir -DestinationPath $destination -SourcePath $tool.Source -Version $version
        }
        catch {
            Write-MoleWarning "Skipping $($tool.Name).exe after a non-fatal setup error: $_"
            $binPath = $null
        }
        if ($binPath) {
            Write-Success "Ready: $($tool.Name).exe"
        }
        else {
            Write-MoleWarning "Could not prepare $($tool.Name).exe. Install Go or wait for a Windows prerelease asset."
        }
    }
}

function Install-Mole {
    Write-Info "Installing Mole v$script:VERSION..."
    Write-Host ""

    if (Test-ProtectedInstallRoot -Path $InstallDir) {
        Write-MoleError "Refusing to use protected install directory: $InstallDir"
        return $false
    }

    $inPlaceInstall = Test-SamePath -PathA $script:SourceDir -PathB $InstallDir

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
                    if ((Get-Item $src).PSIsContainer) {
                        # For directories, remove destination first if exists to avoid nesting
                        if (Test-Path $dst) {
                            Remove-Item -Path $dst -Recurse -Force
                        }
                        Copy-Item -Path $src -Destination $dst -Recurse -Force
                    }
                    else {
                        Copy-Item -Path $src -Destination $dst -Force
                    }
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

    # Create launcher batch file for easier access
    # Note: Store %~dp0 immediately to avoid issues with delayed expansion in the parse loop
    $batchContent = @"
@echo off
setlocal EnableDelayedExpansion

rem Store the script directory immediately before any shifting
set "MOLE_DIR=%~dp0"

set "ARGS="
:parse
if "%~1"=="" goto run
set "ARGS=!ARGS! '%~1'"
shift
goto parse
:run
powershell.exe -ExecutionPolicy Bypass -NoLogo -NoProfile -Command "& '%MOLE_DIR%mole.ps1' !ARGS!"
"@
    $batchPath = Join-Path $InstallDir "mole.cmd"
    Set-Content -Path $batchPath -Value $batchContent -Encoding ASCII
    Write-Success "Created launcher: mole.cmd"
    
    # Also create 'mo' alias
    $moPath = Join-Path $InstallDir "mo.cmd"
    Set-Content -Path $moPath -Value $batchContent -Encoding ASCII
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

function Uninstall-Mole {
    Write-Info "Uninstalling Mole..."
    Write-Host ""

    # Check for existing installation
    $configPath = Join-Path $env:LOCALAPPDATA "Mole"
    $installPath = if (Test-Path $InstallDir) { $InstallDir } elseif (Test-Path $configPath) { $configPath } else { $null }

    if (-not $installPath) {
        Write-MoleWarning "Mole is not installed"
        return $true
    }

    if (Test-ProtectedInstallRoot -Path $installPath) {
        Write-MoleError "Refusing to remove protected install directory: $installPath"
        return $false
    }

    # Remove from PATH
    Remove-FromUserPath -Directory $installPath

    # Remove shortcut
    Remove-StartMenuShortcut -ShortcutName $script:ShortcutName

    # Remove installation directory
    try {
        Remove-Item -LiteralPath $installPath -Recurse -Force
        Write-Success "Removed directory: $installPath"
    }
    catch {
        Write-MoleError "Failed to remove directory: $_"
        return $false
    }

    # Remove config directory if different from install
    $configDir = Join-Path $env:USERPROFILE ".config\mole"
    if (Test-Path $configDir) {
        Write-Info "Found config directory: $configDir"
        $response = Read-Host "  Remove config files? (y/N)"
        if ($response -eq "y" -or $response -eq "Y") {
            try {
                Remove-Item -LiteralPath $configDir -Recurse -Force
                Write-Success "Removed config: $configDir"
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
