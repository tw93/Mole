# Mole - Optimize Command
# System optimization and health checks for Windows

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('dry-run')]
    [switch]$DryRun,
    
    [Alias('d')]
    [switch]$DebugMode,
    
    [Alias('h')]
    [switch]$ShowHelp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path (Split-Path -Parent $scriptDir) "lib"

# Import core modules
. "$libDir\core\base.ps1"
. "$libDir\core\log.ps1"
. "$libDir\core\ui.ps1"
. "$libDir\core\file_ops.ps1"

# ============================================================================
# Configuration
# ============================================================================

$script:OptimizationsApplied = 0
$script:IssuesFound = 0
$script:IssuesFixed = 0

# ============================================================================
# Help
# ============================================================================

function Show-OptimizeHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mmo optimize$esc[0m - System optimization and maintenance"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m mo optimize [options]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  --dry-run    Preview changes without applying"
    Write-Host "  --debug      Enable debug logging"
    Write-Host "  --help       Show this help message"
    Write-Host ""
    Write-Host "$esc[33mWhat it does:$esc[0m"
    Write-Host "  - Disk optimization (TRIM/Defrag)"
    Write-Host "  - DNS and ARP cache flush"
    Write-Host "  - Startup, disk health and Windows Update checks"
    Write-Host ""
    Write-Host "$esc[33mExamples:$esc[0m"
    Write-Host "  mo optimize            # Run all optimizations"
    Write-Host "  mo optimize --dry-run  # Preview what would happen"
    Write-Host ""
}

# ============================================================================
# System Health Information
# ============================================================================

function Get-SystemHealth {
    <#
    .SYNOPSIS
        Collect system health metrics
    #>

    $health = @{}

    # Memory info
    $os = Get-WmiObject Win32_OperatingSystem
    $health.MemoryTotalGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $health.MemoryUsedGB = [Math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
    $health.MemoryUsedPercent = [Math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 0)

    # Disk info
    $disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    $health.DiskTotalGB = [Math]::Round($disk.Size / 1GB, 0)
    $health.DiskUsedGB = [Math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 0)
    $health.DiskUsedPercent = [Math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 0)

    # Uptime
    $uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $health.UptimeDays = [Math]::Round($uptime.TotalDays, 1)

    # CPU info
    $cpu = Get-WmiObject Win32_Processor
    $health.CPUName = $cpu.Name
    $health.CPUCores = $cpu.NumberOfLogicalProcessors

    return $health
}

function Show-SystemHealth {
    param([hashtable]$Health)

    $esc = [char]27

    Write-Host "$esc[34m$($script:Icons.Admin)$esc[0m System  " -NoNewline
    Write-Host "$($Health.MemoryUsedGB)/$($Health.MemoryTotalGB)GB RAM | " -NoNewline
    Write-Host "$($Health.DiskUsedGB)/$($Health.DiskTotalGB)GB Disk | " -NoNewline
    Write-Host "Uptime $($Health.UptimeDays)d"
}

# ============================================================================
# Optimization Tasks
# ============================================================================

function Get-SystemDriveLetter {
    if (-not $env:SystemDrive) {
        throw "SystemDrive environment variable is not set."
    }

    $match = [regex]::Match($env:SystemDrive, '^[A-Za-z]')
    if (-not $match.Success) {
        throw "Could not determine the system drive letter from '$env:SystemDrive'."
    }

    return $match.Value.ToUpperInvariant()
}

function Test-SystemDriveOptimizable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveLetter
    )

    $getVolume = Get-Command Get-Volume -ErrorAction SilentlyContinue
    if (-not $getVolume) {
        return $true
    }

    $volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue | Select-Object -First 1
    return ($null -ne $volume)
}

