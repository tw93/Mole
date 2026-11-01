# Mole Windows - dry-run and accounting tests for uninstall and purge
# The functions are lifted out of the command scripts so no menu or prompt runs.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir "lib"
    . "$script:LibDir\core\base.ps1"
    . "$script:LibDir\core\log.ps1"
    . "$script:LibDir\core\ui.ps1"
    . "$script:LibDir\core\file_ops.ps1"

    function Import-ScriptFunction {
        param([string]$Script, [string[]]$Names)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
        foreach ($name in $Names) {
            $definition = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                }, $true)
            if (-not $definition) { throw "$name not found in $Script" }
            . ([scriptblock]::Create($definition.Extent.Text))
            Set-Item -Path "function:script:$name" -Value (Get-Item "function:$name").ScriptBlock
        }
    }

    Import-ScriptFunction -Script (Join-Path $script:WindowsDir "bin\uninstall.ps1") -Names @(
        "Get-UninstallMethodDescription", "Show-UninstallChargeLimitNote", "Uninstall-SelectedApps", "Test-MoleStoreRemovalAllowed", "Invoke-MoleUninstallProcess", "Get-MoleProperty", "Get-NormalizedFolderPath",
        "Test-MoleInstallContentFree", "Test-MoleInstallFolder", "Get-MoleInstallOwners", "Test-MoleLeftoverOwnership", "Test-UninstallEntryGone", "Get-MsiProductCode", "Split-UninstallCommand", "Test-InnoUninstaller",
        "Test-NsisUninstaller", "Test-SteamClientUninstaller", "Get-UninstallLaunch"
    )
    Import-ScriptFunction -Script (Join-Path $script:WindowsDir "bin\purge.ps1") -Names @(
        "Remove-ProjectArtifacts", "Get-PurgeDisplayPath", "Test-PurgeArtifactKind", "Test-PurgeArtifactContent", "Invoke-PurgeGit"
    )
    $script:AppCacheFile = Join-Path $TestDrive "no-cache.json"
}

AfterAll {
    Set-DryRunMode -Enabled $false
}

Describe "mo uninstall --dry-run" {
    BeforeEach {
        Set-DryRunMode -Enabled $true
        Reset-CleanupStats
        Mock Get-MoleInstallOwners { @{ Complete = $true; Owners = @() } }
        Mock Invoke-MoleUninstallProcess { throw "Uninstaller must not run in a dry run" }
        Mock Remove-AppxPackage { throw "Remove-AppxPackage must not run in a dry run" }
        Mock Test-MoleStoreRemovalAllowed { $true }
    }

    It "Runs no uninstaller for MSI, EXE or Store apps" {
        $leftover = Join-Path $TestDrive "App Folder"
        New-Item -ItemType Directory -Path $leftover -Force | Out-Null
        Set-Content -Path (Join-Path $leftover "app.dll") -Value "x"
        $apps = @(
            [pscustomobject]@{ Name = "Msi App"; Source = "Registry"; UninstallString = "MsiExec.exe /X{11111111-2222-3333-4444-555555555555}"; InstallLocation = $leftover; PackageFullName = $null },
            [pscustomobject]@{ Name = "Exe App"; Source = "Registry"; UninstallString = "C:\Program Files\Exe App\uninstall.exe"; InstallLocation = $null; PackageFullName = $null },
            [pscustomobject]@{ Name = "Store App"; Source = "WindowsStore"; UninstallString = $null; InstallLocation = $null; PackageFullName = "Store.App_1.0_x64__abc" }
        )

        { Uninstall-SelectedApps -Apps $apps 6>$null } | Should -Not -Throw

        Should -Invoke Invoke-MoleUninstallProcess -Times 0
        Should -Invoke Remove-AppxPackage -Times 0
        Test-Path (Join-Path $leftover "app.dll") | Should -BeTrue
    }

    It "Describes the MSI product code it would remove" {
        $app = [pscustomobject]@{ Source = "Registry"; UninstallString = "MsiExec.exe /X{11111111-2222-3333-4444-555555555555}" }
        Get-UninstallMethodDescription -App $app | Should -Be "msiexec /x {11111111-2222-3333-4444-555555555555}"
    }
}

Describe "mo purge accounting" {
    It "Counts each removed artifact's size once" {
        Set-DryRunMode -Enabled $false
        Reset-CleanupStats
        $script:ItemsCleaned = 0
        $artifact = Join-Path $TestDrive "project\node_modules"
        New-Item -ItemType Directory -Path $artifact -Force | Out-Null
        Set-Content -Path (Join-Path $artifact "index.js") -Value ("x" * 8192)
        $sizeKB = [Math]::Ceiling((Get-PathSize -Path $artifact) / 1024)
        $project = [pscustomobject]@{
            Name      = "project"
            Path      = Split-Path -Parent $artifact
            Artifacts = @([pscustomobject]@{ Snapshot = (Get-MolePathSnapshot $artifact); Path = $artifact; Name = "node_modules"; SizeKB = $sizeKB; SizeHuman = "8KB" })
        }

        Remove-ProjectArtifacts -Projects @($project) 6>$null

        Test-Path $artifact | Should -BeFalse
        (Get-CleanupStats).TotalSizeKB | Should -Be $sizeKB
        $script:ItemsCleaned | Should -Be 1
    }
}
