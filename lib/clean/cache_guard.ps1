# Shared guards for exact, rebuildable application cache directories.
#Requires -Version 5.1
if (Get-Variable MOLE_CACHE_GUARD_LOADED -Scope Script -ErrorAction SilentlyContinue) { return }
$script:MOLE_CACHE_GUARD_LOADED = $true

function Test-MoleCacheOwnerIdle {
    param([string[]]$Names, [string]$LockPath = '')
    if (-not $Names -or $Names.Count -eq 0) { return $false }
    try {
        # An empty complete snapshot means idle; a failed/incomplete one is unknown.
        foreach ($process in @(Get-Process -ErrorAction Stop)) {
            if ($Names -contains $process.ProcessName) { return $false }
        }
        if ($LockPath) {
            try { $attributes = [IO.File]::GetAttributes($LockPath) }
            catch [IO.FileNotFoundException] { return $true }
            catch [IO.DirectoryNotFoundException] { return $true }
            if ($attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory)) { return $false }
            $handle = [IO.File]::Open($LockPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
            $handle.Dispose()
        }
        return $true
    }
    catch { return $false }
}

function Clear-MoleAppCache {
    param([string]$Path, [string]$Description, [string[]]$Processes, [string]$LockPath = '')
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    if (-not (Test-SafePath $Path) -or -not (Get-MolePathSnapshot $Path)) { return }
    # The callback runs synchronously while this scope is alive. It is not a
    # cached idle answer: the sink calls it again after sizing and before deletion.
    $cacheOwnerNames = $Processes
    $cacheOwnerLock = $LockPath
    $condition = { Test-MoleCacheOwnerIdle -Names $cacheOwnerNames -LockPath $cacheOwnerLock }
    Clear-DirectoryContents -Path $Path -Description $Description -CanRemove $condition
}

# A named app's logs: files seven days old or more, only while it is not running.
function Clear-MoleOwnerLogs {
    param([string]$Path, [string]$Description, [string[]]$Processes)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    if (-not (Test-MoleCacheOwnerIdle -Names $Processes)) { return }
    Remove-OldFiles -Path $Path -DaysOld 7 -Description $Description
}

function Get-MoleCacheProfiles {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    $snapshot = Get-MolePathSnapshot $Root
    if (-not $snapshot) { return }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        # One directory level only, no unbounded recursive profile discovery.
        $profiles = New-Object 'System.Collections.Generic.List[IO.DirectoryInfo]'
        $seen = 0
        foreach ($path in [IO.Directory]::EnumerateDirectories($Root)) {
            $seen++
            if ($seen -gt 128 -or $timer.Elapsed.TotalSeconds -gt 2) { return }
            $profile = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (-not ($profile.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $profiles.Add($profile) }
        }
        if ($timer.Elapsed.TotalSeconds -gt 2 -or -not (Test-MolePathSnapshot $snapshot)) { return }
        return $profiles.ToArray()
    }
    catch { return }
}
