# Mole - Installer command
# Find old Windows Installer packages (.msi) in Downloads and move the chosen
# ones to the Recycle Bin.

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

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path (Split-Path -Parent $scriptDir) "lib"

. "$libDir\core\base.ps1"
. "$libDir\core\log.ps1"
. "$libDir\core\ui.ps1"
. "$libDir\core\file_ops.ps1"

# ============================================================================
# Rules
# ============================================================================

# The same scope as the Mole for Windows app's downloaded installers: only an
# .msi directly in Downloads that arrived at least two weeks ago and whose
# bytes are a Windows Installer database. An .exe is never offered: a setup
# program and a portable app look the same from outside, and a portable app
# in Downloads may be the only copy someone runs.
$script:InstallerMinimumAgeDays = 14
# Downloads can hold tens of thousands of files; read at most this many
# entries, and open at most the largest this many candidates.
$script:InstallerMaxEntries = 4096
$script:InstallerMaxFiles = 128
$script:InstallerBytesRecycled = 0
$script:InstallerItemsRecycled = 0
$script:InstallerItemsHeld = 0
$script:InstallerItemsKept = 0

function Show-InstallerHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mmo installer$esc[0m - Find and remove old installer files"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m mo installer [options]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  --dry-run    Show what would be removed, change nothing"
    Write-Host "  --debug      Enable debug logging"
    Write-Host "  --help       Show this help message"
    Write-Host ""
    Write-Host "Lists .msi installers in your Downloads folder that are at least $($script:InstallerMinimumAgeDays) days old."
    Write-Host "Chosen files go to the Recycle Bin."
    Write-Host ""
}

function Get-InstallerDownloadsFolder {
    return (Join-Path $env:USERPROFILE 'Downloads')
}

