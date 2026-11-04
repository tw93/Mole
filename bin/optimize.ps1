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
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $health.MemoryTotalGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $health.MemoryUsedGB = [Math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
    $health.MemoryUsedPercent = [Math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 0)

    # Disk info
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    $health.DiskTotalGB = [Math]::Round($disk.Size / 1GB, 0)
    $health.DiskUsedGB = [Math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 0)
    $health.DiskUsedPercent = [Math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 0)

    # Uptime
    $uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $health.UptimeDays = [Math]::Round($uptime.TotalDays, 1)

    # CPU info
    $cpu = Get-CimInstance -ClassName Win32_Processor
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

function Test-MoleDiskPowerReady {
    # Use the same CIM provider already used for system health. A complete empty
    # Win32_Battery result identifies a desktop; unknown is never AC evidence.
    try {
        $batteries = @(Get-CimInstance -ClassName Win32_Battery -OperationTimeoutSec 3 -ErrorAction Stop)
        if ($batteries.Count -eq 0) { return $true }
        $power = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -OperationTimeoutSec 3 -ErrorAction Stop |
            Where-Object { $_.Active -eq $true })
        if ($power.Count -lt $batteries.Count) { return $false }
        foreach ($sample in $power) {
            if ($sample.PowerOnline -ne $true -or $sample.Discharging -ne $false) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Get-MoleExtraTrimVolumes {
    # Other fixed NTFS/ReFS drives Windows reports as Healthy, only on a disk
    # Windows reports as a Healthy SSD. A hard disk is never defragmented here, and unknown media or health
    # keeps the drive untouched. A failed disk or volume inventory adds nothing.
    # A property a provider leaves out reads as unknown and skips only that drive.
    param([string]$SystemDriveLetter)
    $read = { param($Object, $Name) $p = $Object.PSObject.Properties[$Name]; if ($p) { [string]$p.Value } else { '' } }
    try {
        $physical = @(Get-PhysicalDisk -ErrorAction Stop)
        $letters = New-Object 'System.Collections.Generic.List[string]'
        foreach ($volume in @(Get-Volume -ErrorAction Stop)) {
            $letter = & $read $volume 'DriveLetter'
            if ($letter -notmatch '^[A-Za-z]$' -or $letter -eq $SystemDriveLetter) { continue }
            if ((& $read $volume 'DriveType') -ne 'Fixed' -or (& $read $volume 'FileSystemType') -notin @('NTFS', 'ReFS')) { continue }
            if ((& $read $volume 'HealthStatus') -ne 'Healthy') { continue }
            # A volume whose partition or disk cannot be read is skipped on its own.
            try {
                $partitions = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)
                if ($partitions.Count -ne 1) { continue }
                $diskNumber = & $read $partitions[0] 'DiskNumber'
                if ($diskNumber -notmatch '^\d+$') { continue }
                $disks = @(Get-Disk -Number ([uint32]$diskNumber) -ErrorAction Stop)
            }
            catch { continue }
            if ($disks.Count -ne 1 -or (& $read $disks[0] 'HealthStatus') -ne 'Healthy') { continue }
            $match = @($physical | Where-Object { (& $read $_ 'DeviceId') -eq $diskNumber })
            if ($match.Count -ne 1 -or (& $read $match[0] 'MediaType') -ne 'SSD' -or (& $read $match[0] 'HealthStatus') -ne 'Healthy') { continue }
            $letters.Add($letter.ToUpperInvariant())
        }
        return $letters.ToArray()
    }
    catch { return @() }
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

    if (-not (Test-MoleDiskPowerReady)) {
        Write-Host "  $esc[90mDisk optimization skipped: external power could not be confirmed$esc[0m"
        return
    }

    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would optimize $env:SystemDrive"
        $script:OptimizationsApplied++
        foreach ($letter in @(Get-MoleExtraTrimVolumes -SystemDriveLetter (Get-SystemDriveLetter))) {
            Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would retrim ${letter}:"
        }
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
        Invoke-MoleExtraRetrim -SystemDriveLetter $systemDriveLetter
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

function Invoke-MoleExtraRetrim {
    param([string]$SystemDriveLetter)
    $esc = [char]27
    foreach ($letter in @(Get-MoleExtraTrimVolumes -SystemDriveLetter $SystemDriveLetter)) {
        try {
            Start-Spinner "Retrimming drive ${letter}:..."
            try { $null = Optimize-Volume -DriveLetter $letter -ReTrim -ErrorAction Stop } finally { Stop-Spinner }
            Write-MoleOperation -Action "OPTIMIZED" -Path "${letter}:" -Detail "Optimize-Volume -ReTrim"
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Retrimmed drive ${letter}:"
        }
        catch {
            Write-MoleOperation -Action "FAILED" -Path "${letter}:" -Detail "Optimize-Volume -ReTrim: $($_.Exception.Message)"
            Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Retrim of drive ${letter}: failed: $($_.Exception.Message)"
        }
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

    # Registered entries may be disabled in StartupApproved. Count them without
    # inferring a health issue or recommending changes from quantity alone.
    $noun = if ($startupCount -eq 1) { 'program' } else { 'programs' }
    Write-Host "  $esc[90m$startupCount startup $noun$esc[0m"
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

    $outputPath = $null
    try {
        # Atomically reserve our own scratch file, never a shared fixed filename.
        $outputPath = [System.IO.Path]::GetTempFileName()
        $cbsStartLength = Get-CbsLogLength
        $sfcResult = Start-Process -FilePath "sfc.exe" -ArgumentList "/scannow" `
            -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outputPath -ErrorAction Stop

        $output = Read-SfcOutput $outputPath

        $sfcExit = if ($sfcResult -and $sfcResult.PSObject.Properties['ExitCode']) { $sfcResult.ExitCode } else { "unknown" }
        $verdict = if ($output -match "did not find any integrity violations") { "no integrity violations" }
        elseif ($output -match "found corrupt files and successfully repaired") { "repaired corrupt files" }
        elseif ($output -match "found corrupt files but was unable to fix") { "found corrupt files it could not repair" }
        else { $null }
        # A localized Windows prints its own words (#1915); CBS.log is never localized.
        if (-not $verdict -and $sfcExit -eq 0) { $verdict = Read-SfcCbsVerdict -StartLength $cbsStartLength }
        if (-not $verdict) { $verdict = "result not read, see CBS.log" }
        $completed = $sfcExit -eq 0 -and $verdict -in @("no integrity violations", "repaired corrupt files")
        $action = if ($completed) { "OPTIMIZED" } else { "FAILED" }
        Write-MoleOperation -Action $action -Path "System files" -Detail "sfc /scannow exit code ${sfcExit}: $verdict"
        if ($sfcExit -ne 0) {
            Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m System File Checker did not complete (exit code $sfcExit)"
            return
        }

        switch ($verdict) {
            "no integrity violations" {
                Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m No integrity violations found"
            }
            "repaired corrupt files" {
                Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Corrupt files were repaired"
                $script:IssuesFixed++
            }
            "found corrupt files it could not repair" {
                Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Found corrupt files that could not be repaired"
                Write-Host "  $esc[90mRun 'DISM /Online /Cleanup-Image /RestoreHealth' then retry SFC$esc[0m"
                $script:IssuesFound++
            }
            default {
                # An unread result is never shown as clean.
                Write-Host "  $esc[90m$($script:Icons.Empty)$esc[0m Scan finished; details are in $env:WINDIR\Logs\CBS\CBS.log"
            }
        }
    }
    catch {
        Write-MoleOperation -Action "FAILED" -Path "System files" -Detail "sfc /scannow: $($_.Exception.Message)"
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m System File Checker failed: $_"
    }
    finally {
        if ($outputPath) { Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue }
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

function Get-CbsLogLength {
    <#
    .SYNOPSIS
        Length of CBS.log before a scan, so the scan's own [SR] lines can be read afterwards; $null when unreadable.
    #>
    param([string]$Path = (Join-Path $env:WINDIR 'Logs\CBS\CBS.log'))

    try { return ([System.IO.FileInfo]::new($Path)).Length } catch { return $null }
}

function Read-SfcCbsVerdict {
    <#
    .SYNOPSIS
        Read SFC's verdict from the [SR] lines CBS.log gained since StartLength. Microsoft documents
        these lines (findstr /c:"[SR]") and they stay English on every display language, unlike
        sfc.exe's console text (#1915). $null when the log is unreadable, rotated during the scan,
        or proves nothing.
    #>
    param($StartLength, [string]$Path = (Join-Path $env:WINDIR 'Logs\CBS\CBS.log'))

    if ($null -eq $StartLength) { return $null }
    $lines = New-Object System.Collections.Generic.List[string]
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        # A shorter log was rotated mid-scan: the earlier [SR] lines are gone, so nothing is proven.
        if ($stream.Length -lt [long]$StartLength) { return $null }
        [void]$stream.Seek([long]$StartLength, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object System.IO.StreamReader($stream)
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.Contains('[SR]')) { $lines.Add($line) }
        }
    }
    catch { return $null }
    finally { if ($stream) { $stream.Dispose() } }

    return ConvertTo-SfcCbsVerdict $lines.ToArray()
}

function ConvertTo-SfcCbsVerdict {
    <#
    .SYNOPSIS
        Map one scan's CBS.log [SR] lines to a verdict. SFC verifies in batches, each ending with
        "Repairing N components" and "Repair complete"; an unrepairable file logs "Cannot repair member file".
    #>
    param([string[]]$Lines)

    if (-not $Lines -or $Lines.Count -eq 0) { return $null }
    foreach ($line in $Lines) {
        if ($line -match '\[SR\] (Cannot repair member file|Could not reproject corrupted file)') {
            return "found corrupt files it could not repair"
        }
    }
    $repairCompleted = $false
    $batches = 0
    $repairing = 0
    foreach ($line in $Lines) {
        if ($line -match '\[SR\] Repair complete') { $repairCompleted = $true }
        if ($line -match '\[SR\] Repairing (\d+) components') {
            $batches++
            $repairing += [int]$Matches[1]
        }
    }
    if (-not $repairCompleted -or $batches -eq 0) { return $null }
    if ($repairing -gt 0) { return "repaired corrupt files" }
    return "no integrity violations"
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
        try { $disks = @(Get-PhysicalDisk -ErrorAction Stop) }
        catch { $disks = @() }
        finally { Stop-Spinner }
        # If Windows cannot map the written volume, retain the conservative
        # all-disks verdict. A known unrelated disk must not block this drive.
        $targetDisks = @()
        try {
            $targetDisks = @(Get-Partition -DriveLetter (Get-SystemDriveLetter) -ErrorAction Stop |
                Get-Disk -ErrorAction Stop)
        }
        catch { $targetDisks = @() }
        # Independent target evidence remains useful when the display inventory fails.
        if ($disks.Count -eq 0) {
            $disks = $targetDisks
            if ($disks.Count -eq 0) { Write-Host "  $esc[90mCould not check disk health$esc[0m" }
        }
        $targetProblem = $false
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
            elseif ($status -eq "Unhealthy") {
                Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m $name - $status"
                Write-Host "  $esc[31mDisk has critical issues, back up data immediately!$esc[0m"
                $script:IssuesFound++
            }
            else { Write-Host "  $esc[90m$name - health unknown$esc[0m" }
        }
        $healthTargets = $disks
        if ($targetDisks.Count -gt 0) { $healthTargets = $targetDisks }
        foreach ($target in $healthTargets) {
            if ($target.HealthStatus -in @('Warning', 'Unhealthy')) { $targetProblem = $true }
        }
        return (-not $targetProblem)
    }
    catch {
        Write-Host "  $esc[90mCould not check disk health$esc[0m"
        return $true
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

    $job = $null
    Start-Spinner "Checking for updates..."
    try {
        # Query the local catalog in a disposable process: COM can stall even
        # without network access, and must not hold the maintenance command open.
        try {
            $job = Start-Job -ScriptBlock {
                $ErrorActionPreference = 'Stop'
                $updateSession = New-Object -ComObject Microsoft.Update.Session
                $updateSearcher = $updateSession.CreateUpdateSearcher()
                $updateSearcher.Online = $false
                $searchResult = $updateSearcher.Search("IsInstalled=0")
                [pscustomobject]@{
                    Total = $searchResult.Updates.Count
                    Important = @($searchResult.Updates | Where-Object { $_.MsrcSeverity -in @('Critical', 'Important') }).Count
                }
            }
            $completed = Wait-Job -Job $job -Timeout 5
        }
        finally { Stop-Spinner } # Clear the line before any result is written on it.
        if (-not $completed -or $job.State -ne 'Completed') { throw 'Windows Update query did not complete' }
        $result = @(Receive-Job -Job $job -ErrorAction Stop)
        if ($result.Count -ne 1 -or $null -eq $result[0].Total -or $null -eq $result[0].Important -or
            $result[0].Total -lt 0 -or $result[0].Important -lt 0 -or $result[0].Important -gt $result[0].Total) {
            throw 'Windows Update query returned an incomplete result'
        }
        if ($result[0].Important -gt 0) {
            $noun = if ($result[0].Important -eq 1) { 'update' } else { 'updates' }
            Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m $($result[0].Important) important $noun available"
            Write-Host "  $esc[90mRun Windows Update to install$esc[0m"
            $script:IssuesFound++
        }
        elseif ($result[0].Total -gt 0) {
            $noun = if ($result[0].Total -eq 1) { 'update' } else { 'updates' }
            Write-Host "  $esc[90m$($script:Icons.List)$esc[0m $($result[0].Total) optional $noun available"
        }
        else {
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m No pending updates in the local catalog"
        }
    }
    catch {
        Write-Host "  $esc[90mCould not check Windows Update status$esc[0m"
    }
    finally {
        if ($null -ne $job) {
            if ($job.State -notin @('Completed', 'Failed', 'Stopped')) { Stop-Job -Job $job -ErrorAction SilentlyContinue }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
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
    Clear-MoleScreen

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

    # Read health before the write-heavy operation, including in preview mode.
    $diskAllowsOptimization = Test-DiskHealth
    if ($diskAllowsOptimization) { Optimize-DiskDrive }
    else { Write-Host "  Disk optimization skipped: the target disk reports a problem" }

    # Run optimizations
    Clear-DnsCache
    Optimize-Network

    # Run health checks
    Get-StartupPrograms
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
