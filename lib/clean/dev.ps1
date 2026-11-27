# Mole - Developer Tools Cleanup Module
# Cleans development tool caches and build artifacts

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_CLEAN_DEV_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_CLEAN_DEV_LOADED) { return }
$script:MOLE_CLEAN_DEV_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\..\core\base.ps1"
. "$scriptDir\..\core\log.ps1"
. "$scriptDir\..\core\file_ops.ps1"

. "$PSScriptRoot\cache_guard.ps1"

# ============================================================================
# Node.js / JavaScript Ecosystem
# ============================================================================

# Invoke an installed owner in a bounded child process. Encoded PowerShell keeps
# executable paths and arguments as data, including spaces and quote characters.
function Invoke-MoleOwnerProcess {
    param([string]$Name, [string[]]$Arguments, [int]$TimeoutSeconds = 5, [hashtable]$Outcome = $null)

    # Outcome.Reason says why a run returned nothing, including a forced stop,
    # so the caller's operations.log row can say the owner was killed.
    if ($null -eq $Outcome) { $Outcome = @{} }
    $Outcome.Reason = ""
    $command = Get-Command $Name -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { $Outcome.Reason = "$Name not found"; return $null }
    $quote = { param($value) "'" + $value.Replace("'", "''") + "'" }
    $words = @(& $quote $command.Source) + @($Arguments | ForEach-Object { & $quote $_ })
    $code = '$ErrorActionPreference = ''Stop''; [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); $OutputEncoding = [Console]::OutputEncoding; & ' + ($words -join ' ') + '; if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $process = New-Object Diagnostics.Process
    $started = $false
    $process.StartInfo = New-Object Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $process.StartInfo.FileName)) {
        $process.StartInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    }
    $process.StartInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $process.StartInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    try {
        $null = $process.Start()
        $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $Outcome.Reason = "timed out after ${TimeoutSeconds}s"
            return $null
        }
        if (-not $stdout.Wait(1000) -or -not $stderr.Wait(1000)) { $Outcome.Reason = "output not captured"; return $null }
        if ($process.ExitCode -ne 0) { $Outcome.Reason = "exit code $($process.ExitCode)"; return $null }
        return [pscustomobject]@{ Output = $stdout.Result.Trim() }
    }
    catch { $Outcome.Reason = $_.Exception.Message; return $null }
    finally {
        # Also terminate on capture exceptions, not only WaitForExit timeouts.
        if ($started -and -not $process.HasExited) {
            $stopper = $null
            try {
                $stopper = New-Object Diagnostics.Process
                $stopper.StartInfo.FileName = "$env:SystemRoot\System32\taskkill.exe"
                $stopper.StartInfo.Arguments = '/PID ' + $process.Id + ' /T /F'
                $stopper.StartInfo.UseShellExecute = $false
                $stopper.StartInfo.CreateNoWindow = $true
                $stopper.StartInfo.RedirectStandardOutput = $true
                $stopper.StartInfo.RedirectStandardError = $true
                $null = $stopper.Start()
                $null = $stopper.StandardOutput.ReadToEndAsync()
                $null = $stopper.StandardError.ReadToEndAsync()
                $stopResult = if (-not $stopper.WaitForExit(5000)) { "taskkill timed out; process tree termination unverified" }
                elseif ($stopper.ExitCode -ne 0) { "taskkill exit code $($stopper.ExitCode); process tree termination unverified" }
                else { "process tree $($process.Id) stopped with taskkill /T /F" }
                $Outcome.Reason = (@($Outcome.Reason, $stopResult) | Where-Object { $_ }) -join "; "
            }
            catch {
                Write-Debug "$Name process tree cancellation failed: $_"
                $Outcome.Reason = (@($Outcome.Reason, "taskkill failed: $($_.Exception.Message)") | Where-Object { $_ }) -join "; "
            }
            finally { if ($null -ne $stopper) { $stopper.Dispose() } }
            if (-not $process.HasExited) { try { $process.Kill() } catch { } }
        }
        $process.Dispose()
    }
}

function Get-MoleOwnerCachePath {
    param([string]$Name, [string[]]$Arguments)

    $result = Invoke-MoleOwnerProcess -Name $Name -Arguments $Arguments
    if ($null -eq $result -or [string]::IsNullOrWhiteSpace($result.Output)) { return $null }
    $path = $result.Output.Trim()
    if ($path -match '[\r\n]' -or $path -notmatch '^[A-Za-z]:\\') { return $null }
    return $path
}