function Optimize-DiskDrive {
    <#
    .SYNOPSIS
        Optimize the system drive using Windows defaults
    #>

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Disk Optimization$esc[0m"

    if (-not (Test-IsAdmin)) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Requires administrator privileges"
        return
    }

    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would optimize $env:SystemDrive"
        $script:OptimizationsApplied++
        return
    }

    if (-not (Get-Command Optimize-Volume -ErrorAction SilentlyContinue)) {
        Write-Host "  $esc[90mDisk optimization skipped: Optimize-Volume is not available on this system$esc[0m"
        return
    }

    try {
        $systemDriveLetter = Get-SystemDriveLetter
        if (-not (Test-SystemDriveOptimizable -DriveLetter $systemDriveLetter)) {
            Write-Host "  $esc[90mDisk optimization skipped: Windows could not resolve drive ${systemDriveLetter} to an optimizable volume$esc[0m"
            return
        }

        Write-Host "  Running Windows default optimization on drive ${systemDriveLetter}:..."
        Start-Spinner "Optimizing drive..."
        try { $null = Optimize-Volume -DriveLetter $systemDriveLetter -ErrorAction Stop } finally { Stop-Spinner }
        Write-MoleOperation -Action "OPTIMIZED" -Path "${systemDriveLetter}:" -Detail "Optimize-Volume"
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Drive optimization completed"
        $script:OptimizationsApplied++
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'MSFT_Volume' -or $message -match 'DriveLetter') {
            Write-Host "  $esc[90mDisk optimization skipped: Windows could not resolve drive ${systemDriveLetter} to an optimizable volume$esc[0m"
            return
        }

        # $systemDriveLetter is unset when resolving it was what failed.
        $volumeLabel = if ($env:SystemDrive) { $env:SystemDrive } else { "system drive" }
        Write-MoleOperation -Action "FAILED" -Path $volumeLabel -Detail "Optimize-Volume: $message"
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Disk optimization failed: $message"
    }
}

function Clear-DnsCache {
    <#
    .SYNOPSIS
        Clear DNS resolver cache
    #>

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) DNS Cache$esc[0m"

    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would flush DNS cache"
        $script:OptimizationsApplied++
        return
    }

    try {
        Clear-DnsClientCache -ErrorAction Stop
        Write-MoleOperation -Action "OPTIMIZED" -Path "DNS client cache" -Detail "Clear-DnsClientCache"
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m DNS cache flushed"
        $script:OptimizationsApplied++
    }
    catch {
        Write-MoleOperation -Action "FAILED" -Path "DNS client cache" -Detail "Clear-DnsClientCache: $($_.Exception.Message)"
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Could not flush DNS cache: $_"
    }
}

function Optimize-Network {
    <#
    .SYNOPSIS
        Network stack optimization
    #>

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Network Optimization$esc[0m"

    if (-not (Test-IsAdmin)) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Requires administrator privileges"
        return
    }

    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would clear ARP cache"
        $script:OptimizationsApplied++
        return
    }

    try {
        # Flush ARP cache
        $null = netsh interface ip delete arpcache 2>&1
        if ($LASTEXITCODE -ne 0) { throw "netsh exited with code $LASTEXITCODE" }
        Write-MoleOperation -Action "OPTIMIZED" -Path "ARP cache" -Detail "netsh interface ip delete arpcache"
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m ARP cache cleared"
        $script:OptimizationsApplied++
    }
    catch {
        Write-MoleOperation -Action "FAILED" -Path "ARP cache" -Detail "netsh interface ip delete arpcache: $($_.Exception.Message)"
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m ARP cache clear failed"
    }
}

function Get-StartupPrograms {
    <#
    .SYNOPSIS
        Analyze startup programs
    #>

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Startup Programs$esc[0m"

    $startupPaths = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    )

    $startupCount = 0

    foreach ($path in $startupPaths) {
        if (Test-Path $path) {
            $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
            $props = @($items.PSObject.Properties | Where-Object {
                $_.Name -notin @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
            })
            $startupCount += $props.Count
        }
    }

    # Also check startup folder
    $startupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    if (Test-Path $startupFolder) {
        $startupFiles = @(Get-ChildItem -Path $startupFolder -File -ErrorAction SilentlyContinue)
        $startupCount += $startupFiles.Count
    }

    if ($startupCount -gt 10) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m $startupCount startup programs (high)"
        Write-Host "  $esc[90mConsider disabling unnecessary startup items in Task Manager$esc[0m"
        $script:IssuesFound++
    }
    elseif ($startupCount -gt 5) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m $startupCount startup programs (moderate)"
        $script:IssuesFound++
    }
    else {
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m $startupCount startup programs"
    }
}

