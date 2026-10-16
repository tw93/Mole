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
                $null = $stopper.WaitForExit(5000)
                $stopper.Dispose()
                $Outcome.Reason = (@($Outcome.Reason, "process tree $($process.Id) stopped with taskkill /T /F") | Where-Object { $_ }) -join "; "
            }
            catch {
                Write-Debug "$Name process tree cancellation failed: $_"
                $Outcome.Reason = (@($Outcome.Reason, "taskkill failed: $($_.Exception.Message)") | Where-Object { $_ }) -join "; "
            }
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
    param([string]$Name, [string[]]$Query, [string[]]$Arguments, [string]$Description)

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
    if (Test-DryRunMode) {
        # Selective owner pruning cannot promise the size of the whole store.
        Add-DryRunListEntries -Description $Description -Paths @($path)
        $script:OwnerCleanups++
        Write-DryRun $Description
        Set-SectionActivity
        return
    }
    # Query again at the boundary; a changed configuration is not the previewed root.
    $current = Get-MoleOwnerCachePath -Name $Name -Arguments $Query
    if ($current -ne $path -or -not (Test-SafePath $path) -or
        -not (Test-MolePathSnapshot $snapshot)) { return }
    foreach ($item in $tree.Items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }
        if (-not (Test-SafePath $item.FullName) -or
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
        if (Test-MolePathSnapshot $snapshot) {
            $after = Get-SafeDirectoryTreeItems -Path $path
            if ($after.Success -and (Test-MolePathSnapshot $snapshot)) {
                $afterFiles = @($after.Items | Where-Object { -not $_.PSIsContainer })
                $afterBytes = 0L
                foreach ($file in $afterFiles) { $afterBytes += $file.Length }
                $removedBytes = [Math]::Max(0, [long]$beforeBytes - [long]$afterBytes)
                $script:TotalSizeCleaned += [Math]::Floor($removedBytes / 1024)
                $script:FilesCleaned += [Math]::Max(0, $beforeFiles.Count - $afterFiles.Count)
                if ($removedBytes -gt 0) { $script:TotalItems++ }
            }
        }
        Write-Success $Description
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

    # Yarn cache
    $yarnCachePaths = @(
        "$env:LOCALAPPDATA\Yarn\Cache"
        "$env:USERPROFILE\.yarn\cache"
    )
    foreach ($path in $yarnCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Yarn cache"
        }
    }
    
    # Bun cache
    $bunCachePath = "$env:USERPROFILE\.bun\install\cache"
    if (Test-Path $bunCachePath) {
        Clear-DirectoryContents -Path $bunCachePath -Description "Bun cache"
    }
}