function Invoke-MoleOwnerCacheCleanup {
    param([string]$Name, [string[]]$Query, [string[]]$Arguments, [string]$Description, [scriptblock]$CanRemove = $null)

    if (-not (Test-MoleRemovalCondition -CanRemove $CanRemove)) { return }
    $path = Get-MoleOwnerCachePath -Name $Name -Arguments $Query
    if (-not $path -or -not (Test-SafePath $path)) { return }
    $snapshot = Get-MolePathSnapshot -Path $path
    if (-not $snapshot) { return }
    # A whole-cache owner command must honor descendant whitelist entries too.
    $tree = Get-SafeDirectoryTreeItems -Path $path
    if (-not $tree.Success -or -not (Test-MolePathSnapshot $snapshot)) { return }
    foreach ($item in $tree.Items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }
    }
    if (-not (Test-MoleRemovalCondition -CanRemove $CanRemove)) { return }
    if (Test-DryRunMode) {
        # Selective owner pruning cannot promise the size of the whole store.
        Add-DryRunListEntries -Description $Description -Paths @($path)
        $script:OwnerCleanups++
        Write-DryRun $Description
        Set-SectionActivity
        return
    }
    # Query again at the boundary; a changed configuration is not the previewed root.
    # One fresh whitelist read for the boundary, not one per cache entry.
    $current = Get-MoleOwnerCachePath -Name $Name -Arguments $Query
    $whitelistState = Get-WhitelistState
    if (-not (Test-MoleRemovalCondition -CanRemove $CanRemove)) { return }
    if ($current -ne $path -or -not (Test-SafePath $path -WhitelistState $whitelistState) -or
        -not (Test-MolePathSnapshot $snapshot)) { return }
    foreach ($item in $tree.Items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }
        if (-not (Test-SafePath $item.FullName -WhitelistState $whitelistState) -or
            -not (Test-MolePathSnapshot $item.MolePathSnapshot)) { return }
    }
    $beforeFiles = @($tree.Items | Where-Object { -not $_.PSIsContainer })
    $beforeBytes = 0L
    foreach ($file in $beforeFiles) { $beforeBytes += $file.Length }
    $commandDetail = (@($Name) + $Arguments) -join ' '
    $ownerOutcome = @{}
    $result = Invoke-MoleOwnerProcess -Name $Name -Arguments $Arguments -TimeoutSeconds 120 -Outcome $ownerOutcome
    if ($null -ne $result) {
        Write-MoleOperation -Action "OWNER" -Path $path -Detail $commandDetail
        $script:OwnerCleanups++
        # Count only a complete before/after measurement of the same root.
        # Missing or replaced roots are unmeasured, never assumed empty.
        $removedBytes = 0L
        if (Test-MolePathSnapshot $snapshot) {
            $after = Get-SafeDirectoryTreeItems -Path $path
            if ($after.Success -and (Test-MolePathSnapshot $snapshot)) {
                $afterFiles = @($after.Items | Where-Object { -not $_.PSIsContainer })
                $afterBytes = 0L
                foreach ($file in $afterFiles) { $afterBytes += $file.Length }
                $removedBytes = [Math]::Max(0L, [long]$beforeBytes - [long]$afterBytes)
                $script:TotalSizeCleaned += [Math]::Floor($removedBytes / 1024)
                $script:FilesCleaned += [Math]::Max(0, $beforeFiles.Count - $afterFiles.Count)
                if ($removedBytes -gt 0) { $script:TotalItems++ }
            }
        }
        if ($removedBytes -gt 0) {
            Write-Success "$Description $($script:Colors.Green)($(Format-ByteSize -Bytes $removedBytes))$($script:Colors.NC)"
        }
        else { Write-Success $Description }
        Set-SectionActivity
    }
    else {
        # Indexed: under StrictMode a missing key read as a property throws.
        $why = if ($ownerOutcome['Reason']) { "; $($ownerOutcome['Reason'])" } else { "" }
        Write-MoleOperation -Action "FAILED" -Path $path -Detail "${commandDetail}: incomplete$why"
        Write-Debug "$Name cache cleanup did not complete"
    }
}

function Clear-NpmCache {
    <#
    .SYNOPSIS
        Clean npm, pnpm, yarn, and bun caches
    #>
    
    Invoke-MoleOwnerCacheCleanup -Name 'npm' -Query @('config', 'get', 'cache') -Arguments @('cache', 'clean', '--force') -Description 'npm cache'
    Invoke-MoleOwnerCacheCleanup -Name 'pnpm' -Query @('store', 'path') -Arguments @('store', 'prune') -Description 'pnpm store'

    # Classic's download cache is rebuildable. Berry's archives are live
    # dependencies and are protected by the shared clean path policy.
    Clear-MoleAppCache -Path "$env:LOCALAPPDATA\Yarn\Cache" -Description 'Yarn cache' -Processes @('node')

    # A usable Bun owns its configured cache. Unknown roots and failed owner
    # commands must never fall back to deleting a guessed directory.
    if (Test-MoleCacheOwnerIdle -Names @('bun', 'bunx')) {
        $bun = Invoke-MoleOwnerProcess -Name 'bun' -Arguments @('--version')
        if ($null -ne $bun -and -not [string]::IsNullOrWhiteSpace($bun.Output)) {
            Invoke-MoleOwnerCacheCleanup -Name 'bun' -Query @('pm', 'cache') -Arguments @('pm', 'cache', 'rm') -Description 'Bun cache' -CanRemove { Test-MoleCacheOwnerIdle -Names @('bun', 'bunx') }
        }
        else {
            Clear-MoleAppCache -Path "$env:USERPROFILE\.bun\install\cache" -Description 'Bun cache' -Processes @('bun', 'bunx')
        }
    }
}

function Clear-NodeBuildCaches {
    <#
    .SYNOPSIS
        Clean Node.js build-related caches
    #>
    
    # A build or editor that is running reads these, so each waits for its
    # owner, as Mole for Windows holds them. tsserver keeps one type cache for
    # every editor and runs inside the editor's own process, so that row waits
    # for each editor this file cleans, not only VS Code.
    Clear-MoleAppCache -Path "$env:LOCALAPPDATA\node-gyp\Cache" -Description "node-gyp cache" -Processes @('node')
    Clear-MoleAppCache -Path "$env:LOCALAPPDATA\electron\Cache" -Description "Electron cache" -Processes @('node')
    Clear-MoleAppCache -Path "$env:LOCALAPPDATA\Microsoft\TypeScript" -Description "TypeScript cache" -Processes @('Code', 'Code - Insiders', 'Cursor', 'Windsurf', 'VSCodium', 'devenv', 'node')
}

# ============================================================================
# Python Ecosystem
# ============================================================================

