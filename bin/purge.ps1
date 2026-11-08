# Mole - Purge Command
# Aggressive cleanup of project build artifacts

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('dry-run')]
    [switch]$DryRun,

    [Alias('d')]
    [switch]$DebugMode,
    
    [Alias('p')]
    [switch]$Paths,
    
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

$script:DefaultSearchPaths = @(
    "$env:USERPROFILE\Documents"
    "$env:USERPROFILE\Projects"
    "$env:USERPROFILE\Code"
    "$env:USERPROFILE\Development"
    "$env:USERPROFILE\Developer"
    "$env:USERPROFILE\workspace"
    "$env:USERPROFILE\github"
    "$env:USERPROFILE\repos"
    "$env:USERPROFILE\src"
    "D:\Projects"
    "D:\Code"
    "D:\Development"
)

$script:ConfigFile = "$env:USERPROFILE\.config\mole\purge_paths.txt"

# Artifact patterns to clean
$script:ArtifactPatterns = @(
    @{ Name = "node_modules"; Type = "Directory"; Language = "JavaScript/Node.js" }
    @{ Name = "vendor"; Type = "Directory"; Language = "PHP/Go" }
    @{ Name = ".venv"; Type = "Directory"; Language = "Python" }
    @{ Name = "venv"; Type = "Directory"; Language = "Python" }
    @{ Name = "__pycache__"; Type = "Directory"; Language = "Python" }
    @{ Name = ".pytest_cache"; Type = "Directory"; Language = "Python" }
    @{ Name = "target"; Type = "Directory"; Language = "Rust/Java" }
    @{ Name = "build"; Type = "Directory"; Language = "General" }
    @{ Name = "dist"; Type = "Directory"; Language = "General" }
    @{ Name = ".next"; Type = "Directory"; Language = "Next.js" }
    @{ Name = ".nuxt"; Type = "Directory"; Language = "Nuxt.js" }
    @{ Name = ".turbo"; Type = "Directory"; Language = "Turborepo" }
    @{ Name = ".parcel-cache"; Type = "Directory"; Language = "Parcel" }
    @{ Name = "bin"; Type = "Directory"; Language = ".NET" }
    @{ Name = "obj"; Type = "Directory"; Language = ".NET" }
    @{ Name = ".gradle"; Type = "Directory"; Language = "Java/Gradle" }
    @{ Name = "*.log"; Type = "File"; Language = "Logs" }
)

$script:TotalSizeCleaned = 0
$script:ItemsCleaned = 0

# ============================================================================
# Help
# ============================================================================

function Show-PurgeHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mmo purge$esc[0m - Clean project build artifacts"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m mo purge [options]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  --dry-run    Show what would be removed, change nothing"
    Write-Host "  --paths      Edit custom scan directories"
    Write-Host "  --debug      Enable debug logging"
    Write-Host "  --help       Show this help message"
    Write-Host ""
    Write-Host "$esc[33mDefault Search Paths:$esc[0m"
    foreach ($path in $script:DefaultSearchPaths) {
        if (Test-Path $path) {
            Write-Host "  $esc[32m+$esc[0m $path"
        }
        else {
            Write-Host "  $esc[90m-$esc[0m $path (not found)"
        }
    }
    Write-Host ""
    Write-Host "$esc[33mArtifacts Cleaned:$esc[0m"
    Write-Host "  node_modules, vendor, venv, target, build, dist, __pycache__, etc."
    Write-Host ""
}

# ============================================================================
# Path Management
# ============================================================================

function Get-SearchPaths {
    <#
    .SYNOPSIS
        Get list of paths to scan for projects
    #>

    $paths = @()

    # Load custom paths if available
    if (Test-Path $script:ConfigFile) {
        # A config that exists but cannot be read must not silently widen the scan to the defaults.
        try {
            $configLines = @(Get-Content -LiteralPath $script:ConfigFile -ErrorAction Stop)
        }
        catch {
            throw "Cannot read your purge paths: $($script:ConfigFile). Check its permissions, then run mo purge again"
        }
        $customPaths = $configLines |
                       Where-Object { $_ -and -not $_.StartsWith('#') } |
                       ForEach-Object { $_.Trim() }

        foreach ($path in $customPaths) {
            if (Test-Path $path) {
                $paths += $path
            }
        }
    }

    # Add default paths if no custom paths or custom paths don't exist
    if ($null -eq $paths -or @($paths).Count -eq 0) {
        foreach ($path in $script:DefaultSearchPaths) {
            if (Test-Path $path) {
                $paths += $path
            }
        }
    }

    return $paths
}

