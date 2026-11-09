BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . "$script:RepoRoot\lib\core\base.ps1"
    . "$script:RepoRoot\lib\core\log.ps1"
    . "$script:RepoRoot\lib\core\ui.ps1"
    . "$script:RepoRoot\lib\core\file_ops.ps1"
    $ast = [Management.Automation.Language.Parser]::ParseFile("$script:RepoRoot\bin\purge.ps1", [ref]$null, [ref]$null)
    foreach ($definition in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ne 'Main' }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $patterns = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ArtifactPatterns' }, $false)
    . ([scriptblock]::Create($patterns.Extent.Text))
    function New-PurgeFixture {
        param([string]$Marker = 'package.json', [string]$Content = '{}', [string[]]$Artifacts = @('node_modules'))
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        Set-Content -LiteralPath (Join-Path $root $Marker) -Value $Content
        foreach ($name in $Artifacts) {
            $dir = New-Item -ItemType Directory -Path (Join-Path $root $name)
            Set-Content -LiteralPath (Join-Path $dir.FullName 'payload.txt') -Value 'fixture'
        }
        return $root
    }
}

Describe 'Purge project boundaries' {
    BeforeEach { Reset-CleanupStats; $script:ItemsCleaned = 0; Set-DryRunMode -Enabled $false }

    It 'keeps authored and unrelated generic folders in a Node project' {
        $root = New-PurgeFixture -Artifacts @('.idea', 'bin', 'obj', 'vendor', 'target', 'build', 'dist', 'node_modules')
        $names = @(Find-ProjectArtifacts $root | ForEach-Object Name)
        $names | Should -Contain 'node_modules'
        foreach ($name in @('.idea', 'bin', 'obj', 'vendor', 'target', 'build', 'dist')) { $names | Should -Not -Contain $name }
    }

    It 'keeps authored bin in an unversioned Go project' {
        $root = New-PurgeFixture -Marker 'go.mod' -Content 'module fixture' -Artifacts @('bin', 'vendor')
        $names = @(Find-ProjectArtifacts $root | ForEach-Object Name)
        $names | Should -Not -Contain 'bin'
        $names | Should -Contain 'vendor'
    }

    It 'keeps real ecosystem artifacts eligible' {
        foreach ($case in @(
            @{ Marker='app.csproj'; Content='<Project />'; Names=@('bin','obj') },
            @{ Marker='Cargo.toml'; Content='[package]'; Names=@('target') },
            @{ Marker='pom.xml'; Content='<project />'; Names=@('target') },
            @{ Marker='go.mod'; Content='module fixture'; Names=@('vendor') },
            @{ Marker='composer.json'; Content='{}'; Names=@('vendor') },
            @{ Marker='package.json'; Content='{"scripts":{"build":"vite build"}}'; Names=@('build','dist') },
            @{ Marker='build.gradle'; Content='plugins {}'; Names=@('build') }
        )) {
            $root = New-PurgeFixture -Marker $case.Marker -Content $case.Content -Artifacts $case.Names
            $names = @(Find-ProjectArtifacts $root | ForEach-Object Name)
            foreach ($name in $case.Names) { $names | Should -Contain $name }
        }
    }

    It 'matches tracked artifacts under literal bracket project names' {
        $root = New-PurgeFixture
        $repository = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $repository
        $project = Join-Path $repository 'project[literal]'
        Move-Item -LiteralPath $root -Destination $project
        & git -C $repository init -q
        @(Find-ProjectArtifacts $project).Count | Should -Be 1
        & git --literal-pathspecs -C $repository add -- 'project[literal]/node_modules/payload.txt'
        $LASTEXITCODE | Should -Be 0
        @(Find-ProjectArtifacts $project).Count | Should -Be 0
    }

    It 'reads Git root paths as UTF8 for Unicode projects' {
        $root = New-PurgeFixture
        $unicodeRoot = $root + [char]0x6D4B + [char]0x8BD5
        Move-Item -LiteralPath $root -Destination $unicodeRoot
        & git -C $unicodeRoot init -q
        @(Find-ProjectArtifacts $unicodeRoot).Count | Should -Be 1
        & git -C $unicodeRoot add -- 'node_modules/payload.txt'
        $LASTEXITCODE | Should -Be 0
        @(Find-ProjectArtifacts $unicodeRoot).Count | Should -Be 0
    }

    It 'keeps tracked content without relying on wildcard path failure' {
        $root = New-PurgeFixture
        & git -C $root init -q
        & git -C $root add -- 'node_modules/payload.txt'
        $LASTEXITCODE | Should -Be 0
        @(Find-ProjectArtifacts $root).Count | Should -Be 0
    }

    It 'finds untracked artifacts under literal bracket project paths' {
        $root = New-PurgeFixture
        $bracketRoot = $root + '[literal]'
        Move-Item -LiteralPath $root -Destination $bracketRoot
        @(Find-ProjectArtifacts $bracketRoot).Count | Should -Be 1
    }

    It 'keeps nested repositories' {
        $root = New-PurgeFixture
        $nested = Join-Path $root 'node_modules\child'
        $null = New-Item -ItemType Directory -Path $nested
        & git -C $nested init -q
        $LASTEXITCODE | Should -Be 0
        @(Find-ProjectArtifacts $root).Count | Should -Be 0
    }

    It 'keeps candidates when Git inspection fails' {
        $root = New-PurgeFixture
        $null = New-Item -ItemType Directory -Path (Join-Path $root '.git')
        @(Find-ProjectArtifacts $root).Count | Should -Be 0
    }

    It 'checks Git again immediately before removal after sizing' {
        $root = New-PurgeFixture
        & git -C $root init -q
        $artifact = @(Find-ProjectArtifacts $root)
        $artifact.Count | Should -Be 1
        $script:ChangingProject = $root
        Mock Get-ValidatedTreeSize {
            & git -C $script:ChangingProject add -- 'node_modules/payload.txt'
            if ($LASTEXITCODE -ne 0) { throw 'fixture Git add failed' }
            return 8
        }
        Remove-ProjectArtifacts @([pscustomobject]@{Path=$root; Name='fixture'; Artifacts=$artifact}) 6>$null
        Test-Path -LiteralPath (Join-Path $root 'node_modules\payload.txt') | Should -BeTrue
        $script:ItemsCleaned | Should -Be 0
    }

    It 'keeps candidates when the content walk is incomplete' {
        $root = New-PurgeFixture
        Mock Get-TreeItemsNoFollow { throw 'fixture walk timeout' }
        @(Find-ProjectArtifacts $root).Count | Should -Be 0
    }

    It 'does not discover dependency packages as independent projects' {
        $root = New-PurgeFixture
        $package = Join-Path $root 'node_modules\dependency'
        $null = New-Item -ItemType Directory -Path $package
        Set-Content -LiteralPath (Join-Path $package 'package.json') '{}'
        $projects = @(Get-PurgeProjectDirectories $root)
        $projects.Count | Should -Be 1
        $projects[0].Path | Should -Be $root
    }

    It 'does not inherit Git index or pathspec overrides' {
        $root = New-PurgeFixture
        & git -C $root init -q
        & git -C $root add -- 'node_modules/payload.txt'
        $oldIndex = $env:GIT_INDEX_FILE
        $oldLiteral = $env:GIT_LITERAL_PATHSPECS
        try {
            $env:GIT_INDEX_FILE = Join-Path $TestDrive 'empty-index'
            $env:GIT_LITERAL_PATHSPECS = '1'
            @(Find-ProjectArtifacts $root).Count | Should -Be 0
        }
        finally { $env:GIT_INDEX_FILE=$oldIndex; $env:GIT_LITERAL_PATHSPECS=$oldLiteral }
    }
}