function Clear-PythonCaches {
    <#
    .SYNOPSIS
        Clean Python and pip caches
    #>
    
    Invoke-MoleOwnerCacheCleanup -Name 'pip' -Query @('cache', 'dir') -Arguments @('cache', 'purge') -Description 'pip cache'

    # Python bytecode caches (__pycache__)
    # Note: These are typically in project directories, cleaned by purge command
    
    # pyenv cache
    $pyenvCachePath = "$env:USERPROFILE\.pyenv\cache"
    if (Test-Path $pyenvCachePath) {
        Clear-DirectoryContents -Path $pyenvCachePath -Description "pyenv cache"
    }
    
    # Poetry cache
    $poetryCachePath = "$env:LOCALAPPDATA\pypoetry\Cache"
    foreach ($leaf in @('artifacts', 'cache')) {
        Clear-MoleAppCache -Path (Join-Path $poetryCachePath $leaf) -Description "Poetry cache" -Processes @('python', 'pythonw', 'poetry')
    }
    
    # conda packages
    $condaCachePaths = @(
        "$env:USERPROFILE\.conda\pkgs"
        "$env:USERPROFILE\anaconda3\pkgs"
        "$env:USERPROFILE\miniconda3\pkgs"
    )
    foreach ($path in $condaCachePaths) {
        if (Test-Path $path) {
            # Only clean index and temp files, not actual packages
            $tempFiles = Get-ChildItem -Path $path -Filter "*.tmp" -ErrorAction SilentlyContinue
            if ($tempFiles) {
                $paths = $tempFiles | ForEach-Object { $_.FullName }
                Remove-SafeItems -Paths $paths -Description "Conda temp files"
            }
        }
    }
    
    # pytest cache
    $pytestCachePath = "$env:USERPROFILE\.pytest_cache"
    if (Test-Path $pytestCachePath) {
        $null = Remove-SafeItem -Path $pytestCachePath -Description "pytest cache" -Recurse
    }
}

# ============================================================================
# .NET / C# Ecosystem
# ============================================================================

function Clear-DotNetDevCaches {
    <#
    .SYNOPSIS
        Clean .NET development caches
    #>
    
    # NuGet cache
    $nugetCachePath = "$env:USERPROFILE\.nuget\packages"
    # Don't clean packages by default - they're needed for builds
    # Only clean http-cache and temp
    
    $nugetHttpCache = "$env:LOCALAPPDATA\NuGet\v3-cache"
    if (Test-Path $nugetHttpCache) {
        Clear-MoleAppCache -Path $nugetHttpCache -Description "NuGet HTTP cache" -Processes @('devenv', 'dotnet', 'MSBuild')
    }
    
    $nugetTempPath = "$env:LOCALAPPDATA\NuGet\plugins-cache"
    if (Test-Path $nugetTempPath) {
        Clear-MoleAppCache -Path $nugetTempPath -Description "NuGet plugins cache" -Processes @('devenv', 'dotnet', 'MSBuild')
    }
    
    # MSBuild temp files
    $msbuildTemp = "$env:LOCALAPPDATA\Microsoft\MSBuild"
    if (Test-Path $msbuildTemp) {
        $tempDirs = Get-ChildItem -Path $msbuildTemp -Directory -Filter "*temp*" -ErrorAction SilentlyContinue
        foreach ($dir in $tempDirs) {
            Clear-MoleAppCache -Path $dir.FullName -Description "MSBuild temp" -Processes @('devenv', 'dotnet', 'MSBuild')
        }
    }
}

# ============================================================================
# Go Ecosystem
# ============================================================================

function Clear-GoCaches {
    <#
    .SYNOPSIS
        Clean Go build and module caches
    #>
    
    # Go applies GOFLAGS to `go clean`: a -modcache exported or saved with
    # `go env -w` would make this call empty the whole module cache, sources
    # included, past the owner guard below. An empty value falls through to the
    # saved one, so the harmless -modcacherw is pinned for the call.
    $savedGoFlags = $env:GOFLAGS
    try {
        $env:GOFLAGS = '-modcacherw'
        Invoke-MoleOwnerCacheCleanup -Name 'go' -Query @('env', 'GOCACHE') -Arguments @('clean', '-cache') -Description 'Go build cache'
    }
    finally {
        $env:GOFLAGS = $savedGoFlags
    }

    $moduleRoot = Get-MoleOwnerCachePath -Name 'go' -Arguments @('env', 'GOMODCACHE')
    if ($moduleRoot) {
        Clear-MoleAppCache -Path (Join-Path $moduleRoot 'cache') -Description 'Go module cache' -Processes @('go')
    }
}

function Clear-MiseCache {
    Invoke-MoleOwnerCacheCleanup -Name 'mise' -Query @('cache', 'path') -Arguments @('cache', 'clear') -Description 'mise cache'
}

# ============================================================================
# Rust Ecosystem
# ============================================================================

function Clear-RustCaches {
    <#
    .SYNOPSIS
        Clean Rust/Cargo caches
    #>
    
    # Only the download copies, and only while no Rust tool runs. The whole of
    # .cargo and .rustup used to be default whitelist entries, so these rows
    # never cleaned anything; sources, the index and git checkouts stay there.
    $rustTooling = @('cargo', 'rustc', 'rustdoc', 'clippy-driver', 'cargo-nextest', 'rustup')
    Clear-MoleAppCache -Path "$env:USERPROFILE\.cargo\registry\cache" -Description "Cargo registry cache" -Processes $rustTooling
    Clear-MoleAppCache -Path "$env:USERPROFILE\.rustup\downloads" -Description "Rustup downloads" -Processes $rustTooling
}

# ============================================================================
# Java / JVM Ecosystem
# ============================================================================

# Enumerate a cache tree under a wall-clock budget. Maven repositories and
# Stack snapshot trees can hold tens of thousands of files, and one unbounded
# recursive Get-ChildItem made a cleanup row run for minutes. A tree that was
# not fully enumerated is unknown, so callers keep every candidate instead of
# deleting a partial prefix. Links and junctions are never entered.
function Get-FilesWithinBudget {
    param(
        [string]$Root,
        [string]$Filter,
        [int]$TimeoutSeconds = 15
    )

    $result = @{ Files = @(); Complete = $false }
    if (-not (Test-Path -LiteralPath $Root)) {
        $result.Complete = $true
        return $result
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($Root)
    $files = New-Object System.Collections.Generic.List[string]
    while ($pending.Count -gt 0) {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            return $result
        }
        $directory = $pending.Pop()
        try {
            $entries = @([System.IO.Directory]::GetFileSystemEntries($directory))
        }
        catch {
            # An unreadable directory makes the whole scan incomplete.
            return $result
        }
        foreach ($entry in $entries) {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                return $result
            }
            try {
                $attributes = [System.IO.File]::GetAttributes($entry)
            }
            catch {
                return $result
            }
            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                    $pending.Push($entry)
                }
                continue
            }
            if ([System.IO.Path]::GetFileName($entry) -like $Filter) {
                $files.Add($entry)
            }
        }
    }
    $result.Files = $files.ToArray()
    $result.Complete = $true
    return $result
}