function Edit-SearchPaths {
    <#
    .SYNOPSIS
        Open search paths configuration for editing
    #>

    $configDir = Split-Path -Parent $script:ConfigFile

    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    if (-not (Test-Path $script:ConfigFile)) {
        $defaultContent = @"
# Mole Purge - Custom Search Paths
# Add directories to scan for project artifacts (one per line)
# Lines starting with # are ignored
#
# Examples:
# D:\MyProjects
# E:\Work\Code
#
# Default paths (used if this file is empty):
# $env:USERPROFILE\Documents
# $env:USERPROFILE\Projects
# $env:USERPROFILE\Code

"@
        Set-Content -Path $script:ConfigFile -Value $defaultContent
    }

    Write-Info "Opening paths configuration: $($script:ConfigFile)"
    Start-Process notepad.exe -ArgumentList $script:ConfigFile -Wait

    Write-Success "Configuration saved"
}

# ============================================================================
# Project Discovery
# ============================================================================

# Run only read-only Git queries. The child must not inherit a redirected index,
# repository, pathspec mode, configuration or fsmonitor hook from the caller.
function Invoke-PurgeGit {
    param([string]$ProjectPath, [string[]]$Arguments)
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) { return $null }
    $quote = {
        param([string]$Value)
        $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        return '"' + $escaped + '"'
    }
    $words = @('-c', 'core.fsmonitor=false', '-C', $ProjectPath) + $Arguments
    $process = New-Object Diagnostics.Process
    $process.StartInfo = New-Object Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $git.Source
    $process.StartInfo.Arguments = ($words | ForEach-Object { & $quote $_ }) -join ' '
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $process.StartInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($key in @($process.StartInfo.EnvironmentVariables.Keys)) {
        if ($key -like 'GIT_*') { $process.StartInfo.EnvironmentVariables.Remove($key) }
    }
    $process.StartInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    $process.StartInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = '/dev/null'
    $process.StartInfo.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            $process.Kill()
            return $null
        }
        if (-not $stdout.Wait(1000) -or -not $stderr.Wait(1000) -or $process.ExitCode -ne 0) { return $null }
        return @{ Output = $stdout.Result }
    }
    catch { return $null }
    finally { $process.Dispose() }
}

function Test-PurgeArtifactKind {
    param([string]$ProjectPath, [string]$Name)
    try {
        $files = @(Get-ChildItem -LiteralPath $ProjectPath -File -Force -ErrorAction Stop)
        $names = @($files | ForEach-Object Name)
        switch ($Name) {
            '.idea' { return $false }
            'bin' { return @($names -match '\.(cs|fs|vb)proj$').Count -gt 0 }
            'obj' { return @($names -match '\.(cs|fs|vb)proj$').Count -gt 0 }
            'target' { return $names -contains 'Cargo.toml' -or $names -contains 'pom.xml' }
            'vendor' { return $names -contains 'go.mod' -or $names -contains 'composer.json' }
            { $_ -eq 'build' -or $_ -eq 'dist' } {
                if ($Name -eq 'build' -and ($names -contains 'build.gradle' -or $names -contains 'build.gradle.kts' -or $names -contains 'CMakeLists.txt')) { return $true }
                if ($names -contains 'setup.py') { return $true }
                if ($names -contains 'pyproject.toml') {
                    if ((Get-Content -LiteralPath (Join-Path $ProjectPath 'pyproject.toml') -Raw -ErrorAction Stop) -match '(?m)^\s*\[build-system\]') { return $true }
                }
                if ($names -contains 'package.json') {
                    $package = Get-Content -LiteralPath (Join-Path $ProjectPath 'package.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($package.PSObject.Properties['scripts'] -and $package.scripts -and $package.scripts.PSObject.Properties['build']) {
                        return $package.scripts.build -is [string] -and -not [string]::IsNullOrWhiteSpace($package.scripts.build)
                    }
                }
                return $false
            }
            default { return $true }
        }
    }
    catch { return $false }
}

