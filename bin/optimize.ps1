# Mole - Optimize Command
# System optimization, health checks, and repairs for Windows

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
$script:RepairsApplied = 0

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
    Write-Host "  - Windows Search & Update check"
    Write-Host "  - Network & DNS optimization"
    Write-Host "  - System cache cleanup & repairs"
    Write-Host "    (Font cache, Icon cache, Store cache)"
    Write-Host ""
    Write-Host "$esc[33mExamples:$esc[0m"
    Write-Host "  mo optimize              # Run all optimizations"
    Write-Host "  mo optimize --dry-run    # Preview what would happen"
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

    try {
        $systemDriveLetter = Get-SystemDriveLetter
        Write-Host "  Running Windows default optimization on drive ${systemDriveLetter}:..."

        $volume = Get-Volume -DriveLetter $systemDriveLetter -ErrorAction SilentlyContinue
        if ($volume) {
            $null = Optimize-Volume -DriveLetter $systemDriveLetter -ErrorAction Stop
        } else {
            $result = & defrag "${systemDriveLetter}:" /U /V 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "defrag.exe exited with code $LASTEXITCODE"
            }
        }

        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Drive optimization completed"
        $script:OptimizationsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Disk optimization failed: $_"
    }
}

function Optimize-SearchIndex {
    <#
    .SYNOPSIS
        Rebuild Windows Search index if needed
    #>

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Windows Search$esc[0m"

    $searchService = Get-Service -Name WSearch -ErrorAction SilentlyContinue

    if (-not $searchService) {
        Write-Host "  $esc[90mWindows Search service not found$esc[0m"
        return
    }

    if ($searchService.Status -ne 'Running') {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Windows Search service is not running"

        if ($script:DryRun) {
            Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would start search service"
            return
        }

        try {
            Start-Service -Name WSearch -ErrorAction Stop
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Started Windows Search service"
            $script:OptimizationsApplied++
        }
        catch {
            Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Could not start search service"
        }
    }
    else {
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Search service running"
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
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m DNS cache flushed"
        $script:OptimizationsApplied++
    }
    catch {
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
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would reset Winsock catalog"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would reset TCP/IP stack"
        $script:OptimizationsApplied += 2
        return
    }

    try {
        # Reset Winsock
        $null = netsh winsock reset 2>&1
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Winsock catalog reset"
        $script:OptimizationsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Winsock reset failed"
    }

    try {
        # Flush ARP cache
        $null = netsh interface ip delete arpcache 2>&1
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m ARP cache cleared"
        $script:OptimizationsApplied++
    }
    catch {
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

        $output = Get-Content "$env:TEMP\sfc_output.txt" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\sfc_output.txt" -Force -ErrorAction SilentlyContinue

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
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Scan completed"
        }
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m System File Checker failed: $_"
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
        $disks = Get-PhysicalDisk -ErrorAction Stop

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

        Write-Host "  Checking for updates..."
        $searchResult = $updateSearcher.Search("IsInstalled=0")

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
# Repair Functions
# ============================================================================

function Repair-FontCache {
    <#
    .SYNOPSIS
        Rebuild Windows font cache
    .DESCRIPTION
        Stops the font cache service, clears the cache files, and restarts.
        Fixes issues with fonts not displaying correctly or missing fonts.
    #>

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Font Cache Rebuild$esc[0m"

    if (-not (Test-IsAdmin)) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Requires administrator privileges"
        return
    }

    # Font cache locations
    $fontCachePaths = @(
        "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
        "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\FontCache"
        "$env:WINDIR\System32\FNTCACHE.DAT"
    )

    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would stop Windows Font Cache Service"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would delete font cache files"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would restart Windows Font Cache Service"
        $script:OptimizationsApplied++
        return
    }

    try {
        # Stop font cache service
        Write-Host "  $esc[90mStopping Font Cache Service...$esc[0m"
        Stop-Service -Name "FontCache" -Force -ErrorAction SilentlyContinue
        Stop-Service -Name "FontCache3.0.0.0" -Force -ErrorAction SilentlyContinue

        # Wait a moment for service to stop
        Start-Sleep -Seconds 2

        # Delete font cache files
        foreach ($path in $fontCachePaths) {
            if (Test-Path $path) {
                if (Test-Path $path -PathType Container) {
                    Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue |
                        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
                }
                else {
                    Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # Restart font cache service
        Write-Host "  $esc[90mRestarting Font Cache Service...$esc[0m"
        Start-Service -Name "FontCache" -ErrorAction SilentlyContinue
        Start-Service -Name "FontCache3.0.0.0" -ErrorAction SilentlyContinue

        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Font cache rebuilt successfully"
        Write-Host "  $esc[90mNote: Some apps may need restart to see changes$esc[0m"
        $script:OptimizationsApplied++
        $script:RepairsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Could not rebuild font cache: $_"
        Start-Service -Name "FontCache" -ErrorAction SilentlyContinue
    }
}

function Repair-IconCache {
    <#
    .SYNOPSIS
        Rebuild Windows icon cache
    .DESCRIPTION
        Clears the icon cache database files, forcing Windows to rebuild them.
        Fixes issues with missing, corrupted, or outdated icons.
    #>

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Icon Cache Rebuild$esc[0m"

    $iconCachePath = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"

    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would stop Explorer"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would delete icon cache files (iconcache_*.db)"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would restart Explorer"
        $script:OptimizationsApplied++
        return
    }

    try {
        Write-Host "  $esc[90mStopping Explorer...$esc[0m"
        Stop-Process -Name "explorer" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        # Delete icon cache files
        $iconCacheFiles = Get-ChildItem -Path $iconCachePath -Filter "iconcache_*.db" -Force -ErrorAction SilentlyContinue
        $thumbCacheFiles = Get-ChildItem -Path $iconCachePath -Filter "thumbcache_*.db" -Force -ErrorAction SilentlyContinue

        $deletedCount = 0
        foreach ($file in $iconCacheFiles) {
            Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
            $deletedCount++
        }

        foreach ($file in $thumbCacheFiles) {
            Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
            $deletedCount++
        }

        $systemIconCache = "$env:LOCALAPPDATA\IconCache.db"
        if (Test-Path $systemIconCache) {
            Remove-Item -Path $systemIconCache -Force -ErrorAction SilentlyContinue
            $deletedCount++
        }

        Write-Host "  $esc[90mRestarting Explorer...$esc[0m"
        Start-Process "explorer.exe"

        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Icon cache rebuilt ($deletedCount files cleared)"
        Write-Host "  $esc[90mNote: Icons will rebuild gradually as you browse$esc[0m"
        $script:OptimizationsApplied++
        $script:RepairsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Could not rebuild icon cache: $_"
        Start-Process "explorer.exe" -ErrorAction SilentlyContinue
    }
}

function Repair-SearchIndex {
    <#
    .SYNOPSIS
        Reset Windows Search index
    .DESCRIPTION
        Stops the Windows Search service, deletes the search index, and restarts.
        Fixes issues with search not finding files or returning incorrect results.
    #>

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Windows Search Index Reset$esc[0m"

    if (-not (Test-IsAdmin)) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Requires administrator privileges"
        return
    }

    $searchIndexPath = "$env:ProgramData\Microsoft\Search\Data\Applications\Windows"

    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would stop Windows Search service"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would delete search index database"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would restart Windows Search service"
        $script:OptimizationsApplied++
        return
    }

    try {
        function Wait-ForServiceStatus {
            param(
                [Parameter(Mandatory)]
                [string]$Name,
                [Parameter(Mandatory)]
                [System.ServiceProcess.ServiceControllerStatus]$ExpectedStatus,
                [int]$TimeoutSeconds = 15
            )

            $service = Get-Service -Name $Name -ErrorAction Stop
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

            do {
                $service.Refresh()
                if ($service.Status -eq $ExpectedStatus) {
                    return $true
                }
                Start-Sleep -Milliseconds 500
            } while ((Get-Date) -lt $deadline)

            $service.Refresh()
            return $service.Status -eq $ExpectedStatus
        }

        function Stop-ServiceSafely {
            param(
                [Parameter(Mandatory)]
                [string]$Name,
                [int]$TimeoutSeconds = 20
            )

            $service = Get-Service -Name $Name -ErrorAction Stop
            if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                return
            }

            if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::StopPending) {
                try {
                    Stop-Service -Name $Name -Force -ErrorAction Stop
                }
                catch {
                    $service.Refresh()
                    if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::StopPending) {
                        throw
                    }
                }
            }

            if (-not (Wait-ForServiceStatus -Name $Name -ExpectedStatus ([System.ServiceProcess.ServiceControllerStatus]::Stopped) -TimeoutSeconds $TimeoutSeconds)) {
                throw "Windows Search service did not stop within $TimeoutSeconds seconds."
            }
        }

        function Start-ServiceSafely {
            param(
                [Parameter(Mandatory)]
                [string]$Name,
                [int]$TimeoutSeconds = 20
            )

            $service = Get-Service -Name $Name -ErrorAction Stop
            if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
                return
            }

            if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::StartPending) {
                Start-Service -Name $Name -ErrorAction Stop
            }

            if (-not (Wait-ForServiceStatus -Name $Name -ExpectedStatus ([System.ServiceProcess.ServiceControllerStatus]::Running) -TimeoutSeconds $TimeoutSeconds)) {
                throw "Windows Search service did not start within $TimeoutSeconds seconds."
            }
        }

        Write-Host "  $esc[90mStopping Windows Search service...$esc[0m"
        Stop-ServiceSafely -Name "WSearch"

        if (Test-Path $searchIndexPath) {
            Write-Host "  $esc[90mDeleting search index...$esc[0m"
            Remove-Item -Path "$searchIndexPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Host "  $esc[90mRestarting Windows Search service...$esc[0m"
        Start-ServiceSafely -Name "WSearch"

        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Search index reset successfully"
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Indexing will rebuild in the background (may take hours)"
        $script:OptimizationsApplied++
        $script:RepairsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Could not reset search index: $_"
        Start-Service -Name "WSearch" -ErrorAction SilentlyContinue
    }
}

function Repair-StoreCache {
    <#
    .SYNOPSIS
        Reset Windows Store cache
    .DESCRIPTION
        Runs wsreset.exe to clear the Windows Store cache.
        Fixes issues with Store apps not installing, updating, or launching.
    #>

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Windows Store Cache Reset$esc[0m"

    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would run wsreset.exe"
        $script:OptimizationsApplied++
        return
    }

    try {
        Write-Host "  $esc[90mResetting Windows Store cache...$esc[0m"
        $wsreset = Start-Process -FilePath "wsreset.exe" -PassThru -WindowStyle Hidden
        $wsreset.WaitForExit(30000)

        if ($wsreset.ExitCode -eq 0) {
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Windows Store cache reset successfully"
            $script:RepairsApplied++
        }
        else {
            Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m wsreset completed with code $($wsreset.ExitCode)"
        }
        $script:OptimizationsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Could not reset Store cache: $_"
    }
}

# ============================================================================
# Summary
# ============================================================================

function Show-OptimizeSummary {
    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[1;35m" -NoNewline
    if ($script:DryRun) {
        Write-Host "Dry Run Complete - No Changes Made" -NoNewline
    }
    else {
        Write-Host "Optimization Complete" -NoNewline
    }
    Write-Host "$esc[0m"
    Write-Host ""

    if ($script:DryRun) {
        Write-Host "  Would apply $esc[33m$($script:OptimizationsApplied)$esc[0m optimizations"
        Write-Host "  Run without --dry-run to apply changes"
    }
    else {
        Write-Host "  Optimizations applied: $esc[32m$($script:OptimizationsApplied)$esc[0m"

        if ($script:RepairsApplied -gt 0) {
            Write-Host "  Repairs applied: $esc[32m$($script:RepairsApplied)$esc[0m"
        }

        if ($script:IssuesFixed -gt 0) {
            Write-Host "  Issues fixed: $esc[32m$($script:IssuesFixed)$esc[0m"
        }

        if ($script:IssuesFound -gt 0) {
            Write-Host "  Issues found: $esc[33m$($script:IssuesFound)$esc[0m"
        }
        else {
            Write-Host "  System health: $esc[32mGood$esc[0m"
        }
    }

    Write-Host ""
}

# ============================================================================
# Main Entry Point
# ============================================================================

function Main {
    # Enable debug if requested
    if ($DebugMode) {
        $env:MOLE_DEBUG = "1"
        $DebugPreference = "Continue"
    }

    # Show help
    if ($ShowHelp) {
        Show-OptimizeHelp
        return
    }

    # Set dry-run mode
    $script:DryRun = $DryRun

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
    $health = Get-SystemHealth
    Show-SystemHealth -Health $health

    # Run optimizations
    Optimize-DiskDrive
    Clear-DnsCache
    Optimize-Network

    # Run health checks
    Get-StartupPrograms
    Test-DiskHealth
    Test-WindowsUpdate

    # Run repairs (consolidated)
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) System Repairs$esc[0m"

    Repair-FontCache
    Repair-StoreCache
    Repair-SearchIndex
    Repair-IconCache

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
Main