# ============================================================================
# Docker / Containers
# ============================================================================

function Clear-DockerCaches {
    # A builder can use a remote daemon, a container or a Desktop VM disk. Docker
    # exposes no complete Windows path plan for builder prune, so local whitelist
    # checks cannot constrain its mutation. Keep this owner cleanup review-only.
    Write-Debug 'Docker build cache kept: cleanup roots cannot be verified against the whitelist'
}

# ============================================================================
# Cloud CLI Tools
# ============================================================================

function Clear-CloudCliCaches {
    <#
    .SYNOPSIS
        Clean cloud CLI tool caches (gcloud logs, Terraform plugins)
    #>
    
    # Google Cloud logs
    $gcloudLogsPath = "$env:APPDATA\gcloud\logs"
    if (Test-Path $gcloudLogsPath) {
        Clear-DirectoryContents -Path $gcloudLogsPath -Description "gcloud logs"
    }
    
    # Terraform plugin cache
    $terraformCachePath = "$env:APPDATA\terraform.d\plugin-cache"
    if (Test-Path $terraformCachePath) {
        Clear-DirectoryContents -Path $terraformCachePath -Description "Terraform plugin cache"
    }
}

# ============================================================================
# Elixir/Erlang Ecosystem
# ============================================================================

function Clear-ElixirCaches {
    <#
    .SYNOPSIS
        Clean Elixir Mix and Hex caches
    #>
    
    # Mix archives - skip auto-cleanup to preserve globally installed Mix tools
    # NOTE: This directory contains globally installed Mix tools and tasks (e.g., phx_new, hex).
    # Clearing it would remove user-installed tools requiring reinstallation.
    $mixArchivesPath = "$env:USERPROFILE\.mix\archives"
    if (Test-Path $mixArchivesPath) {
        Write-Debug "Skipping Mix archives at '$mixArchivesPath' - contains globally installed tools"
    }
    
    # Hex cache
    $hexCachePath = "$env:USERPROFILE\.hex\cache"
    if (Test-Path $hexCachePath) {
        Clear-DirectoryContents -Path $hexCachePath -Description "Hex cache"
    }
}

# ============================================================================
# Haskell Ecosystem
# ============================================================================

function Clear-HaskellCaches {
    <#
    .SYNOPSIS
        Clean Haskell Stack temp files
    #>

    # The Cabal store holds installed packages, not a cache: an old timestamp
    # does not mean no project depends on it.
    # Stack snapshots (be careful - these are needed for builds)
    $stackSnapshotsPath = "$env:USERPROFILE\.stack\snapshots"
    if (Test-Path $stackSnapshotsPath) {
        # Only clean temp files
        $scan = Get-FilesWithinBudget -Root $stackSnapshotsPath -Filter "*.tmp" -TimeoutSeconds 15
        if (-not $scan.Complete) {
            Write-Debug "Stack temp-file scan did not complete within 15s; kept every temp file"
        }
        elseif ($scan.Files.Count -gt 0) {
            Remove-SafeItems -Paths $scan.Files -Description "Stack temp files"
        }
    }
}

# ============================================================================
# OCaml Ecosystem
# ============================================================================

function Clear-OCamlCaches {
    <#
    .SYNOPSIS
        Clean OCaml Opam caches
    #>
    
    # Opam download cache
    $opamDownloadCache = "$env:USERPROFILE\.opam\download-cache"
    if (Test-Path $opamDownloadCache) {
        Clear-DirectoryContents -Path $opamDownloadCache -Description "Opam download cache"
    }
    
    # Opam repo cache
    $opamRepoCache = "$env:USERPROFILE\.opam\repo"
    if (Test-Path $opamRepoCache) {
        $cacheDirs = Get-ChildItem -Path $opamRepoCache -Directory -Filter "*cache*" -ErrorAction SilentlyContinue
        foreach ($dir in $cacheDirs) {
            Clear-DirectoryContents -Path $dir.FullName -Description "Opam repo cache"
        }
    }
}

# ============================================================================
# Editor Caches (VS Code, Zed, etc.)
# ============================================================================