# Eligibility is checked at discovery and again after the delete helper sizes
# the candidate. Neither a familiar directory name nor Git ignore state proves
# that its contents are disposable.
function Test-PurgeArtifactContent {
    param([string]$ProjectPath, [string]$Path)
    try {
        $snapshot = Get-MolePathSnapshot -Path $Path
        if (-not $snapshot -or -not (Test-PurgeArtifactKind $ProjectPath ([IO.Path]::GetFileName($Path)))) { return $false }
        $project = [IO.Path]::GetFullPath($ProjectPath).TrimEnd('\')
        if (-not [string]::Equals([IO.Path]::GetDirectoryName($snapshot.Path), $project, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (Test-Path -LiteralPath $Path -PathType Container) {
            foreach ($child in Get-TreeItemsNoFollow -Path $Path) {
                if ($child.Name -eq '.git') { return $false }
            }
        }
        # Determine repository membership without turning a failed Git command
        # into evidence that this is an unversioned directory.
        $ancestor = $project
        $hasRepository = $false
        while ($ancestor) {
            if (-not (Get-MolePathSnapshot -Path $ancestor)) { return $false }
            try {
                # PS 5.1's provider can return null without an error for a
                # missing literal child of a bracket-named directory. Read the
                # filesystem attribute directly, preserving unknown failures.
                $null = [IO.File]::GetAttributes((Join-Path $ancestor '.git'))
                $hasRepository = $true
                break
            }
            catch {
                $failure = $_.Exception
                while ($failure.InnerException) { $failure = $failure.InnerException }
                $code = $failure.HResult -band 0xFFFF
                if ($code -ne 2 -and $code -ne 3) { return $false }
            }
            $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        }
        if ($hasRepository) {
            $root = Invoke-PurgeGit $project @('rev-parse', '--show-toplevel')
            if (-not $root) { return $false }
            $repository = $root.Output.Trim().Replace('/', '\').TrimEnd('\')
            $prefix = $repository + '\'
            if (-not $snapshot.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
            $relative = $snapshot.Path.Substring($prefix.Length).Replace('\', '/')
            $tracked = Invoke-PurgeGit $project @('ls-files', '-z', '--', (':(top,literal,icase)' + $relative))
            if (-not $tracked -or $tracked.Output.Length -gt 0) { return $false }
        }
        return Test-MolePathSnapshot $snapshot
    }
    catch {
        Write-Debug "Could not verify purge artifact: $Path - $_"
        return $false
    }
}

function Get-PurgeProjectDirectories {
    param([string]$Root)
    $pending = New-Object System.Collections.Generic.Stack[object]
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $pending.Push(@{ Path = $Root; Depth = 0 })
    $excluded = @($script:ArtifactPatterns | Where-Object { $_.Type -eq 'Directory' } | ForEach-Object Name) + @('.git', '.idea')
    while ($pending.Count -gt 0) {
        if ($timer.Elapsed.TotalSeconds -ge 15) { return }
        $directory = $pending.Pop()
        $snapshot = Get-MolePathSnapshot -Path $directory.Path
        if (-not $snapshot) { continue }
        try { $children = @(Get-ChildItem -LiteralPath $directory.Path -Force -ErrorAction Stop) }
        catch { continue }
        if (-not (Test-MolePathSnapshot $snapshot)) { continue }
        $marker = $children | Where-Object {
            -not $_.PSIsContainer -and ($_.Name -match '^(package\.json|composer\.json|Cargo\.toml|go\.mod|pom\.xml|build\.gradle(\.kts)?|requirements\.txt|pyproject\.toml|.+\.(csproj|fsproj|vbproj|sln))$')
        } | Select-Object -First 1
        if ($marker) { [pscustomobject]@{ Path = $directory.Path; Marker = $marker.Name } }
        if ($directory.Depth -ge 4) { continue }
        foreach ($child in $children) {
            if ($timer.Elapsed.TotalSeconds -ge 15) { return }
            if ($child.PSIsContainer -and $excluded -notcontains $child.Name -and
                ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                $pending.Push(@{ Path = $child.FullName; Depth = $directory.Depth + 1 })
            }
        }
    }
}

# Projects often share a folder name (frontend, backend, api), so lists show
# the path, from ~ when it is under the profile. A search root keeps the form
# written in the config (C:/code, ~\code), so only this label is normalized;
# the project Path that removal checks stays as discovered.
function Get-PurgeDisplayPath {
    param([string]$Path)
    try { $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    catch { Write-Debug "Could not normalize purge label: $Path - $_" }
    $userHome = "$env:USERPROFILE".TrimEnd('\')
    if (-not $userHome) { return $Path }
    if ($Path.Equals($userHome, [StringComparison]::OrdinalIgnoreCase)) { return '~' }
    if ($Path.StartsWith("$userHome\", [StringComparison]::OrdinalIgnoreCase)) {
        return '~' + $Path.Substring($userHome.Length)
    }
    return $Path
}

function Find-Projects {
    param([string[]]$SearchPaths)
    $projects = @()
    $seen = @{}
    $pathCount = 0
    $totalPaths = @($SearchPaths).Count
    foreach ($searchPath in $SearchPaths) {
        $pathCount++
        Write-Progress -Activity "Scanning for projects" `
            -Status "Searching: $searchPath" `
            -PercentComplete (($pathCount / $totalPaths) * 100)
        foreach ($project in Get-PurgeProjectDirectories -Root $searchPath) {
            if ($seen.ContainsKey($project.Path)) { continue }
            $seen[$project.Path] = $true
            $artifacts = @(Find-ProjectArtifacts -ProjectPath $project.Path)
            if ($artifacts.Count -eq 0) { continue }
            $totalSize = ($artifacts | Measure-Object -Property SizeKB -Sum).Sum
            $projects += [pscustomobject]@{
                Path = $project.Path
                Name = Split-Path -Leaf $project.Path
                DisplayPath = Get-PurgeDisplayPath $project.Path
                Marker = $project.Marker
                Artifacts = $artifacts
                TotalSizeKB = $totalSize
                TotalSizeHuman = Format-ByteSize -Bytes ($totalSize * 1024)
            }
        }
    }
    Write-Progress -Activity "Scanning for projects" -Completed
    return $projects | Sort-Object -Property TotalSizeKB -Descending
}

function Find-ProjectArtifacts {
    <#
    .SYNOPSIS
        Find cleanable artifacts in a project directory
    #>
    param([string]$ProjectPath)

    $artifacts = @()

    foreach ($pattern in $script:ArtifactPatterns) {
        $items = Get-ChildItem -LiteralPath $ProjectPath -Filter $pattern.Name -Force -ErrorAction SilentlyContinue

        foreach ($item in $items) {
            if (-not (Test-PurgeArtifactKind $ProjectPath $item.Name)) { continue }
            $snapshot = Get-MolePathSnapshot -Path $item.FullName
            if (-not $snapshot) { continue }
            if ($pattern.Type -eq "Directory" -and $item.PSIsContainer) {
                $sizeKB = Get-PathSizeKB -Path $item.FullName

                if (-not (Test-MolePathSnapshot $snapshot) -or
                    -not (Test-PurgeArtifactContent $ProjectPath $item.FullName)) { continue }
                $artifacts += [PSCustomObject]@{
                    Snapshot = $snapshot
                    Path = $item.FullName
                    Name = $item.Name
                    Type = "Directory"
                    Language = $pattern.Language
                    SizeKB = $sizeKB
                    SizeHuman = Format-ByteSize -Bytes ($sizeKB * 1024)
                }
            }
            elseif ($pattern.Type -eq "File" -and -not $item.PSIsContainer) {
                $sizeKB = [Math]::Ceiling($item.Length / 1024)

                if (-not (Test-MolePathSnapshot $snapshot) -or
                    -not (Test-PurgeArtifactContent $ProjectPath $item.FullName)) { continue }
                $artifacts += [PSCustomObject]@{
                    Snapshot = $snapshot
                    Path = $item.FullName
                    Name = $item.Name
                    Type = "File"
                    Language = $pattern.Language
                    SizeKB = $sizeKB
                    SizeHuman = Format-ByteSize -Bytes ($sizeKB * 1024)
                }
            }
        }
    }

    return $artifacts
}

# ============================================================================
# Project Selection UI
# ============================================================================

function Show-ProjectSelectionMenu {
    <#
    .SYNOPSIS
        Interactive menu for selecting projects to clean
    #>
    param([array]$Projects)

    $projectCount = if ($null -eq $Projects) { 0 } else { @($Projects).Count }
    if ($projectCount -eq 0) {
        Write-MoleWarning "No projects with cleanable artifacts found"
        return @()
    }

    $esc = [char]27
    $selectedIndices = @{}
    $currentIndex = 0
    $pageSize = 12
    $pageStart = 0

    try { [Console]::CursorVisible = $false } catch { }

    try {
        while ($true) {
            Clear-MoleScreen

            # Header
            Write-Host ""
            Write-Host "$esc[1;35mSelect Projects to Clean$esc[0m"
            Write-Host ""
            Write-Host "$esc[90mUse: $($script:Icons.NavUp)$($script:Icons.NavDown) navigate | Space select | A select all | Enter confirm | Q quit$esc[0m"
            Write-Host ""

            # Display projects
            $pageEnd = [Math]::Min($pageStart + $pageSize, $projectCount)

            for ($i = $pageStart; $i -lt $pageEnd; $i++) {
                $project = $Projects[$i]
                $isSelected = $selectedIndices.ContainsKey($i)
                $isCurrent = ($i -eq $currentIndex)

                $checkbox = if ($isSelected) { "$esc[32m[$($script:Icons.Success)]$esc[0m" } else { "[ ]" }

                if ($isCurrent) {
                    Write-Host "$esc[7m" -NoNewline
                }

                $artifactCount = if ($null -eq $project.Artifacts) { 0 } else { @($project.Artifacts).Count }
                $entry = Format-SizeListEntry -Name $project.DisplayPath -Size $project.TotalSizeHuman -Suffix " ($artifactCount $(if ($artifactCount -eq 1) { 'item' } else { 'items' }))" -NameWidth 60 -KeepEnd
                Write-Host "  $checkbox $entry" -NoNewline

                if ($isCurrent) {
                    Write-Host "$esc[0m"
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
                foreach ($idx in $selectedIndices.Keys) {
                    $totalSize += $Projects[$idx].TotalSizeKB
                }
                $totalSizeHuman = Format-ByteSize -Bytes ($totalSize * 1024)
                $noun = if ($selectedCount -eq 1) { 'project' } else { 'projects' }
                Write-Host "$esc[33mSelected:$esc[0m $selectedCount $noun ($totalSizeHuman)"
            }

            # Page indicator
            $totalPages = [Math]::Ceiling($projectCount / $pageSize)
            $currentPage = [Math]::Floor($pageStart / $pageSize) + 1
            Write-Host "$esc[90mPage $currentPage of $totalPages | Total: $projectCount $(if ($projectCount -eq 1) { 'project' } else { 'projects' })$esc[0m"

            # Handle input
            $key = [Console]::ReadKey($true)

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
                    if ($currentIndex -lt $projectCount - 1) {
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
                    $pageStart = [Math]::Min($projectCount - $pageSize, $pageStart + $pageSize)
                    if ($pageStart -lt 0) { $pageStart = 0 }
                    $currentIndex = $pageStart
                }
                'Spacebar' {
                    if ($selectedIndices.ContainsKey($currentIndex)) {
                        $selectedIndices.Remove($currentIndex)
                    }
                    else {
                        $selectedIndices[$currentIndex] = $true
                    }
                }
                'A' {
                    # Select/deselect all
                    if ($selectedIndices.Count -eq $projectCount) {
                        $selectedIndices.Clear()
                    }
                    else {
                        for ($i = 0; $i -lt $projectCount; $i++) {
                            $selectedIndices[$i] = $true
                        }
                    }
                }
                'Enter' {
                    if ($selectedIndices.Count -gt 0) {
                        $selected = @()
                        foreach ($idx in $selectedIndices.Keys) {
                            $selected += $Projects[$idx]
                        }
                        return $selected
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

# ============================================================================
# Cleanup
# ============================================================================

function Remove-ProjectArtifacts {
    <#
    .SYNOPSIS
        Remove artifacts from selected projects
    #>
    param([array]$Projects)

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[1;35mCleaning Project Artifacts$esc[0m"
    Write-Host ""

    foreach ($project in $Projects) {
        Write-Host "$esc[34m$($script:Icons.Arrow)$esc[0m $(Get-PurgeDisplayPath $project.Path)"

        foreach ($artifact in $project.Artifacts) {
            if (Test-Path -LiteralPath $artifact.Path) {
                if (-not (Test-MolePathSnapshot $artifact.Snapshot) -or
                    -not (Test-PurgeArtifactContent $project.Path $artifact.Path)) { continue }
                $projectPath = $project.Path
                $previewSnapshot = $artifact.Snapshot
                $guard = {
                    param($candidate)
                    return (Test-MolePathSnapshot $previewSnapshot) -and
                        (Test-PurgeArtifactContent $projectPath $candidate)
                }
                # Remove-SafeItem prints the result row and adds the size to
                # $script:TotalSizeCleaned; counting it here as well doubled it.
                $success = Remove-SafeItem -Path $artifact.Path -Description $artifact.Name -Recurse -Guard $guard

                if ($success) {
                    $script:ItemsCleaned++
                }
                else {
                    Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m $($artifact.Name) - removal failed"
                }
            }
        }
    }
}

# ============================================================================
# Summary
# ============================================================================

function Show-PurgeSummary {
    $heading = if ($script:MoleDryRunMode) { 'Dry run complete - no changes made' } else { 'Purge complete' }
    $details = @()
    if ($script:TotalSizeCleaned -gt 0) {
        $size = Format-ByteSize -Bytes ($script:TotalSizeCleaned * 1024)
        $label = if ($script:MoleDryRunMode) { 'Potential space' } else { 'Tracked cleanup' }
        $details += "${label}: $(Get-MoleColor -Name Green)$size$(Get-MoleColor -Name NC) | Items: $($script:ItemsCleaned)"
    }
    else { $details += 'No artifacts to clean.' }
    $details += "Free space: $(Get-FreeSpace)"
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
        Show-PurgeHelp
        return
    }

    # Edit paths
    if ($Paths) {
        Edit-SearchPaths
        return
    }

    if ($DryRun) {
        $env:MOLE_DRY_RUN = "1"
        Set-DryRunMode -Enabled $true
    }

    # Clear screen
    Clear-MoleScreen

    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mPurge Project Artifacts$esc[0m"
    Write-Host ""

    # Get search paths
    try {
        $searchPaths = @(Get-SearchPaths)
    }
    catch {
        Write-MoleError $_.Exception.Message
        exit 1
    }

    if ($null -eq $searchPaths -or $searchPaths.Count -eq 0) {
        Write-MoleWarning "No valid search paths found"
        Write-Host "Run 'mo purge --paths' to configure search directories"
        return
    }

    Write-Info "Searching in $($searchPaths.Count) directories..."

    # Find projects
    $projects = @(Find-Projects -SearchPaths $searchPaths)

    if ($null -eq $projects -or $projects.Count -eq 0) {
        Write-Host ""
        Write-Host "$esc[32m$($script:Icons.Success)$esc[0m No cleanable artifacts found"
        Write-Host ""
        return
    }

    $totalSize = ($projects | Measure-Object -Property TotalSizeKB -Sum).Sum
    if ($null -eq $totalSize) { $totalSize = 0 }
    $totalSizeHuman = Format-ByteSize -Bytes ($totalSize * 1024)

    Write-Host ""
    Write-Host "Found $esc[33m$($projects.Count)$esc[0m projects with $esc[33m$totalSizeHuman$esc[0m of artifacts"
    Write-Host ""

    # Project selection
    $selected = @(Show-ProjectSelectionMenu -Projects $projects)

    if ($null -eq $selected -or $selected.Count -eq 0) {
        Write-Info "No projects selected"
        return
    }

    # Confirm
    Clear-MoleScreen
    Write-Host ""
    $selectedSize = ($selected | Measure-Object -Property TotalSizeKB -Sum).Sum
    if ($null -eq $selectedSize) { $selectedSize = 0 }
    $selectedSizeHuman = Format-ByteSize -Bytes ($selectedSize * 1024)

    Write-Host "$esc[33mThe following will be cleaned ($selectedSizeHuman):$esc[0m"
    Write-Host ""

    foreach ($project in $selected) {
        Write-Host "  $($script:Icons.List) $($project.DisplayPath) ($($project.TotalSizeHuman))"
        foreach ($artifact in $project.Artifacts) {
            Write-Host "      $esc[90m$($artifact.Name) - $($artifact.SizeHuman)$esc[0m"
        }
    }

    Write-Host ""
    # A dry run only reports, so it needs no confirmation.
    if ($script:MoleDryRunMode) {
        Remove-ProjectArtifacts -Projects $selected
        Show-PurgeSummary
        return
    }
    $confirm = Read-Host "Continue? (y/N)"

    if ($confirm -eq 'y' -or $confirm -eq 'Y') {
        Remove-ProjectArtifacts -Projects $selected
        Show-PurgeSummary
    }
    else {
        Write-Info "Cancelled"
    }
}

# Run main
try { Main } finally { Stop-Spinner }
# Git probes leave their own exit status; the router returns this one.
exit 0
