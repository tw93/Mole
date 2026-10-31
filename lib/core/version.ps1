# Mole - Version helpers
# Provides a single source of truth for the Windows version string.

#Requires -Version 5.1
Set-StrictMode -Version Latest

if ((Get-Variable -Name 'MOLE_VERSION_HELPERS_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_VERSION_HELPERS_LOADED) {
    return
}
$script:MOLE_VERSION_HELPERS_LOADED = $true

# mo.cmd starts Windows PowerShell 5.1 through cmd.exe, so from a PowerShell 7
# terminal the child inherits PowerShell 7's module folders first. Autoloading
# then finds the PowerShell 7 builds of shared modules and commands such as
# Get-FileHash stop resolving (#1744). Drop those folders for this process
# only, keep everything else the user added, and make sure the Windows
# PowerShell system modules stay reachable.
function Repair-MoleModulePath {
    param([string]$Edition = $PSVersionTable.PSEdition)

    if ($Edition -ne 'Desktop' -or [string]::IsNullOrEmpty($env:PSModulePath)) {
        return
    }

    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($entry in ($env:PSModulePath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ($entry -match '\\PowerShell\\' -or $entry -match '\\Microsoft\.PowerShell_') { continue }
        $kept.Add($entry)
    }
    $systemModules = "$($env:SystemRoot.TrimEnd('\'))\System32\WindowsPowerShell\v1.0\Modules"
    if (-not ($kept | Where-Object { $_.TrimEnd('\') -ieq $systemModules })) {
        $kept.Add($systemModules)
    }
    $env:PSModulePath = $kept -join ';'
}

# Last-resort fallback for artifacts that ship without the VERSION file.
# Keep this equal to VERSION: released ZIP/EXE installs read it, not the file
# (issue #635 shipped v1.29.1 reporting v1.29.0 from exactly this constant).
# Locked by the "compiled-in fallback" test in tests/Core.Tests.ps1.
$script:MoleDefaultVersion = "1.40.0"

function Get-MoleVersionFilePath {
    param([string]$RootDir)

    if ([string]::IsNullOrWhiteSpace($RootDir)) {
        return $null
    }

    return Join-Path $RootDir "VERSION"
}

function Get-MoleVersionString {
    param(
        [string]$RootDir,
        [string]$DefaultVersion = $script:MoleDefaultVersion
    )

    $versionFile = Get-MoleVersionFilePath -RootDir $RootDir
    if (-not $versionFile -or -not (Test-Path $versionFile)) {
        return $DefaultVersion
    }

    $version = (Get-Content $versionFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($version)) {
        return $DefaultVersion
    }

    return $version
}
