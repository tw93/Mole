# Mole Windows - release tooling tests
# Covers the checksum writer, manifest rendering and the package-manager update hint.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:WindowsDir "scripts"
}

Describe "Release filesystem paths" {
    It "Passes a native filesystem path to consumers in <ScriptName>" -ForEach @(
        @{ ScriptName = "sign-release.ps1"; Variable = "assetDir" },
        @{ ScriptName = "new-release-zip.ps1"; Variable = "root" }
    ) {
        $native = Join-Path $TestDrive "native-path"
        New-Item -ItemType Directory -Path $native -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $native "payload.txt"), "payload")
        # UNC resolution can return a provider-qualified Path, which native
        # executables and System.IO cannot consume. Model that resolved value.
        Mock Resolve-Path {
            [pscustomobject]@{
                Path = "Microsoft.PowerShell.Core\FileSystem::$native"
                ProviderPath = $native
            }
        }
        $Path = $native
        $SourceDir = $native
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:ScriptsDir $ScriptName), [ref]$null, [ref]$null)
        $assignments = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -eq $Variable
        }, $true))
        $assignments.Count | Should -Be 1
        . ([scriptblock]::Create($assignments[0].Extent.Text))
        $resolved = Get-Variable -Name $Variable -ValueOnly
        $resolved | Should -BeExactly $native
        [IO.File]::ReadAllText((Join-Path $resolved "payload.txt")) | Should -Be "payload"
    }
}

Describe "write-checksums.ps1" {
    It "Writes one LF-terminated checksum line per file without a BOM" {
        $dir = Join-Path $TestDrive "sums"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path (Join-Path $dir "a.zip") -Value "zip"
        Set-Content -Path (Join-Path $dir "b.exe") -Value "exe"

        & (Join-Path $script:ScriptsDir "write-checksums.ps1") -Directory $dir -Files @("a.zip", "b.exe") 6>$null

        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $dir "SHA256SUMS.txt"))
        $bytes[0] | Should -Not -Be 0xEF
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $text | Should -Not -Match "`r"
        $lines = @($text.TrimEnd("`n") -split "`n")
        $lines.Count | Should -Be 2
        $expected = (Get-FileHash (Join-Path $dir "a.zip") -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines[0] | Should -Be "$expected  a.zip"
    }

    It "Fails when a listed file is missing" {
        $dir = Join-Path $TestDrive "missing"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        { & (Join-Path $script:ScriptsDir "write-checksums.ps1") -Directory $dir -Files @("absent.zip") } | Should -Throw "*absent.zip*"
    }
}

Describe "render-packaging.ps1" {
    BeforeAll {
        $script:Hash = "a" * 64
        $script:Sums = Join-Path $TestDrive "SHA256SUMS.txt"
        Set-Content -Path $script:Sums -Value @("$($script:Hash)  mole-1.31.0-x64.zip", ("b" * 64) + "  status-windows-x64.exe")
        $script:Out = Join-Path $TestDrive "packaging"
        & (Join-Path $script:ScriptsDir "render-packaging.ps1") -Version "1.31.0" -SumsFile $script:Sums -OutDir $script:Out -ReleaseDate "2026-10-11" 6>$null
    }

    It "Fills every placeholder in every manifest" {
        $files = @(Get-ChildItem -Path $script:Out -Recurse -File)
        $files.Count | Should -Be 4
        foreach ($file in $files) {
            [System.IO.File]::ReadAllText($file.FullName) | Should -Not -Match '\{\{'
        }
    }

    It "Points Scoop and winget at the tagged zip and its checksum" {
        $scoop = Get-Content (Join-Path $script:Out "scoop\mole.json") -Raw | ConvertFrom-Json
        $scoop.version | Should -Be "1.31.0"
        $scoop.architecture.'64bit'.url | Should -Be "https://github.com/tw93/Mole/releases/download/V1.31.0-windows/mole-1.31.0-x64.zip"
        $scoop.architecture.'64bit'.hash | Should -Be $script:Hash

        $installer = Get-Content (Join-Path $script:Out "winget\manifests\t\tw93\MoleCLI\1.31.0\tw93.MoleCLI.installer.yaml") -Raw
        $installer | Should -Match "InstallerSha256: $($script:Hash)"
        $installer | Should -Match "RelativeFilePath: mo.exe"
    }

    It "Refuses a release whose checksum file lacks the zip" {
        $sums = Join-Path $TestDrive "no-zip.txt"
        Set-Content -Path $sums -Value (("b" * 64) + "  status-windows-x64.exe")
        { & (Join-Path $script:ScriptsDir "render-packaging.ps1") -Version "1.31.0" -SumsFile $sums -OutDir (Join-Path $TestDrive "x") } | Should -Throw "*mole-1.31.0-x64.zip*"
    }
}

