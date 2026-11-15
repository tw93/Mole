# Mole Windows - Hardlink Analyze Benchmark
# Compares two analyze builds on one fixture that holds hard links.
#
# Build A is the current windows head. Build B is the same tree with the
# hardlink dedup patch. Build both from separate checkouts: a dirty tree cannot
# produce A.
#
# The fixture total is known by construction. The script checks size and speed.

#Requires -Version 5.1
param(
    [string]$Root = "",
    [string]$BaselineDir = "",
    [string]$CandidateDir = "",
    [string]$BaselineExe = "",
    [string]$CandidateExe = "",
    [int]$FileCount = 30000,
    [int]$LinkCount = 60000,
    [int]$DirCount = 2000,
    [int]$AverageKiB = 64,
    [int]$Runs = 5,
    [switch]$GenerateOnly,
    [switch]$KeepFixture,
    [switch]$NoFail,
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Acceptance limits from the plan. Wall clock may grow this much, and peak
# memory may grow this many MB per 100k entries.
$script:WallClockLimit = 0.03
$script:MemoryMBPer100k = 16.0

function Show-BenchHelp {
    Write-Host ""
    Write-Host "Mole Windows - Hardlink Analyze Benchmark" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: .\bench_analyze_hardlinks.ps1 -BaselineDir <dir> -CandidateDir <dir>"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Root <dir>          Fixture path. Defaults to a fresh folder under TEMP."
    Write-Host "  -BaselineDir <dir>   Checkout of the windows head, without the patch."
    Write-Host "  -CandidateDir <dir>  Checkout that contains the patch."
    Write-Host "  -BaselineExe <exe>   Use a built analyze.exe instead of building one."
    Write-Host "  -CandidateExe <exe>  Use a built analyze.exe instead of building one."
    Write-Host "  -FileCount <n>       Unique files in the fixture. Default 30000."
    Write-Host "  -LinkCount <n>       Hard links to those files. Default 60000."
    Write-Host "  -DirCount <n>        Project folders that hold links. Default 2000."
    Write-Host "  -AverageKiB <n>      Mean unique file size. Default 64 KiB."
    Write-Host "  -Runs <n>            Runs per build. Default 5."
    Write-Host "  -GenerateOnly        Build the fixture, print its total, stop."
    Write-Host "  -KeepFixture         Keep the fixture after the run."
    Write-Host "  -NoFail              Report a failed check without a nonzero exit."
    Write-Host "  -ShowHelp            Show this help."
    Write-Host ""
}

if ($ShowHelp) {
    Show-BenchHelp
    return
}

function New-BenchFixture {
    param(
        [string]$Path,
        [int]$Files,
        [int]$Links,
        [int]$Directories,
        [int]$MeanKiB
    )

    $leaf = Split-Path -Leaf $Path
    if ($leaf -notlike "mole-analyze-bench-*") {
        throw "Refusing to use '$Path': the folder name must start with mole-analyze-bench-."
    }
    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to replace the existing folder '$Path'."
    }
    New-Item -ItemType Directory -Path $Path | Out-Null

    $store = Join-Path $Path "store"
    New-Item -ItemType Directory -Path $store | Out-Null

    $projectDirs = New-Object "System.Collections.Generic.List[string]"
    for ($index = 0; $index -lt $Directories; $index++) {
        $name = "project{0:d4}" -f $index
        $created = New-Item -ItemType Directory -Path (Join-Path $Path $name)
        $projectDirs.Add($created.FullName)
    }

    $spread = [Math]::Max(1, $MeanKiB * 2)
    $chunk = New-Object byte[] 65536
    $uniqueBytes = [int64]0

    for ($index = 0; $index -lt $Files; $index++) {
        $sizeKiB = 4 + (($index * 37) % $spread)
        $size = [int64]$sizeKiB * 1024
        $target = Join-Path $store ("blob{0:d6}.bin" -f $index)
        $stream = [System.IO.File]::Create($target)
        try {
            $remaining = $size
            while ($remaining -gt 0) {
                $count = [int][Math]::Min([int64]$chunk.Length, $remaining)
                $stream.Write($chunk, 0, $count)
                $remaining -= $count
            }
        }
        finally {
            $stream.Dispose()
        }
        $uniqueBytes += $size
    }

    for ($index = 0; $index -lt $Links; $index++) {
        $target = Join-Path $store ("blob{0:d6}.bin" -f ($index % $Files))
        $directory = $projectDirs[$index % $projectDirs.Count]
        $link = Join-Path $directory ("link{0:d6}.bin" -f $index)
        $null = New-Item -ItemType HardLink -Path $link -Target $target
        if ($index -eq 0) {
            $created = Get-Item -LiteralPath $link
            if ($created.LinkType -ne "HardLink") {
                throw "The fixture volume does not create hard links. Use an NTFS volume."
            }
        }
    }

    $truth = [pscustomobject]@{
        unique_bytes = $uniqueBytes
        unique_files = $Files
        links        = $Links
        directories  = $Directories
    }
    # Keep the truth file outside the fixture: anything inside is scanned.
    $truth | ConvertTo-Json | Set-Content -LiteralPath ($Path + ".truth.json") -Encoding ASCII
    return $truth
}