Describe 'Purge search paths' {
    BeforeEach {
        $script:DefaultSearchPaths = @($TestDrive)
    }

    It 'stops on a config it cannot read instead of scanning the default paths' {
        $script:ConfigFile = Join-Path $TestDrive 'unreadable-config'
        $null = New-Item -ItemType Directory -Path $script:ConfigFile -Force

        { Get-SearchPaths } | Should -Throw '*Cannot read your purge paths*'
    }

    It 'falls back to the default paths when the config is missing' {
        $script:ConfigFile = Join-Path $TestDrive 'missing-config'

        @(Get-SearchPaths) | Should -Be @($TestDrive)
    }
}

Describe 'Purge project labels' {
    BeforeAll { $script:OldProfile = $env:USERPROFILE }
    BeforeEach { $env:USERPROFILE = 'C:\Users\dev' }
    AfterAll { $env:USERPROFILE = $script:OldProfile }

    It 'shows paths under the profile from ~' {
        Get-PurgeDisplayPath 'C:\Users\dev\code\shop\frontend' | Should -BeExactly '~\code\shop\frontend'
        Get-PurgeDisplayPath 'c:\users\DEV\code\blog\frontend' | Should -BeExactly '~\code\blog\frontend'
        Get-PurgeDisplayPath 'C:\Users\dev' | Should -BeExactly '~'
        Get-PurgeDisplayPath 'C:/Users/dev/code/app' | Should -BeExactly '~\code\app'
    }

    It 'keeps other paths, including a profile prefix sibling, in full' {
        Get-PurgeDisplayPath 'D:\work\shop\frontend' | Should -BeExactly 'D:\work\shop\frontend'
        Get-PurgeDisplayPath 'C:\Users\dev2\shop\frontend' | Should -BeExactly 'C:\Users\dev2\shop\frontend'
        $env:USERPROFILE = ''
        Get-PurgeDisplayPath 'C:\Users\dev\shop\frontend' | Should -BeExactly 'C:\Users\dev\shop\frontend'
    }

    It 'labels same-named projects by their path' {
        Mock Write-Progress {}
        Mock Get-PurgeProjectDirectories { @(
            [pscustomobject]@{ Path = 'C:\Users\dev\code\shop\frontend'; Marker = 'package.json' },
            [pscustomobject]@{ Path = 'C:\Users\dev\code\blog\frontend'; Marker = 'package.json' }) }
        Mock Find-ProjectArtifacts { [pscustomobject]@{ Name = 'node_modules'; SizeKB = 10 } }
        $labels = @(Find-Projects -SearchPaths @('C:\Users\dev\code') | ForEach-Object DisplayPath)
        $labels | Should -Contain '~\code\shop\frontend'
        $labels | Should -Contain '~\code\blog\frontend'
    }

    It 'names each project by its path while cleaning' {
        $script:CleaningLines = @()
        Mock Write-Host { $script:CleaningLines += "$Object" }
        $profileRoot = Join-Path $TestDrive 'profile'
        $env:USERPROFILE = $profileRoot
        $projects = foreach ($parent in 'shop', 'blog') {
            [pscustomobject]@{ Path = Join-Path $profileRoot "$parent\frontend"; Name = 'frontend'; Artifacts = @() }
        }
        Remove-ProjectArtifacts -Projects $projects
        ($script:CleaningLines -join "`n") | Should -Match ([regex]::Escape('~\shop\frontend'))
        ($script:CleaningLines -join "`n") | Should -Match ([regex]::Escape('~\blog\frontend'))
    }
}

