# Mole - TUI binary helper
# Resolves, downloads, or builds analyze/status executables on Windows.

#Requires -Version 5.1
Set-StrictMode -Version Latest

if ((Get-Variable -Name 'MOLE_TUI_BINARIES_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_TUI_BINARIES_LOADED) {
    return
}
$script:MOLE_TUI_BINARIES_LOADED = $true

$script:MOLE_TUI_CORE_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$script:MOLE_TUI_CORE_DIR\version.ps1"

$script:MoleGitHubRepo = "tw93/Mole"
# Release assets are fetched from their fixed download URLs, never through the
# GitHub API: anonymous API calls are limited to 60 an hour per IP, and a shared
# office or proxy address runs out, leaving status and analyze with no binary.
$script:MoleReleaseDownloadRoot = "https://github.com/$($script:MoleGitHubRepo)/releases/download"
$script:MoleGitHubHeaders = @{
    "User-Agent" = "Mole-Windows"
}

# Progress and failure lines while preparing a tool. With stdout redirected
# (`$out = mo analyze --json`) the launcher's child PowerShell would put host
# lines ahead of the JSON, so they go to stderr then.
function Write-TuiBinaryStatus {
    param([string]$Message, [string]$Color = "Gray")

    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { }
    if ($redirected) { [Console]::Error.WriteLine($Message) }
    else { Write-Host $Message -ForegroundColor $Color }
}

function Get-MoleVersionFromScriptFile {
    param([string]$WindowsDir)

    return Get-MoleVersionString -RootDir $WindowsDir
}

function Get-TuiBinaryAssetName {
    param([string]$Name)

    return "$Name-windows-x64.exe"
}

function Resolve-TuiBinaryPath {
    param(
        [string]$WindowsDir,
        [string]$Name
    )

    $candidates = @(
        (Join-Path $WindowsDir "bin\$Name.exe"),
        (Join-Path $WindowsDir "$Name.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

# The SHA-256 a SHA256SUMS.txt text publishes for one asset, or $null when it
# does not list that asset.
function Get-ChecksumFromSums {
    param(
        [string]$SumsText,
        [string]$AssetName
    )

    foreach ($line in ($SumsText -split "`r?`n")) {
        $entry = $line.Trim([char]0xFEFF).Trim()
        if ($entry -match '^([0-9a-fA-F]{64})\s+\*?(.+)$' -and $Matches[2].Trim() -eq $AssetName) {
            return $Matches[1].ToLowerInvariant()
        }
    }

    return $null
}

# SHA-256 through .NET, so verification never depends on module autoloading
# (Get-FileHash is a script function in Windows PowerShell 5.1, #1744).
function Get-MoleFileSha256 {
    param([string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

# Returns "ok", "unavailable" (no release, asset or published checksum) or
# "mismatch" (the download did not match its published checksum and was deleted).
function Restore-PrebuiltTuiBinary {
    param(
        [string]$Name,
        [string]$WindowsDir,
        [string]$DestinationPath,
        [string]$Version
    )

    if (-not $Version) {
        return "unavailable"
    }

    $assetName = Get-TuiBinaryAssetName -Name $Name
    # An executable is never used without a published checksum to compare, so the
    # release is the first tag whose SHA256SUMS.txt answers.
    $releaseRoot = $null
    $sumsText = $null
    foreach ($tag in @("V$Version-windows", "v$Version-windows")) {
        $candidate = "$($script:MoleReleaseDownloadRoot)/$tag"
        try {
            $content = (Invoke-WebRequest -Uri "$candidate/SHA256SUMS.txt" -Headers $script:MoleGitHubHeaders -UseBasicParsing).Content
        }
        catch {
            continue
        }
        if ($content -is [byte[]]) {
            $content = [System.Text.Encoding]::UTF8.GetString($content)
        }
        $releaseRoot = $candidate
        $sumsText = [string]$content
        break
    }
    if (-not $releaseRoot) {
        return "unavailable"
    }

    $expectedHash = Get-ChecksumFromSums -SumsText $sumsText -AssetName $assetName
    if (-not $expectedHash) {
        return "unavailable"
    }

    $binDir = Split-Path -Parent $DestinationPath
    if (-not (Test-Path $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }

    Write-TuiBinaryStatus "Downloading prebuilt $Name tool..." -Color Cyan

    $downloadPath = "$DestinationPath.download"
    try {
        Invoke-WebRequest -Uri "$releaseRoot/$assetName" -Headers $script:MoleGitHubHeaders -OutFile $downloadPath -UseBasicParsing
        $actualHash = Get-MoleFileSha256 -Path $downloadPath
        if ($actualHash -ne $expectedHash) {
            Remove-Item $downloadPath -Force -ErrorAction SilentlyContinue
            return "mismatch"
        }
        Move-Item -Path $downloadPath -Destination $DestinationPath -Force
        return "ok"
    }
    catch {
        # The release and its checksum answered, so this is a real failure;
        # say what it was instead of only suggesting Go (#1744).
        Write-TuiBinaryStatus "  Could not fetch the prebuilt $Name tool: $($_.Exception.Message)" -Color Yellow
        if (Test-Path $downloadPath) {
            Remove-Item $downloadPath -Force -ErrorAction SilentlyContinue
        }
        return "unavailable"
    }
}

function Build-TuiBinary {
    param(
        [string]$Name,
        [string]$WindowsDir,
        [string]$DestinationPath,
        [string]$SourcePath
    )

    $binDir = Split-Path -Parent $DestinationPath
    if (-not (Test-Path $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }

    Write-TuiBinaryStatus "Building $Name tool..." -Color Cyan

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    # Build beside the destination so a failed build never replaces its old copy.
    $buildPath = Join-Path $binDir (".mole-$Name-" + [guid]::NewGuid().ToString("N") + ".exe")
    try {
        Push-Location $WindowsDir
        try {
            $process = Start-Process -FilePath "go" `
                -ArgumentList @("build", "-o", ('"{0}"' -f $buildPath), ('"{0}"' -f $SourcePath)) `
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        }
        finally {
            Pop-Location
        }
        if ($process.ExitCode -ne 0) {
            $details = @([string](Get-Content -LiteralPath $stdoutPath -Raw), [string](Get-Content -LiteralPath $stderrPath -Raw)) -join [Environment]::NewLine
            Write-TuiBinaryStatus "Failed to build $Name tool (exit $($process.ExitCode)): $($details.Trim())" -Color Red
            return $false
        }
        Move-Item -LiteralPath $buildPath -Destination $DestinationPath -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-TuiBinaryStatus "Failed to build $Name tool: $_" -Color Red
        return $false
    }
    finally {
        foreach ($path in @($stdoutPath, $stderrPath, $buildPath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# Compares a source checkout's native tool sources with its release tag:
# "match" when they are identical, "upstream" when they are clean and differ only
# by commits after that tag (HEAD descends from it), and "unknown" otherwise.
# Caller Git overrides can redirect the worktree or index, so they read unknown.
function Get-TuiSourceReleaseRelation {
    param([string]$WindowsDir, [string]$Name, [string]$Version)

    if (-not (Test-Path -LiteralPath (Join-Path $WindowsDir ".git")) -or
        -not (Get-Command git -ErrorAction SilentlyContinue)) {
        return "unknown"
    }
    foreach ($overrideName in @("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS")) {
        if ([Environment]::GetEnvironmentVariable($overrideName)) { return "unknown" }
    }
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $paths = @("cmd/$Name", "go.mod", "go.sum")
        $dirty = & git -C $WindowsDir -c core.fsmonitor=false status --porcelain --untracked-files=all -- @paths 2>$null
        if ($LASTEXITCODE -ne 0 -or $dirty) { return "unknown" }
        foreach ($tag in @("V$Version-windows", "v$Version-windows")) {
            & git -C $WindowsDir -c core.fsmonitor=false diff --quiet --no-ext-diff --no-textconv $tag -- @paths 2>$null
            if ($LASTEXITCODE -eq 0) { return "match" }
        }
        foreach ($tag in @("V$Version-windows", "v$Version-windows")) {
            & git -C $WindowsDir merge-base --is-ancestor $tag HEAD 2>$null
            if ($LASTEXITCODE -eq 0) { return "upstream" }
        }
        return "unknown"
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
}

# A source refresh may use a release binary only when its source is unchanged.
# Unknown or locally edited sources require a build, not an older tagged binary.
function Test-TuiSourceMatchesRelease {
    param([string]$WindowsDir, [string]$Name, [string]$Version)

    return (Get-TuiSourceReleaseRelation -WindowsDir $WindowsDir -Name $Name -Version $Version) -eq "match"
}

# True when the source is clean and HEAD descends from its release tag, so the
# release binary is that same tool minus the commits after it. Uncommitted edits
# never qualify; a local commit cannot be told apart from an upstream one here.
function Test-TuiSourceIsUpstreamOfRelease {
    param([string]$WindowsDir, [string]$Name, [string]$Version)

    return (Get-TuiSourceReleaseRelation -WindowsDir $WindowsDir -Name $Name -Version $Version) -eq "upstream"
}

function Ensure-TuiBinary {
    param(
        [string]$Name,
        [string]$WindowsDir,
        [string]$DestinationPath,
        [string]$SourcePath,
        [string]$Version,
        [switch]$Refresh
    )

    $existingBin = Resolve-TuiBinaryPath -WindowsDir $WindowsDir -Name $Name
    if ($existingBin -and -not $Refresh) {
        return $existingBin
    }

    if (-not $Version) {
        $Version = Get-MoleVersionFromScriptFile -WindowsDir $WindowsDir
    }

    $mismatchMessage = "The downloaded $Name tool did not match its published checksum and was deleted. Run 'mo update' and try again, or report it at https://github.com/tw93/Mole/issues."
    $restoreResult = "unavailable"
    $restoreTried = $false
    $sourceInstall = Test-Path -LiteralPath (Join-Path $WindowsDir ".git")
    try {
        if ((-not $Refresh -and -not $sourceInstall) -or (Test-TuiSourceMatchesRelease -WindowsDir $WindowsDir -Name $Name -Version $Version)) {
            $restoreTried = $true
            $restoreResult = Restore-PrebuiltTuiBinary -Name $Name -WindowsDir $WindowsDir -DestinationPath $DestinationPath -Version $Version
        }
    }
    catch {
        Write-TuiBinaryStatus "Failed to restore prebuilt $Name tool: $_" -Color Yellow
    }
    if ($restoreResult -eq "ok") {
        return $DestinationPath
    }
    # A checksum mismatch means the published file is not the one released;
    # stop here instead of quietly building something else.
    if ($restoreResult -eq "mismatch") {
        Write-TuiBinaryStatus $mismatchMessage -Color Red
        return $null
    }

    if (Get-Command go -ErrorAction SilentlyContinue) {
        try {
            if (Build-TuiBinary -Name $Name -WindowsDir $WindowsDir -DestinationPath $DestinationPath -SourcePath $SourcePath) {
                return $DestinationPath
            }
        }
        catch {
            Write-TuiBinaryStatus "Failed to prepare $Name tool: $_" -Color Yellow
        }
    }

    # A source install whose tool changed after the release, with no Go and no
    # copy to keep, would otherwise have no tool until the next release: every
    # commit to cmd/ after a tag left fresh installs without status and analyze.
    # The verified release build is what zip, winget and Scoop users run, so it
    # is used, and said, only when the change came after that tag in a clean
    # tree. Uncommitted edits and an existing older copy keep the build-only rule.
    if (-not $existingBin -and $sourceInstall -and -not $restoreTried) {
        try {
            if (Test-TuiSourceIsUpstreamOfRelease -WindowsDir $WindowsDir -Name $Name -Version $Version) {
                if (Get-Command go -ErrorAction SilentlyContinue) {
                    Write-TuiBinaryStatus "Building the newer $Name source failed. Using the v$Version release build instead." -Color Yellow
                }
                else {
                    Write-TuiBinaryStatus "This source has $Name changes newer than the v$Version release. Using the release build; install Go to build them." -Color Yellow
                }
                $fallbackResult = Restore-PrebuiltTuiBinary -Name $Name -WindowsDir $WindowsDir -DestinationPath $DestinationPath -Version $Version
                if ($fallbackResult -eq "ok") {
                    return $DestinationPath
                }
                if ($fallbackResult -eq "mismatch") {
                    Write-TuiBinaryStatus $mismatchMessage -Color Red
                }
            }
        }
        catch {
            Write-TuiBinaryStatus "Failed to restore prebuilt $Name tool: $_" -Color Yellow
        }
    }

    return $null
}