function Build-AnalyzeExe {
    param([string]$SourceDir, [string]$Label)

    $exe = Join-Path $env:TEMP ("mole-analyze-bench-{0}-{1}.exe" -f $Label, (Get-Date -Format "HHmmss"))
    Push-Location $SourceDir
    try {
        & go build -o $exe ./cmd/analyze/
        if ($LASTEXITCODE -ne 0) {
            throw "go build failed in $SourceDir"
        }
    }
    finally {
        Pop-Location
    }
    return $exe
}

function Invoke-OneRun {
    param([string]$Exe, [string]$Target)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Exe
    $startInfo.Arguments = "--json `"$Target`""
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($startInfo)
    # Read before waiting: a large JSON document fills the pipe buffer and the
    # process blocks until the parent drains it.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $peak = [int64]0
    while (-not $process.HasExited) {
        try {
            $process.Refresh()
            $current = $process.PeakWorkingSet64
            if ($current -gt $peak) {
                $peak = $current
            }
        }
        catch {
            # The process object can throw while it tears down; the earlier
            # samples still hold.
        }
        Start-Sleep -Milliseconds 50
    }
    $stopwatch.Stop()
    $process.WaitForExit()
    $process.Refresh()
    $peak = [Math]::Max($peak, [int64]$process.PeakWorkingSet64)

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()

    $result = [pscustomobject]@{
        seconds   = $stopwatch.Elapsed.TotalSeconds
        peakBytes = $peak
        exitCode  = $exitCode
        stderr    = $stderr
        document  = $null
    }
    if ($exitCode -eq 0 -and $stdout.Trim().Length -gt 0) {
        $result.document = $stdout | ConvertFrom-Json
    }
    return $result
}

function Get-Median {
    param([double[]]$Values)

    $sorted = $Values | Sort-Object
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) {
        return $sorted[$middle]
    }
    return ($sorted[$middle - 1] + $sorted[$middle]) / 2
}

function Measure-Build {
    param([string]$Label, [string]$Exe, [string]$Target, [int]$RunCount)

    $runs = New-Object "System.Collections.Generic.List[object]"
    for ($index = 1; $index -le $RunCount; $index++) {
        Write-Host ("  {0} run {1}/{2}" -f $Label, $index, $RunCount) -ForegroundColor DarkGray
        $run = Invoke-OneRun -Exe $Exe -Target $Target
        if ($run.exitCode -ne 0) {
            throw ("{0} exited {1}: {2}" -f $Label, $run.exitCode, $run.stderr.Trim())
        }
        if ($null -eq $run.document) {
            throw ("{0} printed no JSON" -f $Label)
        }
        $runs.Add($run)
    }

    $seconds = @()
    $peaks = @()
    foreach ($run in $runs) {
        $seconds += $run.seconds
        $peaks += $run.peakBytes
    }
    return [pscustomobject]@{
        label     = $Label
        medianSec = Get-Median -Values $seconds
        minSec    = ($seconds | Measure-Object -Minimum).Minimum
        maxSec    = ($seconds | Measure-Object -Maximum).Maximum
        peakMB    = [Math]::Max(0, (($peaks | Measure-Object -Maximum).Maximum / 1MB))
        total     = $runs[0].document.total_size
        files     = $runs[0].document.total_files
        status    = $runs[0].document.scan_status
    }
}

if ($Root -eq "") {
    $Root = Join-Path $env:TEMP ("mole-analyze-bench-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
}
if ((Split-Path -Leaf $Root) -notlike "mole-analyze-bench-*") {
    throw "Refusing to use '$Root': the folder name must start with mole-analyze-bench-. Use -GenerateOnly to build a fixture only."
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Mole Windows - Hardlink Benchmark" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("Fixture: {0}" -f $Root)

$truthPath = $Root + ".truth.json"
$createdFixture = $false
if (Test-Path -LiteralPath $truthPath) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "The truth file exists, but the fixture folder is missing: '$Root'."
    }
    $truth = Get-Content -LiteralPath $truthPath -Raw | ConvertFrom-Json
    Write-Host "Reusing the existing fixture." -ForegroundColor DarkGray
}
else {
    Write-Host "Building the fixture..." -ForegroundColor DarkGray
    $truth = New-BenchFixture -Path $Root -Files $FileCount -Links $LinkCount -Directories $DirCount -MeanKiB $AverageKiB
    $createdFixture = $true
}

$expectedBytes = [int64]$truth.unique_bytes
$expectedFiles = [int64]$truth.unique_files + [int64]$truth.links
Write-Host ("Files {0:N0}, links {1:N0}, folders {2:N0}" -f $truth.unique_files, $truth.links, $truth.directories)
Write-Host ("Fixture total: {0:N0} bytes, {1:N0} entries, {2:N0} links" -f $expectedBytes, $expectedFiles, $truth.links)
Write-Host ""

if ($GenerateOnly) {
    Write-Host "Fixture ready. Truth file: $truthPath" -ForegroundColor Green
    return
}

if ($BaselineExe -eq "") {
    if ($BaselineDir -eq "") {
        throw "Give -BaselineDir or -BaselineExe for build A. Use -GenerateOnly to build the fixture only."
    }
    Write-Host "Building A from $BaselineDir" -ForegroundColor DarkGray
    $BaselineExe = Build-AnalyzeExe -SourceDir $BaselineDir -Label "a"
}
if ($CandidateExe -eq "") {
    if ($CandidateDir -eq "") {
        throw "Give -CandidateDir or -CandidateExe for build B. Use -GenerateOnly to build the fixture only."
    }
    Write-Host "Building B from $CandidateDir" -ForegroundColor DarkGray
    $CandidateExe = Build-AnalyzeExe -SourceDir $CandidateDir -Label "b"
}

Write-Host ""
$baseline = Measure-Build -Label "A" -Exe $BaselineExe -Target $Root -RunCount $Runs
$candidate = Measure-Build -Label "B" -Exe $CandidateExe -Target $Root -RunCount $Runs

Write-Host ""
Write-Host "Results" -ForegroundColor Cyan
@($baseline, $candidate) | Format-Table -AutoSize @(
    @{ Label = "build"; Expression = { $_.label } },
    @{ Label = "median s"; Expression = { "{0:N2}" -f $_.medianSec } },
    @{ Label = "min s"; Expression = { "{0:N2}" -f $_.minSec } },
    @{ Label = "max s"; Expression = { "{0:N2}" -f $_.maxSec } },
    @{ Label = "peak MB"; Expression = { "{0:N1}" -f $_.peakMB } },
    @{ Label = "total bytes"; Expression = { "{0:N0}" -f $_.total } },
    @{ Label = "delta bytes"; Expression = { "{0:N0}" -f ($_.total - $expectedBytes) } },
    @{ Label = "files"; Expression = { "{0:N0}" -f $_.files } },
    @{ Label = "status"; Expression = { $_.status } }
)

$failures = New-Object "System.Collections.Generic.List[string]"

if (($baseline.total -le $expectedBytes) -and ([int64]$truth.links -gt 0)) {
    $failures.Add("A did not over-report. The fixture may not hold hard links.")
}
if ($candidate.total -ne $expectedBytes) {
    $failures.Add(("B total {0:N0} != fixture {1:N0}" -f $candidate.total, $expectedBytes))
}
if ($baseline.files -ne $expectedFiles -or $candidate.files -ne $expectedFiles) {
    $failures.Add("A or B reported the wrong file count")
}
if ($candidate.total -gt $baseline.total) {
    $failures.Add("B reported more than A")
}
if ($candidate.status -ne "complete") {
    $failures.Add(("B scan status is '{0}', not 'complete'" -f $candidate.status))
}

$wallClockGrowth = 0.0
if ($baseline.medianSec -gt 0) {
    $wallClockGrowth = ($candidate.medianSec - $baseline.medianSec) / $baseline.medianSec
}
if ($wallClockGrowth -gt $script:WallClockLimit) {
    $failures.Add(("{0:P1} slower than A, limit {1:P0}" -f $wallClockGrowth, $script:WallClockLimit))
}

$memoryBudgetMB = $script:MemoryMBPer100k * ([double]$expectedFiles / 100000.0)
if ($memoryBudgetMB -lt $script:MemoryMBPer100k) {
    $memoryBudgetMB = $script:MemoryMBPer100k
}
$memoryGrowthMB = $candidate.peakMB - $baseline.peakMB
if ($memoryGrowthMB -gt $memoryBudgetMB) {
    $failures.Add(("peak memory grew {0:N1} MB, budget {1:N1} MB" -f $memoryGrowthMB, $memoryBudgetMB))
}

Write-Host ""
Write-Host ("Wall clock change: {0:P1} (limit {1:P0})" -f $wallClockGrowth, $script:WallClockLimit)
Write-Host ("Peak memory change: {0:N1} MB (budget {1:N1} MB)" -f $memoryGrowthMB, $memoryBudgetMB)

if (-not $KeepFixture -and $createdFixture) {
    if (Test-Path -LiteralPath $Root) {
        # SAFE: this run created the fixture folder and owns its contents.
        Remove-Item -LiteralPath $Root -Recurse -Force
    }
    if (Test-Path -LiteralPath $truthPath) {
        Remove-Item -LiteralPath $truthPath -Force
    }
}
else {
    Write-Host ("Fixture kept at {0}" -f $Root) -ForegroundColor DarkGray
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "FAILED" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host ("  - " + $failure) -ForegroundColor Red
    }
    if (-not $NoFail) {
        exit 1
    }
    return
}

Write-Host ""
Write-Host "PASSED" -ForegroundColor Green
Write-Host "Record these numbers in the pull request, not in a tracked file." -ForegroundColor DarkGray
