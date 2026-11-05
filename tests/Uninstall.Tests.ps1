# Mole Windows - uninstall regression tests

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $libDir = Join-Path $script:WindowsDir "lib"
    . "$libDir\core\base.ps1"
    . "$libDir\core\log.ps1"
    . "$libDir\core\ui.ps1"
    . "$libDir\core\file_ops.ps1"

    # Load the script's settings and functions without running Main, so tests never
    # scan installed apps or run an uninstaller.
    $path = Join-Path $script:WindowsDir "bin\uninstall.ps1"
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw $parseErrors[0] }
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $statement.Left.Extent.Text -like '$script:*') {
            . ([scriptblock]::Create($statement.Extent.Text))
        }
    }
    $definitions = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $false)
    foreach ($definition in $definitions) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    # Permit old-source red runs; the old caller still invokes Start-Process directly.
    if (-not (Get-Command Invoke-MoleUninstallProcess -ErrorAction SilentlyContinue)) {
        function Invoke-MoleUninstallProcess { param($FilePath, $ArgumentList) }
    }

    $script:DeclaredCacheName = Split-Path -Leaf $script:AppCacheFile
    $script:CacheDir = Join-Path $TestDrive "cache"
    $script:AppCacheFile = Join-Path $script:CacheDir "apps.json"

    # A real, throwaway Uninstall-like key, so the "is it gone" check reads the registry.
    $script:RegistryRoot = "HKCU:\Software\MoleCliTests\$([guid]::NewGuid().ToString('N'))"

    function New-TestUninstallKey {
        param([string]$Name, [hashtable]$Values)
        $key = Join-Path $script:RegistryRoot $Name
        New-Item -Path $key -Force | Out-Null
        foreach ($entry in $Values.GetEnumerator()) {
            New-ItemProperty -Path $key -Name $entry.Key -Value $entry.Value -Force | Out-Null
        }
        # The scan stores the provider-qualified PSPath, so the tests use that form too.
        return (Get-Item -LiteralPath $key).PSPath
    }

    function New-TestFolder {
        param([string]$Name)
        $folder = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -Path (Join-Path $folder "app.dll") -Value ("x" * 8192)
        return $folder
    }
}

AfterAll {
    Set-DryRunMode -Enabled $false
    if (Test-Path -LiteralPath $script:RegistryRoot) {
        Remove-Item -LiteralPath $script:RegistryRoot -Recurse
    }
    $parent = Split-Path -Parent $script:RegistryRoot
    if ((Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent)) {
        Remove-Item -LiteralPath $parent
    }
}

Describe "Uninstall selection under strict mode" {
    BeforeAll {
        $DryRun = $false
        $DebugMode = $false
        $ShowHelp = $false
        $Rescan = $false
        $List = $false
        $script:Icons = @{ List = "-" }
        $script:MoleDryRunMode = $false
        $script:TestApps = @(
            [PSCustomObject]@{ Name = "First app"; SizeHuman = "1MB" }
            [PSCustomObject]@{ Name = "Second app"; SizeHuman = "2MB" }
        )

        function Get-InstalledApplications { param([switch]$ForceRescan) }
        function Show-AppSelectionMenu { param([array]$Apps) }
        function Uninstall-SelectedApps { param([array]$Apps) throw "Real uninstall must never run" }
        function Write-Info { param([string]$Message) }
        function Write-MoleWarning { param([string]$Message) }
    }

    BeforeEach {
        Mock Clear-MoleScreen {}
        Mock Write-Host {}
        Mock Write-Info {}
        Mock Write-MoleWarning {}
        Mock Get-InstalledApplications { $script:TestApps }
        Mock Show-AppSelectionMenu { $script:TestApps[0] }
        Mock Read-Host { "y" }
        Mock Uninstall-SelectedApps {}
    }

    It "Confirms and passes a single selected app to the uninstaller" {
        & { Set-StrictMode -Version Latest; Main }

        Should -Invoke Read-Host -Times 1 -Exactly
        Should -Invoke Uninstall-SelectedApps -Times 1 -Exactly -ParameterFilter {
            $Apps.Count -eq 1 -and $Apps[0].Name -eq "First app"
        }
    }

    It "Returns without confirmation when the selection is cancelled" {
        Mock Show-AppSelectionMenu { return @() }

        & { Set-StrictMode -Version Latest; Main }

        Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -eq "No applications selected" }
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Uninstall-SelectedApps -Times 0 -Exactly
    }

    It "Preserves multiple selected apps" {
        Mock Show-AppSelectionMenu { $script:TestApps }

        & { Set-StrictMode -Version Latest; Main }

        Should -Invoke Uninstall-SelectedApps -Times 1 -Exactly -ParameterFilter {
            $Apps.Count -eq 2 -and $Apps[0].Name -eq "First app" -and $Apps[1].Name -eq "Second app"
        }
    }

    It "Does not uninstall when confirmation is declined" {
        Mock Read-Host { "n" }

        & { Set-StrictMode -Version Latest; Main }

        Should -Invoke Read-Host -Times 1 -Exactly
        Should -Invoke Uninstall-SelectedApps -Times 0 -Exactly
    }

    It "Handles a single discovered app" {
        Mock Get-InstalledApplications { $script:TestApps[0] }

        & { Set-StrictMode -Version Latest; Main }

        Should -Invoke Show-AppSelectionMenu -Times 1 -Exactly -ParameterFilter { $Apps.Count -eq 1 }
        Should -Invoke Uninstall-SelectedApps -Times 1 -Exactly
    }

    It "Returns without showing the menu when no apps are discovered" {
        Mock Get-InstalledApplications { return @() }

        & { Set-StrictMode -Version Latest; Main }

        Should -Invoke Write-MoleWarning -Times 1 -Exactly -ParameterFilter { $Message -eq "No applications found" }
        Should -Invoke Show-AppSelectionMenu -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Uninstall-SelectedApps -Times 0 -Exactly
    }
}