function Test-SystemFiles {
    <#
    .SYNOPSIS
        Run System File Checker (SFC)
    #>

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) System File Verification$esc[0m"

    if (-not (Test-IsAdmin)) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Requires administrator privileges"
        return
    }

    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would run System File Checker"
        return
    }

    Write-Host "  Running System File Checker (this may take several minutes)..."

    try {
        $sfcResult = Start-Process -FilePath "sfc.exe" -ArgumentList "/scannow" `
            -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\sfc_output.txt" -ErrorAction Stop

        $output = Read-SfcOutput "$env:TEMP\sfc_output.txt"
        Remove-Item "$env:TEMP\sfc_output.txt" -Force -ErrorAction SilentlyContinue

        $sfcExit = if ($sfcResult -and $sfcResult.PSObject.Properties['ExitCode']) { $sfcResult.ExitCode } else { "unknown" }
        $verdict = if ($output -match "did not find any integrity violations") { "no integrity violations" }
        elseif ($output -match "found corrupt files and successfully repaired") { "repaired corrupt files" }
        elseif ($output -match "found corrupt files but was unable to fix") { "found corrupt files it could not repair" }
        else { "result not read, see CBS.log" }
        Write-MoleOperation -Action "OPTIMIZED" -Path "System files" -Detail "sfc /scannow exit code ${sfcExit}: $verdict"

        if ($output -match "did not find any integrity violations") {
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m No integrity violations found"
        }
        elseif ($output -match "found corrupt files and successfully repaired") {
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Corrupt files were repaired"
            $script:IssuesFixed++
        }
        elseif ($output -match "found corrupt files but was unable to fix") {
            Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Found corrupt files that could not be repaired"
            Write-Host "  $esc[90mRun 'DISM /Online /Cleanup-Image /RestoreHealth' then retry SFC$esc[0m"
            $script:IssuesFound++
        }
        else {
            # A localized Windows prints its own words; an unread result is never shown as clean.
            Write-Host "  $esc[90m$($script:Icons.Empty)$esc[0m Scan finished; details are in $env:WINDIR\Logs\CBS\CBS.log"
        }
    }
    catch {
        Write-MoleOperation -Action "FAILED" -Path "System files" -Detail "sfc /scannow: $($_.Exception.Message)"
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m System File Checker failed: $_"
    }
}

function Read-SfcOutput {
    <#
    .SYNOPSIS
        Read redirected sfc.exe output, which is UTF-16 without a byte order mark.
        Read as ANSI every other byte is NUL and no English phrase ever matched.
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return [System.Text.Encoding]::Unicode.GetString($bytes)
}

function Test-SystemImage {
    <#
    .SYNOPSIS
        Read Windows' own verdict on the system image (DISM CheckHealth, under a second).
        A repair downloads from Windows Update and can take half an hour, so it is suggested, never run.
    #>

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) System Image$esc[0m"

    if (-not (Test-IsAdmin)) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Requires administrator privileges"
        return
    }

    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would check the system image"
        return
    }

    try {
        $state = [string](Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop).ImageHealthState
    }
    catch {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Could not check the system image"
        return
    }

    switch ($state) {
        "Healthy" {
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m System image is healthy"
        }
        "Repairable" {
            Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m System image can be repaired"
            Write-Host "  $esc[90mRun 'DISM /Online /Cleanup-Image /RestoreHealth' as administrator; it downloads from Windows Update and can take up to 30 minutes$esc[0m"
            $script:IssuesFound++
        }
        "NonRepairable" {
            Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m System image cannot be repaired by Windows"
            $script:IssuesFound++
        }
        default {
            Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Could not check the system image"
        }
    }
}

function Test-DiskHealth {
    <#
    .SYNOPSIS
        Check disk health status
    #>

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Disk Health$esc[0m"

    try {
        Start-Spinner "Checking disk health..."
        try { $disks = Get-PhysicalDisk -ErrorAction Stop } finally { Stop-Spinner }

        foreach ($disk in $disks) {
            $status = $disk.HealthStatus
            $name = $disk.FriendlyName

            if ($status -eq "Healthy") {
                Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m $name - Healthy"
            }
            elseif ($status -eq "Warning") {
                Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m $name - Warning"
                Write-Host "  $esc[90mDisk may have issues, consider backing up data$esc[0m"
                $script:IssuesFound++
            }
            else {
                Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m $name - $status"
                Write-Host "  $esc[31mDisk has critical issues, back up data immediately!$esc[0m"
                $script:IssuesFound++
            }
        }
    }
    catch {
        Write-Host "  $esc[90mCould not check disk health$esc[0m"
    }
}

function Test-WindowsUpdate {
    <#
    .SYNOPSIS
        Check Windows Update status
    #>

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Windows Update$esc[0m"

    try {
        $updateSession = New-Object -ComObject Microsoft.Update.Session
        $updateSearcher = $updateSession.CreateUpdateSearcher()

        Start-Spinner "Checking for updates..."
        try { $searchResult = $updateSearcher.Search("IsInstalled=0") } finally { Stop-Spinner }

        $importantUpdates = $searchResult.Updates | Where-Object {
            $_.MsrcSeverity -in @('Critical', 'Important')
        }

        if ($importantUpdates.Count -gt 0) {
            Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m $($importantUpdates.Count) important updates available"
            Write-Host "  $esc[90mRun Windows Update to install$esc[0m"
            $script:IssuesFound++
        }
        elseif ($searchResult.Updates.Count -gt 0) {
            Write-Host "  $esc[90m$($script:Icons.List)$esc[0m $($searchResult.Updates.Count) optional updates available"
        }
        else {
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m System is up to date"
        }
    }
    catch {
        Write-Host "  $esc[90mCould not check Windows Update status$esc[0m"
    }
}

# ============================================================================
# Summary
# ============================================================================

function Show-OptimizeSummary {
    $heading = if ($script:DryRun) { 'Dry run complete - no changes made' } else { 'Optimization complete' }
    $details = @()
    if ($script:DryRun) {
        $noun = if ($script:OptimizationsApplied -eq 1) { 'optimization' } else { 'optimizations' }
        $details += "Would apply $($script:OptimizationsApplied) $noun"
    }
    else {
        $details += "Optimizations applied: $($script:OptimizationsApplied)"
        if ($script:IssuesFixed -gt 0) { $details += "Issues fixed: $($script:IssuesFixed)" }
        if ($script:IssuesFound -gt 0) { $details += "Issues found: $($script:IssuesFound)" }
    }
    Show-SummaryBlock -Heading $heading -Details $details
}

# ============================================================================
# Main Entry Point
# ============================================================================

function Main {
    # Enable debug if requested
    if ($DebugMode) {
        Enable-DebugMode
        $DebugPreference = "Continue"
    }

    # Show help
    if ($ShowHelp) {
        Show-OptimizeHelp
        return
    }

    # Set dry-run mode
    $script:DryRun = $DryRun -or ($env:MOLE_DRY_RUN -eq '1')

    # Clear screen
    Clear-Host

    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mOptimize and Maintain$esc[0m"
    Write-Host ""

    if ($script:DryRun) {
        Write-Host "$esc[33m$($script:Icons.DryRun) DRY RUN MODE$esc[0m - No changes will be made"
        Write-Host ""
    }

    # Show system health
    Start-Spinner "Checking system health..."
    try { $health = Get-SystemHealth } finally { Stop-Spinner }
    Show-SystemHealth -Health $health

    # Run optimizations
    Optimize-DiskDrive
    Clear-DnsCache
    Optimize-Network

    # Run health checks
    Get-StartupPrograms
    Test-DiskHealth
    Test-WindowsUpdate
    Test-SystemImage

    # System file check is slow, ask first
    if (-not $script:DryRun -and (Test-IsAdmin)) {
        Write-Host ""
        $runSfc = Read-Host "Run System File Checker? This may take several minutes (y/N)"
        if ($runSfc -eq 'y' -or $runSfc -eq 'Y') {
            Test-SystemFiles
        }
    }

    # Summary
    Show-OptimizeSummary
}

# Run main
try { Main } finally { Stop-Spinner }