function Clear-NodeBuildCaches {
    <#
    .SYNOPSIS
        Clean Node.js build-related caches
    #>
    
    # node-gyp
    $nodeGypPath = "$env:LOCALAPPDATA\node-gyp\Cache"
    if (Test-Path $nodeGypPath) {
        Clear-DirectoryContents -Path $nodeGypPath -Description "node-gyp cache"
    }
    
    # Electron cache
    $electronCachePath = "$env:LOCALAPPDATA\electron\Cache"
    if (Test-Path $electronCachePath) {
        Clear-DirectoryContents -Path $electronCachePath -Description "Electron cache"
    }
    
    # TypeScript cache
    $tsCachePath = "$env:LOCALAPPDATA\TypeScript"
    if (Test-Path $tsCachePath) {
        Clear-DirectoryContents -Path $tsCachePath -Description "TypeScript cache"
    }
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
    if (Test-Path $poetryCachePath) {
        Clear-DirectoryContents -Path $poetryCachePath -Description "Poetry cache"
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
        Clear-DirectoryContents -Path $nugetHttpCache -Description "NuGet HTTP cache"
    }
    
    $nugetTempPath = "$env:LOCALAPPDATA\NuGet\plugins-cache"
    if (Test-Path $nugetTempPath) {
        Clear-DirectoryContents -Path $nugetTempPath -Description "NuGet plugins cache"
    }
    
    # MSBuild temp files
    $msbuildTemp = "$env:LOCALAPPDATA\Microsoft\MSBuild"
    if (Test-Path $msbuildTemp) {
        $tempDirs = Get-ChildItem -Path $msbuildTemp -Directory -Filter "*temp*" -ErrorAction SilentlyContinue
        foreach ($dir in $tempDirs) {
            Clear-DirectoryContents -Path $dir.FullName -Description "MSBuild temp"
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
    
    Invoke-MoleOwnerCacheCleanup -Name 'go' -Query @('env', 'GOCACHE') -Arguments @('clean', '-cache') -Description 'Go build cache'

    $moduleRoot = Get-MoleOwnerCachePath -Name 'go' -Arguments @('env', 'GOMODCACHE')
    if ($moduleRoot) {
        Clear-DirectoryContents -Path (Join-Path $moduleRoot 'cache') -Description 'Go module cache'
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
    
    # Cargo registry cache
    $cargoRegistryCache = "$env:USERPROFILE\.cargo\registry\cache"
    if (Test-Path $cargoRegistryCache) {
        Clear-DirectoryContents -Path $cargoRegistryCache -Description "Cargo registry cache"
    }
    
    # Cargo git cache
    $cargoGitCache = "$env:USERPROFILE\.cargo\git\checkouts"
    if (Test-Path $cargoGitCache) {
        Clear-DirectoryContents -Path $cargoGitCache -Description "Cargo git cache"
    }
    
    # Rustup downloads
    $rustupDownloads = "$env:USERPROFILE\.rustup\downloads"
    if (Test-Path $rustupDownloads) {
        Clear-DirectoryContents -Path $rustupDownloads -Description "Rustup downloads"
    }
}

# ============================================================================
# Java / JVM Ecosystem
# ============================================================================

function Clear-JvmCaches {
    <#
    .SYNOPSIS
        Clean JVM ecosystem caches (Gradle, Maven, etc.)
    #>
    
    # Gradle lock files coordinate active builds and downloads. Neither their
    # age nor an idle process proves that removing one is safe.

    # Maven repository (only clean temp files)
    $mavenRepoPath = "$env:USERPROFILE\.m2\repository"
    if (Test-Path $mavenRepoPath) {
        $tempFiles = Get-ChildItem -Path $mavenRepoPath -Recurse -Filter "*.lastUpdated" -ErrorAction SilentlyContinue
        if ($tempFiles) {
            $paths = $tempFiles | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "Maven update markers"
        }
    }
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
        $tempFiles = Get-ChildItem -Path $stackSnapshotsPath -Recurse -Filter "*.tmp" -ErrorAction SilentlyContinue
        if ($tempFiles) {
            $paths = $tempFiles | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "Stack temp files"
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
            Clear-DirectoryContents -Path $path -Description "VS Code cache"
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
            Clear-DirectoryContents -Path $path -Description "VS Code Insiders cache"
        }
    }
    
    # Zed editor cache
    $zedCachePaths = @(
        "$env:LOCALAPPDATA\Zed\cache"
        "$env:APPDATA\Zed\cache"
    )
    foreach ($path in $zedCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Zed cache"
        }
    }
    
    # Sublime Text cache
    $sublimeCachePath = "$env:APPDATA\Sublime Text\Cache"
    if (Test-Path $sublimeCachePath) {
        Clear-DirectoryContents -Path $sublimeCachePath -Description "Sublime Text cache"
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
            if (Test-Path $path.Path) {
                Clear-DirectoryContents -Path $path.Path -Description "Visual Studio cache"
            }
        }
    }
    
    # JetBrains IDEs caches
    $jetbrainsBasePaths = @(
        "$env:LOCALAPPDATA\JetBrains"
        "$env:APPDATA\JetBrains"
    )
    foreach ($basePath in $jetbrainsBasePaths) {
        if (Test-Path $basePath) {
            $ideFolders = Get-ChildItem -Path $basePath -Directory -ErrorAction SilentlyContinue
            foreach ($ideFolder in $ideFolders) {
                $cacheFolders = @("caches", "index", "tmp")
                foreach ($cacheFolder in $cacheFolders) {
                    $cachePath = Join-Path $ideFolder.FullName $cacheFolder
                    if (Test-Path $cachePath) {
                        Clear-DirectoryContents -Path $cachePath -Description "$($ideFolder.Name) $cacheFolder"
                    }
                }
            }
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
                      Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) }
        if ($cacheFiles) {
            $paths = $cacheFiles | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "GitHub CLI cache"
        }
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
    
    # JVM ecosystem
    Clear-JvmCaches
    
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
    
    Stop-Section
}

# ============================================================================
# Exports
# ============================================================================
# Functions: Clear-NpmCache, Clear-PythonCaches, Clear-DockerCaches, etc.