Describe "Install folder eligibility" {
    It "Rejects <Label>" -TestCases @(
        @{ Label = "a drive root"; Path = "C:\" }
        @{ Label = "another drive root"; Path = "D:\" }
        @{ Label = "the Users folder"; Path = "C:\Users" }
        @{ Label = "the user profile"; Path = $env:USERPROFILE }
        @{ Label = "AppData"; Path = "$env:USERPROFILE\AppData" }
        @{ Label = "Local"; Path = $env:LOCALAPPDATA }
        @{ Label = "Roaming"; Path = $env:APPDATA }
        @{ Label = "LocalLow"; Path = "$env:USERPROFILE\AppData\LocalLow" }
        @{ Label = "Documents"; Path = "$env:USERPROFILE\Documents" }
        @{ Label = "Desktop"; Path = "$env:USERPROFILE\Desktop" }
        @{ Label = "Downloads"; Path = "$env:USERPROFILE\Downloads" }
        @{ Label = "Music"; Path = "$env:USERPROFILE\Music" }
        @{ Label = "Pictures"; Path = "$env:USERPROFILE\Pictures" }
        @{ Label = "ProgramData"; Path = $env:ProgramData }
        @{ Label = "Program Files"; Path = $env:ProgramFiles }
        @{ Label = "Program Files (x86)"; Path = ${env:ProgramFiles(x86)} }
        @{ Label = "Common Files"; Path = $env:CommonProgramFiles }
        @{ Label = "Windows"; Path = $env:windir }
        @{ Label = "a folder inside Windows"; Path = "$env:windir\System32" }
        @{ Label = "a quoted Program Files with a trailing slash"; Path = "`"$env:ProgramFiles\`"" }
        @{ Label = "a path with dot segments"; Path = "$env:ProgramFiles\Contoso\..\" }
        @{ Label = "an empty value"; Path = "" }
    ) {
        Test-MoleInstallFolder -Path $Path | Should -BeFalse
    }

    It "Rejects container and shared names on any drive: <Name>" -TestCases @(
        @{ Name = "Program Files" }
        @{ Name = "Program Files (x86)" }
        @{ Name = "Common Files" }
        @{ Name = "AppData" }
        @{ Name = "Downloads" }
        @{ Name = "Microsoft" }
        @{ Name = "Package Cache" }
    ) {
        $folder = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $folder -Force | Out-Null

        Test-MoleInstallFolder -Path $folder | Should -BeFalse
    }

    It "Accepts an app's own folder, quoted or with a trailing slash" {
        $folder = New-TestFolder -Name "Contoso App"

        Test-MoleInstallFolder -Path $folder | Should -BeTrue
        Test-MoleInstallFolder -Path "`"$folder\`"" | Should -BeTrue
    }

    It "Rejects a folder that does not exist" {
        Test-MoleInstallFolder -Path (Join-Path $TestDrive "Missing App") | Should -BeFalse
    }

    It "Never takes a Steam library or its steamapps folders for one app: <Label>" -TestCases @(
        @{ Label = "the library root"; Relative = "SteamLibrary" }
        @{ Label = "steamapps"; Relative = "SteamLibrary\steamapps" }
        @{ Label = "steamapps\common"; Relative = "SteamLibrary\steamapps\common" }
        @{ Label = "the workshop"; Relative = "SteamLibrary\steamapps\workshop\content" }
        @{ Label = "the Steam client folder"; Relative = "Steam" }
    ) {
        foreach ($folder in @("SteamLibrary\steamapps\common\Some Game", "SteamLibrary\steamapps\workshop\content", "Steam\steamapps\common")) {
            New-Item -ItemType Directory -Path (Join-Path $TestDrive $folder) -Force | Out-Null
        }
        Set-Content -Path (Join-Path $TestDrive "SteamLibrary\libraryfolder.vdf") -Value '"libraryfolder" {}'

        Test-MoleInstallFolder -Path (Join-Path $TestDrive $Relative) | Should -BeFalse
    }

    It "Accepts one game's folder inside a Steam library" {
        $game = Join-Path $TestDrive "SteamLibrary\steamapps\common\Some Game"
        New-Item -ItemType Directory -Path $game -Force | Out-Null

        Test-MoleInstallFolder -Path $game | Should -BeTrue
    }

    It "Rejects a library root marked only by libraryfolder.vdf" {
        $root = New-TestFolder -Name "GamesDrive"
        Set-Content -Path (Join-Path $root "libraryfolder.vdf") -Value '"libraryfolder" {}'

        Test-MoleInstallFolder -Path $root | Should -BeFalse
    }
}

Describe 'Generic game content in install folders' {
    BeforeEach {
        Mock Test-UninstallEntryGone { $true }
        Mock Get-MoleInstallOwners { @{Complete=$true;Owners=@()} }
        $script:ContentApp = [pscustomobject]@{RegistryKey='selected';MergedKeys=@()}
    }
    It 'Keeps a content folder <Name> inside an otherwise ordinary install' -TestCases @(
        @{Name='roms'}, @{Name='saves'}, @{Name='states'}, @{Name='bios'}, @{Name='games'}, @{Name='gog games'}
    ) {
        param($Name)
        $root = New-TestFolder ('Emulator ' + $Name)
        New-Item -ItemType Directory -Path (Join-Path $root $Name) -Force | Out-Null
        Test-MoleLeftoverOwnership $root $script:ContentApp | Should -BeFalse
    }
    It 'Keeps content markers at the root or below one wrapper: <Marker>' -TestCases @(
        @{Marker='goggame-42.info'}, @{Marker='galaxy-2.0.db'},
        @{Marker='OneGame\goggame-42.info'}, @{Marker='Library\steamapps'}, @{Marker='Library\libraryfolder.vdf'}
    ) {
        param($Marker)
        $root = New-TestFolder ('Launcher ' + $Marker.Replace('\', '_'))
        $path = Join-Path $root $Marker
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        if ($Marker -like '*steamapps') { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        else { [IO.File]::WriteAllText($path,'content marker') }
        Test-MoleLeftoverOwnership $root $script:ContentApp | Should -BeFalse
    }
    It 'Retains an install folder when child identity is unknown' {
        $root = New-TestFolder 'Unknown install'
        $script:UnknownContentChild = Join-Path $root 'plugins'
        New-Item -ItemType Directory -Path $script:UnknownContentChild -Force | Out-Null
        Mock Get-MolePathSnapshot { $null } -ParameterFilter { $Path -eq $script:UnknownContentChild }
        Test-MoleLeftoverOwnership $root $script:ContentApp | Should -BeFalse
    }
    It 'Retains an incomplete bounded listing rather than accepting its early files' {
        $root = New-TestFolder 'Large install'
        foreach ($index in 1..257) { [IO.Directory]::CreateDirectory((Join-Path $root "component$index")) | Out-Null }
        Test-MoleLeftoverOwnership $root $script:ContentApp | Should -BeFalse
    }
    It 'Keeps ordinary installs and a single Steam game eligible' {
        $root = New-TestFolder 'Ordinary'
        foreach ($name in @('program.dll','goggame-not-info.txt','galaxy-2.0.db.backup')) { [IO.File]::WriteAllText((Join-Path $root $name),'program') }
        [IO.Directory]::CreateDirectory((Join-Path $root 'bioshelpers')) | Out-Null
        Test-MoleLeftoverOwnership $root $script:ContentApp | Should -BeTrue
        $game = Join-Path $TestDrive 'SteamLibrary\steamapps\common\OneGame'
        [IO.Directory]::CreateDirectory($game) | Out-Null
        Test-MoleLeftoverOwnership $game $script:ContentApp | Should -BeTrue
    }
    It 'Rechecks content in the existing final leftover ownership guard' {
        $root = New-TestFolder 'Content appears later'
        $app = [pscustomobject]@{RegistryKey='selected';MergedKeys=@()}
        Mock Test-UninstallEntryGone { $true }
        Mock Get-MoleInstallOwners { @{Complete=$true;Owners=@()} }
        Test-MoleLeftoverOwnership $root $app | Should -BeTrue
        [IO.Directory]::CreateDirectory((Join-Path $root 'saves')) | Out-Null
        Test-MoleLeftoverOwnership $root $app | Should -BeFalse
    }
}

Describe "Uninstall entry removal check" {
    It "Treats a missing key as removed" {
        $root = New-TestUninstallKey -Name "parent" -Values @{}
        Test-UninstallEntryGone -KeyPath "$root\never-created" | Should -BeTrue
    }

    It "Treats a key that still names an app as installed" {
        $key = New-TestUninstallKey -Name "present" -Values @{ DisplayName = "Present"; UninstallString = "C:\x\uninstall.exe" }

        Test-UninstallEntryGone -KeyPath $key | Should -BeFalse
    }

    It "Treats a key emptied of its name and uninstall command as removed" {
        $key = New-TestUninstallKey -Name "emptied" -Values @{ EstimatedSize = 1024 }

        Test-UninstallEntryGone -KeyPath $key | Should -BeTrue
    }

    It "Treats an unknown key as still installed" {
        Test-UninstallEntryGone -KeyPath "" | Should -BeFalse
    }
}

Describe "Uninstalling registry apps" {
    BeforeAll {
        Set-DryRunMode -Enabled $false
        $script:Icons = Get-MoleDefaultIcons
    }

    BeforeEach {
        Set-DryRunMode -Enabled $false
        Mock Write-Host {}
        Mock Remove-SafeItem { $true }
        Mock Get-MoleInstallOwners { @{ Complete = $true; Owners = @() } }
        # The launch recheck has its own Describe.
        Mock Test-UninstallLaunchCurrent { $true }
        Mock Remove-AppxPackage { throw "Remove-AppxPackage must not run" }

        $script:AppFolder = New-TestFolder -Name "Contoso Tool"
        $script:Uninstaller = Join-Path $script:AppFolder "uninstall.exe"
        Set-Content -Path $script:Uninstaller -Value "not an installer we recognise"
        $script:PresentKey = New-TestUninstallKey -Name "contoso" -Values @{ DisplayName = "Contoso Tool"; UninstallString = $script:Uninstaller }
        # Registered at launch; the uninstaller removes it, as a real one would.
        $script:GoneKey = New-TestUninstallKey -Name "removed-by-uninstaller" -Values @{ DisplayName = "Contoso Tool"; UninstallString = $script:Uninstaller }
        Mock Invoke-MoleUninstallProcess {
            if (Test-Path -LiteralPath $script:GoneKey) { Remove-Item -LiteralPath $script:GoneKey -Recurse -Force }
            [PSCustomObject]@{ ExitCode = 1 }
        }
    }

    It "Stops the batch on an uninstaller timeout even after registration disappears" {
        Mock Invoke-MoleUninstallProcess {
            Remove-Item -LiteralPath $script:GoneKey -Recurse -Force
            throw [TimeoutException]::new('test timeout')
        }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        $app = [pscustomobject]@{
            Name = 'Resident'; Source = 'Registry'; UninstallString = "`"$script:Uninstaller`""
            InstallLocation = $script:AppFolder; RegistryKey = $script:GoneKey; PackageFullName = $null
        }
        Uninstall-SelectedApps -Apps @($app, $app)
        Should -Invoke Remove-SafeItem -Times 0 -Exactly
        Should -Invoke Invoke-MoleUninstallProcess -Times 1 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It "Runs an unrecognised uninstaller exactly once, as registered" {
        $app = [PSCustomObject]@{
            Name = "Contoso Tool"; Source = "Registry"; UninstallString = "`"$script:Uninstaller`""
            InstallLocation = $script:AppFolder; RegistryKey = $script:PresentKey; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Invoke-MoleUninstallProcess -Times 1 -Exactly
        Should -Invoke Invoke-MoleUninstallProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $script:Uninstaller -and $null -eq $ArgumentList
        }
    }

    It "Keeps the install folder when the uninstall entry is still there" {
        $app = [PSCustomObject]@{
            Name = "Contoso Tool"; Source = "Registry"; UninstallString = "`"$script:Uninstaller`""
            InstallLocation = $script:AppFolder; RegistryKey = $script:PresentKey; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Remove-SafeItem -Times 0 -Exactly
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like "*still installed, exit code 1*" }
        $script:MoleUninstallIncomplete | Should -BeTrue
    }

    It "Reports a complete batch once every uninstall entry is gone" {
        $app = [PSCustomObject]@{
            Name = "Contoso Tool"; Source = "Registry"; UninstallString = "`"$script:Uninstaller`""
            InstallLocation = $script:AppFolder; RegistryKey = $script:GoneKey; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        $script:MoleUninstallIncomplete | Should -BeFalse
    }

    It "Recycles the install folder once the uninstall entry is gone" {
        $app = [PSCustomObject]@{
            Name = "Contoso Tool"; Source = "Registry"; UninstallString = "`"$script:Uninstaller`""
            InstallLocation = $script:AppFolder; RegistryKey = $script:GoneKey; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Remove-SafeItem -Times 1 -Exactly -ParameterFilter { $Path -eq $script:AppFolder -and $Recycle }
    }

    It "Never removes a profile or system folder named as the install location: <Label>" -TestCases @(
        @{ Label = 'profile'; Variable = 'USERPROFILE' }
        @{ Label = 'Program Files'; Variable = 'ProgramFiles' }
    ) {
        # One app per run, so each reaches the removal decision after its own uninstaller.
        $app = [PSCustomObject]@{
            Name = "$Label App"; Source = "Registry"; UninstallString = "`"$script:Uninstaller`""
            InstallLocation = [Environment]::GetEnvironmentVariable($Variable); RegistryKey = $script:GoneKey; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Invoke-MoleUninstallProcess -Times 1 -Exactly
        Should -Invoke Remove-SafeItem -Times 0 -Exactly
    }

    It "Removes MSI products with msiexec /passive" {
        $code = "{11111111-2222-3333-4444-555555555555}"
        $app = [PSCustomObject]@{
            Name = "Msi App"; Source = "Registry"; UninstallString = "MsiExec.exe /X$code"; KeyName = $code
            InstallLocation = $null; RegistryKey = $script:PresentKey; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Invoke-MoleUninstallProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -like "*\System32\msiexec.exe" -and
            ($ArgumentList -join " ") -eq "/x $code /passive REBOOT=ReallySuppress /norestart"
        }
    }

    It "Prefers the vendor's QuietUninstallString" {
        $app = [PSCustomObject]@{
            Name = "Quiet App"; Source = "Registry"; UninstallString = "`"$script:Uninstaller`""
            QuietUninstallString = "`"$script:Uninstaller`" --mode unattended"
            InstallLocation = $null; RegistryKey = $script:PresentKey; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Invoke-MoleUninstallProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $script:Uninstaller -and ($ArgumentList -join " ") -eq "--mode unattended"
        }
    }

    It "Adds the Inno Setup switches only to an Inno uninstaller" {
        $inno = Join-Path $script:AppFolder "unins000.exe"
        Set-Content -Path $inno -Value "inno"
        Set-Content -Path (Join-Path $script:AppFolder "unins000.dat") -Value "inno data"
        $app = [PSCustomObject]@{
            Name = "Inno App"; Source = "Registry"; UninstallString = "`"$inno`""
            InstallLocation = $null; RegistryKey = $script:PresentKey; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Invoke-MoleUninstallProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $inno -and ($ArgumentList -join " ") -eq "/SILENT /SUPPRESSMSGBOXES /NORESTART"
        }
    }

    It "Adds /S only to an uninstaller carrying the NSIS marker" {
        $nsis = Join-Path $script:AppFolder "uninst.exe"
        [System.IO.File]::WriteAllBytes($nsis, [System.Text.Encoding]::ASCII.GetBytes("MZ....Nullsoft.NSIS.exehead...."))
        $app = [PSCustomObject]@{
            Name = "Nsis App"; Source = "Registry"; UninstallString = "`"$nsis`""
            InstallLocation = $null; RegistryKey = $script:PresentKey; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Invoke-MoleUninstallProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $nsis -and ($ArgumentList -join " ") -eq "/S"
        }
    }

    It "Records the install folder, registry key and command with each outcome" {
        Mock Write-MoleOperation {}
        $app = [PSCustomObject]@{
            Name = "Contoso Tool"; Source = "Registry"; UninstallString = "`"$script:Uninstaller`""
            InstallLocation = $script:AppFolder; RegistryKey = $script:GoneKey; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter {
            $Action -eq "UNINSTALLED" -and $Path -eq "Contoso Tool" -and
            $Detail -like "exit code 1; location $($script:AppFolder); key HKEY_CURRENT_USER\*\removed-by-uninstaller; command $($script:Uninstaller)"
        }
    }

    It "Records a still-installed app with the same detail" {
        Mock Write-MoleOperation {}
        $app = [PSCustomObject]@{
            Name = "Contoso Tool"; Source = "Registry"; UninstallString = "`"$script:Uninstaller`""
            InstallLocation = $script:AppFolder; RegistryKey = $script:PresentKey; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter {
            $Action -eq "FAILED" -and $Detail -like "still installed, exit code 1; location *; key *; command $($script:Uninstaller)"
        }
    }

    It "Records an app with no runnable uninstaller" {
        Mock Write-MoleOperation {}
        $app = [PSCustomObject]@{
            Name = "Missing App"; Source = "Registry"; UninstallString = "`"$TestDrive\gone\uninstall.exe`""
            InstallLocation = $script:AppFolder; RegistryKey = $script:GoneKey; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter {
            $Action -eq "FAILED" -and $Detail -like "no runnable uninstaller; location *; key *; registered *gone\uninstall.exe*"
        }
    }

    It "Starts nothing when the registered uninstaller does not exist" {
        $app = [PSCustomObject]@{
            Name = "Missing App"; Source = "Registry"; UninstallString = "`"$TestDrive\gone\uninstall.exe`""
            InstallLocation = $script:AppFolder; RegistryKey = $script:GoneKey; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Invoke-MoleUninstallProcess -Times 0 -Exactly
        Should -Invoke Remove-SafeItem -Times 0 -Exactly
    }
}

Describe "Uninstall command recheck before launch" {
    BeforeEach {
        Set-DryRunMode -Enabled $false
        Mock Write-Host {}
        Mock Write-MoleOperation {}
        Mock Remove-SafeItem { $true }
        Mock Get-MoleInstallOwners { @{ Complete = $true; Owners = @() } }
        $script:AppFolder = New-TestFolder -Name "Recheck Tool"
        $script:Uninstaller = Join-Path $script:AppFolder "uninstall.exe"
        Set-Content -Path $script:Uninstaller -Value "not an installer we recognise"
        $script:RecheckKey = New-TestUninstallKey -Name "recheck" -Values @{ DisplayName = "Recheck Tool"; UninstallString = $script:Uninstaller }
        $script:RecheckApp = [PSCustomObject]@{
            Name = "Recheck Tool"; Source = "Registry"; UninstallString = "`"$script:Uninstaller`""
            InstallLocation = $script:AppFolder; RegistryKey = $script:RecheckKey; PackageFullName = $null
        }
        # The vendor uninstaller removes its own registration.
        Mock Invoke-MoleUninstallProcess { Remove-Item -LiteralPath $script:RecheckKey -Recurse -Force; [PSCustomObject]@{ ExitCode = 0 } }
    }

    It "Runs the reviewed command when the registration still names it" {
        Uninstall-SelectedApps -Apps @($script:RecheckApp)
        Should -Invoke Invoke-MoleUninstallProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq $script:Uninstaller }
        $script:MoleUninstallIncomplete | Should -BeFalse
    }

    It "Does not run a command rewritten after review: <Case>" -ForEach @(
        @{ Case = 'other program'; Name = 'UninstallString'; Value = 'OTHER' }
        @{ Case = 'added arguments'; Name = 'UninstallString'; Value = 'UNINSTALLER --wipe' }
        @{ Case = 'new quiet command'; Name = 'QuietUninstallString'; Value = 'OTHER /S' }
    ) {
        # The rewritten command names a program that exists, so it would really run.
        $other = Join-Path $script:AppFolder 'other.exe'
        Set-Content -Path $other -Value 'another program'
        $value = $Value.Replace('UNINSTALLER', "`"$script:Uninstaller`"").Replace('OTHER', "`"$other`"")
        Set-ItemProperty -LiteralPath $script:RecheckKey -Name $Name -Value $value
        Uninstall-SelectedApps -Apps @($script:RecheckApp)
        Should -Invoke Invoke-MoleUninstallProcess -Times 0 -Exactly
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'FAILED' -and $Detail -like 'uninstall command changed since review*' }
        $script:MoleUninstallIncomplete | Should -BeTrue
    }

    It "Counts an entry an earlier row's uninstaller removed as done without running it" {
        $script:SiblingKey = New-TestUninstallKey -Name "recheck-sibling" -Values @{ DisplayName = "Recheck Tool Helper"; UninstallString = $script:Uninstaller }
        $sibling = [PSCustomObject]@{
            Name = "Recheck Tool Helper"; Source = "Registry"; UninstallString = "`"$script:Uninstaller`""
            InstallLocation = $null; RegistryKey = $script:SiblingKey; PackageFullName = $null
        }
        # The suite uninstaller removes both registrations.
        Mock Invoke-MoleUninstallProcess {
            Remove-Item -LiteralPath $script:RecheckKey, $script:SiblingKey -Recurse -Force; [PSCustomObject]@{ ExitCode = 0 }
        }
        Uninstall-SelectedApps -Apps @($script:RecheckApp, $sibling)
        Should -Invoke Invoke-MoleUninstallProcess -Times 1 -Exactly
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'UNINSTALLED' -and $Detail -like 'already removed*' }
        $script:MoleUninstallIncomplete | Should -BeFalse
    }

    It "Does not count an entry gone before anything ran as uninstalled: <Case>" -ForEach @(
        @{ Case = 'key removed' }, @{ Case = 'blank name' }, @{ Case = 'blank commands' }
    ) {
        switch ($Case) {
            'key removed' { Remove-Item -LiteralPath $script:RecheckKey -Recurse -Force }
            'blank name' { Set-ItemProperty -LiteralPath $script:RecheckKey -Name DisplayName -Value '' }
            'blank commands' { Set-ItemProperty -LiteralPath $script:RecheckKey -Name UninstallString -Value '' }
        }
        Uninstall-SelectedApps -Apps @($script:RecheckApp)
        Should -Invoke Invoke-MoleUninstallProcess -Times 0 -Exactly
        Should -Invoke Remove-SafeItem -Times 0 -Exactly
        Should -Invoke Write-MoleOperation -Times 0 -Exactly -ParameterFilter { $Action -eq 'UNINSTALLED' }
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'SKIPPED' -and $Detail -like 'no longer registered*' }
        $script:MoleUninstallIncomplete | Should -BeTrue
    }

    It "Does not run a command whose registration can no longer be read" {
        Mock Get-ItemProperty { throw [UnauthorizedAccessException]::new('denied') } -ParameterFilter { $LiteralPath -eq $script:RecheckKey }
        Uninstall-SelectedApps -Apps @($script:RecheckApp)
        Should -Invoke Invoke-MoleUninstallProcess -Times 0 -Exactly
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'FAILED' }
        $script:MoleUninstallIncomplete | Should -BeTrue
    }
}

Describe "Uninstall dry run leftovers" {
    BeforeEach {
        Set-DryRunMode -Enabled $true
        $script:Icons = Get-MoleDefaultIcons
        Mock Write-Host {}
        Mock Invoke-MoleUninstallProcess { throw "Start-Process must not run in a dry run" }
        Mock Remove-SafeItem { $true }
        Mock Get-MoleInstallOwners { @{ Complete = $true; Owners = @() } }
    }

    AfterEach {
        Set-DryRunMode -Enabled $false
    }

    It "Previews no folder that would not be removed" {
        $app = [PSCustomObject]@{
            Name = "Profile App"; Source = "Registry"; UninstallString = "C:\nowhere\uninstall.exe"
            InstallLocation = $env:USERPROFILE; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Remove-SafeItem -Times 0 -Exactly
        Should -Invoke Invoke-MoleUninstallProcess -Times 0 -Exactly
    }

    It "Previews an app's own folder" {
        $folder = New-TestFolder -Name "Preview App"
        $app = [PSCustomObject]@{
            Name = "Preview App"; Source = "Registry"; UninstallString = "C:\nowhere\uninstall.exe"
            InstallLocation = $folder; PackageFullName = $null
        }

        Uninstall-SelectedApps -Apps @($app)

        Should -Invoke Remove-SafeItem -Times 1 -Exactly -ParameterFilter { $Path -eq $folder -and $Recycle }
    }
}

Describe "Scanning installed apps" {
    BeforeEach {
        Mock Write-Info {}
        Mock Write-Progress {}
        Mock Get-AppxPackage { @() }
        Mock Get-AppxPackageManifest { [xml]'<Package><Properties /></Package>' }
        $script:RegistryFixtures = @()
        Mock Get-ItemProperty {
            if ("$Path" -like "HKLM:\SOFTWARE\Microsoft\*") { $script:RegistryFixtures }
        } -ParameterFilter { "$Path" -like "HK*" }
        if (Test-Path -LiteralPath $script:AppCacheFile) { Remove-Item -LiteralPath $script:AppCacheFile }
    }

    It 'Does not reuse the v5 inventory with lost install identities and Game Bar' {
        $savedCache = $script:AppCacheFile
        try {
            New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
            $script:AppCacheFile = Join-Path $script:CacheDir $script:DeclaredCacheName
            @([pscustomobject]@{Name='Stale Game Bar';Source='WindowsStore';PackageFullName='Microsoft.XboxGamingOverlay_1.0.0.0_x64__abc'}) |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:CacheDir 'app_scan_cache_v5.json') -Encoding UTF8
            @(Get-InstalledApplications -Quiet).Count | Should -Be 0
            Should -Invoke Get-AppxPackage -Times 1 -Exactly
        }
        finally { $script:AppCacheFile = $savedCache }
    }

    It 'Reuses an inventory cache written <Hours> hours from now only when it is not in the future' -TestCases @(
        @{ Hours = -1; Expected = 1 }
        @{ Hours = 1; Expected = 0 }
    ) {
        param($Hours, $Expected)
        New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
        @([pscustomobject]@{Name='Cached app';Source='Registry'}) |
            ConvertTo-Json | Set-Content -LiteralPath $script:AppCacheFile -Encoding UTF8
        [IO.File]::SetLastWriteTime($script:AppCacheFile, (Get-Date).AddHours($Hours))
        @(Get-InstalledApplications -Quiet).Count | Should -Be $Expected
    }

    It 'Preserves distinct registered identities when <ProtectedCount> installs contain saves' -TestCases @(@{ProtectedCount=1},@{ProtectedCount=2}) {
        param($ProtectedCount)
        $first = New-TestFolder "Identity $ProtectedCount A"
        $second = New-TestFolder "Identity $ProtectedCount B"
        [IO.Directory]::CreateDirectory((Join-Path $first 'saves')) | Out-Null
        if ($ProtectedCount -eq 2) { [IO.Directory]::CreateDirectory((Join-Path $second 'saves')) | Out-Null }
        $script:RegistryFixtures = @(foreach ($folder in @($first,$second)) {
            [pscustomobject]@{PSPath="HKLM-test\$folder";PSChildName=$folder;DisplayName='Same emulator';DisplayVersion='1.0';Publisher='Contoso';InstallLocation=$folder;UninstallString="`"$folder\uninstall.exe`"";EstimatedSize=1024}
        })
        $apps = @(Get-InstalledApplications -ForceRescan -Quiet)
        $apps.Count | Should -Be 2
        @($apps.InstallLocation | Sort-Object) | Should -Be @($first,$second | Sort-Object)
    }

    It 'Keeps two distinct registered Steam library roots without measuring or removing either' {
        $folders = @((New-TestFolder 'Registered Steam A'),(New-TestFolder 'Registered Steam B'))
        $script:RegistryFixtures = @(foreach ($folder in $folders) {
            [IO.Directory]::CreateDirectory((Join-Path $folder 'steamapps')) | Out-Null
            [pscustomobject]@{PSPath="HKLM-test\$folder";PSChildName=$folder;DisplayName='Same client';DisplayVersion='1.0';Publisher='Contoso';InstallLocation=$folder;UninstallString="`"$folder\uninstall.exe`"";EstimatedSize=70987979}
        })
        Mock Get-PathSizeKB { throw 'Protected containers must not be measured' }
        $apps = @(Get-InstalledApplications -ForceRescan -Quiet)
        $apps.Count | Should -Be 2
        @($apps.InstallLocation | Sort-Object) | Should -Be @($folders | Sort-Object)
        foreach ($app in $apps) { Test-MoleLeftoverOwnership $app.InstallLocation $app | Should -BeFalse }
        Should -Invoke Get-PathSizeKB -Times 0 -Exactly
    }

    It 'Retains <Kind> registration identity without recursive measurement or leftover removal' -TestCases @(
        @{Kind='shared root';Variable='ProgramFiles'},@{Kind='system root';Variable='SystemRoot'}
    ) {
        param($Kind,$Variable)
        $folder = [Environment]::GetEnvironmentVariable($Variable)
        $script:RegistryFixtures = @([pscustomobject]@{PSPath='HKLM-test\container';PSChildName='container';DisplayName='Container app';InstallLocation=$folder;UninstallString='C:\fixture\uninstall.exe';EstimatedSize=70987979})
        Mock Get-PathSizeKB { throw 'Protected containers must not be measured' }
        $app = @(Get-InstalledApplications -ForceRescan -Quiet)[0]
        $app.InstallLocation | Should -Be (Get-NormalizedFolderPath $folder)
        $app.SizeKB | Should -Be 70987979
        Test-MoleLeftoverOwnership $folder $app | Should -BeFalse
        Should -Invoke Get-PathSizeKB -Times 0 -Exactly
    }

    It 'Measures an outlier estimate even when personal content prevents leftover removal' {
        $folder = New-TestFolder 'Measured with saves'
        [IO.Directory]::CreateDirectory((Join-Path $folder 'saves')) | Out-Null
        $script:RegistryFixtures = @([pscustomobject]@{PSPath='HKLM-test\measured';PSChildName='measured';DisplayName='Measured emulator';InstallLocation=$folder;UninstallString="`"$folder\uninstall.exe`"";EstimatedSize=70987979})
        $measured = Get-PathSizeKB $folder
        $app = @(Get-InstalledApplications -ForceRescan -Quiet)[0]
        $app.InstallLocation | Should -Be $folder
        $app.SizeKB | Should -Be $measured
        $app.SizeChecked | Should -BeTrue
        Mock Test-UninstallEntryGone { $true }
        Mock Get-MoleInstallOwners { @{Complete=$true;Owners=@()} }
        Test-MoleLeftoverOwnership $folder $app | Should -BeFalse
    }

    It "Shows a RustDesk-like outlier size as measured, once, beside its duplicate key (#1717)" {
        $folder = New-TestFolder -Name "RustDesk"
        $code = "{3BF1D48C-7A7B-4E4F-9D1F-0123456789AB}"
        $base = "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        $script:RegistryFixtures = @(
            [PSCustomObject]@{
                PSPath = "$base\$code"; PSChildName = $code; DisplayName = "RustDesk"; DisplayVersion = "1.2.3"
                Publisher = "Purslane"; UninstallString = "MsiExec.exe /X$code"; EstimatedSize = 70987979
                InstallLocation = $folder; WindowsInstaller = 1
            },
            [PSCustomObject]@{
                PSPath = "$base\RustDesk"; PSChildName = "RustDesk"; DisplayName = "RustDesk"; DisplayVersion = "1.2.3"
                Publisher = "Purslane"; UninstallString = "`"$folder\RustDesk.exe`" --uninstall"; InstallLocation = $folder
            }
        )
        $measuredKB = Get-PathSizeKB -Path $folder

        $apps = @(Get-InstalledApplications -ForceRescan)

        $rustDesk = @($apps | Where-Object { $_.Name -eq "RustDesk" })
        $rustDesk.Count | Should -Be 1
        $rustDesk[0].SizeKB | Should -Be $measuredKB
        $rustDesk[0].SizeKB | Should -BeLessThan 1024
    }

    It "Keeps a large size that the install folder cannot disprove" {
        $folder = New-TestFolder -Name "Big Game"
        $script:RegistryFixtures = @(
            [PSCustomObject]@{
                PSPath = "HKLM-test\big"; PSChildName = "big"; DisplayName = "Big Game"; UninstallString = "C:\x\u.exe"
                EstimatedSize = 20971520
            },
            [PSCustomObject]@{
                PSPath = "HKLM-test\small"; PSChildName = "small"; DisplayName = "Small Tool"; UninstallString = "C:\y\u.exe"
                EstimatedSize = 2048; InstallLocation = $folder
            }
        )

        $apps = @(Get-InstalledApplications -ForceRescan)

        @($apps | Where-Object { $_.Name -eq "Big Game" })[0].SizeKB | Should -Be 20971520
        @($apps | Where-Object { $_.Name -eq "Small Tool" })[0].SizeKB | Should -Be 2048
    }

    It "Keeps two copies with one name in different install folders" {
        $first = New-TestFolder -Name "Tool x86"
        $second = New-TestFolder -Name "Tool x64"
        $script:RegistryFixtures = @(
            [PSCustomObject]@{
                PSPath = "HKLM-test\tool32"; PSChildName = "tool32"; DisplayName = "Tool"; DisplayVersion = "1.0"
                Publisher = "Contoso"; UninstallString = "`"$first\uninstall.exe`""; InstallLocation = $first
            },
            [PSCustomObject]@{
                PSPath = "HKLM-test\tool64"; PSChildName = "tool64"; DisplayName = "Tool"; DisplayVersion = "1.0"
                Publisher = "Contoso"; UninstallString = "`"$second\uninstall.exe`""; InstallLocation = $second
            }
        )

        $apps = @(Get-InstalledApplications -ForceRescan)

        @($apps | Where-Object { $_.Name -eq "Tool" }).Count | Should -Be 2
    }

    It "Merges entries with one name, version and publisher" {
        $script:RegistryFixtures = @(
            [PSCustomObject]@{
                PSPath = "HKLM-test\a"; PSChildName = "a"; DisplayName = "Twin"; DisplayVersion = "2.0"
                Publisher = "Contoso"; UninstallString = "C:\a\uninstall.exe"
            },
            [PSCustomObject]@{
                PSPath = "HKLM-test\b"; PSChildName = "b"; DisplayName = "Twin"; DisplayVersion = "2.0"
                Publisher = "Contoso"; UninstallString = "C:\b\uninstall.exe"
            }
        )

        $apps = @(Get-InstalledApplications -ForceRescan)

        @($apps | Where-Object { $_.Name -eq "Twin" }).Count | Should -Be 1
        @($apps | Where-Object { $_.Name -eq "Twin" } | ForEach-Object { $_.MergedKeys }) | Sort-Object | Should -Be @("HKLM-test\a", "HKLM-test\b")
    }

    It "Hides system components, updates and child entries" {
        $script:RegistryFixtures = @(
            [PSCustomObject]@{ PSPath = "HKLM-test\c"; PSChildName = "c"; DisplayName = "Hidden Component"; UninstallString = "x"; SystemComponent = 1 }
            [PSCustomObject]@{ PSPath = "HKLM-test\u"; PSChildName = "u"; DisplayName = "Security Update for Thing"; UninstallString = "x"; ReleaseType = "Security Update" }
            [PSCustomObject]@{ PSPath = "HKLM-test\h"; PSChildName = "h"; DisplayName = "Hotfix for Thing"; UninstallString = "x"; ReleaseType = "Hotfix" }
            [PSCustomObject]@{ PSPath = "HKLM-test\p"; PSChildName = "p"; DisplayName = "Child Package"; UninstallString = "x"; ParentKeyName = "Parent" }
            [PSCustomObject]@{ PSPath = "HKLM-test\v"; PSChildName = "v"; DisplayName = "Visible App"; UninstallString = "x" }
        )

        $apps = @(Get-InstalledApplications -ForceRescan)

        @($apps | ForEach-Object { $_.Name }) | Should -Be @("Visible App")
    }

    It "Keeps a non-ASCII app name through the cache" {
        # Set-Content in Windows PowerShell 5.1 wrote the ANSI code page, so on
        # a Western system this name came back from the cache as question marks.
        $name = "测试应用 Über " + [char]::ConvertFromUtf32(0x1F680)
        $script:RegistryFixtures = @(
            [PSCustomObject]@{ PSPath = "HKLM-test\cjk"; PSChildName = "cjk"; DisplayName = $name; UninstallString = "C:\x\u.exe"; EstimatedSize = 1024 }
        )

        @(Get-InstalledApplications -ForceRescan)[0].Name | Should -BeExactly $name
        $script:RegistryFixtures = @()
        @(Get-InstalledApplications)[0].Name | Should -BeExactly $name
        [System.IO.File]::ReadAllText($script:AppCacheFile, [System.Text.Encoding]::UTF8) | Should -Not -Match '\?\?'
    }

    It "Reads the per-user 32-bit Uninstall key too" {
        Get-InstalledApplications -ForceRescan | Out-Null

        Should -Invoke Get-ItemProperty -Times 1 -Exactly -ParameterFilter {
            "$Path" -eq "HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        }
    }

    It "Leaves out Store packages Windows depends on" {
        Mock Get-AppxPackage {
            $names = @(
                "Microsoft.WindowsStore", "Microsoft.StorePurchaseApp", "Microsoft.DesktopAppInstaller",
                "Microsoft.SecHealthUI", "Microsoft.GetHelp", "Microsoft.XboxGamingOverlay", "Microsoft.Windows.Photos", "Contoso.Notes"
            )
            foreach ($name in $names) {
                [PSCustomObject]@{
                    Name = $name; PackageFullName = "${name}_1.0.0.0_x64__abc"; Publisher = "CN=Test"; Version = "1.0.0.0"
                    IsFramework = $false; IsResourcePackage = $false; IsBundle = $false; SignatureKind = "Store"; InstallLocation = $null
                }
            }
            [PSCustomObject]@{
                Name = "Contoso.Resources"; PackageFullName = "Contoso.Resources_1.0.0.0_neutral_split.scale-100_abc"; Publisher = "CN=Test"
                Version = "1.0.0.0"; IsFramework = $false; IsResourcePackage = $true; IsBundle = $false; SignatureKind = "Store"; InstallLocation = $null
            }
            [PSCustomObject]@{
                Name = "Contoso.Bundle"; PackageFullName = "Contoso.Bundle_1.0.0.0_neutral_~_abc"; Publisher = "CN=Test"
                Version = "1.0.0.0"; IsFramework = $false; IsResourcePackage = $false; IsBundle = $true; SignatureKind = "Store"; InstallLocation = $null
            }
        }

        $apps = @(Get-InstalledApplications -ForceRescan)

        @($apps | ForEach-Object { $_.Name }) | Should -Be @("Contoso.Notes")
    }

    It "Leaves out a sparse package a desktop app registers, like WinMerge's context menu" {
        Mock Get-AppxPackage {
            foreach ($name in @("WinMerge", "Contoso.Notes", "Contoso.Unread")) {
                [PSCustomObject]@{
                    Name = $name; PackageFullName = "${name}_1.0.8.0_neutral__f62ztx9ss5ed4"; Publisher = "CN=Test"; Version = "1.0.8.0"
                    IsFramework = $false; IsResourcePackage = $false; IsBundle = $false; SignatureKind = "Developer"; InstallLocation = $null
                }
            }
        }
        Mock Get-AppxPackageManifest {
            if ($Package -like "Contoso.Unread_*") { throw "manifest unavailable" }
            $external = if ($Package -like "WinMerge_*") { "<uap10:AllowExternalContent>true</uap10:AllowExternalContent>" } else { "" }
            [xml]("<Package xmlns='http://schemas.microsoft.com/appx/manifest/foundation/windows10' " +
                "xmlns:uap10='http://schemas.microsoft.com/appx/manifest/uap/windows10/10'><Properties>" +
                "<DisplayName>$($Package.Split('_')[0])</DisplayName>$external</Properties></Package>")
        }

        $apps = @(Get-InstalledApplications -ForceRescan)

        @($apps | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @("Contoso.Notes")
    }
}

Describe "Selecting apps that share a name" {
    BeforeEach {
        Mock Clear-MoleScreen {}
        Mock Write-Host {}
        $script:MenuKeys = @("Spacebar", "Enter")
        $script:MenuKeyIndex = 0
        Mock Read-MenuKey {
            $key = $script:MenuKeys[$script:MenuKeyIndex]
            $script:MenuKeyIndex++
            [PSCustomObject]@{ Key = $key }
        }
    }

    It "Toggles each entry by its registry key, not its name" {
        $apps = @(
            [PSCustomObject]@{ Name = "Same Name"; SizeKB = 1; SizeHuman = "1KB"; RegistryKey = "HKLM-test\first"; PackageFullName = $null }
            [PSCustomObject]@{ Name = "Same Name"; SizeKB = 2; SizeHuman = "2KB"; RegistryKey = "HKLM-test\second"; PackageFullName = $null }
        )

        $selected = @(Show-AppSelectionMenu -Apps $apps)

        $selected.Count | Should -Be 1
        $selected[0].RegistryKey | Should -Be "HKLM-test\first"
    }
}


Describe 'Leftover install folder ownership' {
    BeforeAll {
        # The stub lets the pre-fix command run the same behavior fixtures.
        if (-not (Get-Command Get-MoleInstallOwners -ErrorAction SilentlyContinue)) {
            function Get-MoleInstallOwners { @{ Complete = $true; Owners = @() } }
        }
        if (-not (Get-Command Test-UninstallLaunchCurrent -ErrorAction SilentlyContinue)) {
            function Test-UninstallLaunchCurrent { $true }
        }
    }
    BeforeEach {
        $script:SharedFolder = New-TestFolder -Name 'Shared Vendor'
        $script:SelectedApp = [pscustomobject]@{
            Name = 'Tool A'; Source = 'Registry'; InstallLocation = $script:SharedFolder
            RegistryKey = 'selected-key'; UninstallString = 'mock.exe'; PackageFullName = $null
        }
        $script:Owners = @()
        Mock Get-MoleInstallOwners { @{ Complete = $true; Owners = $script:Owners } }
        Mock Get-UninstallLaunch { @{ FilePath = 'mock.exe'; Arguments = '' } }
        Mock Test-UninstallLaunchCurrent { $true }
        # The entry disappears once the uninstaller has run, not before.
        $script:UninstallerRan = $false
        Mock Invoke-MoleUninstallProcess { $script:UninstallerRan = $true; [pscustomobject]@{ ExitCode = 0 } }
        Mock Test-UninstallEntryGone { $script:UninstallerRan }
        Mock Remove-SafeItem { $true }
        Mock Write-Host {}
        Set-DryRunMode -Enabled $false
    }
    AfterEach { Set-DryRunMode -Enabled $false }

    It 'Keeps a surviving <Relation> owner in preview and real uninstall' -TestCases @(
        @{ Relation = 'same'; Relative = '' }
        @{ Relation = 'child'; Relative = 'Tool B' }
        @{ Relation = 'parent'; Relative = '..' }
    ) {
        param($Relation, $Relative)
        $ownerPath = if ($Relative) { [IO.Path]::GetFullPath((Join-Path $script:SharedFolder $Relative)) } else { $script:SharedFolder }
        $script:Owners = @(@{ Path = $ownerPath; Key = 'other-key' })
        Uninstall-SelectedApps @($script:SelectedApp)
        Set-DryRunMode -Enabled $true
        Uninstall-SelectedApps @($script:SelectedApp)
        Should -Invoke Remove-SafeItem -Times 0 -Exactly
    }
    It 'Keeps leftovers when the ownership inventory is incomplete' {
        Mock Get-MoleInstallOwners { @{ Complete = $false; Owners = @() } }
        Uninstall-SelectedApps @($script:SelectedApp)
        Set-DryRunMode -Enabled $true
        Uninstall-SelectedApps @($script:SelectedApp)
        Should -Invoke Remove-SafeItem -Times 0 -Exactly
    }
    It 'Allows an independent prefix sibling and ignores only the selected preview key' {
        $script:Owners = @(@{ Path = $script:SharedFolder + '-other'; Key = 'other-key' })
        Uninstall-SelectedApps @($script:SelectedApp)
        $script:Owners += @{ Path = $script:SharedFolder; Key = 'selected-key' }
        Set-DryRunMode -Enabled $true
        Uninstall-SelectedApps @($script:SelectedApp)
        Should -Invoke Remove-SafeItem -Times 2 -Exactly
    }
    It 'Previews a leftover when the only blocking key is a duplicate merged into the selected app' {
        $script:SelectedApp | Add-Member -NotePropertyName MergedKeys -NotePropertyValue @('selected-key', 'duplicate-key') -Force
        $script:Owners = @(@{ Path = $script:SharedFolder; Key = 'selected-key' }, @{ Path = $script:SharedFolder; Key = 'duplicate-key' })
        Set-DryRunMode -Enabled $true
        Uninstall-SelectedApps @($script:SelectedApp)
        Should -Invoke Remove-SafeItem -Times 1 -Exactly
    }
    It 'Keeps the leftover in a real run while a merged duplicate key survives' {
        $script:SelectedApp | Add-Member -NotePropertyName MergedKeys -NotePropertyValue @('selected-key', 'duplicate-key') -Force
        $script:Owners = @(@{ Path = $script:SharedFolder; Key = 'duplicate-key' })
        Uninstall-SelectedApps @($script:SelectedApp)
        Should -Invoke Remove-SafeItem -Times 0 -Exactly
    }
    It 'Retains game content that appears at the final removal boundary' {
        $script:SelectedApp.InstallLocation = New-TestFolder 'Late game content'
        $script:GuardResult = $true
        Mock Remove-SafeItem {
            param($Path, $Guard)
            [IO.Directory]::CreateDirectory((Join-Path $Path 'saves')) | Out-Null
            if ($null -ne $Guard) { $script:GuardResult = & $Guard $Path }
            return $false
        }
        Uninstall-SelectedApps @($script:SelectedApp)
        Should -Invoke Remove-SafeItem -Times 1 -Exactly
        $script:GuardResult | Should -BeFalse
    }
    It 'Rechecks ownership in the final removal guard' {
        $script:GuardResult = $true
        Mock Remove-SafeItem {
            param($Path, $Guard)
            $script:Owners = @(@{ Path = $Path; Key = 'new-owner' })
            if ($null -ne $Guard) { $script:GuardResult = & $Guard $Path }
            return $false
        }
        Uninstall-SelectedApps @($script:SelectedApp)
        Should -Invoke Remove-SafeItem -Times 1 -Exactly
        $script:GuardResult | Should -BeFalse
    }
}


Describe 'Complete install owner probes' {
    BeforeEach {
        Mock Get-Item { [pscustomobject]@{} } -ParameterFilter { $LiteralPath -like 'HK*' }
        Mock Get-ChildItem { @() } -ParameterFilter { $LiteralPath -like 'HK*' }
        Mock Get-AppxPackage { @() }
    }
    It 'Includes hidden registered components without applying the menu filter' {
        Mock Get-ChildItem { @([pscustomobject]@{ PSPath = 'owner-entry' }) } -ParameterFilter { $LiteralPath -like 'HK*' }
        Mock Get-ItemProperty { [pscustomobject]@{ InstallLocation = 'D:\Tools\Shared'; SystemComponent = 1 } } -ParameterFilter { $LiteralPath -eq 'owner-entry' }
        $result = Get-MoleInstallOwners
        $result.Complete | Should -BeTrue
        @($result.Owners | Where-Object { $_.Path -eq 'D:\Tools\Shared' }).Count | Should -Be 4
    }
    It 'Reports registry read failures as incomplete' {
        Mock Get-ChildItem { throw 'unreadable registry' } -ParameterFilter { $LiteralPath -like 'HK*' }
        (Get-MoleInstallOwners).Complete | Should -BeFalse
    }
    It 'Reports Store enumeration failures as incomplete' {
        Mock Get-AppxPackage { throw 'package inventory unavailable' }
        (Get-MoleInstallOwners).Complete | Should -BeFalse
    }
    It 'Allows an empty complete inventory' {
        $result = Get-MoleInstallOwners
        $result.Complete | Should -BeTrue
        @($result.Owners).Count | Should -Be 0
    }
}

Describe 'Store display sizes without deletion authority' {
    It 'measures readable packages when ancestor deletion identity is unavailable' {
        $folder = New-TestFolder 'read-only-package'
        Mock Get-MolePathSnapshot { $null }
        (Get-AppxInstallSizeKB -Path $folder) | Should -BeGreaterThan 0
        Should -Invoke Get-MolePathSnapshot -Times 0 -Exactly
    }

    It 'retains unknown size for missing packages and never follows a junction' {
        $target = New-TestFolder 'size-target'
        $link = Join-Path $TestDrive 'size-link'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        (Get-AppxInstallSizeKB -Path $link) | Should -BeNullOrEmpty
        (Get-AppxInstallSizeKB -Path (Join-Path $TestDrive 'missing-size')) | Should -BeNullOrEmpty
    }

    It 'does not turn a failed child enumeration into a complete size' {
        $folder = New-TestFolder 'unreadable-package'
        Mock Get-ChildItem { throw 'Access denied' } -ParameterFilter { $LiteralPath -eq $folder }
        (Get-AppxInstallSizeKB -Path $folder) | Should -BeNullOrEmpty
    }
}

Describe 'Uninstall rendered regression' {
    It 'keeps Chinese and ASCII menu sizes on the same display column' {
        Mock Clear-MoleScreen {}
        Mock Get-TerminalSize { @{Width=80;Height=24} }
        Mock Read-MenuKey { [pscustomobject]@{Key='Q'; KeyChar='q'} }
        $script:RenderedRows = @()
        Mock Write-Host { if ("$Object" -match '^  \[ \] ') { $script:RenderedRows += "$Object" } }
        $null = Show-AppSelectionMenu -Apps @(
            [pscustomobject]@{Name='Clash Party';SizeHuman='683.5MB'},
            [pscustomobject]@{Name='微信输入法';SizeHuman='443.4MB'},
            [pscustomobject]@{Name=('中文应用' * 20);SizeHuman='1MB'})
        $script:RenderedRows.Count | Should -Be 3
        foreach ($row in $script:RenderedRows) {
            # Independent oracle: these fixtures contain ASCII and BMP CJK only.
            ($row.Length + [regex]::Matches($row,'[\u4e00-\u9fff]').Count) | Should -Be 59
        }
    }

    It 'selects the only app a search matches' {
        Mock Clear-MoleScreen {}
        Mock Write-Host {}
        Mock Get-TerminalSize { @{Width=80;Height=24} }
        Mock Read-Host { 'Clash' }
        $script:MenuKeys = [System.Collections.Queue]::new()
        foreach ($key in 'Oem2', 'Spacebar', 'Enter') { $script:MenuKeys.Enqueue([pscustomobject]@{Key=$key; KeyChar=' '}) }
        Mock Read-MenuKey { $script:MenuKeys.Dequeue() }
        $selected = @(Show-AppSelectionMenu -Apps @(
            [pscustomobject]@{Name='Clash Party';SizeHuman='683.5MB';SizeKB=699904},
            [pscustomobject]@{Name='WeChat';SizeHuman='875.5MB';SizeKB=896512}))
        $selected.Count | Should -Be 1
        $selected[0].Name | Should -Be 'Clash Party'
    }

    It 'publishes a measured Store size without ancestor deletion access' {
        $folder = New-TestFolder 'store-inventory'
        Mock Write-Info {}
        Mock Write-Progress {}
        Mock Get-ItemProperty { @() } -ParameterFilter { "$Path" -like 'HK*' }
        Mock Get-MolePathSnapshot { $null }
        Mock Get-AppxPackageManifest { [xml]'<Package><Properties /></Package>' }
        Mock Get-AppxPackage {
            [pscustomobject]@{Name='Contoso.Notes';PackageFullName='Contoso.Notes_1.0_x64__abc';
                Publisher='CN=Test';Version='1.0';IsFramework=$false;IsResourcePackage=$false;
                IsBundle=$false;SignatureKind='Store';InstallLocation=$folder}
        }
        $apps = @(Get-InstalledApplications -ForceRescan)
        $apps.Count | Should -Be 1
        $apps[0].SizeKB | Should -BeGreaterThan 0
        $apps[0].SizeChecked | Should -BeTrue
    }
}

Describe 'Registered Proton Pass uninstall compatibility' {
    BeforeEach {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like 'C:\Apps\Proton Pass\*.exe' -or $LiteralPath -eq 'C:\Other\Update.exe' }
        $script:Proton = [pscustomobject]@{
            Name = 'Proton Pass'; Publisher = 'Proton AG'; Version = '1.37.0'
            QuietUninstallString = '"C:\Apps\Proton Pass\Update.exe" --uninstall -s'
            UninstallString = '"C:\Apps\Proton Pass\Update.exe" --uninstall'
        }
    }
    It 'Uses the exact registered normal command for the known broken quiet command' {
        $launch = Get-UninstallLaunch -App $script:Proton
        $launch.Arguments | Should -Be '--uninstall'
        $launch.Kind | Should -Be 'registered'
    }
    It 'Preserves quiet commands outside the verified vendor version and executable' -TestCases @(
        @{ Field = 'Name'; Value = 'Another App' }
        @{ Field = 'Publisher'; Value = 'Another Vendor' }
        @{ Field = 'Version'; Value = '1.37.1' }
        @{ Field = 'UninstallString'; Value = '"C:\Other\Update.exe" --uninstall' }
        @{ Field = 'UninstallString'; Value = '"C:\Apps\Proton Pass\Update.exe" --uninstall --other' }
        @{ Field = 'QuietUninstallString'; Value = '"C:\Apps\Proton Pass\Other.exe" --uninstall -s' }
        @{ Field = 'QuietUninstallString'; Value = '"C:\Apps\Proton Pass\Update.exe" --uninstall -s true' }
    ) {
        param($Field, $Value)
        $script:Proton.$Field = $Value
        $launch = Get-UninstallLaunch -App $script:Proton
        $launch.Kind | Should -Be 'quiet'
    }
}

Describe "mo uninstall --list" {
    BeforeAll {
        $DryRun = $false
        $DebugMode = $false
        $ShowHelp = $false
        $Rescan = $false
        $List = $true
        $base = "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        $script:ListRegistryApp = [PSCustomObject]@{
            Name = "Contoso Editor"; Publisher = "Contoso"; Version = "2.1"; SizeKB = 2048; SizeHuman = "2.0MB"
            SizeChecked = $true; InstallLocation = "C:\Program Files\Contoso Editor"; RegistryKey = "$base\ContosoEditor"
            PackageFullName = $null; Source = "Registry"
        }
        $script:ListStoreApp = [PSCustomObject]@{
            Name = "Contoso Notes"; Publisher = "CN=Contoso"; Version = "1.0.0.0"; SizeKB = 0; SizeHuman = "0B"
            SizeChecked = $false; InstallLocation = "C:\Program Files\WindowsApps\Contoso.Notes_1.0.0.0_x64__abc"
            RegistryKey = $null; PackageFullName = "Contoso.Notes_1.0.0.0_x64__abc"; Source = "WindowsStore"
        }
    }

    BeforeEach {
        Mock Test-UninstallListAsJson { $true }
        Mock Get-InstalledApplications { @($script:ListRegistryApp, $script:ListStoreApp) }
        Mock Clear-MoleScreen { throw "--list must not clear the screen" }
        Mock Show-AppSelectionMenu { throw "--list must not open the menu" }
        Mock Read-Host { throw "--list must not prompt" }
        Mock Uninstall-SelectedApps { throw "--list must not uninstall" }
        Mock Invoke-MoleUninstallProcess { throw "--list must not start a process" }
        Mock Remove-AppxPackage { throw "--list must not remove a package" }
        Mock Write-MoleOperation { throw "--list must not write operations.log" }
        Mock Add-MoleOperationText { throw "--list must not write operations.log" }
    }

    It "Prints the inventory as a JSON array when output is redirected" {
        $text = (& { Set-StrictMode -Version Latest; Main }) -join "`n"

        $text.TrimStart().StartsWith("[") | Should -BeTrue
        $parsed = ConvertFrom-Json -InputObject $text
        $records = @($parsed)
        $records.Count | Should -Be 2
        $records[0].name | Should -BeExactly "Contoso Editor"
        # The provider prefix of PSPath stays out of the id.
        $records[0].id | Should -BeExactly "registry:HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ContosoEditor"
        $records[0].source | Should -BeExactly "Registry"
        $records[0].version | Should -BeExactly "2.1"
        $records[0].publisher | Should -BeExactly "Contoso"
        $records[0].path | Should -BeExactly "C:\Program Files\Contoso Editor"
        $records[0].size | Should -BeExactly "2.0MB"
        $records[0].size_bytes | Should -Be 2097152
        $records[1].id | Should -BeExactly "package:Contoso.Notes_1.0.0.0_x64__abc"
        $records[1].source | Should -BeExactly "WindowsStore"
        $records[1].size | Should -BeExactly "Unknown"
        $records[1].size_bytes | Should -BeNullOrEmpty
        Should -Invoke Get-InstalledApplications -Times 1 -Exactly -ParameterFilter { $Quiet -and -not $ForceRescan }
    }

    It "Keeps a single app inside a JSON array" {
        Mock Get-InstalledApplications { $script:ListRegistryApp }

        $text = (& { Set-StrictMode -Version Latest; Main }) -join "`n"

        $text.TrimStart().StartsWith("[") | Should -BeTrue
        $text.TrimEnd().EndsWith("]") | Should -BeTrue
        $parsed = ConvertFrom-Json -InputObject $text
        @($parsed).Count | Should -Be 1
        @($parsed)[0].name | Should -BeExactly "Contoso Editor"
    }

    It "Prints an empty array for an empty inventory" {
        Mock Get-InstalledApplications { @() }

        $text = (& { Set-StrictMode -Version Latest; Main }) -join "`n"

        $text | Should -BeExactly "[]"
    }

    It "Escapes non-ASCII names so the console code page cannot change them" {
        $name = "Contoso " + [string][char]0x7B14 + [string][char]0x8BB0
        $app = [PSCustomObject]@{ Name = $name; SizeKB = 4; SizeHuman = "4KB"; SizeChecked = $true; RegistryKey = "HKLM-test\notes"; Source = "Registry" }
        Mock Get-InstalledApplications { $app }

        $text = (& { Set-StrictMode -Version Latest; Main }) -join "`n"

        $text | Should -Not -Match '[^\x00-\x7F]'
        $text | Should -Match '\\u7b14\\u8bb0'
        @(ConvertFrom-Json -InputObject $text)[0].name | Should -BeExactly $name
        @(ConvertFrom-Json -InputObject $text)[0].path | Should -BeExactly ""
        @(ConvertFrom-Json -InputObject $text)[0].version | Should -BeNullOrEmpty
    }

    It "Passes --rescan to the inventory as the menu does" {
        $Rescan = $true
        try {
            $null = & { Set-StrictMode -Version Latest; Main }
        }
        finally { $Rescan = $false }

        Should -Invoke Get-InstalledApplications -Times 1 -Exactly -ParameterFilter { $ForceRescan -and $Quiet }
    }

    It "Lists before dry-run setup even when combined with --dry-run" {
        $DryRun = $true
        try {
            $null = & { Set-StrictMode -Version Latest; Main }
        }
        finally { $DryRun = $false }

        Should -Invoke Clear-MoleScreen -Times 0 -Exactly
    }

    It "Prints an aligned table on a console and nothing to the pipeline" {
        Mock Test-UninstallListAsJson { $false }
        $script:ListLines = @()
        Mock Write-Host { $script:ListLines += [string]$Object }

        $output = @(& { Set-StrictMode -Version Latest; Main })

        $output.Count | Should -Be 0
        $rows = @($script:ListLines | Where-Object { $_ -match 'Contoso' })
        $rows.Count | Should -Be 2
        $rows[0] | Should -BeExactly ("  " + (Format-SizeListEntry -Name "Contoso Editor" -Size "2.0MB"))
        $rows[1] | Should -BeExactly ("  " + (Format-SizeListEntry -Name "Contoso Notes" -Size "Unknown"))
        $script:ListLines | Should -Contain "2 application(s)"
    }

    It "Never runs an uninstaller, prompts or writes the log" {
        $null = & { Set-StrictMode -Version Latest; Main }

        Should -Invoke Invoke-MoleUninstallProcess -Times 0 -Exactly
        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
        Should -Invoke Uninstall-SelectedApps -Times 0 -Exactly
        Should -Invoke Show-AppSelectionMenu -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Write-MoleOperation -Times 0 -Exactly
        Should -Invoke Add-MoleOperationText -Times 0 -Exactly
    }
}

Describe "Quiet inventory scan" {
    BeforeEach {
        Mock Write-Info { throw "a quiet scan must not write to the host" }
        Mock Write-Progress { throw "a quiet scan must not report progress" }
        Mock Get-AppxPackage { @() }
        Mock Get-AppxPackageManifest { [xml]'<Package><Properties /></Package>' }
        Mock Get-ItemProperty {
            if ("$Path" -like "HKLM:\SOFTWARE\Microsoft\*") {
                [PSCustomObject]@{ PSPath = "HKLM-test\quiet"; PSChildName = "quiet"; DisplayName = "Quiet Tool"; UninstallString = "C:\q\u.exe"; EstimatedSize = 1024 }
            }
        } -ParameterFilter { "$Path" -like "HK*" }
        if (Test-Path -LiteralPath $script:AppCacheFile) { Remove-Item -LiteralPath $script:AppCacheFile }
    }

    It "Scans the same inventory without host output" {
        $apps = @(Get-InstalledApplications -ForceRescan -Quiet)

        $apps.Count | Should -Be 1
        $apps[0].Name | Should -BeExactly "Quiet Tool"
        Should -Invoke Write-Info -Times 0 -Exactly
        Should -Invoke Write-Progress -Times 0 -Exactly
    }
}

Describe 'Store package eligibility at the removal boundary' {
    BeforeEach {
        Set-DryRunMode -Enabled $false
        Mock Write-Host {}
        Mock Show-SummaryBlock {}
        Mock Write-MoleOperation {}
        Mock Remove-AppxPackage {}
        Mock Invoke-MoleUninstallProcess { throw 'No vendor uninstaller is allowed' }
        $script:CurrentStorePackage = [pscustomobject]@{
            Name='Contoso.Notes';PackageFullName='Contoso.Notes_1.0.0.0_x64__abc';SignatureKind='Store'
            IsFramework=$false;IsResourcePackage=$false;IsBundle=$false
            InstallLocation='C:\Program Files\WindowsApps\Contoso.Notes_1.0.0.0_x64__abc'
        }
        Mock Get-AppxPackage { $script:CurrentStorePackage }
        Mock Get-AppxPackageManifest { [xml]'<Package><Properties /></Package>' }
        $script:SelectedStoreApp = [pscustomobject]@{Name='Cached friendly name';Source='WindowsStore';PackageFullName=$script:CurrentStorePackage.PackageFullName}
    }
    AfterEach { Set-DryRunMode -Enabled $false }

    It 'Refuses current Game Bar metadata even with an old friendly name, preview=<Preview>' -TestCases @(@{Preview=$true},@{Preview=$false}) {
        param($Preview)
        Set-DryRunMode -Enabled $Preview
        $script:CurrentStorePackage.Name = 'Microsoft.XboxGamingOverlay'
        $script:CurrentStorePackage.PackageFullName = 'Microsoft.XboxGamingOverlay_1.0.0.0_x64__abc'
        $script:CurrentStorePackage.InstallLocation = 'C:\Program Files\WindowsApps\Microsoft.XboxGamingOverlay_1.0.0.0_x64__abc'
        $script:SelectedStoreApp.PackageFullName = $script:CurrentStorePackage.PackageFullName
        Uninstall-SelectedApps @($script:SelectedStoreApp)
        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
        if ($Preview) {
            Should -Invoke Write-MoleOperation -Times 0 -Exactly
            Should -Invoke Show-SummaryBlock -Times 1 -Exactly -ParameterFilter { $Details -contains 'Would uninstall: 0' }
        }
        else {
            Should -Invoke Write-MoleOperation -Times 0 -Exactly -ParameterFilter { $Action -eq 'UNINSTALLED' }
            $script:MoleUninstallIncomplete | Should -BeTrue
        }
    }
    It 'Retains a stale Store selection when current evidence is <State>' -TestCases @(@{State='missing'},@{State='unreadable'},@{State='system'},@{State='different version'}) {
        param($State)
        switch ($State) {
            'missing' { Mock Get-AppxPackage { @() } }
            'unreadable' { Mock Get-AppxPackage { throw 'inventory unavailable' } }
            'system' { $script:CurrentStorePackage.SignatureKind='System' }
            'different version' { $script:CurrentStorePackage.PackageFullName='Contoso.Notes_2.0.0.0_x64__abc' }
        }
        Uninstall-SelectedApps @($script:SelectedStoreApp)
        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
    }
    It 'Does not preview a Store package when current inventory is unreadable' {
        Set-DryRunMode -Enabled $true
        Mock Get-AppxPackage { throw 'inventory unavailable' }
        Uninstall-SelectedApps @($script:SelectedStoreApp)
        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
        Should -Invoke Write-MoleOperation -Times 0 -Exactly
        Should -Invoke Show-SummaryBlock -Times 1 -Exactly -ParameterFilter { $Details -contains 'Would uninstall: 0' }
    }
    It 'Previews an eligible ordinary Store package without writing' {
        Set-DryRunMode -Enabled $true
        Uninstall-SelectedApps @($script:SelectedStoreApp)
        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
        Should -Invoke Write-MoleOperation -Times 0 -Exactly
        Should -Invoke Show-SummaryBlock -Times 1 -Exactly -ParameterFilter { $Details -contains 'Would uninstall: 1' }
    }
    It 'Rechecks an explicit sparse manifest even when the cached full identity still matches' {
        Mock Get-AppxPackageManifest { [xml]'<Package><Properties><AllowExternalContent>true</AllowExternalContent></Properties></Package>' }
        Uninstall-SelectedApps @($script:SelectedStoreApp)
        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
    }
    It 'Retains a Store package with unknown manifest evidence <Evidence>, preview=<Preview>' -TestCases @(
        @{ Evidence='unreadable'; Preview=$false }, @{ Evidence='unreadable'; Preview=$true },
        @{ Evidence='empty'; Preview=$false }, @{ Evidence='empty'; Preview=$true },
        @{ Evidence='non-XML'; Preview=$false }, @{ Evidence='non-XML'; Preview=$true },
        @{ Evidence='missing properties'; Preview=$false }, @{ Evidence='missing properties'; Preview=$true },
        @{ Evidence='invalid external flag'; Preview=$false }, @{ Evidence='invalid external flag'; Preview=$true }
    ) {
        param($Evidence, $Preview)
        Set-DryRunMode -Enabled $Preview
        switch ($Evidence) {
            'unreadable' { Mock Get-AppxPackageManifest { throw 'manifest unreadable' } }
            'empty' { Mock Get-AppxPackageManifest { $null } }
            'non-XML' { Mock Get-AppxPackageManifest { 'not a manifest' } }
            'missing properties' { Mock Get-AppxPackageManifest { [xml]'<Package />' } }
            'invalid external flag' { Mock Get-AppxPackageManifest { [xml]'<Package><Properties><AllowExternalContent>unknown</AllowExternalContent></Properties></Package>' } }
        }
        Uninstall-SelectedApps @($script:SelectedStoreApp)
        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
        Should -Invoke Write-MoleOperation -Times 0 -Exactly -ParameterFilter { $Action -eq 'UNINSTALLED' }
        if ($Preview) {
            Should -Invoke Show-SummaryBlock -Times 1 -Exactly -ParameterFilter { $Details -contains 'Would uninstall: 0' }
        }
    }
    It 'Still removes an exactly matched ordinary Store app, external flag=<Flag>' -TestCases @(
        @{ Flag='' }, @{ Flag='false' }, @{ Flag='0' }
    ) {
        param($Flag)
        $external = if ($Flag) { "<AllowExternalContent>$Flag</AllowExternalContent>" } else { '' }
        $script:OrdinaryManifest = [xml]"<Package><Properties>$external</Properties></Package>"
        Mock Get-AppxPackageManifest { $script:OrdinaryManifest }
        Uninstall-SelectedApps @($script:SelectedStoreApp)
        Should -Invoke Remove-AppxPackage -Times 1 -Exactly -ParameterFilter { $Package -eq 'Contoso.Notes_1.0.0.0_x64__abc' }
        Should -Invoke Get-AppxPackage -Times 1 -Exactly -ParameterFilter { $Name -eq 'Contoso.Notes' }
    }
}


Describe 'Charge limit uninstall notice' {
    BeforeEach {
        $DryRun = $false
        $DebugMode = $false
        $ShowHelp = $false
        $Rescan = $false
        $List = $false
        Set-DryRunMode -Enabled $false
        $script:Icons = Get-MoleDefaultIcons
        Mock Clear-MoleScreen {}
        Mock Write-Info {}
        Mock Write-Host {}
        Mock Read-Host { 'n' }
        Mock Test-MoleStoreRemovalAllowed { $true }
        Mock Test-MoleLeftoverOwnership { $false }
        Mock Invoke-MoleUninstallProcess { throw 'No real uninstall' }
        Mock Remove-AppxPackage { throw 'No real uninstall' }
    }

    AfterEach { Set-DryRunMode -Enabled $false }

    It 'Shows the charge-limit consequence for <Identity> only when applicable' -ForEach @(
        @{Identity='E046963F.LenovoCompanion';Source='WindowsStore';Publisher='';Expected=1},
        @{Identity='LenovoCompanyLimited.LenovoVantageService';Source='WindowsStore';Publisher='';Expected=1},
        @{Identity='B9ECED6F.ASUSPCAssistant';Source='WindowsStore';Publisher='';Expected=1},
        @{Identity='Microsoft.SurfaceHub';Source='WindowsStore';Publisher='';Expected=1},
        @{Identity='Lenovo Vantage Service';Source='Registry';Publisher='Lenovo Group Limited';Expected=1},
        @{Identity='Lenovo Vantage Service';Source='Registry';Publisher='Other vendor';Expected=0},
        @{Identity='Lenovo Vantage Service';Source='Registry';Publisher='LenovoClone';Expected=0},
        @{Identity='E046963F.LenovoCompanionExtra';Source='WindowsStore';Publisher='';Expected=0},
        @{Identity='Microsoft.SurfaceHub';Source='Registry';Publisher='Microsoft';Expected=0},
        @{Identity='Ordinary app';Source='Registry';Publisher='Lenovo';Expected=0}
    ) {
        $script:ChargeApp = [pscustomobject]@{
            Name=$Identity; Source=$Source; Publisher=$Publisher; SizeHuman='1MB'
            PackageFullName=($Identity + '_1.0.0.0_x64__example'); InstallLocation=''
            UninstallString='C:\fixture\uninstall.exe'; QuietUninstallString=$null; WindowsInstaller=$false
        }
        Mock Get-InstalledApplications { $script:ChargeApp }
        Mock Show-AppSelectionMenu { $script:ChargeApp }
        Main
        Should -Invoke Write-Host -Times $Expected -Exactly -ParameterFilter { "$Object" -like '*charge limit*' }
        Should -Invoke Read-Host -Times 1 -Exactly
        Set-DryRunMode -Enabled $true
        Uninstall-SelectedApps @($script:ChargeApp)
        Should -Invoke Write-Host -Times ($Expected * 2) -Exactly -ParameterFilter { "$Object" -like '*charge limit*' }
        Should -Invoke Invoke-MoleUninstallProcess -Times 0 -Exactly
        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
    }
}
