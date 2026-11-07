# Mole - Uninstall Command
# Interactive application uninstaller for Windows

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('dry-run')]
    [switch]$DryRun,

    [Alias('d')]
    [switch]$DebugMode,
    
    [Alias('r')]
    [switch]$Rescan,

    [switch]$List,
    
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

$script:CacheDir = "$env:USERPROFILE\.cache\mole"
# v3: Store display sizing does not require deletion authority over ancestors.
# v4: written as UTF-8. v3 used the ANSI code page, which turned non-ASCII
# app names into question marks, so a v3 file is not read as UTF-8.
# v5: sparse Store packages a desktop app registers are no longer listed.
# v6: preserve registered identities independently of content retention; protect Game Bar.
# v7: require readable manifest evidence before listing a Store package.
$script:AppCacheFile = "$script:CacheDir\app_scan_cache_v7.json"
$script:CacheTTLHours = 24

# A vendor EstimatedSize above this is measured against the install folder (#1717).
$script:SizeOutlierKB = 10485760

# ============================================================================
# Help
# ============================================================================

function Show-UninstallHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mmo uninstall$esc[0m - Interactive application uninstaller"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m mo uninstall [options]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  --dry-run    Show what would be uninstalled, change nothing"
    Write-Host "  --rescan     Force rescan of installed applications"
    Write-Host "  --list       List installed applications and exit (JSON when piped)"
    Write-Host "  --debug      Enable debug logging"
    Write-Host "  --help       Show this help message"
    Write-Host ""
    Write-Host "$esc[33mFeatures:$esc[0m"
    Write-Host "  - Scans installed programs from registry and Windows Apps"
    Write-Host "  - Shows program size, largest first"
    Write-Host "  - Interactive selection with arrow keys"
    Write-Host "  - Cleans leftover files after uninstall"
    Write-Host ""
}

# ============================================================================
# Protected Applications
# ============================================================================

$script:ProtectedApps = @(
    "Microsoft Windows"
    "Windows Feature Experience Pack"
    "Microsoft Edge"
    "Microsoft Edge WebView2"
    "Windows Security"
    "Microsoft Visual C++ *"
    "Microsoft .NET *"
    ".NET Desktop Runtime*"
    "Microsoft Update Health Tools"
    "NVIDIA Graphics Driver*"
    "AMD Software*"
    "Intel*Driver*"
)

function Test-ProtectedApp {
    param([string]$AppName)

    foreach ($pattern in $script:ProtectedApps) {
        if ($AppName -like $pattern) {
            return $true
        }
    }
    return $false
}

# Store packages Windows itself stands on: the Store and its purchase flow, App
# Installer (winget), Windows Security, and Get Help, which runs the troubleshooters.
$script:ProtectedPackageNames = @(
    "Microsoft.WindowsStore"
    "Microsoft.StorePurchaseApp"
    "Microsoft.DesktopAppInstaller"
    "Microsoft.SecHealthUI"
    "Microsoft.GetHelp"
    "Microsoft.XboxGamingOverlay"
)

# ============================================================================
# Registry Entry Helpers
# ============================================================================

