# Mole - Update Command
# Updates a source-channel installation from the windows branch.

#Requires -Version 5.1
param(
    [Alias('debug', 'd')]
    [switch]$DebugMode,

    [Alias('h')]
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsDir = Split-Path -Parent $scriptDir
$installScript = Join-Path $windowsDir "install.ps1"
$gitDir = Join-Path $windowsDir ".git"

function Show-UpdateHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mmo update$esc[0m - Update the Windows source channel"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m mo update"
    Write-Host ""
    Write-Host "$esc[33mBehavior:$esc[0m"
    Write-Host "  - Pulls the latest commit from origin/windows"
    Write-Host "  - Re-runs the local installer in-place when the source changed"
    Write-Host "    or the last refresh did not finish"
    Write-Host "  - Rebuilds analyze/status if Go is available"
    Write-Host ""
    Write-Host "$esc[33mNotes:$esc[0m"
    Write-Host "  - Works only for git-based source installs"
    Write-Host "  - Legacy copied installs should be reinstalled with quick-install"
    Write-Host "  - Use --debug to include full git output on failures"
    Write-Host ""
}

$script:MoleGitProxyArguments = $null

# Git ignores the Windows system proxy that PowerShell downloads use, so on a
# machine that reaches GitHub only through that proxy, clone and pull fail
# while every other download works. Pass the system proxy to git for this
# run, unless the user already gave git a proxy of their own.
function Get-MoleSystemProxy {
    param([Uri]$Target)

    try {
        $proxy = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy($Target)
    }
    catch {
        return $null
    }
    if (-not $proxy -or $proxy.AbsoluteUri -eq $Target.AbsoluteUri) {
        return $null
    }
    return $proxy.AbsoluteUri.TrimEnd('/')
}

function Get-GitProxyArguments {
    if ($null -ne $script:MoleGitProxyArguments) {
        return $script:MoleGitProxyArguments
    }
    $script:MoleGitProxyArguments = @()

    foreach ($name in @("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY")) {
        if ([Environment]::GetEnvironmentVariable($name) -or [Environment]::GetEnvironmentVariable($name.ToLowerInvariant())) {
            return $script:MoleGitProxyArguments
        }
    }
    foreach ($key in @("http.proxy", "https.proxy")) {
        try {
            $configured = & git config --get $key 2>$null
        }
        catch {
            $configured = $null
        }
        if ($configured) {
            return $script:MoleGitProxyArguments
        }
    }

    $proxy = Get-MoleSystemProxy -Target ([Uri]"https://github.com/")
    if ($proxy) {
        $script:MoleGitProxyArguments = @("-c", "http.proxy=$proxy")
    }
    return $script:MoleGitProxyArguments
}

function Invoke-GitCommand {
    param(
        [string]$WorkingDirectory,
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $previousNativeErrorPreference = $null
    $hasNativeErrorPreference = $false

    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        $hasNativeErrorPreference = $true
    }

    try {
        $gitArguments = @()
        if ($WorkingDirectory) {
            $gitArguments += @("-C", $WorkingDirectory)
        }
        $gitArguments += @(Get-GitProxyArguments)
        $gitArguments += $Arguments

        $output = & git @gitArguments 2>&1
        $exitCode = $LASTEXITCODE

        return [pscustomobject]@{
            ExitCode = $exitCode
            Text = ((@($output) | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hasNativeErrorPreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
        }
    }
}

function Mask-GitText {
    param([string]$Text)

    if (-not $Text) {
        return ""
    }

    return ($Text -replace '(https?://)([^/@\s]+)@', '$1***@')
}

function Write-IndentedText {
    param([string]$Text)

    if (-not $Text) {
        return
    }

    foreach ($line in ($Text -split "`r?`n")) {
        Write-Host "    $line"
    }
}

function Write-GitFailure {
    param(
        [string]$Message,
        [Parameter(Mandatory)]
        $Result
    )

    Write-Host "$Message (git exit $($Result.ExitCode))." -ForegroundColor Red
    $text = Mask-GitText -Text $Result.Text
    if (-not $text) {
        return
    }

    if ($DebugMode) {
        Write-Host "Git output:" -ForegroundColor Yellow
        Write-IndentedText -Text $text
    }
    else {
        $firstLine = ($text -split "`r?`n" | Select-Object -First 1)
        Write-Host "    $firstLine"
        Write-Host "    Re-run with 'mo update --debug' for full git output." -ForegroundColor Yellow
    }
}

function Test-InstallDirOnUserPath {
    param([string]$Path)

    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if (-not $currentPath) {
        return $false
    }

    return $currentPath -split ";" | Where-Object { $_ -eq $Path }
}

if ($ShowHelp) {
    Show-UpdateHelp
    return
}

# The upgrade command for a copy installed by winget or Scoop,
# recognized by the folder each one installs into; $null otherwise.
function Get-PackageManagerUpgradeCommand {
    param([string]$InstallDir)

    $path = $InstallDir.TrimEnd('\') + '\'
    if ($path -like "*\Microsoft\WinGet\Packages\tw93.MoleCLI_*") {
        return "winget upgrade tw93.MoleCLI"
    }
    if ($path -like "*\scoop\apps\mole\*") {
        return "scoop update mole"
    }
    return $null
}

if ($DebugMode) {
    $env:MOLE_DEBUG = "1"
}

if (-not (Test-Path $installScript)) {
    Write-Host "Installer not found at: $installScript" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $gitDir)) {
    # Package-manager installs update through that manager, never through git.
    $upgradeCommand = Get-PackageManagerUpgradeCommand -InstallDir $windowsDir
    if ($upgradeCommand) {
        Write-Host "This copy of Mole is managed by a package manager." -ForegroundColor Yellow
        Write-Host "Update it with: $upgradeCommand" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "This copy is not a git-based source install, so 'mo update' cannot update it in place." -ForegroundColor Red
    Write-Host "To replace it, remove or rename $windowsDir, then run:" -ForegroundColor Yellow
    Write-Host "  irm https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex" -ForegroundColor Yellow
    Write-Host "A release ZIP also works: run its install.ps1 with a new -InstallDir and -AddToPath." -ForegroundColor Yellow
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Git is not installed. Install Git to use 'mo update'." -ForegroundColor Red
    exit 1
}

$dirtyStatus = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("status", "--porcelain", "--untracked-files=no")
if ($dirtyStatus.ExitCode -ne 0) {
    Write-GitFailure -Message "Failed to inspect git status" -Result $dirtyStatus
    exit 1
}

if ($dirtyStatus.Text) {
    Write-Host "Local tracked changes detected in the installation directory." -ForegroundColor Red
    Write-Host "Commit or discard them before running 'mo update'." -ForegroundColor Yellow
    exit 1
}

$remoteResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("remote", "get-url", "origin")
$remote = $remoteResult.Text
if ($remoteResult.ExitCode -ne 0 -or -not $remote) {
    if ($remoteResult.ExitCode -ne 0) {
        Write-GitFailure -Message "Failed to inspect git remote 'origin'" -Result $remoteResult
    }
    else {
        Write-Host "Git remote 'origin' is not configured for this install." -ForegroundColor Red
    }
    exit 1
}

$branchResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("branch", "--show-current")
$branch = $branchResult.Text
if ($branchResult.ExitCode -ne 0 -or -not $branch) {
    $branch = "windows"
}

$beforeResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("rev-parse", "--short", "HEAD")
$before = $beforeResult.Text
if ($beforeResult.ExitCode -ne 0 -or -not $before) {
    Write-Host "Failed to read current revision." -ForegroundColor Red
    exit 1
}

Write-Host "Updating source from $(Mask-GitText -Text $remote) ($branch)..." -ForegroundColor Cyan

$pullResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("pull", "--ff-only", "--tags", "origin", $branch)
if ($pullResult.ExitCode -ne 0) {
    Write-GitFailure -Message "Failed to update source" -Result $pullResult
    exit 1
}

$afterResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("rev-parse", "--short", "HEAD")
$after = $afterResult.Text
if ($afterResult.ExitCode -ne 0 -or -not $after) {
    Write-Host "Updated source, but failed to read the new revision." -ForegroundColor Red
    exit 1
}

# The revision the installer last finished at. An unchanged pull skips the
# refresh only when that refresh succeeded at this revision and both launchers
# exist; a refresh that failed (a tool kept at an older build) or a missing
# launcher runs the installer again. A marker that cannot be read or written
# falls back to refreshing every time.
$refreshMarker = Join-Path $gitDir "mole-refreshed-revision"
$markerResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("rev-parse", "--git-path", "mole-refreshed-revision")
if ($markerResult.ExitCode -eq 0 -and $markerResult.Text) {
    $refreshMarker = $markerResult.Text
    if (-not [System.IO.Path]::IsPathRooted($refreshMarker)) {
        $refreshMarker = Join-Path $windowsDir $refreshMarker
    }
}

if ($after -eq $before) {
    $refreshedAt = $null
    if (Test-Path -LiteralPath $refreshMarker -PathType Leaf) {
        try {
            $refreshedAt = (Get-Content -LiteralPath $refreshMarker -Raw -ErrorAction Stop).Trim()
        }
        catch {
            $refreshedAt = $null
        }
    }
    $launchersPresent = (Test-Path -LiteralPath (Join-Path $windowsDir "mole.cmd") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $windowsDir "mo.cmd") -PathType Leaf)
    Write-Host "Already up to date at $after." -ForegroundColor Green
    if ($refreshedAt -eq $after -and $launchersPresent) {
        exit 0
    }
}
else {
    Write-Host "Updated source: $before -> $after" -ForegroundColor Green
}

$installParams = @{
    InstallDir = $windowsDir
}

if (Test-InstallDirOnUserPath -Path $windowsDir) {
    $installParams.AddToPath = $true
}

Write-Host "Refreshing local installation..." -ForegroundColor Cyan
# Drop the old marker first, so a refresh that dies midway is retried.
Remove-Item -LiteralPath $refreshMarker -Force -ErrorAction SilentlyContinue
$global:LASTEXITCODE = 0
& $installScript @installParams
$installExit = $LASTEXITCODE
if ($installExit -ne 0) {
    exit $installExit
}

try {
    Set-Content -LiteralPath $refreshMarker -Value $after -NoNewline -Encoding ASCII -ErrorAction Stop
}
catch {
    # Without the marker the next unchanged update refreshes again.
}