function Clear-EditorCaches {
    <#
    .SYNOPSIS
        Clean VS Code, Zed, and other editor caches
    #>
    
    # VS Code cached data
    # NOTE: workspaceStorage excluded - contains workspace-specific settings and extension data
    $vscodeCachePaths = @(
        "$env:APPDATA\Code\Cache"
        "$env:APPDATA\Code\CachedData"
        "$env:APPDATA\Code\CachedExtensions"
        "$env:APPDATA\Code\CachedExtensionVSIXs"
        "$env:APPDATA\Code\Code Cache"
        "$env:APPDATA\Code\GPUCache"
        "$env:LOCALAPPDATA\Microsoft\vscode-cpptools"
    )
    foreach ($path in $vscodeCachePaths) {
        if (Test-Path $path) {
            $owners = if ($path -eq "$env:LOCALAPPDATA\Microsoft\vscode-cpptools") { @('Code', 'Code - Insiders') } else { @('Code') }
            Clear-MoleAppCache -Path $path -Description "VS Code cache" -Processes $owners
        }
    }
    
    # VS Code Insiders
    # NOTE: workspaceStorage excluded - contains workspace-specific settings and extension data
    $vscodeInsidersCachePaths = @(
        "$env:APPDATA\Code - Insiders\Cache"
        "$env:APPDATA\Code - Insiders\CachedData"
        "$env:APPDATA\Code - Insiders\CachedExtensions"
        "$env:APPDATA\Code - Insiders\CachedExtensionVSIXs"
        "$env:APPDATA\Code - Insiders\Code Cache"
        "$env:APPDATA\Code - Insiders\GPUCache"
    )
    foreach ($path in $vscodeInsidersCachePaths) {
        if (Test-Path $path) {
            Clear-MoleAppCache -Path $path -Description "VS Code Insiders cache" -Processes @('Code - Insiders')
        }
    }
    
    # Zed editor cache
    $zedCachePaths = @(
        "$env:LOCALAPPDATA\Zed\cache"
        "$env:APPDATA\Zed\cache"
    )
    foreach ($path in $zedCachePaths) {
        Clear-MoleAppCache -Path $path -Description "Zed cache" -Processes @('Zed')
    }
    
    # Sublime Text cache
    foreach ($sublimeCachePath in @("$env:LOCALAPPDATA\Sublime Text\Cache", "$env:APPDATA\Sublime Text\Cache")) {
        Clear-MoleAppCache -Path $sublimeCachePath -Description "Sublime Text cache" -Processes @('sublime_text', 'plugin_host')
    }
    
    # Atom cache (legacy)
    $atomCachePath = "$env:APPDATA\.atom\compile-cache"
    if (Test-Path $atomCachePath) {
        Clear-DirectoryContents -Path $atomCachePath -Description "Atom compile cache"
    }
}

# ============================================================================
# IDE Caches
# ============================================================================