# Reads a property that may be absent; strict mode throws on a missing one.
function Get-MoleProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# A full local folder path without quotes, trailing slashes or dot segments; $null otherwise.
function Get-NormalizedFolderPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $text = [Environment]::ExpandEnvironmentVariables($Path).Trim().Trim('"', "'").Trim()
    $text = $text.Replace('/', '\').TrimEnd('\')
    if ($text -notmatch '^[A-Za-z]:\\') { return $null }
    foreach ($segment in $text.Split('\')) {
        if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..') { return $null }
    }
    return $text
}

function Test-MoleInstallContentFree {
    param([string]$Path)

    # Registered install folders can also hold a portable emulator or game library.
    # Inspect the root and immediate children completely; uncertainty retains the folder.
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $folders = [Collections.Generic.List[string]]::new()
    $folders.Add($Path)
    $entries = 0
    try {
        for ($index = 0; $index -lt $folders.Count; $index++) {
            $folder = $folders[$index]
            $snapshot = Get-MolePathSnapshot -Path $folder
            if ($null -eq $snapshot) { return $false }
            $enumerator = ([IO.DirectoryInfo]::new($folder)).EnumerateFileSystemInfos().GetEnumerator()
            try {
                while ($enumerator.MoveNext()) {
                    $entries++
                    if ($entries -gt 4096 -or $clock.ElapsedMilliseconds -gt 2000) { return $false }
                    $entry = $enumerator.Current
                    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
                    if ($entry.Attributes -band [IO.FileAttributes]::Directory) {
                        if ($entry.Name -in @('roms', 'saves', 'states', 'bios', 'games', 'gog games', 'steamapps')) { return $false }
                        if ($index -eq 0) {
                            if ($folders.Count -ge 257) { return $false }
                            $folders.Add($entry.FullName)
                        }
                    } elseif ($entry.Name -like 'goggame-*.info' -or
                        $entry.Name -in @('galaxy-2.0.db', 'libraryfolder.vdf')) { return $false }
                }
            } finally { $enumerator.Dispose() }
            if (-not (Test-MolePathSnapshot -Snapshot $snapshot)) { return $false }
        }
        return ($clock.ElapsedMilliseconds -le 2000)
    } catch { return $false }
}

# Static eligibility for display measurement and a possible install leftover.
# This never authorizes deletion: Test-MoleLeftoverOwnership also checks content
# and current owners. Reject drive roots, profiles and shared/system containers.
function Test-MoleInstallFolder {
    param([string]$Path)

    # Folders that hold many apps or none, never one app's install folder.
    $containerNames = @(
        "Program Files", "Program Files (x86)", "ProgramData", "AppData", "Local", "LocalLow", "Roaming", "Programs"
    )
    $sharedFolderNames = @(
        "Windows", "Package Cache", "Installer", "Common Files", "Temp", "WindowsApps",
        "InstallShield Installation Information", "Uninstall Information", "Downloaded Installations"
    )
    $notAppFolderNames = @(
        "Microsoft", "Microsoft Games", "Common", "Clients", "Downloads", "Desktop", "Documents", "Internet Explorer",
        "Windows NT", "Windows Defender", "Windows Mail", "Windows Media Player", "Windows Photo Viewer",
        "Reference Assemblies", "winsxs", "DirectX", "DirectXRedist"
    )

    $folder = Get-NormalizedFolderPath -Path $Path
    if (-not $folder) { return $false }
    $segments = $folder.Split('\')
    if ($segments.Count -lt 2) { return $false }
    if ($segments[1] -eq 'Windows') { return $false }
    if ($segments[1] -eq 'Users' -and $segments.Count -le 3) { return $false }

    $last = $segments[$segments.Count - 1]
    if ($containerNames -contains $last -or
        $sharedFolderNames -contains $last -or
        $notAppFolderNames -contains $last) {
        return $false
    }

    # A Steam library holds every game installed to it. Its root (any folder with
    # a steamapps child, the Steam client's own folder included), steamapps and
    # everything in it outside one game's steamapps\common\<Game> are never one
    # app's install folder.
    $steamIndex = -1
    for ($i = 0; $i -lt $segments.Count; $i++) {
        if ($segments[$i] -ieq 'steamapps') { $steamIndex = $i; break }
    }
    if ($steamIndex -ge 0 -and
        -not ($segments.Count -ge $steamIndex + 3 -and $segments[$steamIndex + 1] -ieq 'common')) {
        return $false
    }
    if ([System.IO.Directory]::Exists((Join-Path $folder 'steamapps')) -or
        [System.IO.File]::Exists((Join-Path $folder 'libraryfolder.vdf'))) {
        return $false
    }

    $roots = @(
        $env:USERPROFILE, $env:PUBLIC, $env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData,
        $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432,
        $env:CommonProgramFiles, ${env:CommonProgramFiles(x86)}
    )
    foreach ($root in $roots) {
        $normalized = Get-NormalizedFolderPath -Path $root
        if ($normalized -and $folder -eq $normalized) { return $false }
    }
    # The profile's own shell folders are the user's, whatever an entry registers.
    $userProfile = Get-NormalizedFolderPath -Path $env:USERPROFILE
    $profileFolders = @(
        "Music", "Pictures", "Videos", "OneDrive", "Favorites", "Saved Games", "Contacts", "Links", "Searches", "3D Objects"
    )
    if ($userProfile -and $profileFolders -contains $last -and
        (Split-Path -Parent $folder) -eq $userProfile) {
        return $false
    }
    foreach ($root in @($env:SystemRoot, $env:windir)) {
        $normalized = Get-NormalizedFolderPath -Path $root
        if ($normalized -and ($folder -eq $normalized -or
                $folder.StartsWith($normalized + '\', [StringComparison]::OrdinalIgnoreCase))) {
            return $false
        }
    }

    return (Test-Path -LiteralPath $folder -PathType Container)
}

# Read ownership separately from the display inventory: hidden components and
# duplicate keys still own files, and an incomplete scan is never absence.
function Get-MoleInstallOwners {
    $owners = @()
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    try {
        foreach ($root in $roots) {
            try { $null = Get-Item -LiteralPath $root -ErrorAction Stop }
            catch [System.Management.Automation.ItemNotFoundException] { continue }
            foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
                $entry = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                $raw = [string](Get-MoleProperty $entry 'InstallLocation')
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                $path = Get-NormalizedFolderPath $raw
                if (-not $path) { throw 'Unresolved install ownership path' }
                $owners += @{ Path = $path; Key = $key.PSPath }
            }
        }
        foreach ($package in @(Get-AppxPackage -ErrorAction Stop)) {
            $raw = [string](Get-MoleProperty $package 'InstallLocation')
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $path = Get-NormalizedFolderPath $raw
            if (-not $path) { throw 'Unresolved package ownership path' }
            $owners += @{ Path = $path; Key = '' }
        }
        return @{ Complete = $true; Owners = $owners }
    }
    catch {
        Write-Debug "Could not verify install folder ownership: $_"
        return @{ Complete = $false; Owners = @() }
    }
}

function Test-MoleLeftoverOwnership {
    param([string]$Path, $App, [switch]$Preview)

    if (-not (Test-MoleInstallFolder $Path)) { return $false }
    # Content retention is removal authority, not registered identity or display size.
    if (-not (Test-MoleInstallContentFree $Path)) { return $false }
    $folder = Get-NormalizedFolderPath $Path
    $key = [string](Get-MoleProperty $App 'RegistryKey')
    $mergedKeys = @(Get-MoleProperty $App 'MergedKeys')
    if (-not $Preview -and -not (Test-UninstallEntryGone $key)) { return $false }
    $inventory = Get-MoleInstallOwners
    if (-not $inventory.Complete) { return $false }
    foreach ($owner in $inventory.Owners) {
        if ($Preview -and $owner.Key -and ($owner.Key -eq $key -or $owner.Key -in $mergedKeys)) { continue }
        if ($folder -eq $owner.Path -or
            $folder.StartsWith($owner.Path + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $owner.Path.StartsWith($folder + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Test-UninstallEntryFlag {
    param($Entry, [string]$Name)

    $value = Get-MoleProperty $Entry $Name
    if ($null -eq $value) { return $false }
    $number = 0L
    if ([long]::TryParse(([string]$value).Trim(), [ref]$number)) { return $number -ne 0 }
    return $false
}

# ParentKeyName, an Update or Hotfix ReleaseType, or a "KB123456" default value mark an update.
function Test-UninstallEntryIsUpdate {
    param($Entry)

    if (-not [string]::IsNullOrWhiteSpace([string](Get-MoleProperty $Entry 'ParentKeyName'))) { return $true }
    if ([string](Get-MoleProperty $Entry 'ReleaseType') -match 'Update|Hotfix') { return $true }
    return ([string](Get-MoleProperty $Entry '(default)') -match '^KB\d{6,}')
}

# EstimatedSize is KB; a DWORD above 2 GB reads back negative, and some vendors write a string.
function Get-EstimatedSizeKB {
    param($Entry)

    $value = Get-MoleProperty $Entry 'EstimatedSize'
    if ($null -eq $value) { return 0L }
    $kb = 0L
    if ($value -is [int]) {
        $kb = [long]$value
        if ($kb -lt 0) { $kb += 4294967296 }
    }
    elseif (-not [long]::TryParse(([string]$value).Trim(), [ref]$kb)) {
        $kb = 0L
    }
    if ($kb -lt 0) { return 0L }
    return $kb
}

# The size to show and whether it was verified. A vendor value can be wrong by 1000x
# (#1717: RustDesk wrote bytes into the KB field), so one above 10 GB is measured against
# the install folder and the measurement wins when it is at least 10x smaller.
function Get-RegistryAppSize {
    param([long]$EstimatedKB, [string]$InstallFolder)

    if ($EstimatedKB -gt 0 -and $EstimatedKB -le $script:SizeOutlierKB) {
        return [PSCustomObject]@{ SizeKB = $EstimatedKB; Checked = $true }
    }
    if (-not $InstallFolder) {
        return [PSCustomObject]@{ SizeKB = $EstimatedKB; Checked = $false }
    }
    $measured = [long](Get-PathSizeKB -Path $InstallFolder)
    if ($EstimatedKB -le 0) {
        return [PSCustomObject]@{ SizeKB = $measured; Checked = ($measured -gt 0) }
    }
    if ($measured -le 0) {
        return [PSCustomObject]@{ SizeKB = $EstimatedKB; Checked = $false }
    }
    if (($measured * 10) -le $EstimatedKB) {
        return [PSCustomObject]@{ SizeKB = $measured; Checked = $true }
    }
    return [PSCustomObject]@{ SizeKB = $EstimatedKB; Checked = $true }
}

# A search splits on whitespace and needs every word, read literally, so "Fan Control"
# finds "FanControl" and a typed [ or * means itself.
function Test-AppNameMatchesSearch {
    param([string]$Name, [string]$Search)
    foreach ($word in ($Search -split '\s+')) {
        if ($word -and $Name.IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

# One Uninstall registry entry as an app, or $null for entries Settings > Apps hides.
function ConvertFrom-UninstallEntry {
    param($Entry)

    $displayName = [string](Get-MoleProperty $Entry 'DisplayName')
    $uninstallString = ([string](Get-MoleProperty $Entry 'UninstallString')).Trim()
    $quietString = ([string](Get-MoleProperty $Entry 'QuietUninstallString')).Trim()
    if ([string]::IsNullOrWhiteSpace($displayName)) { return $null }
    if (-not $uninstallString -and -not $quietString) { return $null }
    if (Test-UninstallEntryFlag $Entry 'SystemComponent') { return $null }
    # NoRemove is the publisher saying this entry is not to be uninstalled.
    if (Test-UninstallEntryFlag $Entry 'NoRemove') { return $null }
    if (Test-UninstallEntryIsUpdate $Entry) { return $null }
    $displayName = $displayName.Trim()
    if (Test-ProtectedApp $displayName) { return $null }

    # A protected registered directory still distinguishes installations. Only
    # display measurement and leftover removal require their own eligibility.
    $installFolder = Get-NormalizedFolderPath -Path ([string](Get-MoleProperty $Entry 'InstallLocation'))
    $sizeFolder = $null
    if (Test-MoleInstallFolder -Path $installFolder) { $sizeFolder = $installFolder }
    $size = Get-RegistryAppSize -EstimatedKB (Get-EstimatedSizeKB $Entry) -InstallFolder $sizeFolder

    $installDate = $null
    try {
        $rawDate = [string](Get-MoleProperty $Entry 'InstallDate')
        if ($rawDate) {
            $installDate = [DateTime]::ParseExact($rawDate, "yyyyMMdd", $null)
        }
    }
    catch { }

    $publisher = [string](Get-MoleProperty $Entry 'Publisher')
    $version = [string](Get-MoleProperty $Entry 'DisplayVersion')

    return [PSCustomObject]@{
        Name                 = $displayName
        Publisher            = $(if ($publisher) { $publisher.Trim() } else { $null })
        Version              = $(if ($version) { $version.Trim() } else { $null })
        SizeKB               = $size.SizeKB
        SizeHuman            = Format-ByteSize -Bytes ($size.SizeKB * 1024)
        SizeChecked          = $size.Checked
        InstallLocation      = $installFolder
        UninstallString      = $(if ($uninstallString) { $uninstallString } else { $null })
        QuietUninstallString = $(if ($quietString) { $quietString } else { $null })
        WindowsInstaller     = (Test-UninstallEntryFlag $Entry 'WindowsInstaller')
        RegistryKey          = [string](Get-MoleProperty $Entry 'PSPath')
        KeyName              = [string](Get-MoleProperty $Entry 'PSChildName')
        PackageFullName      = $null
        InstallDate          = $installDate
        Source               = "Registry"
    }
}

# One product often registers twice (32- and 64-bit keys, an MSI plus a bootstrapper).
# Entries naming the same install folder and name, the same uninstaller, or the same
# name, version and publisher are one app; entries naming two different install folders
# never merge, since each copy has its own uninstaller. The richer entry wins: one with
# an install folder, then one whose size passed the outlier check.
function Merge-InstalledApps {
    param([array]$Apps)

    $kept = New-Object System.Collections.ArrayList
    $scores = New-Object System.Collections.ArrayList
    $mergedKeys = New-Object System.Collections.ArrayList
    foreach ($app in $Apps) {
        if ($null -eq $app) { continue }
        $appKey = [string](Get-MoleProperty $app 'RegistryKey')
        $folder = [string](Get-MoleProperty $app 'InstallLocation')
        $uninstall = [string](Get-MoleProperty $app 'UninstallString')
        $score = 0
        if ($folder) { $score += 4 }
        if ((Get-MoleProperty $app 'SizeChecked') -eq $true) { $score += 2 }

        $match = -1
        for ($i = 0; $i -lt $kept.Count; $i++) {
            $other = $kept[$i]
            $otherFolder = [string](Get-MoleProperty $other 'InstallLocation')
            if ($folder -and $otherFolder -and $folder -ne $otherFolder) { continue }
            $sameName = ($app.Name -eq $other.Name)
            if (($folder -and $sameName -and $folder -eq $otherFolder) -or
                ($uninstall -and $uninstall -eq [string](Get-MoleProperty $other 'UninstallString')) -or
                ($sameName -and [string]$app.Version -eq [string]$other.Version -and
                    [string]$app.Publisher -eq [string]$other.Publisher)) {
                $match = $i
                break
            }
        }

        if ($match -lt 0) {
            [void]$kept.Add($app)
            [void]$scores.Add($score)
            [void]$mergedKeys.Add((New-Object System.Collections.ArrayList))
            if ($appKey) { [void]$mergedKeys[$kept.Count - 1].Add($appKey) }
        }
        else {
            if ($appKey) { [void]$mergedKeys[$match].Add($appKey) }
            if ($score -gt $scores[$match]) {
                $kept[$match] = $app
                $scores[$match] = $score
            }
        }
    }
    # A preview treats every key that registered this product as going away with it.
    for ($i = 0; $i -lt $kept.Count; $i++) {
        Add-Member -InputObject $kept[$i] -NotePropertyName MergedKeys -NotePropertyValue @($mergedKeys[$i]) -Force
    }
    return @($kept)
}

# Store packages a user installed: no frameworks, resource packs or bundles, nothing
# signed as or living in Windows, no Microsoft.Windows.* and none Windows stands on.
function Test-ListableAppxPackage {
    param($Package)

    $name = [string](Get-MoleProperty $Package 'Name')
    if (-not $name) { return $false }
    if ((Get-MoleProperty $Package 'IsFramework') -eq $true) { return $false }
    if ((Get-MoleProperty $Package 'IsResourcePackage') -eq $true) { return $false }
    if ((Get-MoleProperty $Package 'IsBundle') -eq $true) { return $false }
    if ([string](Get-MoleProperty $Package 'SignatureKind') -eq 'System') { return $false }
    if ($name.StartsWith('Microsoft.Windows.', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($script:ProtectedPackageNames -contains $name) { return $false }
    if (Test-ProtectedApp $name) { return $false }

    $location = Get-NormalizedFolderPath -Path ([string](Get-MoleProperty $Package 'InstallLocation'))
    $windows = Get-NormalizedFolderPath -Path $env:SystemRoot
    if ($location -and $windows -and ($location -eq $windows -or
            $location.StartsWith($windows + '\', [StringComparison]::OrdinalIgnoreCase))) {
        return $false
    }
    return $true
}

# Cached display rows never authorize removal. Read the exact current package,
# narrowing the provider query by its literal name, then require the full identity.
function Test-MoleStoreRemovalAllowed {
    param([string]$PackageFullName)

    if ([string]::IsNullOrWhiteSpace($PackageFullName)) { return $false }
    $name = ($PackageFullName -split '_', 2)[0]
    try {
        $packages = @(Get-AppxPackage -Name ([WildcardPattern]::Escape($name)) -ErrorAction Stop |
            Where-Object { [string](Get-MoleProperty $_ 'PackageFullName') -eq $PackageFullName })
        if ($packages.Count -ne 1) { return $false }
        if (-not (Test-ListableAppxPackage -Package $packages[0])) { return $false }
        $manifest = Get-AppxPackageManifest -Package $PackageFullName -ErrorAction Stop
        return (Test-RemovableAppxManifest -Manifest $manifest)
    }
    catch { return $false }
}

# A package with external location (a sparse package) is shell integration a desktop
# app registers, such as WinMerge's Windows 11 context menu; that app's own uninstaller
# removes it, so it is not a separate app. Unknown manifest evidence retains it.
function Test-RemovableAppxManifest {
    param($Manifest)

    if ($Manifest -isnot [System.Xml.XmlNode]) { return $false }
    $properties = $Manifest.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Properties']")
    if ($null -eq $properties) { return $false }
    $node = $properties.SelectSingleNode("*[local-name()='AllowExternalContent']")
    if ($null -eq $node) { return $true }
    $value = $node.InnerText.Trim()
    return ($value -eq 'false' -or $value -eq '0')
}

# The size the menu shows: a 0B that was never measured is Unknown, not empty.
function Get-AppDisplaySize {
    param($App)

    $size = [string](Get-MoleProperty $App 'SizeHuman')
    if (-not $size -or ($size -eq '0B' -and -not (Get-MoleProperty $App 'SizeChecked'))) { return 'Unknown' }
    return $size
}

# Identifies an app in the menu: two different apps may share one display name.
function Get-AppSelectionKey {
    param($App)

    $package = [string](Get-MoleProperty $App 'PackageFullName')
    if ($package) { return "package:$package" }
    $key = [string](Get-MoleProperty $App 'RegistryKey')
    # The scan stores the provider-qualified PSPath; the key reads without the provider.
    if ($key) { return "registry:$($key -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')" }
    return "name:$($App.Name)"
}

# ============================================================================
# Uninstaller Planning
# ============================================================================

# Splits a registered command into the program and its arguments. A quoted program is
# taken as quoted; an unquoted path resolves to the longest prefix that is an existing
# file, as CreateProcess does; a bare name is left for PATH. $null when the named
# program does not exist.
function Split-UninstallCommand {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $text = [Environment]::ExpandEnvironmentVariables($Command).Trim()

    if ($text.StartsWith('"')) {
        $end = $text.IndexOf('"', 1)
        if ($end -lt 0) { return $null }
        $file = $text.Substring(1, $end - 1)
        $rest = $text.Substring($end + 1).Trim()
        if ($file -match '^[A-Za-z]:\\' -and -not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
        return [PSCustomObject]@{ FilePath = $file; Arguments = $rest }
    }

    if ($text -notmatch '^[A-Za-z]:\\') {
        $space = $text.IndexOf(' ')
        if ($space -lt 0) { return [PSCustomObject]@{ FilePath = $text; Arguments = "" } }
        return [PSCustomObject]@{ FilePath = $text.Substring(0, $space); Arguments = $text.Substring($space + 1).Trim() }
    }

    if (Test-Path -LiteralPath $text -PathType Leaf) {
        return [PSCustomObject]@{ FilePath = $text; Arguments = "" }
    }
    for ($i = $text.Length - 1; $i -gt 2; $i--) {
        if ($text[$i] -ne ' ') { continue }
        $candidate = $text.Substring(0, $i)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [PSCustomObject]@{ FilePath = $candidate; Arguments = $text.Substring($i + 1).Trim() }
        }
    }
    return $null
}

# The Windows Installer product code, when the entry is an MSI product.
function Get-MsiProductCode {
    param($App)

    $guidPattern = '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}'
    $uninstall = [string](Get-MoleProperty $App 'UninstallString')
    $keyName = [string](Get-MoleProperty $App 'KeyName')
    $isMsi = ((Get-MoleProperty $App 'WindowsInstaller') -eq $true)
    $code = $null
    $match = [regex]::Match($keyName, $guidPattern)
    if ($match.Success) {
        $code = $match.Value.ToUpperInvariant()
    }
    elseif (-not $isMsi) {
        $match = [regex]::Match($uninstall, $guidPattern)
        if ($match.Success) { $code = $match.Value.ToUpperInvariant() }
    }
    if ($code -and $uninstall -match 'msiexec') { $isMsi = $true }
    if ($isMsi -and $code) { return $code }
    return $null
}

# Inno Setup: unins000.exe with its unins000.dat beside it.
function Test-InnoUninstaller {
    param([string]$File)

    if ([System.IO.Path]::GetFileName($File) -notmatch '^unins\d{3}\.exe$') { return $false }
    return (Test-Path -LiteralPath ($File.Substring(0, $File.Length - 4) + '.dat') -PathType Leaf)
}

# NSIS, told by the "Nullsoft" marker in the uninstaller's first MiB, never by its name:
# other uninstall.exe programs may read /S as something else.
function Test-NsisUninstaller {
    param([string]$File)

    if ($File -notmatch '\.exe$' -or -not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($File)
        $buffer = New-Object byte[] 1048576
        $read = $stream.Read($buffer, 0, $buffer.Length)
        return ([System.Text.Encoding]::ASCII.GetString($buffer, 0, $read).Contains('Nullsoft'))
    }
    catch {
        return $false
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

# The Steam client's NSIS uninstaller keeps its window, where Valve warns that the
# games in its library go too.
function Test-SteamClientUninstaller {
    param($App, [string]$File)

    if ($App.Name -ne 'Steam') { return $false }
    $folder = Split-Path -Parent $File
    return ($folder -and (Test-Path -LiteralPath (Join-Path $folder 'steam.exe') -PathType Leaf))
}

# What to start to remove an app, run once: msiexec for MSI products, the vendor's quiet
# command when registered, Inno or NSIS silent switches only when the uninstaller is
# recognised as one, otherwise the registered command as is. $null when nothing runnable.
# The registration is read again right before launch: a command rewritten
# since the user reviewed the list is not run. An unreadable key cannot be
# confirmed and is not run either.
function Test-UninstallLaunchCurrent {
    param($App, $Launch)

    $key = [string](Get-MoleProperty $App 'RegistryKey')
    if ([string]::IsNullOrWhiteSpace($key) -or -not $Launch) { return $false }
    try { $values = Get-ItemProperty -LiteralPath $key -ErrorAction Stop }
    catch { return $false }
    $fresh = $App.PSObject.Copy()
    foreach ($name in @('UninstallString', 'QuietUninstallString')) {
        $text = ([string](Get-MoleProperty $values $name)).Trim()
        $value = $(if ($text) { $text } else { $null })
        if ($fresh.PSObject.Properties[$name]) { $fresh.$name = $value }
        else { $fresh | Add-Member -NotePropertyName $name -NotePropertyValue $value }
    }
    $current = Get-UninstallLaunch -App $fresh
    if (-not $current) { return $false }
    return ([string]$current.FilePath -eq [string]$Launch.FilePath -and
        [string]$current.Arguments -ceq [string]$Launch.Arguments)
}

function Get-UninstallLaunch {
    param($App)

    $productCode = Get-MsiProductCode -App $App
    if ($productCode) {
        return [PSCustomObject]@{
            FilePath  = (Join-Path $env:SystemRoot 'System32\msiexec.exe')
            Arguments = "/x $productCode /passive REBOOT=ReallySuppress /norestart"
            Kind      = 'msi'
        }
    }

    $quiet = Split-UninstallCommand -Command ([string](Get-MoleProperty $App 'QuietUninstallString'))
    # Proton Pass 1.37.0 registers a broken Squirrel -s argument. Use only its
    # verified normal command, never a guessed switch or a second uninstall attempt.
    if ($quiet -and $App.Name -ceq 'Proton Pass' -and
        (Get-MoleProperty $App 'Publisher') -ceq 'Proton AG' -and
        (Get-MoleProperty $App 'Version') -ceq '1.37.0' -and
        $quiet.Arguments -ceq '--uninstall -s' -and
        [IO.Path]::GetFileName($quiet.FilePath) -ieq 'Update.exe') {
        $normal = Split-UninstallCommand -Command ([string](Get-MoleProperty $App 'UninstallString'))
        if ($normal -and $normal.FilePath -ieq $quiet.FilePath -and $normal.Arguments -ceq '--uninstall') {
            return [PSCustomObject]@{ FilePath = $normal.FilePath; Arguments = $normal.Arguments; Kind = 'registered' }
        }
    }
    if ($quiet) {
        return [PSCustomObject]@{ FilePath = $quiet.FilePath; Arguments = $quiet.Arguments; Kind = 'quiet' }
    }

    $command = Split-UninstallCommand -Command ([string](Get-MoleProperty $App 'UninstallString'))
    if (-not $command) { return $null }
    $arguments = $command.Arguments
    $kind = 'registered'
    if (Test-InnoUninstaller -File $command.FilePath) {
        if ($arguments -notmatch 'SILENT') {
            $arguments = ("$arguments /SILENT /SUPPRESSMSGBOXES /NORESTART").Trim()
        }
        $kind = 'inno'
    }
    elseif ($arguments -notmatch '(^|\s)[/-](quiet|passive|silent|q|s)(\s|$)' -and
        (Test-NsisUninstaller -File $command.FilePath) -and
        -not (Test-SteamClientUninstaller -App $App -File $command.FilePath)) {
        $arguments = ("$arguments /S").Trim()
        $kind = 'nsis'
    }
    return [PSCustomObject]@{ FilePath = $command.FilePath; Arguments = $arguments; Kind = $kind }
}

# An uninstall is done once its registry entry is gone or no longer names an app (a name
# plus an uninstall command). A key that cannot be read counts as still installed.
# Keep Start-Process's descendant wait, but bound Mole's wait without killing the
# vendor. Stop cancels the cmdlet pipeline; it is not Stop-Process or taskkill.
# A timeout is never success, even if registration vanished while work continues.
# Thirty minutes is a conservative interactive-uninstall ceiling, not an idle
# threshold. No existing CLI deadline covers vendor uninstallers. The shorter
# injectable deadline is only for tests; callers use the fixed default.
function Invoke-MoleUninstallProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [ValidateRange(1, 1800000)][int]$TimeoutMilliseconds = 1800000
    )

    $runner = [powershell]::Create()
    $pending = $null
    try {
        $null = $runner.AddCommand('Start-Process').AddParameter('FilePath', $FilePath)
        $null = $runner.AddParameter('Wait', $true).AddParameter('PassThru', $true).AddParameter('ErrorAction', 'Stop')
        if ($ArgumentList) { $null = $runner.AddParameter('ArgumentList', $ArgumentList) }
        $pending = $runner.BeginInvoke()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        # Short waits let Ctrl+C unwind this function and cancel the waiting pipeline.
        while (-not $pending.AsyncWaitHandle.WaitOne(250)) {
            if ($clock.Elapsed.TotalMilliseconds -ge $TimeoutMilliseconds) {
                throw [TimeoutException]::new('Uninstaller wait timed out; batch stopped, leftovers kept.')
            }
        }
        $result = @($runner.EndInvoke($pending))
        if ($runner.HadErrors -or $result.Count -ne 1) {
            throw 'Uninstaller completion could not be verified.'
        }
        try { return [pscustomobject]@{ ExitCode = $result[0].ExitCode } }
        finally { $result[0].Dispose() }
    }
    finally {
        # Cleanup errors must not replace timeout/cancellation and let the caller
        # proceed to another app while this vendor may still be running.
        try { if ($null -ne $pending -and -not $pending.IsCompleted) { $runner.Stop() } }
        catch { Write-Debug "Uninstaller wait cancellation failed: $_" }
        try { $runner.Dispose() }
        catch { Write-Debug "Uninstaller wait disposal failed: $_" }
    }
}

function Test-UninstallEntryGone {
    param([string]$KeyPath)

    if ([string]::IsNullOrWhiteSpace($KeyPath)) { return $false }
    try {
        $values = Get-ItemProperty -LiteralPath $KeyPath -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        return $true
    }
    catch {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-MoleProperty $values 'DisplayName'))) { return $true }
    return ([string]::IsNullOrWhiteSpace([string](Get-MoleProperty $values 'UninstallString')) -and
        [string]::IsNullOrWhiteSpace([string](Get-MoleProperty $values 'QuietUninstallString')))
}

# ============================================================================
# Application Discovery
# ============================================================================

# Display-only package measurement. Do not use cleanup snapshots here: a user
# can read a package without FILE_READ_ATTRIBUTES on the WindowsApps parent.
# Nothing from this walk authorizes deletion or changes filesystem permissions.
function Get-AppxInstallSizeKB {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($root.FullName)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $bytes = 0L
        while ($pending.Count -gt 0) {
            if ($timer.Elapsed.TotalSeconds -ge 15) { return $null }
            $directory = Get-Item -LiteralPath $pending.Pop() -Force -ErrorAction Stop
            if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $null }
            foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop)) {
                if ($timer.Elapsed.TotalSeconds -ge 15) { return $null }
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $null }
                if ($item.PSIsContainer) { $pending.Push($item.FullName) }
                else { $bytes += $item.Length }
            }
        }
        return [long][Math]::Ceiling($bytes / 1024)
    }
    catch { return $null }
}

function Get-InstalledApplications {
    <#
    .SYNOPSIS
        Scan and return all installed applications
    #>
    param([switch]$ForceRescan, [switch]$Quiet)

    # Check cache
    if (-not $ForceRescan -and (Test-Path $script:AppCacheFile)) {
        $cacheInfo = Get-Item $script:AppCacheFile
        $cacheAge = (Get-Date) - $cacheInfo.LastWriteTime

        # A cache stamped in the future (the clock was set back) is expired, not fresh.
        if ($cacheAge.TotalHours -ge 0 -and $cacheAge.TotalHours -lt $script:CacheTTLHours) {
            Write-Debug "Loading from cache..."
            try {
                $cached = [System.IO.File]::ReadAllText($script:AppCacheFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                return $cached
            }
            catch {
                Write-Debug "Cache read failed, rescanning..."
            }
        }
    }

    # --list output may be redirected: Write-Host and progress would reach it.
    if (-not $Quiet) { Write-Info "Scanning installed applications..." }

    $apps = @()

    # Registry paths for installed programs
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $count = 0
    $total = $registryPaths.Count

    foreach ($path in $registryPaths) {
        $count++
        if (-not $Quiet) {
            Write-Progress -Activity "Scanning applications" -Status "Registry path $count of $total" -PercentComplete (($count / $total) * 50)
        }

        try {
            $regItems = @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)
        }
        catch {
            Write-Debug "Error scanning registry path $path : $_"
            continue
        }

        foreach ($item in $regItems) {
            try {
                $app = ConvertFrom-UninstallEntry -Entry $item
                if ($app) {
                    $apps += $app
                }
            }
            catch {
                Write-Debug "Skipping unreadable uninstall entry: $_"
            }
        }
    }

    $apps = @(Merge-InstalledApps -Apps $apps)

    # UWP / Store Apps
    if (-not $Quiet) {
        Write-Progress -Activity "Scanning applications" -Status "Scanning Windows Apps" -PercentComplete 75
    }

    try {
        $uwpApps = @(Get-AppxPackage -ErrorAction SilentlyContinue |
                   Where-Object { Test-ListableAppxPackage -Package $_ })

        foreach ($uwp in $uwpApps) {
            # Get friendly name
            $name = $uwp.Name
            $manifest = $null
            try {
                $manifest = Get-AppxPackageManifest -Package $uwp.PackageFullName -ErrorAction Stop
                if ($manifest.Package.Properties.DisplayName -and
                    -not $manifest.Package.Properties.DisplayName.StartsWith("ms-resource:")) {
                    $name = $manifest.Package.Properties.DisplayName
                }
            }
            catch { }
            if (-not (Test-RemovableAppxManifest -Manifest $manifest)) {
                Write-Debug "Keeping package with external or unknown manifest evidence: $($uwp.PackageFullName)"
                continue
            }

            # Calculate size
            $measuredKB = Get-AppxInstallSizeKB -Path $uwp.InstallLocation
            $sizeKB = if ($null -eq $measuredKB) { 0L } else { $measuredKB }

            $apps += [PSCustomObject]@{
                Name = $name
                Publisher = $uwp.Publisher
                Version = $uwp.Version
                SizeKB = $sizeKB
                SizeHuman = Format-ByteSize -Bytes ($sizeKB * 1024)
                SizeChecked = ($null -ne $measuredKB)
                InstallLocation = $uwp.InstallLocation
                UninstallString = $null
                QuietUninstallString = $null
                WindowsInstaller = $false
                RegistryKey = $null
                KeyName = $null
                PackageFullName = $uwp.PackageFullName
                InstallDate = $null
                Source = "WindowsStore"
            }
        }
    }
    catch {
        Write-Debug "Could not enumerate UWP apps: $_"
    }

    if (-not $Quiet) { Write-Progress -Activity "Scanning applications" -Completed }

    # Sort by size (largest first)
    $apps = $apps | Sort-Object -Property SizeKB -Descending

    # Cache results
    if (-not (Test-Path $script:CacheDir)) {
        New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
    }
    # UTF-8 explicitly: Set-Content in Windows PowerShell 5.1 writes the ANSI
    # code page, which cannot hold most non-ASCII app names.
    [System.IO.File]::WriteAllText($script:AppCacheFile, [string]($apps | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))

    return $apps
}

# ============================================================================
# Application Selection UI
# ============================================================================

function Read-MenuKey {
    return [Console]::ReadKey($true)
}

function Show-AppSelectionMenu {
    <#
    .SYNOPSIS
        Interactive menu for selecting applications to uninstall
    #>
    param([array]$Apps)

    if ($Apps.Count -eq 0) {
        Write-MoleWarning "No applications found to uninstall"
        return @()
    }

    $esc = [char]27
    $selectedIndices = @{}
    $currentIndex = 0
    $pageSize = 15
    $pageStart = 0
    $searchTerm = ""
    $filteredApps = $Apps

    # Hide cursor (may fail in non-interactive terminals)
    try { [Console]::CursorVisible = $false } catch { }

    try {
        while ($true) {
            Clear-MoleScreen

            # Header
            Write-Host ""
            Write-Host "$esc[1;35mSelect Applications to Uninstall$esc[0m"
            Write-Host ""
            Write-Host "$esc[90mUse: $($script:Icons.NavUp)$($script:Icons.NavDown) navigate | Space select | Enter confirm | Q quit | / search$esc[0m"
            Write-Host ""

            # Search indicator
            if ($searchTerm) {
                Write-Host "$esc[33mSearch:$esc[0m $searchTerm ($($filteredApps.Count) matches)"
                Write-Host ""
            }

            # Display apps
            $pageEnd = [Math]::Min($pageStart + $pageSize, $filteredApps.Count)

            for ($i = $pageStart; $i -lt $pageEnd; $i++) {
                $app = $filteredApps[$i]
                $isSelected = $selectedIndices.ContainsKey((Get-AppSelectionKey $app))
                $isCurrent = ($i -eq $currentIndex)

                # Selection indicator
                $checkbox = if ($isSelected) { "$esc[32m[$($script:Icons.Success)]$esc[0m" } else { "[ ]" }

                # Highlight current
                if ($isCurrent) {
                    Write-Host "$esc[7m" -NoNewline  # Reverse video
                }

                # App info uses terminal cells for both truncation and padding.
                $entry = Format-SizeListEntry -Name $app.Name -Size (Get-AppDisplaySize $app)
                Write-Host "  $checkbox $entry" -NoNewline

                if ($isCurrent) {
                    Write-Host "$esc[0m"  # Reset
                }
                else {
                    Write-Host ""
                }
            }

            # Footer
            Write-Host ""
            $selectedCount = $selectedIndices.Count
            if ($selectedCount -gt 0) {
                $totalSize = 0
                foreach ($app in $Apps) {
                    if ($selectedIndices.ContainsKey((Get-AppSelectionKey $app)) -and $app.SizeKB) {
                        $totalSize += $app.SizeKB
                    }
                }
                $totalSizeHuman = Format-ByteSize -Bytes ($totalSize * 1024)
                $noun = if ($selectedCount -eq 1) { 'app' } else { 'apps' }
                Write-Host "$esc[33mSelected:$esc[0m $selectedCount $noun ($totalSizeHuman)"
            }

            # Page indicator
            $totalPages = [Math]::Ceiling($filteredApps.Count / $pageSize)
            $currentPage = [Math]::Floor($pageStart / $pageSize) + 1
            Write-Host "$esc[90mPage $currentPage of $totalPages$esc[0m"

            # Handle input
            $key = Read-MenuKey

            switch ($key.Key) {
                'UpArrow' {
                    if ($currentIndex -gt 0) {
                        $currentIndex--
                        if ($currentIndex -lt $pageStart) {
                            $pageStart = [Math]::Max(0, $pageStart - $pageSize)
                        }
                    }
                }
                'DownArrow' {
                    if ($currentIndex -lt $filteredApps.Count - 1) {
                        $currentIndex++
                        if ($currentIndex -ge $pageStart + $pageSize) {
                            $pageStart += $pageSize
                        }
                    }
                }
                'PageUp' {
                    $pageStart = [Math]::Max(0, $pageStart - $pageSize)
                    $currentIndex = $pageStart
                }
                'PageDown' {
                    $pageStart = [Math]::Min($filteredApps.Count - $pageSize, $pageStart + $pageSize)
                    if ($pageStart -lt 0) { $pageStart = 0 }
                    $currentIndex = $pageStart
                }
                'Spacebar' {
                    $selectionKey = Get-AppSelectionKey $filteredApps[$currentIndex]
                    if ($selectedIndices.ContainsKey($selectionKey)) {
                        $selectedIndices.Remove($selectionKey)
                    }
                    else {
                        $selectedIndices[$selectionKey] = $true
                    }
                }
                'Enter' {
                    if ($selectedIndices.Count -gt 0) {
                        # Return selected apps
                        $selected = $Apps | Where-Object { $selectedIndices.ContainsKey((Get-AppSelectionKey $_)) }
                        return $selected
                    }
                }
                'Escape' {
                    return @()
                }
                'Q' {
                    return @()
                }
                'Oem2' {  # Forward slash
                    # Search mode
                    Write-Host ""
                    Write-Host "Search: " -NoNewline
                    try { [Console]::CursorVisible = $true } catch { }
                    $searchTerm = Read-Host
                    try { [Console]::CursorVisible = $false } catch { }

                    if ($searchTerm) {
                        # One match is a single object, and strict mode has no
                        # .Count on it; keep the filtered list an array.
                        $filteredApps = @($Apps | Where-Object { Test-AppNameMatchesSearch -Name $_.Name -Search $searchTerm })
                    }
                    else {
                        $filteredApps = $Apps
                    }
                    $currentIndex = 0
                    $pageStart = 0
                }
                'Backspace' {
                    if ($searchTerm) {
                        $searchTerm = ""
                        $filteredApps = $Apps
                        $currentIndex = 0
                        $pageStart = 0
                    }
                }
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch { }
    }
}

# ============================================================================
# Read-only Listing
# ============================================================================

# Separate so tests can choose the output form without redirecting the host.
function Test-UninstallListAsJson {
    return [Console]::IsOutputRedirected
}

# The menu's inventory as records for scripts and agents, field for field with
# the macOS CLI where Windows has the same fact. id is the menu's selection key.
function ConvertTo-UninstallListRecord {
    param($App)

    $display = Get-AppDisplaySize $App
    $sizeBytes = $null
    if ($display -ne 'Unknown') { $sizeBytes = [long](Get-MoleProperty $App 'SizeKB') * 1024 }
    $location = [string](Get-MoleProperty $App 'InstallLocation')
    return [ordered]@{
        name       = [string]$App.Name
        id         = Get-AppSelectionKey $App
        source     = [string](Get-MoleProperty $App 'Source')
        version    = $(if (Get-MoleProperty $App 'Version') { [string](Get-MoleProperty $App 'Version') } else { $null })
        publisher  = $(if (Get-MoleProperty $App 'Publisher') { [string](Get-MoleProperty $App 'Publisher') } else { $null })
        path       = $location
        size       = $display
        size_bytes = $sizeBytes
    }
}

# A JSON array whatever the count. Non-ASCII characters are written as \u
# escapes, so a console code page cannot change an app name on the way out.
function ConvertTo-UninstallListJson {
    param([array]$Apps)

    $records = @(foreach ($app in @($Apps)) { if ($null -ne $app) { ConvertTo-UninstallListRecord $app } })
    if ($records.Count -eq 0) { return '[]' }
    $json = ConvertTo-Json -InputObject $records -Depth 3
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

# mo uninstall --list: print the inventory and return. It runs no uninstaller,
# asks for no elevation and writes no operations.log line; like the menu it
# reuses the 24-hour app cache unless --rescan is given.
function Show-UninstallList {
    param([switch]$ForceRescan)

    $apps = @(Get-InstalledApplications -ForceRescan:$ForceRescan -Quiet)
    if (Test-UninstallListAsJson) {
        Write-Output (ConvertTo-UninstallListJson -Apps $apps)
        return
    }
    if ($apps.Count -eq 0) {
        Write-Host "No applications found."
        return
    }
    Write-Host ""
    foreach ($app in $apps) {
        Write-Host ("  " + (Format-SizeListEntry -Name $app.Name -Size (Get-AppDisplaySize $app)))
    }
    Write-Host ""
    Write-Host "$($apps.Count) application(s)"
    Write-Host ""
}

# ============================================================================
# Uninstallation
# ============================================================================

# How an app would be removed, for the dry-run preview.
function Get-UninstallMethodDescription {
    param($App)

    if ($App.Source -eq "WindowsStore") {
        return "Remove-AppxPackage $($App.PackageFullName)"
    }
    $productCode = Get-MsiProductCode -App $App
    if ($productCode) {
        return "msiexec /x $productCode"
    }
    $launch = Get-UninstallLaunch -App $App
    if ($launch) {
        return "its uninstaller: $(("$($launch.FilePath) $($launch.Arguments)").Trim())"
    }
    $uninstallString = [string](Get-MoleProperty $App 'UninstallString')
    if ($uninstallString) {
        return "no runnable uninstaller, registered: $uninstallString"
    }
    return "no uninstall command registered"
}

# These public identities name apps that manage firmware charging thresholds.
# This only explains the consequence; it never authorizes or refuses removal.
function Show-UninstallChargeLimitNote {
    param($App)

    $source = [string](Get-MoleProperty $App 'Source')
    $setsLimit = $false
    if ($source -eq 'WindowsStore') {
        $identity = ([string](Get-MoleProperty $App 'PackageFullName') -split '_', 2)[0]
        $setsLimit = $identity -in @(
            'E046963F.LenovoCompanion', 'LenovoCompanyLimited.LenovoVantageService',
            'B9ECED6F.ASUSPCAssistant', 'Microsoft.SurfaceHub'
        )
    }
    elseif ($source -eq 'Registry') {
        $name = ([string](Get-MoleProperty $App 'Name')).Trim()
        $publisher = ([string](Get-MoleProperty $App 'Publisher')).Trim()
        $setsLimit = $name -eq 'Lenovo Vantage Service' -and $publisher -match '^Lenovo(?:\s|$)'
    }
    if ($setsLimit) {
        Write-Host '    The charge limit stays after uninstall. Change it in this app first if needed.'
    }
}

# The display name alone cannot say which install an uninstall row was about,
# so each row also carries the folder, the registry entry and the command run.
function Get-UninstallOperationDetail {
    param($App, [string]$Outcome, $Launch)

    $parts = @($Outcome)
    $folder = [string](Get-MoleProperty $App 'InstallLocation')
    if ($folder) { $parts += "location $folder" }
    $key = [string](Get-MoleProperty $App 'RegistryKey')
    if ($key) { $parts += "key $($key -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')" }
    $package = [string](Get-MoleProperty $App 'PackageFullName')
    if ($package) { $parts += "package $package" }
    if ($Launch) {
        $command = @(@($Launch.FilePath) + @($Launch.Arguments) | Where-Object { $_ }) -join ' '
        $parts += "command $command"
    }
    else {
        $registered = [string](Get-MoleProperty $App 'UninstallString')
        if ($registered) { $parts += "registered $registered" }
    }
    return $parts -join '; '
}

function Uninstall-SelectedApps {
    <#
    .SYNOPSIS
        Uninstall the selected applications
    #>
    param([array]$Apps)

    $esc = [char]27

    # A dry run runs no uninstaller and removes nothing. It names the install folder
    # only when that folder could be removed after a real uninstall; Remove-SafeItem
    # only reports it in dry-run mode.
    if ($script:MoleDryRunMode) {
        Write-Host ""
        Write-Host "$esc[1;35mUninstall preview$esc[0m - no changes made"
        Write-Host ""
        $previewCount = 0
        foreach ($app in $Apps) {
            if ($app.Source -eq "WindowsStore" -and -not (Test-MoleStoreRemovalAllowed -PackageFullName ([string](Get-MoleProperty $app 'PackageFullName')))) { continue }
            $previewCount++
            Write-Host "$esc[34m$($script:Icons.Arrow)$esc[0m $($app.Name)"
            Write-Host "  $esc[90mWould uninstall with $(Get-UninstallMethodDescription -App $app)$esc[0m"
            Show-UninstallChargeLimitNote -App $app
            $folder = [string](Get-MoleProperty $app 'InstallLocation')
            if ($app.Source -ne "WindowsStore" -and (Test-MoleLeftoverOwnership -Path $folder -App $app -Preview)) {
                $guard = { param($candidate) Test-MoleLeftoverOwnership -Path $candidate -App $app -Preview }
                $null = Remove-SafeItem -Path $folder -Description "Leftover files to Recycle Bin" -Recurse -Recycle -Guard $guard
            }
        }
        Show-SummaryBlock -Heading 'Dry run complete - no changes made' -Details @("Would uninstall: $previewCount")
        return
    }

    Write-Host ""
    Write-Host "$esc[1;35mUninstalling Applications$esc[0m"
    Write-Host ""

    $successCount = 0
    $failCount = 0
    $remainingCount = 0
    $ranUninstaller = $false

    foreach ($app in $Apps) {
        if ($app.Source -eq "WindowsStore" -and -not (Test-MoleStoreRemovalAllowed -PackageFullName ([string](Get-MoleProperty $app 'PackageFullName')))) {
            Write-MoleOperation -Action "SKIPPED" -Path $app.Name -Detail (Get-UninstallOperationDetail -App $app -Outcome "current Store package not eligible")
            Write-Host "$esc[33m$($script:Icons.Arrow)$esc[0m Kept: $($app.Name) $esc[33m(current Store package not eligible)$esc[0m"
            $remainingCount++
            continue
        }
        Write-Host "$esc[34m$($script:Icons.Arrow)$esc[0m Uninstalling: $($app.Name)" -NoNewline

        $launch = $null
        try {
            if ($app.Source -eq "WindowsStore") {
                # UWP app
                if ($app.PackageFullName) {
                    Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop
                    Write-MoleOperation -Action "UNINSTALLED" -Path $app.Name -Detail (Get-UninstallOperationDetail -App $app -Outcome "Store package removed")
                    Write-Host " $esc[32m$($script:Icons.Success)$esc[0m"
                    $successCount++
                }
                continue
            }

            # Registry app: run its uninstaller once, then trust only the registry.
            $launch = Get-UninstallLaunch -App $app
            if (-not $launch) {
                Write-MoleOperation -Action "FAILED" -Path $app.Name -Detail (Get-UninstallOperationDetail -App $app -Outcome "no runnable uninstaller")
                Write-Host " $esc[31m(no runnable uninstaller found)$esc[0m"
                $failCount++
                continue
            }
            # An uninstaller an earlier row ran may already have removed this
            # entry; that is done, not a changed command. Without one, the app
            # may have moved to a new entry (a self-update), so it is not done.
            if (Test-UninstallEntryGone -KeyPath ([string](Get-MoleProperty $app 'RegistryKey'))) {
                if ($ranUninstaller) {
                    Write-MoleOperation -Action "UNINSTALLED" -Path $app.Name -Detail (Get-UninstallOperationDetail -App $app -Outcome "already removed, not run" -Launch $launch)
                    Write-Host " $esc[32m$($script:Icons.Success)$esc[0m $esc[90m(already removed)$esc[0m"
                    $successCount++
                }
                else {
                    Write-MoleOperation -Action "SKIPPED" -Path $app.Name -Detail (Get-UninstallOperationDetail -App $app -Outcome "no longer registered, not run" -Launch $launch)
                    Write-Host " $esc[33m(no longer registered, not run)$esc[0m"
                    $remainingCount++
                }
                continue
            }
            if (-not (Test-UninstallLaunchCurrent -App $app -Launch $launch)) {
                Write-MoleOperation -Action "FAILED" -Path $app.Name -Detail (Get-UninstallOperationDetail -App $app -Outcome "uninstall command changed since review, not run" -Launch $launch)
                Write-Host " $esc[31m(uninstall command changed since review, not run)$esc[0m"
                $failCount++
                continue
            }

            $startArgs = @{ FilePath = $launch.FilePath }
            if ($launch.Arguments) {
                $startArgs.ArgumentList = $launch.Arguments
            }
            $ranUninstaller = $true
            $process = Invoke-MoleUninstallProcess @startArgs
            $exitCode = Get-MoleProperty $process 'ExitCode'

            # A cancelled, failed or still-running uninstall leaves its entry behind, and
            # then the install folder is still the app's: nothing is removed.
            if (-not (Test-UninstallEntryGone -KeyPath ([string](Get-MoleProperty $app 'RegistryKey')))) {
                Write-MoleOperation -Action "FAILED" -Path $app.Name -Detail (Get-UninstallOperationDetail -App $app -Outcome "still installed, exit code $exitCode" -Launch $launch)
                Write-Host " $esc[33m(still installed, exit code $exitCode)$esc[0m"
                $remainingCount++
                continue
            }

            Write-MoleOperation -Action "UNINSTALLED" -Path $app.Name -Detail (Get-UninstallOperationDetail -App $app -Outcome "exit code $exitCode" -Launch $launch)
            Write-Host " $esc[32m$($script:Icons.Success)$esc[0m"
            $successCount++

            # Clean leftover files
            $folder = [string](Get-MoleProperty $app 'InstallLocation')
            if (Test-MoleLeftoverOwnership -Path $folder -App $app) {
                Write-Host "  $esc[90mMoving leftover files to Recycle Bin...$esc[0m"
                $guard = { param($candidate) Test-MoleLeftoverOwnership -Path $candidate -App $app }
                $null = Remove-SafeItem -Path $folder -Description "Leftover files to Recycle Bin" -Recurse -Recycle -Guard $guard
            }
        }
        catch [TimeoutException] {
            Write-Host " $esc[31m$($_.Exception.Message)$esc[0m"
            Write-MoleOperation -Action "FAILED" -Path $app.Name -Detail (Get-UninstallOperationDetail -App $app -Outcome $_.Exception.Message -Launch $launch)
            $failCount++
            # Do not overlap the next uninstaller with the still-running vendor.
            break
        }
        catch {
            Write-Host " $esc[31m$($script:Icons.Error)$esc[0m"
            Write-Debug "Uninstall failed: $_"
            Write-MoleOperation -Action "FAILED" -Path $app.Name -Detail (Get-UninstallOperationDetail -App $app -Outcome $_.Exception.Message -Launch $launch)
            $failCount++
        }
    }

    $details = @("Successfully uninstalled: $successCount")
    if ($remainingCount -gt 0) { $details += "Still installed: $remainingCount" }
    if ($failCount -gt 0) { $details += "Failed: $failCount" }
    $script:MoleUninstallIncomplete = ($remainingCount -gt 0 -or $failCount -gt 0)
    $heading = if ($script:MoleUninstallIncomplete) { 'Uninstall incomplete' } else { 'Uninstall complete' }
    Show-SummaryBlock -Heading $heading -Details $details

    # Clear cache
    if (Test-Path $script:AppCacheFile) {
        Remove-Item $script:AppCacheFile -Force -ErrorAction SilentlyContinue
    }
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
        Show-UninstallHelp
        return
    }

    # Read-only: before dry-run setup, the screen clear and any uninstaller.
    if ($List) {
        Show-UninstallList -ForceRescan:$Rescan
        return
    }

    if ($DryRun) {
        $env:MOLE_DRY_RUN = "1"
        Set-DryRunMode -Enabled $true
    }

    # Clear screen
    Clear-MoleScreen

    # Get installed apps
    $apps = @(Get-InstalledApplications -ForceRescan:$Rescan)

    if ($apps.Count -eq 0) {
        Write-MoleWarning "No applications found"
        return
    }

    Write-Info "Found $($apps.Count) applications"

    # Show selection menu
    $selected = @(Show-AppSelectionMenu -Apps $apps)

    if ($selected.Count -eq 0) {
        Write-Info "No applications selected"
        return
    }

    # Confirm uninstall
    $esc = [char]27
    Clear-MoleScreen
    Write-Host ""
    if ($script:MoleDryRunMode) {
        Write-Host "$esc[33mDry run: the following applications would be uninstalled:$esc[0m"
    }
    else {
        Write-Host "$esc[33mThe following applications will be uninstalled:$esc[0m"
    }
    Write-Host ""

    foreach ($app in $selected) {
        Write-Host "  $($script:Icons.List) $($app.Name) ($($app.SizeHuman))"
        Show-UninstallChargeLimitNote -App $app
    }

    Write-Host ""
    $confirm = Read-Host "Continue? (y/N)"

    if ($confirm -eq 'y' -or $confirm -eq 'Y') {
        Uninstall-SelectedApps -Apps $selected
    }
    else {
        Write-Info "Cancelled"
    }
}

# Run main. An app still installed or failed exits 1; the explicit 0 keeps a
# vendor uninstaller's exit code from becoming Mole's.
$script:MoleUninstallIncomplete = $false
try { Main } finally { Stop-Spinner }
if ($script:MoleUninstallIncomplete) { exit 1 }
exit 0