AfterAll {
    # Git fixtures create read-only object files; clear only their attributes so
    # Pester can remove its own TestDrive after the tests.
    Get-ChildItem -LiteralPath $TestDrive -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '[\\/]\.git[\\/]' } |
        ForEach-Object { $_.IsReadOnly = $false }
}

Describe 'Purge leaves an artifact in use alone' {
    BeforeEach {
        Reset-CleanupStats; $script:ItemsCleaned = 0; $script:ItemsHeld = 0; $script:ArtifactsHeldAtScan = 0; Set-DryRunMode -Enabled $false
        $script:held = @()
    }
    AfterEach {
        foreach ($item in $script:held) {
            if ($item -is [Diagnostics.Process]) { Stop-Process -Id $item.Id -Force -ErrorAction SilentlyContinue; $null = $item.WaitForExit(5000) }
            else { $item.Dispose() }
        }
        Set-DryRunMode -Enabled $false
    }

    It 'reads the process list by image path, name boundary and path spelling' {
        function Snapshot($id, $image, $line) { @{ Known = $true; List = @([pscustomobject]@{ ProcessId = $id; ExecutablePath = $image; CommandLine = $line }) } }
        Test-PurgeProcessNames 'C:\p\DIST' (Snapshot 1 'C:\p\dist\app.exe' '') | Should -BeTrue
        Test-PurgeProcessNames 'C:\p\dis' (Snapshot 1 'C:\p\dist\app.exe' '') | Should -BeFalse
        foreach ($line in @('node C:/p/dist/server.js', 'node "C:\p\dist"', 'x (C:\p\dist)', 'x C:\p\dist|y')) {
            Test-PurgeProcessNames 'C:\p\dist' (Snapshot 2 '' $line) | Should -BeTrue -Because $line
        }
        Test-PurgeProcessNames 'C:\p\dist' (Snapshot 4 '' 'node C:\p\dist-old\server.js') | Should -BeFalse
        Test-PurgeProcessNames 'C:\p\dist' (Snapshot $PID '' 'mo purge C:\p\dist') | Should -BeFalse
    }

    It 'retains an artifact when the process list is unknown, and says so' {
        $root = New-PurgeFixture
        $unknown = @{ Known = $false; List = @() }
        Get-PurgeArtifactHold (Join-Path $root 'node_modules') $unknown | Should -Be 'unknown'
        @(Find-ProjectArtifacts $root $unknown).Count | Should -Be 0
        $found = @(Find-ProjectArtifacts $root)
        Mock Get-PurgeProcessSnapshot { @{ Known = $false; List = @() } }
        $output = Remove-ProjectArtifacts -Projects @([pscustomobject]@{ Path = $root; Artifacts = $found }) 6>&1 | Out-String
        $output | Should -Match 'could not check'
        Test-Path -LiteralPath (Join-Path $root 'node_modules\payload.txt') | Should -BeTrue
    }

    It 'does not offer an artifact a running process names, and offers it once that stops' {
        $root = New-PurgeFixture
        $artifact = Join-Path $root 'node_modules'
        $process = Start-Process -FilePath "$env:ComSpec" -ArgumentList '/k', 'rem', "$artifact\x" -WindowStyle Hidden -PassThru
        $script:held += $process
        Start-Sleep -Milliseconds 500
        @(Find-ProjectArtifacts $root).Count | Should -Be 0
        Stop-Process -Id $process.Id -Force
        $null = $process.WaitForExit(5000)
        @(Find-ProjectArtifacts $root).Count | Should -Be 1
    }

    It 'a file held with <Share> sharing keeps the whole folder until it closes' -TestCases @(
        @{ Share = 'None' }
        @{ Share = 'ReadWrite' }
        @{ Share = 'ReadWrite,Delete' }
    ) {
        $root = New-PurgeFixture
        $artifact = Join-Path $root 'node_modules'
        $second = Join-Path $artifact 'other.txt'
        Set-Content -LiteralPath $second -Value 'kept'
        $found = @(Find-ProjectArtifacts $root)
        $found.Count | Should -Be 1
        $handle = [IO.File]::Open((Join-Path $artifact 'payload.txt'), 'Open', 'Read', $Share)
        $script:held += $handle
        @(Find-ProjectArtifacts $root).Count | Should -Be 0
        $output = Remove-ProjectArtifacts -Projects @([pscustomobject]@{ Path = $root; Artifacts = $found }) 6>&1 | Out-String
        $output | Should -Match 'in use'
        Test-Path -LiteralPath $second | Should -BeTrue
        $script:ItemsCleaned | Should -Be 0
        $handle.Dispose()
        $found = @(Find-ProjectArtifacts $root)
        Remove-ProjectArtifacts -Projects @([pscustomobject]@{ Path = $root; Artifacts = $found }) *> $null
        Test-Path -LiteralPath $artifact | Should -BeFalse
        $script:ItemsCleaned | Should -Be 1
    }

    It 'a working directory inside the folder keeps it, even nested' {
        $root = New-PurgeFixture
        $artifact = Join-Path $root 'node_modules'
        $nested = New-Item -ItemType Directory -Path (Join-Path $artifact 'pkg\lib')
        $found = @(Find-ProjectArtifacts $root)
        $process = Start-Process -FilePath "$env:ComSpec" -ArgumentList '/k' -WorkingDirectory $nested.FullName -WindowStyle Hidden -PassThru
        $script:held += $process
        Start-Sleep -Milliseconds 500
        Remove-ProjectArtifacts -Projects @([pscustomobject]@{ Path = $root; Artifacts = $found }) *> $null
        Test-Path -LiteralPath (Join-Path $artifact 'payload.txt') | Should -BeTrue
        $script:ItemsCleaned | Should -Be 0
        $script:ItemsHeld | Should -Be 1
    }

    It 'a skipped artifact leaves a SKIPPED row naming the reason' {
        $root = New-PurgeFixture
        $artifact = Join-Path $root 'node_modules'
        $found = @(Find-ProjectArtifacts $root)
        Mock Write-MoleOperation {}
        $handle = [IO.File]::Open((Join-Path $artifact 'payload.txt'), 'Open', 'Read', 'ReadWrite,Delete')
        try { Remove-ProjectArtifacts -Projects @([pscustomobject]@{ Path = $root; Artifacts = $found }) *> $null }
        finally { $handle.Dispose() }
        Should -Invoke Write-MoleOperation -Times 1 -ParameterFilter { $Action -eq 'SKIPPED' -and $Path -eq $artifact -and $Detail -eq 'in use' }
    }

    It 'a library loaded from the folder keeps it after its file handle closed' {
        if (-not ('Mole.TestLoader' -as [type])) {
            Add-Type -TypeDefinition 'namespace Mole { public static class TestLoader {
                [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern System.IntPtr LoadLibraryExW(string p, System.IntPtr h, uint f);
                [System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool FreeLibrary(System.IntPtr h); } }'
        }
        $root = New-PurgeFixture
        $artifact = Join-Path $root 'node_modules'
        $dll = Join-Path $artifact 'addon.dll'
        Copy-Item -LiteralPath "$env:WINDIR\System32\version.dll" -Destination $dll
        Get-PurgeFirstHeldEntry $artifact | Should -BeNullOrEmpty
        $library = [Mole.TestLoader]::LoadLibraryExW($dll, [IntPtr]::Zero, 0)
        $library | Should -Not -Be ([IntPtr]::Zero)
        try { Get-PurgeFirstHeldEntry $artifact | Should -Match 'addon\.dll$' }
        finally { $null = [Mole.TestLoader]::FreeLibrary($library) }
        Get-PurgeFirstHeldEntry $artifact | Should -BeNullOrEmpty
    }

    It 'a dry run reports a held folder the same as a real run and removes nothing' {
        $root = New-PurgeFixture
        $artifact = Join-Path $root 'node_modules'
        $found = @(Find-ProjectArtifacts $root)
        $handle = [IO.File]::Open((Join-Path $artifact 'payload.txt'), 'Open', 'Read', 'ReadWrite,Delete')
        $script:held += $handle
        Set-DryRunMode -Enabled $true
        $output = Remove-ProjectArtifacts -Projects @([pscustomobject]@{ Path = $root; Artifacts = $found }) 6>&1 | Out-String
        $output | Should -Match 'in use'
        $script:ItemsCleaned | Should -Be 0
        @(Get-ChildItem -LiteralPath $artifact -Force).Count | Should -Be 1
    }

    It 'a read-only file and a junction do not read as held, and the probe stays out of the target' {
        $root = New-PurgeFixture
        $artifact = Join-Path $root 'node_modules'
        $readonly = Join-Path $artifact 'readonly.txt'
        Set-Content -LiteralPath $readonly -Value 'x'
        (Get-Item -LiteralPath $readonly).IsReadOnly = $true
        $target = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $target
        $outside = Join-Path $target 'held.txt'
        Set-Content -LiteralPath $outside -Value 'x'
        $null = New-Item -ItemType Junction -Path (Join-Path $artifact 'link') -Target $target
        $handle = [IO.File]::Open($outside, 'Open', 'Read', 'ReadWrite,Delete')
        $script:held += $handle
        Get-PurgeFirstHeldEntry $artifact | Should -BeNullOrEmpty
    }

    It 'names a probe failure as unknown, not as in use' {
        Mock Get-PurgeFirstHeldEntry { throw 'Access is denied' }
        Get-PurgeArtifactHold (Join-Path (New-PurgeFixture) 'node_modules') @{ Known = $true; List = @() } | Should -Be 'unknown'
    }

    It 'the probe leaves timestamps alone, and a file denying write can still go' {
        $root = New-PurgeFixture
        $artifact = Join-Path $root 'node_modules'
        $file = Join-Path $artifact 'payload.txt'
        $stamp = [datetime]'2020-01-02 03:04:05'
        (Get-Item -LiteralPath $file).LastWriteTime = $stamp
        Get-PurgeFirstHeldEntry $artifact | Should -BeNullOrEmpty
        (Get-Item -LiteralPath $file).LastWriteTime | Should -Be $stamp
        & icacls.exe $file /deny "$($env:USERNAME):(W)" | Out-Null
        try {
            $LASTEXITCODE | Should -Be 0
            Get-PurgeFirstHeldEntry $artifact | Should -BeNullOrEmpty
        }
        finally { & icacls.exe $file /reset | Out-Null }
    }

    It 'a summary with nothing removed names what was skipped' {
        $script:TotalSizeCleaned = 0
        $script:ItemsHeld = 2
        Mock Show-SummaryBlock { $script:summaryDetails = $Details }
        Mock Get-FreeSpace { '1 GB' }
        Show-PurgeSummary
        ($script:summaryDetails -join ' ') | Should -Match 'Skipped 2'
    }

    It 'a command line naming the folder in any absolute spelling keeps it' {
        $root = New-PurgeFixture
        $artifact = Join-Path $root 'node_modules'
        $doubled = $artifact.Replace('\', '\\')
        foreach ($line in @("node -e require('$doubled\\x.js')", "node --roots=[$artifact]", "node <$artifact>", "node $($artifact.Replace('\', '/'))/x.js")) {
            Test-PurgeProcessNames $artifact @{ Known = $true; List = @([pscustomobject]@{ ProcessId = -1; ExecutablePath = ''; CommandLine = $line }) } | Should -BeTrue -Because $line
        }
        foreach ($line in @("node $artifact-old\x.js", "node $artifact.bak", "node ${artifact}2")) {
            Test-PurgeProcessNames $artifact @{ Known = $true; List = @([pscustomobject]@{ ProcessId = -1; ExecutablePath = ''; CommandLine = $line }) } | Should -BeFalse -Because $line
        }
    }

    It 'the script starts both skip counters at zero under strict mode' {
        $ast = [Management.Automation.Language.Parser]::ParseFile("$script:RepoRoot\bin\purge.ps1", [ref]$null, [ref]$null)
        foreach ($name in '$script:ItemsHeld', '$script:ArtifactsHeldAtScan') {
            @($ast.EndBlock.Statements | Where-Object { $_.Extent.Text -eq "$name = 0" }).Count | Should -Be 1
        }
    }

    It 'a real run with every artifact in use says so instead of finding nothing' {
        $home2 = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $searchRoot = Join-Path $home2 'projects'
        $null = New-Item -ItemType Directory -Path (Join-Path $home2 '.config\mole'), $searchRoot
        $root = Join-Path $searchRoot 'app'
        Move-Item -LiteralPath (New-PurgeFixture) -Destination $root
        Set-Content -LiteralPath (Join-Path $home2 '.config\mole\purge_paths.txt') -Value $searchRoot
        $holder = [IO.File]::Open((Join-Path $root 'node_modules\payload.txt'), 'Open', 'Read', 'ReadWrite,Delete')
        $saved = $env:USERPROFILE
        try {
            $env:USERPROFILE = $home2
            $output = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File "$script:RepoRoot\bin\purge.ps1" -DryRun 2>&1 | Out-String
            $exit = $LASTEXITCODE
        }
        finally { $env:USERPROFILE = $saved; $holder.Dispose() }
        $exit | Should -Be 0 -Because $output
        $output | Should -Match '1 in use or unchecked'
        $output | Should -Not -Match 'No cleanable artifacts found'
    }

    It 'an idle folder is removed by the real sink' {
        $root = New-PurgeFixture
        $found = @(Find-ProjectArtifacts $root)
        Remove-ProjectArtifacts -Projects @([pscustomobject]@{ Path = $root; Artifacts = $found }) *> $null
        Test-Path -LiteralPath (Join-Path $root 'node_modules') | Should -BeFalse
        $script:ItemsCleaned | Should -Be 1
    }
}