function Clear-IdeCaches {
    <#
    .SYNOPSIS
        Clean IDE caches (VS, VSCode, JetBrains, etc.)
    #>
    
    # Visual Studio cache
    $vsCachePaths = @(
        "$env:LOCALAPPDATA\Microsoft\VisualStudio\*\ComponentModelCache"
        "$env:LOCALAPPDATA\Microsoft\VisualStudio\*\ImageCache"
    )
    foreach ($pattern in $vsCachePaths) {
        $paths = Resolve-Path $pattern -ErrorAction SilentlyContinue
        foreach ($path in $paths) {
            Clear-MoleAppCache -Path $path.Path -Description "Visual Studio cache" -Processes @('devenv')
        }
    }
    
    # JetBrains IDEs: caches and index in each IDE's system folder, only while
    # no JetBrains IDE runs (Mole for Windows' jetbrains-caches and -index rows).
    # The roaming folder holds settings and plugins, never caches.
    $jetbrainsIdes = @('idea64', 'idea', 'pycharm64', 'webstorm64', 'rider64', 'clion64', 'goland64',
        'phpstorm64', 'rubymine64', 'datagrip64', 'rustrover64', 'dataspell64', 'aqua64', 'writerside64',
        'mps64', 'gateway64', 'jetbrains_client64', 'studio64')
    $jetbrainsRoot = "$env:LOCALAPPDATA\JetBrains"
    foreach ($ideFolder in @(Get-ChildItem -LiteralPath $jetbrainsRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($ideFolder.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        foreach ($cacheFolder in 'caches', 'index') {
            Clear-MoleAppCache -Path (Join-Path $ideFolder.FullName $cacheFolder) -Description "$($ideFolder.Name) $cacheFolder" -Processes $jetbrainsIdes
        }
    }
}

# ============================================================================
# Git Caches
# ============================================================================

function Clear-GitCaches {
    <#
    .SYNOPSIS
        Clean Git temporary files and lock files
    #>
    
    # ~/.gitconfig.lock is left alone: Git holds it while it writes the config,
    # and neither its age nor an idle git process proves the write is over.
    
    # GitHub CLI cache
    $ghCachePath = "$env:APPDATA\GitHub CLI"
    if (Test-Path $ghCachePath) {
        $cacheFiles = Get-ChildItem -Path $ghCachePath -Filter "*.json" -ErrorAction SilentlyContinue |
                      Where-Object { (Test-MoleOlderThan $_ (Get-Date).AddDays(-7)) }
        if ($cacheFiles) {
            $paths = $cacheFiles | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "GitHub CLI cache"
        }
    }
}

# ============================================================================
# AI command-line tools' old releases
# ============================================================================
# Claude Code, Codex, Cursor Agent and GitHub Copilot CLI each update by
# installing a complete new release beside the old one and never remove it.
# Every layout below was read on Windows by installing an older release and
# updating it; none matches the macOS paths. Which release runs is read from
# what each tool itself reads, and anything that cannot be settled keeps every
# release. A release a process still runs is kept too: a running exe opens and
# reads freely with no sharing, so only the Restart Manager can tell, and it
# also names an exe that was renamed while running.

$script:MoleAiSemver = '^\d{1,9}\.\d{1,9}\.\d{1,9}$'
$script:MoleAiCursorVersion = '^\d{4}\.\d{2}\.\d{2}(-\d{2}-\d{2}-\d{2})?-[a-f0-9]+$'
$script:MoleAiCodexRelease = '^\d{1,9}\.\d{1,9}\.\d{1,9}([-.][0-9A-Za-z.]{1,64})?-(x86_64|aarch64)-pc-windows-msvc$'
$script:MoleAiClaudeRenamed = '^claude\.exe\.old\.\d{1,20}(\.\d{1,10})?$'
$script:MoleAiMaxCodeFiles = 1024
$script:MoleAiMaxWalkEntries = 50000

# Orders release names as their tools do: runs of digits by value, the rest by
# ordinal text, so 1.0.114 is newer than 1.0.9.
function Compare-MoleVersionName {
    param([string]$A, [string]$B)

    $i = 0; $j = 0
    while ($i -lt $A.Length -and $j -lt $B.Length) {
        if ([char]::IsDigit($A[$i]) -and [char]::IsDigit($B[$j])) {
            $si = $i; $sj = $j
            while ($i -lt $A.Length -and [char]::IsDigit($A[$i])) { $i++ }
            while ($j -lt $B.Length -and [char]::IsDigit($B[$j])) { $j++ }
            $x = $A.Substring($si, $i - $si).TrimStart('0')
            $y = $B.Substring($sj, $j - $sj).TrimStart('0')
            if ($x.Length -ne $y.Length) { return [Math]::Sign($x.Length - $y.Length) }
            $digits = [string]::CompareOrdinal($x, $y)
            if ($digits -ne 0) { return [Math]::Sign($digits) }
            continue
        }
        $c = [string]::CompareOrdinal([string]$A[$i], [string]$B[$j])
        if ($c -ne 0) { return [Math]::Sign($c) }
        $i++; $j++
    }
    return [Math]::Sign(($A.Length - $i) - ($B.Length - $j))
}

# $true when a process has any of these files open or mapped, $false when none
# does, $null when the Restart Manager could not answer (treated as in use).
function Test-MoleFilesInUse {
    param([string[]]$Paths)

    # Nothing to ask about is no evidence that nothing runs.
    if ($null -eq $Paths -or $Paths.Count -eq 0) { return $null }
    try {
        if (-not ('Mole.RestartManagerProbe' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace Mole {
    public static class RestartManagerProbe {
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmStartSession(out uint session, int flags, StringBuilder key);
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmRegisterResources(uint session, uint files, string[] names, uint apps, IntPtr unique, uint services, string[] serviceNames);
        [DllImport("rstrtmgr.dll")]
        private static extern int RmGetList(uint session, out uint needed, ref uint count, IntPtr info, out uint reasons);
        [DllImport("rstrtmgr.dll")]
        private static extern int RmEndSession(uint session);
        // 1 in use, 0 free, -1 unknown.
        public static int InUse(string[] paths) {
            uint session;
            if (RmStartSession(out session, 0, new StringBuilder(64)) != 0) return -1;
            try {
                for (int i = 0; i < paths.Length; i += 256) {
                    int n = Math.Min(256, paths.Length - i);
                    string[] batch = new string[n];
                    Array.Copy(paths, i, batch, 0, n);
                    if (RmRegisterResources(session, (uint)n, batch, 0, IntPtr.Zero, 0, null) != 0) return -1;
                }
                uint needed, count = 0, reasons;
                int rc = RmGetList(session, out needed, ref count, IntPtr.Zero, out reasons);
                if (rc == 234) return 1;
                if (rc != 0) return -1;
                return needed > 0 ? 1 : 0;
            }
            finally { RmEndSession(session); }
        }
    }
}
'@ -ErrorAction Stop
        }
        $answer = [Mole.RestartManagerProbe]::InUse([string[]]$Paths)
    }
    catch {
        Write-Debug "Restart Manager could not answer: $_"
        return $null
    }
    if ($answer -eq 1) { return $true }
    if ($answer -eq 0) { return $false }
    return $null
}

# Whether a process runs from a release: the file itself for a single-file
# release, else its .exe, .dll and .node files, at most 1024. More than that,
# none at all (an interpreter outside it may run it), a link inside or an
# unreadable folder answer $null.
function Test-MoleAiReleaseInUse {
    param([string]$Path)

    if ([IO.File]::Exists($Path)) { return Test-MoleFilesInUse -Paths @($Path) }
    $code = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($Path)
    $seen = 0
    try {
        while ($pending.Count -gt 0) {
            foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop)) {
                if (++$seen -gt $script:MoleAiMaxWalkEntries) { return $null }
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
                if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
                if ($item.Extension -in @('.exe', '.dll', '.node')) {
                    if ($code.Count -ge $script:MoleAiMaxCodeFiles) { return $null }
                    $code.Add($item.FullName)
                }
            }
        }
    }
    catch {
        return $null
    }
    if ($code.Count -eq 0) { return $null }
    return Test-MoleFilesInUse -Paths $code.ToArray()
}

function Test-MoleAiLinked {
    param($Item)
    return ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

# The plain folders (or files) directly in $Container whose names pass
# $IsRelease, less the newest by $OrderOf (every entry tied with it) and the
# pinned names. One release offers nothing. Any listing error offers nothing.
function Get-MoleAiSuperseded {
    param(
        [string]$Container,
        [scriptblock]$IsRelease,
        [scriptblock]$OrderOf,
        [string[]]$Pins = @()
    )

    $entries = @(Get-ChildItem -LiteralPath $Container -Force -ErrorAction Stop |
        Where-Object { $_.PSIsContainer -and -not (Test-MoleAiLinked $_) -and (& $IsRelease $_) })
    if ($entries.Count -lt 2) { return @() }
    $newest = $null
    foreach ($e in $entries) {
        $key = & $OrderOf $e.Name
        if ($null -eq $newest -or (Compare-MoleVersionName $key $newest) -gt 0) { $newest = $key }
    }
    return @($entries | Where-Object {
            (Compare-MoleVersionName (& $OrderOf $_.Name) $newest) -lt 0 -and $Pins -notcontains $_.Name
        } | ForEach-Object { $_.FullName })
}

function Test-MoleAiDirectChild {
    param([string]$Path, [string]$Parent)
    if (-not $Path) { return $false }
    $p = $Parent.TrimEnd('\')
    return $Path.StartsWith("$p\", [StringComparison]::OrdinalIgnoreCase) -and $Path.IndexOf('\', $p.Length + 1) -lt 0
}

# The length of the plain ~\.local\bin\claude.exe, or $null while Claude's
# state cannot be trusted: no such launcher, a link, or the install lock folder
# holding anything or unreadable.
function Get-MoleClaudeLauncherLength {
    $locks = Join-Path $env:USERPROFILE '.local\state\claude\locks'
    if (Test-Path -LiteralPath $locks) {
        $lockItem = Get-Item -LiteralPath $locks -Force -ErrorAction Stop
        if (-not $lockItem.PSIsContainer -or (Test-MoleAiLinked $lockItem)) { return $null }
        if (@(Get-ChildItem -LiteralPath $locks -Force -ErrorAction Stop).Count -gt 0) { return $null }
    }
    $launcher = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (-not [IO.File]::Exists($launcher)) { return $null }
    $item = Get-Item -LiteralPath $launcher -Force -ErrorAction Stop
    if ((Test-MoleAiLinked $item) -or $item.Length -le 0) { return $null }
    return [long]$item.Length
}

function Get-MoleClaudeOldVersions {
    param([string]$Root)
    $launcherLength = Get-MoleClaudeLauncherLength
    if ($null -eq $launcherLength) { return @() }
    $versions = @(Get-ChildItem -LiteralPath $Root -Force -File -ErrorAction Stop |
        Where-Object { $_.Name -match $script:MoleAiSemver -and -not (Test-MoleAiLinked $_) })
    # A launcher no version matches is not one Claude's installer copied.
    if ($versions.Count -lt 2 -or -not ($versions | Where-Object { $_.Length -eq $launcherLength })) { return @() }
    $newest = $null
    foreach ($v in $versions) { if ($null -eq $newest -or (Compare-MoleVersionName $v.Name $newest) -gt 0) { $newest = $v.Name } }
    return @($versions | Where-Object { (Compare-MoleVersionName $_.Name $newest) -lt 0 -and $_.Length -ne $launcherLength } |
        ForEach-Object { $_.FullName })
}

# The launcher copies an update renamed because they were running.
function Get-MoleClaudeRenamedLaunchers {
    param([string]$Root)
    if ($null -eq (Get-MoleClaudeLauncherLength)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Force -File -ErrorAction Stop |
        Where-Object { $_.Name -match $script:MoleAiClaudeRenamed -and -not (Test-MoleAiLinked $_) } |
        ForEach-Object { $_.FullName })
}

function Get-MoleCodexOldReleases {
    param([string]$Root)
    # The installer can put the PATH launcher elsewhere; Mole would not see which release it runs.
    if ($env:CODEX_INSTALL_DIR) { return @() }
    if (Test-Path -LiteralPath (Join-Path $Root 'install.lock.d')) { return @() }
    $lockFile = Join-Path $Root 'install.lock'
    if ([IO.File]::Exists($lockFile)) {
        # Shared with nobody: any other handle on it, as an install holds, makes this fail.
        try { ([IO.File]::Open($lockFile, 'Open', 'Read', 'None')).Dispose() }
        catch { return @() }
    }
    # Junction targets come back in their final spelling (long names, real
    # case), so the folder they must sit in is read the same way, and releases
    # are then pinned by name.
    $releases = (Resolve-MoleExistingPathInfo -Path (Join-Path $Root 'releases')).Path
    if (-not $releases) { return @() }
    $current = Get-Item -LiteralPath (Join-Path $Root 'current') -Force -ErrorAction SilentlyContinue
    if ($null -eq $current -or -not (Test-MoleAiLinked $current)) { return @() }
    $live = (Resolve-MoleExistingPathInfo -Path $current.FullName).Path
    if (-not (Test-MoleAiDirectChild $live $releases)) { return @() }
    $liveItem = Get-Item -LiteralPath $live -Force -ErrorAction Stop
    if (-not $liveItem.PSIsContainer -or (Test-MoleAiLinked $liveItem)) { return @() }
    $pins = @(Split-Path -Leaf $live)
    # The launcher on PATH is a second junction, to a release's bin; an install
    # stopped between moving the two leaves them on different releases.
    $visible = Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin'
    $visibleItem = Get-Item -LiteralPath $visible -Force -ErrorAction SilentlyContinue
    if ($null -ne $visibleItem -and (Test-MoleAiLinked $visibleItem)) {
        $bin = (Resolve-MoleExistingPathInfo -Path $visible).Path
        if (-not $bin -or (Split-Path -Leaf $bin) -ne 'bin') { return @() }
        $release = Split-Path -Parent $bin
        if (-not (Test-MoleAiDirectChild $release $releases)) { return @() }
        $pins += (Split-Path -Leaf $release)
    }
    $marker = Join-Path $Root 'auto-update-version'
    if (Test-Path -LiteralPath $marker) {
        $markerItem = Get-Item -LiteralPath $marker -Force -ErrorAction Stop
        if ($markerItem.PSIsContainer -or (Test-MoleAiLinked $markerItem) -or $markerItem.Length -eq 0 -or $markerItem.Length -gt 256) { return @() }
        $name = [IO.File]::ReadAllText($marker, (New-Object System.Text.UTF8Encoding($false, $true))).Trim()
        if ($name -notmatch $script:MoleAiCodexRelease) { return @() }
        $pins += $name
    }
    return Get-MoleAiSuperseded -Container $releases -Pins $pins -OrderOf { param($n) $n } -IsRelease {
        param($e) $e.Name -match $script:MoleAiCodexRelease -and [IO.File]::Exists((Join-Path $e.FullName 'bin\codex.exe'))
    }
}

# Cursor's launcher runs the version folder with the newest date, so every
# folder of that date stays.
function Get-MoleCursorAgentOldReleases {
    param([string]$Root)
    if (-not [IO.File]::Exists((Join-Path $Root 'cursor-agent.ps1')) -and -not [IO.File]::Exists((Join-Path $Root 'cursor-agent.cmd'))) { return @() }
    $versions = Join-Path $Root 'versions'
    if (-not [IO.Directory]::Exists($versions) -or (Test-Path -LiteralPath (Join-Path $versions '.promote-lock'))) { return @() }
    $all = @(Get-ChildItem -LiteralPath $versions -Force -ErrorAction Stop)
    if ($all | Where-Object { $_.Name -like '*.new' }) { return @() }
    $children = @($all | Where-Object { $_.PSIsContainer })
    # A mid-2026 launcher read only the short name form, so with both forms the
    # newest date may not be what runs.
    $forms = @($children | Where-Object { $_.Name -match $script:MoleAiCursorVersion } |
        ForEach-Object { $_.Name.Split('-').Length } | Sort-Object -Unique)
    if ($forms.Count -gt 1) { return @() }
    return Get-MoleAiSuperseded -Container $versions -OrderOf { param($n) $n.Split('-')[0] } -IsRelease {
        param($e) $e.Name -match $script:MoleAiCursorVersion
    }
}

# Copilot runs the newest unpacked release: only releases older than the newest
# complete one go.
function Get-MoleCopilotOldReleases {
    param([string]$Root)
    return Get-MoleAiSuperseded -Container $Root -OrderOf { param($n) $n } -IsRelease {
        param($e) $e.Name -match $script:MoleAiSemver -and [IO.File]::Exists((Join-Path $e.FullName '.extraction-complete'))
    }
}

function Get-MoleAiCliHomes {
    $profileRoot = $env:USERPROFILE
    $local = $env:LOCALAPPDATA
    return @(
        @{ Label = 'Claude Code old version'; Root = (Join-Path $profileRoot '.local\share\claude\versions'); Read = 'Get-MoleClaudeOldVersions' }
        @{ Label = 'Claude Code old version'; Root = (Join-Path $profileRoot '.local\bin'); Read = 'Get-MoleClaudeRenamedLaunchers' }
        @{ Label = 'Codex old version'; Root = (Join-Path $profileRoot '.codex\packages\standalone'); Read = 'Get-MoleCodexOldReleases' }
        @{ Label = 'Cursor Agent old version'; Root = (Join-Path $local 'cursor-agent'); Read = 'Get-MoleCursorAgentOldReleases' }
        @{ Label = 'GitHub Copilot CLI old version'; Root = (Join-Path $local 'copilot\pkg\win32-x64'); Read = 'Get-MoleCopilotOldReleases' }
        @{ Label = 'GitHub Copilot CLI old version'; Root = (Join-Path $local 'copilot\pkg\win32-arm64'); Read = 'Get-MoleCopilotOldReleases' }
    )
}

# Every superseded release as @{ Path; Label; Root; Read }. A home reached
# through a link, or one whose reading fails, offers nothing.
function Get-MoleAiCliOldReleases {
    if (-not $env:USERPROFILE -or -not $env:LOCALAPPDATA) { return @() }
    foreach ($aiHome in Get-MoleAiCliHomes) {
        if (-not [IO.Directory]::Exists($aiHome.Root)) { continue }
        if (-not (Get-MolePathSnapshot -Path $aiHome.Root)) { continue }
        try { $paths = @(& $aiHome.Read -Root $aiHome.Root) }
        catch {
            Write-Debug "$($aiHome.Label) kept: $($aiHome.Root) could not be read: $_"
            continue
        }
        foreach ($path in $paths) { @{ Path = $path; Label = $aiHome.Label; Root = $aiHome.Root; Read = $aiHome.Read } }
    }
}

# Right before the delete: the release is still superseded as its home reads
# now and nothing runs from it. An update since the scan may have made it the
# one in use, or a process may have started from it.
function Test-MoleAiReleaseStillOld {
    param([string]$Path)
    if (-not (@(Get-MoleAiCliOldReleases) | Where-Object { $_.Path -eq $Path })) { return $false }
    return (Test-MoleAiReleaseInUse -Path $Path) -eq $false
}

function Clear-AiCliOldVersions {
    <#
    .SYNOPSIS
        Remove the releases AI command-line tools keep after an update
    #>
    foreach ($release in @(Get-MoleAiCliOldReleases)) {
        if ((Test-MoleAiReleaseInUse -Path $release.Path) -ne $false) {
            Write-Debug "$($release.Label) kept: $($release.Path) is in use or its use is unknown"
            continue
        }
        $null = Remove-SafeItem -Path $release.Path -Description $release.Label -Guard { param($Path) Test-MoleAiReleaseStillOld -Path $Path }
    }
}

# ============================================================================
# Main Developer Tools Cleanup Function
# ============================================================================

function Invoke-DevToolsCleanup {
    <#
    .SYNOPSIS
        Run all developer tools cleanup tasks
    #>
    
    Start-Section "Developer tools"
    
    # JavaScript ecosystem
    Clear-NpmCache
    Clear-NodeBuildCaches
    
    # Python ecosystem
    Clear-PythonCaches
    
    # .NET ecosystem
    Clear-DotNetDevCaches
    
    # Go ecosystem
    Clear-GoCaches

    # mise cache
    Clear-MiseCache
    
    # Rust ecosystem
    Clear-RustCaches
    
    # JVM ecosystem: nothing is removed. Gradle lock files coordinate active
    # builds and downloads, and neither their age nor an idle process proves
    # removing one is safe. ~\.m2\repository is a default whitelist entry, so
    # the .lastUpdated markers inside it were never removable, and they free no
    # space; the macOS CLI leaves the Maven repository alone too.

    # Elixir/Erlang ecosystem
    Clear-ElixirCaches
    
    # Haskell ecosystem
    Clear-HaskellCaches
    
    # OCaml ecosystem
    Clear-OCamlCaches
    
    # Containers
    Clear-DockerCaches
    
    # Cloud CLI tools
    Clear-CloudCliCaches
    
    # Editor caches (VS Code, Zed, etc.)
    Clear-EditorCaches
    
    # IDEs (JetBrains, Visual Studio)
    Clear-IdeCaches
    
    # Git
    Clear-GitCaches

    # AI command-line tools' superseded releases (Claude Code, Codex, Cursor Agent, Copilot)
    Clear-AiCliOldVersions
    
    Stop-Section
}

# ============================================================================
# Exports
# ============================================================================
# Functions: Clear-NpmCache, Clear-PythonCaches, Clear-DockerCaches, etc.
