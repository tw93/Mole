#!/usr/bin/env pwsh
# Mole - Windows System Maintenance Toolkit
# Main CLI entry point

#Requires -Version 5.1
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$CommandArgs,

    [Alias('v')]
    [switch]$Version,
    
    [Alias('h')]
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# The installed .cmd launcher uses -File, which binds --debug as PowerShell's
# common parameter instead of leaving it in CommandArgs for the child command.
if ($PSBoundParameters.ContainsKey('Debug') -and $PSBoundParameters['Debug']) {
    if ($null -eq $CommandArgs) { $CommandArgs = @('--debug') }
    else { $CommandArgs += '--debug' }
    $DebugPreference = 'SilentlyContinue'
}

# Get script directory
$script:MOLE_ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:MOLE_BIN = Join-Path $script:MOLE_ROOT "bin"
$script:MOLE_LIB = Join-Path $script:MOLE_ROOT "lib"
$script:MOLE_CORE = Join-Path $script:MOLE_LIB "core"

# Read the version before loading the rest of the runtime so every entrypoint
# resolves the same release tag.
. "$script:MOLE_CORE\version.ps1"
Repair-MoleModulePath
$script:MOLE_VER = Get-MoleVersionString -RootDir $script:MOLE_ROOT

# Import core
. "$script:MOLE_LIB\core\common.ps1"

# ============================================================================
# Version Info
# ============================================================================

function Show-Version {
    $info = Get-MoleVersion
    $windows = Get-WindowsVersion
    Write-Host "Mole version $($info.Version)"
    Write-Host "Windows: $($windows.Name) $($windows.Version)"
    Write-Host "Architecture: $(Get-NativeArchitecture)"
    Write-Host "PowerShell: $($info.PowerShell)"
    Write-Host "Disk Free: $(Get-FreeSpace)"
    Write-Host "Install: $(Get-MoleInstallDescription -RootDir $script:MOLE_ROOT)"
}

# The machine's own architecture. An x64 process on ARM64 Windows (mo.exe
# runs PowerShell under emulation) sees AMD64 in its environment, so read the
# system-wide value Windows keeps in the registry.
function Get-NativeArchitecture {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
    $native = (Get-ItemProperty -Path $key -Name PROCESSOR_ARCHITECTURE -ErrorAction SilentlyContinue).PROCESSOR_ARCHITECTURE
    if ($native) {
        return $native
    }
    return $env:PROCESSOR_ARCHITECTURE
}

