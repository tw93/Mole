# Mole - User Cleanup Module
# Cleans user-level temporary files and caches

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_CLEAN_USER_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_CLEAN_USER_LOADED) { return }
$script:MOLE_CLEAN_USER_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\..\core\base.ps1"
. "$scriptDir\..\core\log.ps1"
. "$scriptDir\..\core\file_ops.ps1"

# ============================================================================
# Windows Temp Files Cleanup
# ============================================================================

function Clear-UserTempFiles {
    <#
    .SYNOPSIS
        Clean user temporary files
    #>
    param([int]$DaysOld = 7)
    
    # User temp directory
    $userTemp = $env:TEMP
    if (Test-Path $userTemp) {
        Remove-OldFiles -Path $userTemp -DaysOld $DaysOld -Description "User temp files"
    }
    
}

# ============================================================================
# Windows Error Reports Cleanup
# ============================================================================

# A report is retained as a whole when any descendant is recent or unreadable.
# The same bounded check runs after sizing and at the removal boundary.
function Test-MoleOldErrorReport {
    param([string]$Path, [datetime]$Cutoff, [int]$MaxEntries = 4096, [double]$Seconds = 2)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Path)
    $seen = 0
    try {
        while ($pending.Count -gt 0) {
            if (++$seen -gt $MaxEntries -or $timer.Elapsed.TotalSeconds -gt $Seconds) { return $false }
            $item = Get-Item -LiteralPath $pending.Pop() -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                $item.LastWriteTime -ge $Cutoff -or $item.CreationTime -ge $Cutoff) { return $false }
            if ($item.PSIsContainer) {
                foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($item.FullName)) {
                    if ($pending.Count + $seen -ge $MaxEntries -or $timer.Elapsed.TotalSeconds -gt $Seconds) { return $false }
                    $pending.Push($child)
                }
            }
        }
        return $true
    }
    catch { return $false }
}

function Clear-ErrorReports {
    param([int]$DaysOld = 7)
    $cutoff = (Get-Date).AddDays(-$DaysOld)
    # Keep the WER collection roots; each report has its own age and guard.
    foreach ($root in @(
        "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive",
        "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue",
        "$env:LOCALAPPDATA\CrashDumps"
    )) {
        $snapshot = Get-MolePathSnapshot -Path $root
        if (-not $snapshot) { continue }
        $reports = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'
        $scan = [Diagnostics.Stopwatch]::StartNew()
        $complete = $true
        try {
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($root)) {
                if ($reports.Count -ge 4096 -or $scan.Elapsed.TotalSeconds -gt 2) { $complete = $false; break }
                $reports.Add((Get-Item -LiteralPath $entry -Force -ErrorAction Stop))
            }
        }
        catch { $complete = $false }
        if (-not $complete -or $scan.Elapsed.TotalSeconds -gt 2) { continue }
        if (-not (Test-MolePathSnapshot $snapshot)) { continue }
        foreach ($report in $reports) {
            if ($root -eq "$env:LOCALAPPDATA\CrashDumps" -and
                ($report.PSIsContainer -or $report.Extension -ine '.dmp')) { continue }
            $reportPath = $report.FullName
            if (-not (Test-MoleOldErrorReport -Path $reportPath -Cutoff $cutoff)) { continue }
            $guard = { (Test-MolePathSnapshot $snapshot) -and (Test-MoleOldErrorReport -Path $reportPath -Cutoff $cutoff) }
            Remove-SafeItems -Paths @($reportPath) -Description 'Error reports' -CanRemove $guard
        }
    }
}

# ============================================================================
# Log Files Cleanup
# ============================================================================

function Clear-UserLogs {
    <#
    .SYNOPSIS
        Clean old log files from common locations
    #>
    param([int]$DaysOld = 7)
    
    $logLocations = @(
        "$env:LOCALAPPDATA\Temp\*.log"
        "$env:APPDATA\*.log"
    )
    
    foreach ($location in $logLocations) {
        $parent = Split-Path -Parent $location
        $filter = Split-Path -Leaf $location
        
        if (Test-Path $parent) {
            $logs = Get-ChildItem -Path $parent -Filter $filter -File -ErrorAction SilentlyContinue |
                    Where-Object { (Test-MoleOlderThan $_ (Get-Date).AddDays(-$DaysOld)) }
            
            if ($logs) {
                $paths = $logs | ForEach-Object { $_.FullName }
                Remove-SafeItems -Paths $paths -Description "Old log files"
            }
        }
    }
}

# ============================================================================
# Main User Cleanup Function
# ============================================================================

function Invoke-UserCleanup {
    <#
    .SYNOPSIS
        Run all user-level cleanup tasks
    #>
    param(
        [int]$TempDaysOld = 7,
        [int]$LogDaysOld = 7
    )
    
    Start-Section "User essentials"
    
    # Always clean these
    Clear-UserTempFiles -DaysOld $TempDaysOld
    Clear-ErrorReports -DaysOld 7
    Clear-UserLogs -DaysOld $LogDaysOld
    
    Stop-Section
}

# ============================================================================
# Exports
# ============================================================================
# Functions: Clear-UserTempFiles, etc.