Describe "mo update for package-manager installs" {
    BeforeAll {
        $updateScript = Join-Path $script:WindowsDir "bin\update.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($updateScript, [ref]$null, [ref]$null)
        $function = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-PackageManagerUpgradeCommand"
            }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }

    It "Names the upgrade command for <Manager>" -ForEach @(
        @{ Manager = "winget"; Dir = "C:\Users\me\AppData\Local\Microsoft\WinGet\Packages\tw93.MoleCLI_Microsoft.Winget.Source_8wekyb3d8bbwe"; Expected = "winget upgrade tw93.MoleCLI" },
        @{ Manager = "Scoop"; Dir = "C:\Users\me\scoop\apps\mole\1.31.0"; Expected = "scoop update mole" },
        @{ Manager = "Chocolatey"; Dir = "C:\ProgramData\chocolatey\lib\mole\tools"; Expected = "choco upgrade mole" }
    ) {
        Get-PackageManagerUpgradeCommand -InstallDir $Dir | Should -Be $Expected
    }

    It "Names choco for an install under a custom ChocolateyInstall root" {
        $saved = $env:ChocolateyInstall
        try {
            $env:ChocolateyInstall = "D:\tools\choco\"
            Get-PackageManagerUpgradeCommand -InstallDir "D:\tools\choco\lib\mole\tools" | Should -Be "choco upgrade mole"
            # Another package's folder under the same root is not Mole's.
            Get-PackageManagerUpgradeCommand -InstallDir "D:\tools\choco\lib\molecule\tools" | Should -BeNullOrEmpty
        }
        finally {
            $env:ChocolateyInstall = $saved
        }
    }

    It "Returns nothing for a plain folder" {
        Get-PackageManagerUpgradeCommand -InstallDir "C:\Users\me\AppData\Local\Mole" | Should -BeNullOrEmpty
    }
}

Describe "new-release-zip.ps1" {
    It "Includes every README language linked by the packaged English README" {
        $build = Get-Content (Join-Path $script:ScriptsDir "build-release.ps1") -Raw
        $start = $build.IndexOf('# Copy all necessary files')
        $end = $build.IndexOf('$zipSize =', $start)
        $start | Should -BeGreaterThan -1
        $end | Should -BeGreaterThan $start

        # Execute the real staging and archive steps, without builds or signing.
        $projectRoot = $script:WindowsDir
        $scriptDir = $script:ScriptsDir
        $releaseDir = Join-Path $TestDrive "readme-release"
        $tempBuildDir = Join-Path $releaseDir "stage"
        $archiveName = "readme-fixture"
        New-Item -ItemType Directory -Path $tempBuildDir -Force | Out-Null
        . ([scriptblock]::Create($build.Substring($start, $end - $start))) 6>$null

        $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $english = [System.IO.File]::ReadAllText((Join-Path $projectRoot "README.md"))
            $languages = @([regex]::Matches($english, 'href="(README_[A-Z]+\.md)"') | ForEach-Object { $_.Groups[1].Value })
            $languages.Count | Should -BeGreaterThan 0
            foreach ($name in @("README.md") + $languages) {
                $entry = $archive.GetEntry($name)
                $entry | Should -Not -BeNullOrEmpty -Because "$name must ship with its language link"
                $reader = New-Object System.IO.StreamReader($entry.Open())
                try { $reader.ReadToEnd() | Should -BeExactly ([System.IO.File]::ReadAllText((Join-Path $projectRoot $name))) }
                finally { $reader.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }

    It "Stores entry names with forward slashes, as winget's archive check requires" {
        $source = Join-Path $TestDrive "zip-source"
        New-Item -ItemType Directory -Path (Join-Path $source "bin\nested") -Force | Out-Null
        Set-Content -Path (Join-Path $source "mole.ps1") -Value "#"
        Set-Content -Path (Join-Path $source "bin\nested\tool.ps1") -Value "#"
        $zip = Join-Path $TestDrive "release.zip"

        & (Join-Path $script:ScriptsDir "new-release-zip.ps1") -SourceDir $source -Destination $zip

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $names = @($archive.Entries | ForEach-Object { $_.FullName })
        }
        finally {
            $archive.Dispose()
        }
        $names | Should -Contain "bin/nested/tool.ps1"
        $names | Should -Contain "mole.ps1"
        @($names | Where-Object { $_.Contains('\') }).Count | Should -Be 0
    }

    It "Is the only way the release scripts build a zip" {
        foreach ($script in @("build-release.ps1", "sign-release.ps1")) {
            $text = Get-Content (Join-Path $script:ScriptsDir $script) -Raw
            $text | Should -Not -Match 'Compress-Archive|CreateFromDirectory'
            $text | Should -Match 'new-release-zip\.ps1'
        }
    }
}
