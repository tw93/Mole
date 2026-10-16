# Mole - Logging Module
# Provides consistent logging functions with colors and icons

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_LOG_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_LOG_LOADED) { return }
$script:MOLE_LOG_LOADED = $true

# Import base module
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\base.ps1"
Initialize-MoleVisualDefaults

# ============================================================================
# Log Configuration
# ============================================================================

# --debug keeps one session log a reporter can send. It sits with the CLI's
# own config; %LOCALAPPDATA%\Mole belongs to the Mole for Windows app.
$script:MoleDebugLogFile = "$env:USERPROFILE\.config\mole\mole_debug_session.log"

# Each command script loads this module afresh after the router has set
# MOLE_DEBUG, so the switch has to be read here, at load time.
$script:LogConfig = @{
    DebugEnabled = $env:MOLE_DEBUG -eq "1"
    LogFile      = $(if ($env:MOLE_DEBUG -eq "1") { $script:MoleDebugLogFile } else { $null })
    Verbose      = $false
}

# What clean, purge, optimize and uninstall actually removed, one line per
# item in the macOS CLI's operations.log format, so a report can carry it.
# Dry runs write nothing; MO_NO_OPLOG=1 turns it off, as on macOS.
$script:MoleOperationsLogFile = "$env:USERPROFILE\.config\mole\operations.log"
$script:MoleOperationsLogMaxBytes = 5MB
$script:MoleOperationsLogStarted = $false

function ConvertTo-MoleLogValue {
    param([string]$Value)

    # Control characters become escapes so a file name cannot forge a record.
    # Backslashes stay literal: Windows paths are full of them.
    return [regex]::Replace([string]$Value, '[\x00-\x1f\x7f]', {
            param($match)
            switch ([int][char]$match.Value) {
                9 { '\t' }
                10 { '\n' }
                13 { '\r' }
                default { '\x{0:x2}' -f [int][char]$match.Value }
            }
        })
}

function Write-MoleOperation {
    param(
        [string]$Action,
        [string]$Path,
        [string]$Detail = ""
    )

    if ($env:MO_NO_OPLOG -eq "1" -or [string]::IsNullOrEmpty($Path)) { return }

    try {
        $command = if ($env:_MOLE_OPLOG_RUN_COMMAND) { $env:_MOLE_OPLOG_RUN_COMMAND } else { "mole" }
        $label = if ($env:_MOLE_OPLOG_RUN_ID) { "$command run=$($env:_MOLE_OPLOG_RUN_ID)" } else { $command }
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        # Every record ends in one parenthesis-free "(detail)", so a reader can split
        # it from a path that holds parentheses, such as "Program Files (x86)".
        $safeDetail = if ($Detail) { (ConvertTo-MoleLogValue $Detail).Replace("(", "[").Replace(")", "]") } else { "-" }
        $line = "[$timestamp] [$label] $Action $(ConvertTo-MoleLogValue $Path) ($safeDetail)"
        $file = $script:MoleOperationsLogFile
        $text = "$line`r`n"
        if (-not $script:MoleOperationsLogStarted) {
            $dir = Split-Path -Parent $file
            if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
            $info = New-Object System.IO.FileInfo $file
            if ($info.Exists -and $info.Length -gt $script:MoleOperationsLogMaxBytes) {
                Move-Item -LiteralPath $file -Destination "$file.old" -Force
            }
            # The marker is written with the first record, so a run that removes
            # nothing leaves the log untouched.
            $text = "`r`n# ========== $label session started at $timestamp ==========`r`n$text"
        }
        Add-MoleOperationText -File $file -Text $text
        $script:MoleOperationsLogStarted = $true
    }
    catch {
        # The record must never fail the removal it describes, but --debug says it was lost.
        Write-Debug "operations.log not written: $($_.Exception.Message)"
    }
}

# Another Mole run (or mo analyze) may hold the file for the moment it appends,
# so a sharing violation is retried briefly instead of dropping the line.
function Add-MoleOperationText {
    param([string]$File, [string]$Text)

    $encoding = New-Object System.Text.UTF8Encoding $false
    $attempts = 5
    for ($attempt = 1; ; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($File, $Text, $encoding)
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -ge $attempts) { throw }
            Start-Sleep -Milliseconds (20 * $attempt)
        }
    }
}

