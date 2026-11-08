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