# Shape only: a direct child of Downloads, a plain file, an .msi name with
# something before the extension and no leading dot.
function Test-InstallerCandidateShape {
    param([IO.FileSystemInfo]$Item, [string]$Downloads)

    if ($Item -isnot [IO.FileInfo]) { return $false }
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    $name = $Item.Name
    if ($name.StartsWith('.') -or $name.Length -le 4) { return $false }
    if (-not $name.EndsWith('.msi', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $parent = [IO.Path]::GetDirectoryName($Item.FullName)
    return [string]::Equals($parent.TrimEnd('\'), $Downloads.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

# A copied or extracted file keeps an old write time, so the later of creation
# and write time is when it arrived in Downloads.
function Get-InstallerArrival {
    param([IO.FileInfo]$Item)
    if ($Item.CreationTimeUtc -gt $Item.LastWriteTimeUtc) { return $Item.CreationTimeUtc }
    return $Item.LastWriteTimeUtc
}

function Test-InstallerOldEnough {
    param([IO.FileInfo]$Item, [datetime]$NowUtc)
    return (Get-InstallerArrival $Item) -le $NowUtc.AddDays(-$script:InstallerMinimumAgeDays)
}

function Read-InstallerBytes {
    param([IO.Stream]$Stream, [long]$Offset, [int]$Count)
    if ($Offset -lt 0 -or $Offset + $Count -gt $Stream.Length) { return $null }
    $null = $Stream.Seek($Offset, [IO.SeekOrigin]::Begin)
    $buffer = New-Object byte[] $Count
    $read = 0
    while ($read -lt $Count) {
        $n = $Stream.Read($buffer, $read, $Count - $read)
        if ($n -le 0) { return $null }
        $read += $n
    }
    return , $buffer
}

# A Windows Installer database is a compound file whose root storage carries
# the MSI class ID. A patch (.msp), transform (.mst) or Office document has the
# same compound-file header with a different class ID.
function Test-InstallerMsiStream {
    param([IO.Stream]$Stream)

    $magic = [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)
    $msiClsid = [byte[]](0x84, 0x10, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46)
    $header = Read-InstallerBytes -Stream $Stream -Offset 0 -Count 512
    if ($null -eq $header) { return $false }
    for ($i = 0; $i -lt 8; $i++) { if ($header[$i] -ne $magic[$i]) { return $false } }
    if ($header[0x1C] -ne 0xFE -or $header[0x1D] -ne 0xFF) { return $false }
    $shift = [BitConverter]::ToUInt16($header, 0x1E)
    if ($shift -ne 9 -and $shift -ne 12) { return $false }
    $firstDirectorySector = [BitConverter]::ToUInt32($header, 0x30)
    # 0xFFFFFFFA and above are reserved sector markers. Written in decimal:
    # Windows PowerShell reads 0xFFFFFFFA as the Int32 -6.
    if ($firstDirectorySector -ge [uint32]4294967290) { return $false }
    $offset = ([long]$firstDirectorySector + 1) * ([long]1 -shl $shift)
    $root = Read-InstallerBytes -Stream $Stream -Offset $offset -Count 128
    if ($null -eq $root) { return $false }
    if ($root[0x42] -ne 5) { return $false }
    for ($i = 0; $i -lt 16; $i++) { if ($root[0x50 + $i] -ne $msiClsid[$i]) { return $false } }
    return $true
}

# 'msi', 'other' or 'held'. The file is opened with no sharing, so a setup
# still running from it, a download still writing it or a scanner reading it
# refuses the open; any failure to open counts as held, never as free.
function Get-InstallerFileVerdict {
    param([string]$Path)

    $stream = $null
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    }
    catch {
        Write-Debug "Installer is open elsewhere or unreadable: $Path - $_"
        return 'held'
    }
    try {
        if (Test-InstallerMsiStream -Stream $stream) { return 'msi' }
        return 'other'
    }
    catch {
        Write-Debug "Could not read installer: $Path - $_"
        return 'held'
    }
    finally { $stream.Dispose() }
}

function Find-DownloadedInstallers {
    param([string]$Downloads = (Get-InstallerDownloadsFolder), [datetime]$NowUtc = [datetime]::UtcNow)

    $result = @{ Items = @(); Held = 0 }
    if (-not (Test-Path -LiteralPath $Downloads -PathType Container)) { return $result }
    # A junction or symbolic link on Downloads or any folder above it means the
    # files belong somewhere else; leave them alone.
    if ($null -eq (Get-MolePathSnapshot -Path $Downloads)) {
        Write-Debug "Downloads is linked or unreadable: $Downloads"
        return $result
    }

    $candidates = New-Object Collections.Generic.List[IO.FileInfo]
    try {
        $seen = 0
        foreach ($entry in (New-Object IO.DirectoryInfo($Downloads)).EnumerateFileSystemInfos()) {
            if (++$seen -gt $script:InstallerMaxEntries) { break }
            if ((Test-InstallerCandidateShape -Item $entry -Downloads $Downloads) -and
                (Test-InstallerOldEnough -Item $entry -NowUtc $NowUtc)) {
                $candidates.Add($entry)
            }
        }
    }
    catch {
        Write-Debug "Could not list Downloads: $_"
        return $result
    }

    $items = @()
    foreach ($file in @($candidates | Sort-Object -Property Length -Descending | Select-Object -First $script:InstallerMaxFiles)) {
        $verdict = Get-InstallerFileVerdict -Path $file.FullName
        if ($verdict -eq 'held') { $result.Held++; continue }
        if ($verdict -ne 'msi') { continue }
        if (-not (Test-SafePath -Path $file.FullName)) { continue }
        $snapshot = Get-MolePathSnapshot -Path $file.FullName
        if ($null -eq $snapshot) { continue }
        $items += [pscustomobject]@{
            Path = $file.FullName
            Name = $file.Name
            Size = [long]$file.Length
            SizeHuman = Format-ByteSize -Bytes $file.Length
            CreationUtc = $file.CreationTimeUtc
            WriteUtc = $file.LastWriteTimeUtc
            Snapshot = $snapshot
        }
    }
    $result.Items = $items
    return $result
}

# The whole judgement again at the sink, against what the list showed: the
# selection may have waited, and a file rewritten or reopened since is not the
# one the user chose.
function Test-InstallerStillEligible {
    param($Item, [string]$Downloads, [datetime]$NowUtc, [hashtable]$State)

    $State.Changed = $true
    if (-not (Test-MolePathSnapshot $Item.Snapshot)) { return $false }
    $file = New-Object IO.FileInfo($Item.Path)
    $file.Refresh()
    if (-not $file.Exists) { return $false }
    if ($file.Length -ne $Item.Size -or $file.CreationTimeUtc -ne $Item.CreationUtc -or
        $file.LastWriteTimeUtc -ne $Item.WriteUtc) { return $false }
    if (-not (Test-InstallerCandidateShape -Item $file -Downloads $Downloads)) { return $false }
    if (-not (Test-InstallerOldEnough -Item $file -NowUtc $NowUtc)) { return $false }
    $verdict = Get-InstallerFileVerdict -Path $Item.Path
    if ($verdict -eq 'held') { $State.Changed = $false; $State.Held = $true; return $false }
    if ($verdict -ne 'msi') { return $false }
    if (-not (Test-MolePathSnapshot $Item.Snapshot)) { return $false }
    $State.Changed = $false
    return $true
}

function Remove-DownloadedInstallers {
    param([array]$Items, [string]$Downloads = (Get-InstallerDownloadsFolder))

    $esc = [char]27
    Write-Host ""
    foreach ($item in $Items) {
        $state = @{ Held = $false; Changed = $false }
        $reviewed = $item
        $guard = {
            param($candidate)
            if (-not [string]::Equals($candidate, $reviewed.Path, [StringComparison]::OrdinalIgnoreCase)) { return $false }
            $eligible = Test-InstallerStillEligible -Item $reviewed -Downloads $Downloads -NowUtc ([datetime]::UtcNow) -State $state
            # Only a single $true passes; Remove-SafeItem refuses anything else.
            return $eligible
        }
        $success = Remove-SafeItem -Path $item.Path -Description $item.Name -Recycle -Guard $guard
        if ($success) {
            $script:InstallerItemsRecycled++
            $script:InstallerBytesRecycled += $item.Size
        }
        elseif ($state.Held) {
            $script:InstallerItemsHeld++
            if (-not $script:MoleDryRunMode) {
                Write-MoleOperation -Action "SKIPPED" -Path $item.Path -Detail 'in use'
            }
            Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Skipped $($item.Name) (in use; close what has it open, then run mo installer again)"
        }
        elseif ($state.Changed) {
            $script:InstallerItemsKept++
            if (-not $script:MoleDryRunMode) {
                Write-MoleOperation -Action "SKIPPED" -Path $item.Path -Detail 'changed since the list'
            }
            Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Kept $($item.Name) (changed since the list)"
        }
        else {
            # Protected, whitelisted or refused by the Recycle Bin; Remove-SafeItem
            # has already logged and warned about a failed move.
            $script:InstallerItemsKept++
            Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Kept $($item.Name)"
        }
    }
}

function Show-InstallerSummary {
    $heading = if ($script:MoleDryRunMode) { 'Dry run complete - no changes made' } else { 'Installer cleanup complete' }
    $details = @()
    if ($script:InstallerItemsRecycled -gt 0) {
        $size = Format-ByteSize -Bytes $script:InstallerBytesRecycled
        $label = if ($script:MoleDryRunMode) { 'Would move to Recycle Bin' } else { 'Moved to Recycle Bin' }
        $details += "${label}: $(Get-MoleColor -Name Green)$size$(Get-MoleColor -Name NC) | Items: $($script:InstallerItemsRecycled)"
    }
    else { $details += 'Nothing was removed.' }
    $left = $script:InstallerItemsHeld + $script:InstallerItemsKept
    if ($left -gt 0) { $details += "Kept: $left" }
    Show-SummaryBlock -Heading $heading -Details $details
}

function Show-InstallerSelectionMenu {
    param([array]$Items)

    $count = if ($null -eq $Items) { 0 } else { @($Items).Count }
    if ($count -eq 0) { return @() }

    $esc = [char]27
    $selectedIndices = @{}
    $currentIndex = 0
    $pageSize = 12
    $pageStart = 0

    try { [Console]::CursorVisible = $false } catch { }
    try {
        while ($true) {
            Clear-MoleScreen
            Write-Host ""
            Write-Host "$esc[1;35mSelect Installers to Remove$esc[0m"
            Write-Host ""
            Write-Host "$esc[90mUse: $($script:Icons.NavUp)$($script:Icons.NavDown) navigate | Space select | A select all | Enter confirm | Q quit$esc[0m"
            Write-Host ""

            $pageEnd = [Math]::Min($pageStart + $pageSize, $count)
            for ($i = $pageStart; $i -lt $pageEnd; $i++) {
                $item = $Items[$i]
                $checkbox = if ($selectedIndices.ContainsKey($i)) { "$esc[32m[$($script:Icons.Success)]$esc[0m" } else { "[ ]" }
                if ($i -eq $currentIndex) { Write-Host "$esc[7m" -NoNewline }
                $entry = Format-SizeListEntry -Name $item.Name -Size $item.SizeHuman -NameWidth 60
                Write-Host "  $checkbox $entry" -NoNewline
                if ($i -eq $currentIndex) { Write-Host "$esc[0m" } else { Write-Host "" }
            }

            Write-Host ""
            if ($selectedIndices.Count -gt 0) {
                $bytes = 0
                foreach ($idx in $selectedIndices.Keys) { $bytes += $Items[$idx].Size }
                $noun = if ($selectedIndices.Count -eq 1) { 'file' } else { 'files' }
                Write-Host "$esc[33mSelected:$esc[0m $($selectedIndices.Count) $noun ($(Format-ByteSize -Bytes $bytes))"
            }
            $totalPages = [Math]::Ceiling($count / $pageSize)
            $currentPage = [Math]::Floor($pageStart / $pageSize) + 1
            Write-Host "$esc[90mPage $currentPage of $totalPages | Total: $count $(if ($count -eq 1) { 'file' } else { 'files' })$esc[0m"

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' {
                    if ($currentIndex -gt 0) {
                        $currentIndex--
                        if ($currentIndex -lt $pageStart) { $pageStart = [Math]::Max(0, $pageStart - $pageSize) }
                    }
                }
                'DownArrow' {
                    if ($currentIndex -lt $count - 1) {
                        $currentIndex++
                        if ($currentIndex -ge $pageStart + $pageSize) { $pageStart += $pageSize }
                    }
                }
                'PageUp' {
                    $pageStart = [Math]::Max(0, $pageStart - $pageSize)
                    $currentIndex = $pageStart
                }
                'PageDown' {
                    $pageStart = [Math]::Max(0, [Math]::Min($count - $pageSize, $pageStart + $pageSize))
                    $currentIndex = $pageStart
                }
                'Spacebar' {
                    if ($selectedIndices.ContainsKey($currentIndex)) { $selectedIndices.Remove($currentIndex) }
                    else { $selectedIndices[$currentIndex] = $true }
                }
                'A' {
                    if ($selectedIndices.Count -eq $count) { $selectedIndices.Clear() }
                    else { for ($i = 0; $i -lt $count; $i++) { $selectedIndices[$i] = $true } }
                }
                'Enter' {
                    if ($selectedIndices.Count -gt 0) {
                        return @($selectedIndices.Keys | Sort-Object | ForEach-Object { $Items[$_] })
                    }
                }
                'Escape' { return @() }
                'Q' { return @() }
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch { }
    }
}

function Main {
    if ($DebugMode) {
        Enable-DebugMode
        $DebugPreference = "Continue"
    }
    if ($ShowHelp) {
        Show-InstallerHelp
        return
    }
    if ($DryRun) {
        $env:MOLE_DRY_RUN = "1"
        Set-DryRunMode -Enabled $true
    }

    Clear-MoleScreen
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mInstaller Files$esc[0m"
    Write-Host ""

    $found = Find-DownloadedInstallers
    $items = @($found.Items)
    if ($found.Held -gt 0) {
        Write-Host "$esc[33m$($script:Icons.Warning)$esc[0m Skipped $($found.Held) in use; close what has them open, then run mo installer again"
    }
    if ($items.Count -eq 0) {
        if ($found.Held -eq 0) {
            Write-Host "$esc[32m$($script:Icons.Success)$esc[0m No old installer files found"
        }
        Write-Host ""
        return
    }

    $total = ($items | Measure-Object -Property Size -Sum).Sum
    $noun = if ($items.Count -eq 1) { 'installer' } else { 'installers' }
    Write-Host "Found $esc[33m$($items.Count)$esc[0m $noun with $esc[33m$(Format-ByteSize -Bytes $total)$esc[0m"
    Write-Host ""

    # Without a console to pick from, a preview covers every file, as purge
    # does; a real run still needs the list.
    if ($script:MoleDryRunMode -and -not (Test-MoleInteractiveOutput)) {
        $selected = $items
    }
    else {
        $selected = @(Show-InstallerSelectionMenu -Items $items)
    }
    if ($null -eq $selected -or @($selected).Count -eq 0) {
        Write-Info "No files selected"
        return
    }

    Clear-MoleScreen
    Write-Host ""
    $selectedBytes = ($selected | Measure-Object -Property Size -Sum).Sum
    Write-Host "$esc[33mThe following will be moved to the Recycle Bin ($(Format-ByteSize -Bytes $selectedBytes)):$esc[0m"
    Write-Host ""
    foreach ($item in $selected) {
        Write-Host "  $($script:Icons.List) $($item.Name) ($($item.SizeHuman))"
    }
    Write-Host ""

    if ($script:MoleDryRunMode) {
        Remove-DownloadedInstallers -Items $selected
        Show-InstallerSummary
        return
    }
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -eq 'y' -or $confirm -eq 'Y') {
        Remove-DownloadedInstallers -Items $selected
        Show-InstallerSummary
    }
    else {
        Write-Info "Cancelled"
    }
}

try { Main } finally { Stop-Spinner }
exit 0