# The facts a --debug session log opens with. No user or machine name.
function Get-MoleDebugHeader {
    param([string]$CommandLine)

    $lines = @("Mole Debug Session, $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "Command: mo $CommandLine")
    try {
        $info = Get-MoleVersion
        $windows = Get-WindowsVersion
        $lines += "Mole version: $($info.Version)"
        $lines += "Windows: $($windows.Name) $($windows.Version)"
        $lines += "Architecture: $(Get-NativeArchitecture)"
        $lines += "PowerShell: $($info.PowerShell) $($PSVersionTable.PSEdition)"
        $lines += "Install: $(Get-MoleInstallDescription -RootDir $script:MOLE_ROOT)"
    }
    catch { $lines += "Environment: unavailable" }
    return $lines
}

# A source install checks out a release tag; naming its commit tells a report
# exactly which source ran. Read from .git without starting git.
function Get-MoleSourceCommit {
    param([string]$RootDir)

    $gitDir = Join-Path $RootDir ".git"
    try {
        $head = ([System.IO.File]::ReadAllText((Join-Path $gitDir "HEAD"))).Trim()
        if ($head -match '^ref: (refs/\S+)$') {
            $ref = $Matches[1]
            $loose = Join-Path $gitDir ($ref -replace '/', '\')
            $head = $null
            if (Test-Path -LiteralPath $loose -PathType Leaf) {
                $head = ([System.IO.File]::ReadAllText($loose)).Trim()
            }
            else {
                $packed = Join-Path $gitDir "packed-refs"
                if (Test-Path -LiteralPath $packed -PathType Leaf) {
                    foreach ($line in [System.IO.File]::ReadAllLines($packed)) {
                        if ($line -match "^([0-9a-f]{40}) $([regex]::Escape($ref))$") { $head = $Matches[1]; break }
                    }
                }
            }
        }
        if ($head -match '^[0-9a-f]{40}$') { return $head.Substring(0, 7) }
    }
    catch { } # A worktree link or unreadable metadata just leaves the commit out.
    return $null
}

function Get-MoleInstallDescription {
    param([string]$RootDir)

    $method = Get-MoleInstallMethod -RootDir $RootDir
    if ($method -eq "Source") {
        $commit = Get-MoleSourceCommit -RootDir $RootDir
        if ($commit) { return "Source ($commit)" }
    }
    return $method
}

# How this copy was installed, by the folder each channel installs into.
function Get-MoleInstallMethod {
    param([string]$RootDir)

    $path = $RootDir.TrimEnd('\') + '\'
    if ($path -like "*\Microsoft\WinGet\Packages\tw93.MoleCLI_*") { return "winget" }
    if ($path -like "*\scoop\apps\mole\*") { return "Scoop" }
    if (Test-Path -LiteralPath (Join-Path $RootDir ".git")) { return "Source" }
    return "Portable"
}

# ============================================================================
# Help
# ============================================================================

function Show-MainHelp {
    $blue = $script:Colors.Blue
    $green = $script:Colors.Green
    $nc = $script:Colors.NC

    function Write-HelpRow([string]$Usage, [string]$Description) {
        Write-Host ("  {0}{1,-28}{2} {3}" -f $green, $Usage, $nc, $Description)
    }

    Show-Banner
    Write-Host "${blue}COMMANDS${nc}"
    Write-HelpRow "mo" "Main menu"
    Write-HelpRow "mo clean" "Free up disk space"
    Write-HelpRow "mo uninstall" "Remove apps completely"
    Write-HelpRow "mo optimize" "Refresh caches and services"
    Write-HelpRow "mo analyze" "Explore disk usage"
    Write-HelpRow "mo status" "Monitor system health"
    Write-HelpRow "mo purge" "Remove old project artifacts"
    Write-HelpRow "mo history" "Review cleanup activity"
    Write-HelpRow "mo update" "Update to latest version"
    Write-HelpRow "mo remove" "Remove Mole from system"
    Write-HelpRow "mo --help" "Show help"
    Write-HelpRow "mo --version" "Show version"
    Write-Host ""
    Write-HelpRow "mo clean --dry-run" "Preview cleanup"
    Write-HelpRow "mo clean --whitelist" "Manage protected paths"
    Write-HelpRow "mo clean --system" "Include system cleanup (run as administrator)"
    Write-HelpRow "mo optimize --dry-run" "Preview optimization"
    Write-HelpRow "mo uninstall --dry-run" "Preview app uninstall"
    Write-HelpRow "mo purge --dry-run" "Preview project purge"
    Write-HelpRow "mo purge --paths" "Configure scan directories"
    Write-HelpRow "mo history --json" "Export cleanup history"
    Write-HelpRow "mo analyze D:\" "Analyze another drive"
    Write-Host ""
    Write-Host "${blue}OPTIONS${nc}"
    Write-HelpRow "--debug" "Show detailed operation logs"
    Write-Host ""
}

# ============================================================================
# Interactive Menu
# ============================================================================

# The macOS CLI's main menu: five numbered commands, arrow keys or 1-5,
# M for the full help, V for the version, Q to quit. Returns a command name,
# "help", "version" or $null.
function Show-MainMenu {
    $items = @(
        @{ Command = "clean"; Label = "Clean        Free up disk space" },
        @{ Command = "uninstall"; Label = "Uninstall    Remove apps completely" },
        @{ Command = "optimize"; Label = "Optimize     Refresh caches and services" },
        @{ Command = "analyze"; Label = "Analyze      Explore disk usage" },
        @{ Command = "status"; Label = "Status       Monitor system health" }
    )
    $cyan = $script:Colors.Cyan
    $gray = $script:Colors.Gray
    $nc = $script:Colors.NC
    $esc = [char]27
    $controls = "${gray}$([char]0x2191)$([char]0x2193)  |  Enter  |  M More  |  V Version  |  Q Quit${nc}"
    $selected = 0

    Write-Host -NoNewline "$esc[?25l"
    try {
        while ($true) {
            Clear-Host
            Write-Host ""
            Show-Banner
            for ($i = 0; $i -lt $items.Count; $i++) {
                if ($i -eq $selected) {
                    Write-Host "${cyan}$($script:Icons.Arrow) $($i + 1). $($items[$i].Label)${nc}"
                }
                else {
                    Write-Host "  $($i + 1). $($items[$i].Label)"
                }
            }
            Write-Host ""
            Write-Host $controls

            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            switch ($key.VirtualKeyCode) {
                38 { if ($selected -gt 0) { $selected-- } }
                40 { if ($selected -lt $items.Count - 1) { $selected++ } }
                13 { return $items[$selected].Command }
                27 { return $null }
            }
            $char = [string]$key.Character
            if ($char -match '^[1-5]$') {
                return $items[[int]$char - 1].Command
            }
            switch ($char.ToLowerInvariant()) {
                'k' { if ($selected -gt 0) { $selected-- } }
                'j' { if ($selected -lt $items.Count - 1) { $selected++ } }
                'm' { return "help" }
                'v' { return "version" }
                'q' { return $null }
            }
        }
    }
    finally {
        Write-Host -NoNewline "$esc[?25h"
    }
}

# ============================================================================
# Command Router
# ============================================================================

# Maps a command-line flag (dry-run, help, h) to the parameter its command
# script declares. A flag nothing declares is refused rather than passed on:
# scripts without [CmdletBinding()] ignore unknown parameters, so
# `mo remove --help` used to uninstall Mole.
function Resolve-CommandParameterName {
    param(
        $Parameters,
        [string]$Flag
    )

    $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
        @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
    foreach ($parameter in $Parameters.Values) {
        if ($common -contains $parameter.Name) {
            continue
        }
        if ($parameter.Name -eq $Flag -or $parameter.Aliases -contains $Flag) {
            return $parameter.Name
        }
    }

    # --help and --debug are spelled the same for every command.
    $synonyms = @{ "help" = "ShowHelp"; "debug" = "DebugMode" }
    if ($synonyms.ContainsKey($Flag)) {
        foreach ($parameter in $Parameters.Values) {
            if ($parameter.Name -eq $synonyms[$Flag]) {
                return $parameter.Name
            }
        }
    }
    return $null
}

function Invoke-MoleCommand {
    param(
        [string]$CommandName,
        [string[]]$Arguments
    )

    $scriptPath = Join-Path $script:MOLE_BIN "$CommandName.ps1"

    if (-not (Test-Path $scriptPath)) {
        $script:MoleExitCode = 2
        Write-MoleError "Unknown command: $CommandName"
        Write-Host ""
        Write-Host "Run 'mo --help' for available commands"
        return
    }

    # A previous native command must not make a help-only invocation fail.
    if ($CommandName -in @("analyze", "status", "history")) { $global:LASTEXITCODE = 0 }

    # Execute the command script with arguments using splatting
    # This properly handles switch parameters passed as strings
    $argCount = if ($null -eq $Arguments) { 0 } else { @($Arguments).Count }
    $splatParams = @{}
    $positionalArgs = @()
    if ($argCount -gt 0) {
        $declared = (Get-Command -Name $scriptPath -CommandType ExternalScript).Parameters

        foreach ($arg in $Arguments) {
            # Shell parsing already removed syntactic quotes. Literal quote
            # characters belong to the argument and must be preserved.
            $cleanArg = $arg

            if ($cleanArg -match '^-{1,2}([\w-]+)$') {
                # It's a switch parameter (e.g., -DryRun or --dry-run)
                $paramName = Resolve-CommandParameterName -Parameters $declared -Flag $Matches[1]
                if (-not $paramName) {
                    Write-MoleError "Unknown option for mo ${CommandName}: $cleanArg"
                    Write-Host "Run 'mo $CommandName --help' to see its options"
                    $script:MoleExitCode = 2
                    return
                }
                $splatParams[$paramName] = $true
            }
            elseif ($cleanArg -match '^-{1,2}([\w-]+)[=:](.+)$') {
                # It's a named parameter with value (e.g., --name=value)
                $paramName = Resolve-CommandParameterName -Parameters $declared -Flag $Matches[1]
                if (-not $paramName) {
                    Write-MoleError "Unknown option for mo ${CommandName}: $cleanArg"
                    Write-Host "Run 'mo $CommandName --help' to see its options"
                    $script:MoleExitCode = 2
                    return
                }
                $paramValue = $Matches[2]
                $splatParams[$paramName] = $paramValue
            }
            else {
                # Positional argument
                $positionalArgs += $cleanArg
            }
        }
    }

    # The operation log reads the run from the environment in the command's own scope.
    $env:_MOLE_OPLOG_RUN_COMMAND = $CommandName
    $env:_MOLE_OPLOG_RUN_ID = "{0}-{1}-{2}" -f (Get-Date -Format "yyyyMMddHHmmss"), $PID, (Get-Random -Maximum 100000)

    # The command script loads the log module afresh, so the session has to
    # exist before it starts for its own debug lines to reach the file.
    $debugSession = $splatParams.ContainsKey("DebugMode")
    if ($debugSession) {
        Start-MoleDebugSession -Header (Get-MoleDebugHeader -CommandLine ((@($CommandName) + @($Arguments)) -join " "))
    }
    try {
        if ($positionalArgs.Count -gt 0) {
            & $scriptPath @splatParams @positionalArgs
        }
        else {
            & $scriptPath @splatParams
        }
    }
    finally {
        if ($debugSession) { Complete-MoleDebugSession }
    }
    if ($CommandName -in @("analyze", "status", "history")) {
        $script:MoleExitCode = $LASTEXITCODE
    }
}

# ============================================================================
# Main
# ============================================================================

function Main {
    # Initialize
    Initialize-Mole

    # Native -File and the executable launcher bind switches differently.
    # Normalize both forms before routing, keeping command options on the child.
    $effectiveShowHelp = $ShowHelp
    $effectiveVersion = $Version
    $effectiveCommand = $Command
    $effectiveArguments = @()
    if ($null -ne $CommandArgs) { $effectiveArguments = @($CommandArgs) }
    if (-not $effectiveCommand -and $effectiveArguments.Count -gt 0) {
        $effectiveCommand = $effectiveArguments[0]
        if ($effectiveArguments.Count -gt 1) {
            $effectiveArguments = @($effectiveArguments[1..($effectiveArguments.Count - 1)])
        }
        else {
            $effectiveArguments = @()
        }
    }
    if ($effectiveCommand) {
        if ($effectiveShowHelp) {
            $effectiveArguments += "--help"
            $effectiveShowHelp = $false
        }
        if ($effectiveVersion) {
            $effectiveArguments += "--version"
            $effectiveVersion = $false
        }
    }

    if ($effectiveCommand -match '^-{1,2}(.+)$') {
        $switchName = $Matches[1].ToLower()
        switch ($switchName) {
            'showhelp' { $effectiveShowHelp = $true; $effectiveCommand = $null }
            'help' { $effectiveShowHelp = $true; $effectiveCommand = $null }
            'h' { $effectiveShowHelp = $true; $effectiveCommand = $null }
            'version' { $effectiveVersion = $true; $effectiveCommand = $null }
            'v' { $effectiveVersion = $true; $effectiveCommand = $null }
        }
    }

    # Handle version flag
    if ($effectiveVersion) {
        Show-Version
        return
    }

    # Handle help flag
    if ($effectiveShowHelp -and -not $effectiveCommand) {
        Show-MainHelp
        return
    }

    # If command specified, route to it
    if ($effectiveCommand) {
        $validCommands = @("clean", "uninstall", "analyze", "status", "optimize", "purge", "history", "update", "remove")

        if ($effectiveCommand -in $validCommands) {
            Invoke-MoleCommand -CommandName $effectiveCommand -Arguments $effectiveArguments
        }
        else {
            $script:MoleExitCode = 2
            Write-MoleError "Unknown command: $effectiveCommand"
            Write-Host ""
            Write-Host "Available commands: $($validCommands -join ', ')"
            Write-Host "Run 'mo --help' for more information"
        }
        return
    }

    # Interactive mode, as on macOS: pick once, run it, return to the shell.
    $choice = Show-MainMenu
    Clear-Host
    if ($null -eq $choice) {
        return
    }
    if ($choice -eq "help") {
        Show-MainHelp
    }
    elseif ($choice -eq "version") {
        Show-Version
    }
    else {
        Invoke-MoleCommand -CommandName $choice -Arguments @()
    }
}

# Run
$script:MoleExitCode = 0
try {
    Main
}
catch {
    Write-Host ""
    Write-MoleError "An error occurred: $_"
    Write-Host ""
    exit 1
}
if ($script:MoleExitCode -ne 0) {
    exit $script:MoleExitCode
}