function Add-MoleLogLine {
    param([string]$Line)

    $path = $script:LogConfig.LogFile
    if (-not $path) { return }
    try {
        [System.IO.File]::AppendAllText($path, "$Line`r`n", (New-Object System.Text.UTF8Encoding $false))
    }
    catch { } # A log that cannot be written must not stop maintenance.
}

# ============================================================================
# Core Logging Functions
# ============================================================================

function Write-LogMessage {
    <#
    .SYNOPSIS
        Internal function to write formatted log message
    #>
    param(
        [string]$Message,
        [string]$Level,
        [string]$Color,
        [string]$Icon
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $colorCode = Get-MoleColor -Name $Color
    $nc = Get-MoleColor -Name "NC"

    $formattedIcon = if ($Icon) { "$Icon " } else { "" }
    $output = "  ${colorCode}${formattedIcon}${nc}${Message}"

    Stop-Spinner
    Write-Host $output
    if ($script:CurrentSection.Active) { Start-Spinner }

    Add-MoleLogLine "$timestamp [$Level] $Message"
}

function Write-Info {
    <#
    .SYNOPSIS
        Write an informational message
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "INFO" -Color "Cyan" -Icon (Get-MoleIcon -Name "List")
}

function Write-Success {
    <#
    .SYNOPSIS
        Write a success message
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "SUCCESS" -Color "Green" -Icon (Get-MoleIcon -Name "Success")
}


function Write-MoleWarning {
    <#
    .SYNOPSIS
        Write a warning message
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "WARN" -Color "Yellow" -Icon (Get-MoleIcon -Name "Warning")
}

function Write-MoleError {
    <#
    .SYNOPSIS
        Write an error message
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "ERROR" -Color "Red" -Icon (Get-MoleIcon -Name "Error")
}


function Write-Debug {
    <#
    .SYNOPSIS
        Write a debug message (only if debug mode is enabled)
    #>
    param([string]$Message)

    if ($script:LogConfig.DebugEnabled) {
        $gray = Get-MoleColor -Name "Gray"
        $nc = Get-MoleColor -Name "NC"
        Stop-Spinner
        Write-Host "  ${gray}[DEBUG] $Message${nc}"
        if ($script:CurrentSection.Active) { Start-Spinner }
        Add-MoleLogLine "$(Get-Date -Format 'HH:mm:ss') [DEBUG] $Message"
    }
}

function Write-DryRun {
    <#
    .SYNOPSIS
        Write a dry-run message (action that would be taken)
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "DRYRUN" -Color "Yellow" -Icon (Get-MoleIcon -Name "DryRun")
}

# ============================================================================
# Section Functions (for progress indication)
# ============================================================================

$script:CurrentSection = @{
    Active   = $false
    Activity = $false
    Name     = ""
}

function Start-Section {
    <#
    .SYNOPSIS
        Start a new section with a title
    #>
    param([string]$Title)

    Stop-Spinner
    $script:CurrentSection.Active = $true
    $script:CurrentSection.Activity = $false
    $script:CurrentSection.Name = $Title

    $purple = Get-MoleColor -Name "PurpleBold"
    $nc = Get-MoleColor -Name "NC"
    $arrow = Get-MoleIcon -Name "Arrow"

    Write-Host ""
    Write-Host "${purple}${arrow} ${Title}${nc}"
    Start-Spinner
}

function Stop-Section {
    <#
    .SYNOPSIS
        End the current section
    #>
    Stop-Spinner
    if ($script:CurrentSection.Active -and -not $script:CurrentSection.Activity) {
        Write-Success "Nothing to tidy"
    }
    $script:CurrentSection.Active = $false
    Stop-Spinner
}

function Set-SectionActivity {
    <#
    .SYNOPSIS
        Mark that activity occurred in current section
    #>
    if ($script:CurrentSection.Active) {
        $script:CurrentSection.Activity = $true
    }
}

# ============================================================================
# Progress Spinner
# ============================================================================

function Test-MoleInteractiveOutput {
    try {
        return $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected -and
            -not [Console]::IsInputRedirected -and $env:TERM -ne 'dumb'
    }
    catch { return $false }
}

function Initialize-MoleSpinner {
    if ('Mole.TerminalSpinner' -as [type]) { return }
    # A CLR timer continues while PowerShell waits on synchronous filesystem work.
    # It never calls PowerShell from a background thread. Stop drains its callback
    # before the foreground writes a row or returns control to the caller.
    Add-Type -TypeDefinition @'
using System;
using System.Threading;
namespace Mole {
    public static class TerminalSpinner {
        static readonly object Gate = new object();
        static readonly char[] Frames = { '\u2816', '\u2832', '\u2834', '\u2826' };
        static Timer timer;
        static string text;
        static int frame;
        static bool drawn;
        public static void Start(string message) {
            lock (Gate) {
                text = message;
                if (timer != null) return;
                frame = 0;
                timer = new Timer(Draw, null, 80, 80);
            }
        }
        static void Draw(object state) {
            lock (Gate) {
                if (timer == null) return;
                try {
                    int columns = 80;
                    try { columns = Console.WindowWidth; } catch (System.IO.IOException) { }
                    int width = Math.Max(1, columns - 5);
                    string label = text.Length > width ? text.Substring(0, width) : text;
                    Console.Write("\r\x1b[2K  \x1b[34m" + Frames[frame++ % Frames.Length] + "\x1b[0m " + label);
                    drawn = true;
                } catch { /* Losing a terminal must not interrupt maintenance. */ }
            }
        }
        public static void Stop() {
            lock (Gate) {
                if (timer != null) { timer.Dispose(); timer = null; }
                if (drawn) {
                    try { Console.Write("\r\x1b[2K"); } catch { }
                    drawn = false;
                }
            }
        }
    }
}
'@
}

function Start-Spinner {
    param([string]$Message = "Scanning...")
    if (-not (Test-MoleInteractiveOutput)) { return }
    try {
        Initialize-MoleSpinner
        # Messages are terminal text, never control sequences supplied by paths.
        $safeMessage = $Message -replace '[\x00-\x1f\x7f]', ' '
        [Mole.TerminalSpinner]::Start($safeMessage)
    }
    catch { } # A host without dynamic compilation keeps the normal static output.
}

function Update-Spinner {
    param([string]$Message = "Scanning...")
    Start-Spinner -Message $Message
}

function Stop-Spinner {
    if ('Mole.TerminalSpinner' -as [type]) { [Mole.TerminalSpinner]::Stop() }
}

function Write-Progress {
    # Match the built-in parameter names used by the application/project scanners.
    param(
        [string]$Activity = "Scanning...",
        [string]$Status = "",
        [int]$PercentComplete = -1,
        [switch]$Completed,
        [int]$Current = 0,
        [int]$Total = 0,
        [string]$Message = "",
        [int]$Width = 30
    )
    if ($Completed) { Stop-Spinner; return }
    $label = if ($Message) { $Message } elseif ($Status) { "$Activity, $Status" } else { $Activity }
    Update-Spinner -Message $label
}

# ============================================================================
# Log File Management
# ============================================================================

function Enable-DebugMode {
    <#
    .SYNOPSIS
        Enable debug logging
    #>
    $env:MOLE_DEBUG = "1"
    $script:LogConfig.DebugEnabled = $true
    if (-not $script:LogConfig.LogFile) { $script:LogConfig.LogFile = $script:MoleDebugLogFile }
}

function Start-MoleDebugSession {
    <#
    .SYNOPSIS
        Start a fresh --debug session log with the given header lines
    #>
    param([string[]]$Header)

    Enable-DebugMode
    $path = $script:MoleDebugLogFile
    $gray = Get-MoleColor -Name "Gray"
    $nc = Get-MoleColor -Name "NC"
    try {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $rule = "-" * 70
        $text = (@($rule) + @($Header) + @($rule)) -join "`r`n"
        [System.IO.File]::WriteAllText($path, "$text`r`n", (New-Object System.Text.UTF8Encoding $false))
        Write-Host "${gray}[DEBUG] Debug logging enabled. Session log: $path${nc}"
    }
    catch {
        $script:LogConfig.LogFile = $null
        Write-MoleWarning "Debug log not writable: $path"
    }
}

function Complete-MoleDebugSession {
    <#
    .SYNOPSIS
        Tell the user where the --debug session log was saved
    #>
    if (-not $script:LogConfig.LogFile) { return }
    $gray = Get-MoleColor -Name "Gray"
    $nc = Get-MoleColor -Name "NC"
    Write-Host ""
    Write-Host "${gray}Debug session log saved to:${nc} $($script:LogConfig.LogFile)"
}

# ============================================================================
# Exports (functions are available via dot-sourcing)
# ============================================================================
# Functions: Write-Info, Write-Success, Write-Warning, Write-Error, etc.
