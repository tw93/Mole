# Mole Windows - optimize step tests
# Main is lifted out of bin/optimize.ps1 and run with every side effect mocked,
# so no real repair, reset or prompt runs on the test machine.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir "lib"
    $script:OptimizeScript = Join-Path $script:WindowsDir "bin\optimize.ps1"
    . "$script:LibDir\core\base.ps1"
    . "$script:LibDir\core\log.ps1"
    . "$script:LibDir\core\ui.ps1"
    . "$script:LibDir\core\file_ops.ps1"

    $script:OptimizeAst = [System.Management.Automation.Language.Parser]::ParseFile($script:OptimizeScript, [ref]$null, [ref]$null)
    $definitions = $script:OptimizeAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $false)
    $script:OptimizeFunctionNames = @()
    foreach ($definition in $definitions) {
        . ([scriptblock]::Create($definition.Extent.Text))
        Set-Item -Path "function:script:$($definition.Name)" -Value (Get-Item "function:$($definition.Name)").ScriptBlock
        $script:OptimizeFunctionNames += $definition.Name
    }

    # Storage and DnsClient cmdlets are CDXML, which Pester cannot mock on
    # Windows PowerShell 5.1; plain functions shadow them so they can be.
    function script:Get-PhysicalDisk { }
    function script:Get-Volume { param($DriveLetter) }
    function script:Get-Partition { param($DriveLetter) }
    function script:Get-Disk { param($Number) }
    function script:Optimize-Volume { param($DriveLetter, [switch]$ReTrim) }
    function script:Clear-DnsClientCache { }
    function script:Repair-WindowsImage { param([switch]$Online, [switch]$CheckHealth, [switch]$RestoreHealth) }
}

Describe "Read-only system health queries" {
    It "Collects health metrics in the current PowerShell host without query mocks" {
        $health = Get-SystemHealth

        $health.MemoryTotalGB | Should -BeGreaterThan 0
        $health.MemoryUsedGB | Should -BeGreaterOrEqual 0
        $health.MemoryUsedPercent | Should -BeGreaterOrEqual 0
        $health.MemoryUsedPercent | Should -BeLessOrEqual 100
        $health.DiskTotalGB | Should -BeGreaterThan 0
        $health.DiskUsedPercent | Should -BeGreaterOrEqual 0
        $health.DiskUsedPercent | Should -BeLessOrEqual 100
        $health.UptimeDays | Should -BeGreaterOrEqual 0
        $health.CPUName | Should -Not -BeNullOrEmpty
        $health.CPUCores | Should -BeGreaterThan 0
    }
}

Describe "mo optimize steps" {
    BeforeEach {
        $script:OptimizationsApplied = 0
        $script:IssuesFound = 0
        $script:IssuesFixed = 0
        $script:SavedLocalAppData = $env:LOCALAPPDATA
        $script:SavedProgramData = $env:ProgramData
        $env:LOCALAPPDATA = Join-Path $TestDrive "LocalAppData"
        $env:ProgramData = Join-Path $TestDrive "ProgramData"

        Mock Test-IsAdmin { $true }
        Mock Clear-MoleScreen { }
        Mock Read-Host { "n" }
        Mock Get-CimInstance { @() }
        Mock Get-SystemHealth { @{ MemoryUsedGB = 1; MemoryTotalGB = 2; DiskUsedGB = 1; DiskTotalGB = 2; UptimeDays = 1 } }
        Mock Get-StartupPrograms { }
        Mock Test-WindowsUpdate { }
        Mock Get-PhysicalDisk { [pscustomobject]@{ FriendlyName = "Test SSD"; HealthStatus = "Healthy" } }
        Mock Get-Volume { [pscustomobject]@{ DriveLetter = "C" } }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 0 } }
        Mock Get-Disk { [pscustomobject]@{ HealthStatus = "Healthy" } }
        Mock Optimize-Volume { }
        Mock Clear-DnsClientCache { }
        Mock Repair-WindowsImage { [pscustomobject]@{ ImageHealthState = "Healthy" } }
        Mock netsh { $global:LASTEXITCODE = 0 }
        Mock Start-Sleep { }
        Mock Get-Service { throw "Get-Service must not run" }
        Mock Stop-Service { }
        Mock Start-Service { }
        Mock Start-Process { }
        Mock Stop-Process { }
        Mock Remove-Item { }
        Mock Write-MoleOperation { }
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocalAppData
        $env:ProgramData = $script:SavedProgramData
    }

    It 'Keeps disk optimization off battery and unknown power: <State>' -TestCases @(
        @{State='battery'}, @{State='unknown'}, @{State='partial'}
    ) {
        param($State)
        $DryRun = $false; $ShowHelp = $false; $DebugMode = $false
        Mock Get-CimInstance { [pscustomobject]@{DeviceID='pack'} } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        if ($State -eq 'battery') {
            Mock Get-CimInstance { [pscustomobject]@{Active=$true;PowerOnline=$false;Discharging=$true} } -ParameterFilter { $ClassName -eq 'BatteryStatus' }
        }
        elseif ($State -eq 'unknown') {
            Mock Get-CimInstance { throw 'power source unreadable' } -ParameterFilter { $ClassName -eq 'BatteryStatus' }
        }
        Main 6>$null
        Should -Invoke Optimize-Volume -Times 0 -Exactly
    }

    It 'Allows a laptop only with complete online non-discharging power evidence' {
        $DryRun = $false; $ShowHelp = $false; $DebugMode = $false
        Mock Get-CimInstance { [pscustomobject]@{DeviceID='pack'} } -ParameterFilter { $ClassName -eq 'Win32_Battery' }
        Mock Get-CimInstance { [pscustomobject]@{Active=$true;PowerOnline=$true;Discharging=$false} } -ParameterFilter { $ClassName -eq 'BatteryStatus' }
        Main 6>$null
        Should -Invoke Optimize-Volume -Times 1 -Exactly
    }

    It 'Checks target disk health before optimization and keeps a failing target untouched' {
        $DryRun = $false; $ShowHelp = $false; $DebugMode = $false
        Mock Get-PhysicalDisk { [pscustomobject]@{ DeviceId=0; FriendlyName='System SSD'; HealthStatus='Warning' } }
        Mock Get-Disk { [pscustomobject]@{ HealthStatus='Warning' } }
        Main 6>$null
        Should -Invoke Optimize-Volume -Times 0 -Exactly
        Should -Invoke Get-PhysicalDisk -Times 1 -Exactly
    }

    It 'An unrelated unhealthy disk does not block the healthy system disk' {
        $DryRun = $false; $ShowHelp = $false; $DebugMode = $false
        Mock Get-PhysicalDisk { @(
            [pscustomobject]@{ DeviceId=0; FriendlyName='System SSD'; HealthStatus='Healthy' },
            [pscustomobject]@{ DeviceId=1; FriendlyName='External'; HealthStatus='Unhealthy' }
        ) }
        Main 6>$null
        Should -Invoke Optimize-Volume -Times 1 -Exactly
    }

    It 'Still checks the target disk when physical inventory fails: <Health>' -TestCases @(
        @{Health='Unhealthy';Writes=0},@{Health='Warning';Writes=0},@{Health='Healthy';Writes=1},@{Health='Unknown';Writes=1}
    ) {
        param($Health,$Writes)
        $DryRun=$false; $ShowHelp=$false; $DebugMode=$false
        Mock Get-PhysicalDisk { throw 'storage inventory unavailable' }
        Mock Get-Partition { [pscustomobject]@{DriveLetter='C';DiskNumber=0} }
        $script:TargetHealthFixture = $Health
        Mock Get-Disk { [pscustomobject]@{FriendlyName='Target disk';HealthStatus=$script:TargetHealthFixture} }
        Main 6>$null
        Should -Invoke Get-Disk -Times 1 -Exactly
        Should -Invoke Optimize-Volume -Times $Writes -Exactly
    }

    It 'Retrims only other fixed drives on a known healthy SSD and never defragments them' {
        $DryRun = $false; $ShowHelp = $false; $DebugMode = $false
        Mock Get-PhysicalDisk { @(
            [pscustomobject]@{ DeviceId='0'; FriendlyName='System SSD'; MediaType='SSD'; HealthStatus='Healthy' },
            [pscustomobject]@{ DeviceId='1'; FriendlyName='Data SSD'; MediaType='SSD'; HealthStatus='Healthy' },
            [pscustomobject]@{ DeviceId='2'; FriendlyName='Data HDD'; MediaType='HDD'; HealthStatus='Healthy' },
            [pscustomobject]@{ DeviceId='3'; FriendlyName='Old SSD'; MediaType='SSD'; HealthStatus='Warning' },
            [pscustomobject]@{ DeviceId='4'; FriendlyName='USB'; MediaType='Unspecified'; HealthStatus='Healthy' }
        ) }
        Mock Get-Volume { @(
            [pscustomobject]@{ DriveLetter='C'; DriveType='Fixed'; FileSystemType='NTFS' },
            [pscustomobject]@{ DriveLetter='D'; DriveType='Fixed'; FileSystemType='NTFS'; HealthStatus='Healthy' },
            [pscustomobject]@{ DriveLetter='E'; DriveType='Fixed'; FileSystemType='NTFS'; HealthStatus='Healthy' },
            [pscustomobject]@{ DriveLetter='F'; DriveType='Fixed'; FileSystemType='NTFS'; HealthStatus='Healthy' },
            [pscustomobject]@{ DriveLetter='G'; DriveType='Fixed'; FileSystemType='NTFS'; HealthStatus='Healthy' },
            [pscustomobject]@{ DriveLetter='H'; DriveType='Fixed'; FileSystemType='FAT32'; HealthStatus='Healthy' },
            [pscustomobject]@{ DriveLetter='J'; DriveType='Fixed'; FileSystemType='NTFS'; HealthStatus='Warning' },
            [pscustomobject]@{ DriveLetter='K'; DriveType='Fixed'; FileSystemType='NTFS' },
            [pscustomobject]@{ DriveLetter='I'; DriveType='Removable'; FileSystemType='NTFS' }
        ) } -ParameterFilter { -not $DriveLetter }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = @{C=0;D=1;E=2;F=3;G=4;H=1;I=1;J=1;K=1}[$DriveLetter]; DriveLetter=$DriveLetter } }
        Mock Get-Disk { [pscustomobject]@{ Number=$Number; HealthStatus = $(if ($Number -eq 3) { 'Warning' } else { 'Healthy' }) } } -ParameterFilter { $null -ne $Number }
        Main 6>$null
        Should -Invoke Optimize-Volume -Times 1 -Exactly -ParameterFilter { $DriveLetter -eq 'C' -and -not $ReTrim }
        Should -Invoke Optimize-Volume -Times 1 -Exactly -ParameterFilter { $DriveLetter -eq 'D' -and $ReTrim }
        Should -Invoke Optimize-Volume -Times 2 -Exactly
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'OPTIMIZED' -and $Path -eq 'D:' -and $Detail -eq 'Optimize-Volume -ReTrim' }
    }

    It 'Lists the extra drive it would retrim in a dry run and retrims nothing' {
        $DryRun = $true; $ShowHelp = $false; $DebugMode = $false
        Mock Get-PhysicalDisk { @(
            [pscustomobject]@{ DeviceId='0'; FriendlyName='System SSD'; MediaType='SSD'; HealthStatus='Healthy' },
            [pscustomobject]@{ DeviceId='1'; FriendlyName='Data SSD'; MediaType='SSD'; HealthStatus='Healthy' }
        ) }
        Mock Get-Volume { @(
            [pscustomobject]@{ DriveLetter='C'; DriveType='Fixed'; FileSystemType='NTFS'; HealthStatus='Healthy' },
            [pscustomobject]@{ DriveLetter='D'; DriveType='Fixed'; FileSystemType='NTFS'; HealthStatus='Healthy' }
        ) } -ParameterFilter { -not $DriveLetter }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = @{C=0;D=1}[$DriveLetter] } }
        Mock Get-Disk { [pscustomobject]@{ Number=$Number; HealthStatus='Healthy' } } -ParameterFilter { $null -ne $Number }
        $output = Main 6>&1 | Out-String
        $output | Should -Match 'Would retrim D:'
        Should -Invoke Optimize-Volume -Times 0 -Exactly
    }

    It 'Skips only a volume whose partition cannot be read and still retrims the others' {
        $DryRun = $false; $ShowHelp = $false; $DebugMode = $false
        Mock Get-PhysicalDisk { @(
            [pscustomobject]@{ DeviceId='0'; FriendlyName='System SSD'; MediaType='SSD'; HealthStatus='Healthy' },
            [pscustomobject]@{ DeviceId='1'; FriendlyName='Data SSD'; MediaType='SSD'; HealthStatus='Healthy' }
        ) }
        Mock Get-Volume { @(
            [pscustomobject]@{ DriveLetter='C'; DriveType='Fixed'; FileSystemType='NTFS'; HealthStatus='Healthy' },
            [pscustomobject]@{ DriveLetter='L'; DriveType='Fixed'; FileSystemType='NTFS'; HealthStatus='Healthy' },
            [pscustomobject]@{ DriveLetter='D'; DriveType='Fixed'; FileSystemType='NTFS'; HealthStatus='Healthy' }
        ) } -ParameterFilter { -not $DriveLetter }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = @{C=0;D=1}[$DriveLetter] } }
        Mock Get-Partition { throw 'no partition for this volume' } -ParameterFilter { "$DriveLetter" -eq 'L' }
        Mock Get-Disk { [pscustomobject]@{ Number=$Number; HealthStatus='Healthy' } } -ParameterFilter { $null -ne $Number }
        Main 6>$null
        Should -Invoke Optimize-Volume -Times 1 -Exactly -ParameterFilter { $DriveLetter -eq 'D' -and $ReTrim }
        Should -Invoke Optimize-Volume -Times 0 -Exactly -ParameterFilter { $DriveLetter -eq 'L' }
    }

    It 'Adds no extra drive when the volume inventory fails' {
        $DryRun = $false; $ShowHelp = $false; $DebugMode = $false
        Mock Get-Volume { throw 'storage provider unavailable' } -ParameterFilter { -not $DriveLetter }
        Main 6>$null
        Should -Invoke Optimize-Volume -Times 1 -Exactly
        Should -Invoke Optimize-Volume -Times 0 -Exactly -ParameterFilter { $ReTrim }
    }

    It 'Reports a failed extra retrim as failed' {
        $DryRun = $false; $ShowHelp = $false; $DebugMode = $false
        Mock Get-PhysicalDisk { @(
            [pscustomobject]@{ DeviceId='0'; FriendlyName='System SSD'; MediaType='SSD'; HealthStatus='Healthy' },
            [pscustomobject]@{ DeviceId='1'; FriendlyName='Data SSD'; MediaType='SSD'; HealthStatus='Healthy' }
        ) }
        Mock Get-Volume { @(
            [pscustomobject]@{ DriveLetter='C'; DriveType='Fixed'; FileSystemType='NTFS' },
            [pscustomobject]@{ DriveLetter='D'; DriveType='Fixed'; FileSystemType='ReFS'; HealthStatus='Healthy' }
        ) } -ParameterFilter { -not $DriveLetter }
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = @{C=0;D=1}[$DriveLetter] } }
        Mock Get-Disk { [pscustomobject]@{ Number=$Number; HealthStatus='Healthy' } } -ParameterFilter { $null -ne $Number }
        Mock Optimize-Volume { throw 'retrim refused' } -ParameterFilter { $ReTrim }
        $output = Main 6>&1 | Out-String
        $output | Should -Match 'Retrim of drive D: failed'
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'FAILED' -and $Path -eq 'D:' }
    }

    It 'Unknown disk health does not invent a critical failure' {
        Mock Get-PhysicalDisk { [pscustomobject]@{ DeviceId=0; FriendlyName='RAID'; HealthStatus='Unknown' } }
        $output = Test-DiskHealth 6>&1 | Out-String
        $output | Should -Match 'health unknown'
        $output | Should -Not -Match 'critical|back up'
        $script:IssuesFound | Should -Be 0
    }

    It "Never resets Winsock or rebuilds search, icon, font or Store caches when elevated" {
        $DryRun = $false
        $ShowHelp = $false
        $DebugMode = $false

        $output = Main 6>&1 | Out-String

        Should -Invoke netsh -ParameterFilter { $args -contains "winsock" } -Times 0 -Exactly
        Should -Invoke Get-Service -Times 0 -Exactly
        Should -Invoke Stop-Service -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Stop-Process -Times 0 -Exactly
        Should -Invoke Remove-Item -Times 0 -Exactly
        $output | Should -Not -Match "Winsock|Font Cache|Icon Cache|Search Index|Store Cache|wsreset"

        # The bounded steps that remain still run.
        Should -Invoke Clear-DnsClientCache -Times 1 -Exactly
        Should -Invoke Optimize-Volume -Times 1 -Exactly
        Should -Invoke netsh -ParameterFilter { $args -contains "arpcache" } -Times 1 -Exactly
        $output | Should -Match "Optimizations applied: \S*3"

        # Each state change leaves one operations.log row.
        Should -Invoke Write-MoleOperation -Times 3 -Exactly
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq "OPTIMIZED" -and $Path -eq "C:" -and $Detail -eq "Optimize-Volume" }
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq "OPTIMIZED" -and $Path -eq "DNS client cache" }
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq "OPTIMIZED" -and $Path -eq "ARP cache" }
    }

    It "Counts only the steps it lists in an elevated dry run" {
        $DryRun = $true
        $ShowHelp = $false
        $DebugMode = $false

        $output = Main 6>&1 | Out-String

        Should -Invoke netsh -Times 0 -Exactly
        Should -Invoke Clear-DnsClientCache -Times 0 -Exactly
        Should -Invoke Optimize-Volume -Times 0 -Exactly
        $output | Should -Match "Would optimize"
        $output | Should -Match "Would flush DNS cache"
        $output | Should -Match "Would clear ARP cache"
        $output | Should -Match "Would apply \S*3\S* optimizations"
        Should -Invoke Write-MoleOperation -Times 0 -Exactly
        $output | Should -Not -Match "Winsock|TCP/IP|Font Cache|Icon Cache|Search Index|Store Cache|wsreset"
    }

    It "Uses the singular noun when a non-admin dry run has one step" {
        Mock Test-IsAdmin { $false }
        $DryRun = $true
        $ShowHelp = $false
        $DebugMode = $false

        $output = Main 6>&1 | Out-String

        $output | Should -Match "Would apply \S*1\S* optimization\b"
        $output | Should -Not -Match "Would apply \S*1\S* optimizations"
    }

    It "No longer defines the removed repair functions" {
        foreach ($name in @("Repair-FontCache", "Repair-IconCache", "Repair-SearchIndex", "Repair-StoreCache")) {
            $script:OptimizeFunctionNames | Should -Not -Contain $name
        }
    }
}

Describe 'Startup registration counts are not failures' {
    It 'Does not infer a problem from <Count> registrations' -TestCases @(@{Count=6},@{Count=11}) {
        param($Count)
        $script:IssuesFound = 0
        $script:StartupFixture = [pscustomobject]@{}
        foreach ($index in 1..$Count) { $script:StartupFixture | Add-Member -NotePropertyName "app$index" -NotePropertyValue 'app.exe' }
        Mock Test-Path { $false }
        Mock Test-Path { $true } -ParameterFilter { $Path -eq 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' }
        Mock Get-ItemProperty { $script:StartupFixture }
        $output = Get-StartupPrograms 6>&1 | Out-String
        $output | Should -Match "$Count startup programs"
        $output | Should -Not -Match 'high|moderate|Consider disabling'
        $script:IssuesFound | Should -Be 0
    }
}

Describe "Native optimization outcomes" {
    BeforeEach {
        $script:OptimizationsApplied = 0
        $script:DryRun = $false
        Mock Test-IsAdmin { $true }
        Mock Write-MoleOperation { }
    }
    It "Does not count a failing native ARP operation as applied" {
        Mock netsh { $global:LASTEXITCODE = 5 }
        $output = Optimize-Network 6>&1 | Out-String
        $script:OptimizationsApplied | Should -Be 0
        $output | Should -Not -Match 'ARP cache cleared'
        $output | Should -Match 'ARP cache clear failed'
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'FAILED' -and $Path -eq 'ARP cache' -and $Detail -like '*code 5' }
    }
    It "Counts a successful native ARP operation" {
        Mock netsh { $global:LASTEXITCODE = 0 }
        Optimize-Network 6>$null
        $script:OptimizationsApplied | Should -Be 1
    }
}

Describe "System image and file checks" {
    BeforeEach {
        $script:IssuesFound = 0
        $script:IssuesFixed = 0
        $script:DryRun = $false
        Mock Test-IsAdmin { $true }
        Mock Write-MoleOperation { }
    }

    It "Reads the image verdict as '<State>' and only suggests the repair" -ForEach @(
        @{ State = "Healthy"; Line = "System image is healthy"; Issues = 0 }
        @{ State = "Repairable"; Line = "System image can be repaired"; Issues = 1 }
        @{ State = "NonRepairable"; Line = "cannot be repaired by Windows"; Issues = 1 }
    ) {
        Mock Repair-WindowsImage { [pscustomobject]@{ ImageHealthState = $State } }

        $output = Test-SystemImage 6>&1 | Out-String

        $output | Should -Match $Line
        $script:IssuesFound | Should -Be $Issues
        Should -Invoke Repair-WindowsImage -ParameterFilter { $CheckHealth -and -not $RestoreHealth } -Times 1 -Exactly
        Should -Invoke Repair-WindowsImage -ParameterFilter { $RestoreHealth } -Times 0 -Exactly
        if ($State -eq "Repairable") { $output | Should -Match "(?s)RestoreHealth.*30 minutes" }
    }

    It "Says it could not check when DISM fails, without counting an issue" {
        Mock Repair-WindowsImage { throw "DISM unavailable" }
        $output = Test-SystemImage 6>&1 | Out-String
        $output | Should -Match "Could not check the system image"
        $script:IssuesFound | Should -Be 0
    }

    It "Does not call DISM without administrator rights or in a dry run" {
        Mock Repair-WindowsImage { [pscustomobject]@{ ImageHealthState = "Healthy" } }
        Mock Test-IsAdmin { $false }
        Test-SystemImage 6>$null
        Mock Test-IsAdmin { $true }
        $script:DryRun = $true
        Test-SystemImage 6>$null
        Should -Invoke Repair-WindowsImage -Times 0 -Exactly
    }

    It "Decodes sfc output, which is UTF-16 without a byte order mark" {
        $path = Join-Path $TestDrive "sfc.txt"
        $text = "Windows Resource Protection did not find any integrity violations."
        [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::Unicode.GetBytes($text))
        Read-SfcOutput $path | Should -Be $text
        Read-SfcOutput (Join-Path $TestDrive "missing.txt") | Should -Be ""
    }

    It "Reports '<Expect>' for sfc output '<Text>'" -ForEach @(
        @{ Text = "Windows Resource Protection did not find any integrity violations."; Expect = "No integrity violations found"; Action = "OPTIMIZED" }
        @{ Text = "Windows Resource Protection found corrupt files and successfully repaired them."; Expect = "Corrupt files were repaired"; Action = "OPTIMIZED" }
        @{ Text = "Der Windows-Ressourcenschutz hat keine Integritaetsverletzungen gefunden."; Expect = "Scan finished; details are in"; Action = "FAILED" }
    ) {
        $savedTemp = $env:TEMP
        try {
            $env:TEMP = $TestDrive
            $script:SfcFixtureText = $Text
            Mock Start-Process {
                [System.IO.File]::WriteAllBytes($RedirectStandardOutput, [System.Text.Encoding]::Unicode.GetBytes($script:SfcFixtureText))
                [pscustomobject]@{ ExitCode = 0 }
            }
            Mock Remove-Item { [IO.File]::Delete($LiteralPath) }
            Mock Get-CbsLogLength { $null }
            $script:ExpectedSfcAction = $Action
            $output = Test-SystemFiles 6>&1 | Out-String
            $output | Should -Match ([regex]::Escape($Expect))
            $output | Should -Not -Match "Scan completed"
            Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq $script:ExpectedSfcAction -and $Path -eq "System files" -and $Detail -like "sfc /scannow exit code 0: *" }
        }
        finally { $env:TEMP = $savedTemp }
    }
}

Describe 'SFC verdict from CBS.log (#1915)' {
    BeforeAll {
        $script:CbsHeader = "2026-11-04 13:40:01, Info                  CBS    Starting TrustedInstaller initialization."
        $script:CbsClean = @(
            "2026-11-04 13:44:05, Info                  CSI    00000008 [SR] Verifying 100 components"
            "2026-11-04 13:44:05, Info                  CSI    00000009 [SR] Beginning Verify and Repair transaction"
            "2026-11-04 13:44:09, Info                  CSI    0000000b [SR] Verify complete"
            "2026-11-04 13:44:09, Info                  CSI    0000000c [SR] Repairing 0 components"
            "2026-11-04 13:44:09, Info                  CSI    0000000d [SR] Beginning Verify and Repair transaction"
            "2026-11-04 13:44:09, Info                  CSI    0000000f [SR] Repair complete"
        )
    }

    It 'Reads <Expect> from [SR] lines' -ForEach @(
        @{ Name = 'clean'; Extra = @(); Expect = 'no integrity violations' }
        @{ Name = 'repaired'; Extra = @('2026-11-04 13:45:01, Info  CSI  00000020 [SR] Repairing 1 components', '2026-11-04 13:45:02, Info  CSI  00000021 [SR] Repairing corrupted file \??\C:\Windows\System32\x.dll', '2026-11-04 13:45:03, Info  CSI  00000022 [SR] Repair complete'); Expect = 'repaired corrupt files' }
        @{ Name = 'unrepairable'; Extra = @('2026-11-04 13:45:01, Info  CSI  00000020 [SR] Repairing 1 components', '2026-11-04 13:45:02, Info  CSI  00000021 [SR] Cannot repair member file [l:10]"x.dll" of Example', '2026-11-04 13:45:03, Info  CSI  00000022 [SR] Repair complete'); Expect = 'found corrupt files it could not repair' }
    ) {
        ConvertTo-SfcCbsVerdict (@($script:CbsClean) + @($Extra)) | Should -Be $Expect
    }

    It 'Proves nothing without a finished repair pass' {
        ConvertTo-SfcCbsVerdict @() | Should -BeNullOrEmpty
        ConvertTo-SfcCbsVerdict @($script:CbsClean[0..3]) | Should -BeNullOrEmpty
        ConvertTo-SfcCbsVerdict @("2026-11-04 13:44:09, Info  CSI  0000000f [SR] Repair complete") | Should -BeNullOrEmpty
    }

    It 'Reads only the lines written after the scan started' {
        $path = Join-Path $TestDrive 'CBS.log'
        $old = @($script:CbsHeader, "2026-11-01 09:00:00, Info  CSI  00000002 [SR] Cannot repair member file [l:10]`"old.dll`"") -join "`r`n"
        [IO.File]::WriteAllText($path, "$old`r`n")
        $start = Get-CbsLogLength -Path $path
        [IO.File]::AppendAllText($path, (($script:CbsClean) -join "`r`n") + "`r`n")
        Read-SfcCbsVerdict -StartLength $start -Path $path | Should -Be 'no integrity violations'
        Read-SfcCbsVerdict -StartLength 0 -Path $path | Should -Be 'found corrupt files it could not repair'
    }

    It 'Returns nothing when the log rotated, is missing or the start is unknown' {
        $path = Join-Path $TestDrive 'CBS-rotated.log'
        [IO.File]::WriteAllText($path, (($script:CbsClean) -join "`r`n"))
        Read-SfcCbsVerdict -StartLength 1000000 -Path $path | Should -BeNullOrEmpty
        Read-SfcCbsVerdict -StartLength 0 -Path (Join-Path $TestDrive 'missing.log') | Should -BeNullOrEmpty
        Read-SfcCbsVerdict -StartLength $null -Path $path | Should -BeNullOrEmpty
        Get-CbsLogLength -Path (Join-Path $TestDrive 'missing.log') | Should -BeNullOrEmpty
    }

    It 'Records a localized clean scan as optimized from CBS.log' {
        $script:DryRun = $false
        $script:IssuesFound = 0
        $script:IssuesFixed = 0
        Mock Test-IsAdmin { $true }
        Mock Write-MoleOperation {}
        Mock Get-CbsLogLength { 42 }
        Mock Read-SfcCbsVerdict { 'no integrity violations' }
        Mock Start-Process {
            [IO.File]::WriteAllBytes($RedirectStandardOutput, [Text.Encoding]::Unicode.GetBytes('Windows Resource Protection localized text without the English phrase'))
            [pscustomobject]@{ ExitCode = 0 }
        }
        $output = Test-SystemFiles 6>&1 | Out-String
        $output | Should -Match 'No integrity violations found'
        Should -Invoke Read-SfcCbsVerdict -Times 1 -Exactly -ParameterFilter { $StartLength -eq 42 }
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'OPTIMIZED' -and $Detail -eq 'sfc /scannow exit code 0: no integrity violations' }
    }

    It 'Does not consult CBS.log when SFC exits nonzero or stdout is already read' -ForEach @(
        @{ Text = 'localized'; Exit = 5 }
        @{ Text = 'Windows Resource Protection did not find any integrity violations.'; Exit = 0 }
    ) {
        $script:DryRun = $false
        Mock Test-IsAdmin { $true }
        Mock Write-MoleOperation {}
        Mock Get-CbsLogLength { 42 }
        Mock Read-SfcCbsVerdict { 'no integrity violations' }
        $script:SfcFixtureText = $Text
        $script:SfcFixtureExit = $Exit
        Mock Start-Process {
            [IO.File]::WriteAllBytes($RedirectStandardOutput, [Text.Encoding]::Unicode.GetBytes($script:SfcFixtureText))
            [pscustomobject]@{ ExitCode = $script:SfcFixtureExit }
        }
        Test-SystemFiles 6>$null
        Should -Invoke Read-SfcCbsVerdict -Times 0 -Exactly
    }
}

Describe 'Review regressions: health summary' {
    It 'Does not turn an unknown DISM result into a healthy summary' -ForEach @('failure', 'unknown') {
        $script:IssuesFound = 0
        $script:IssuesFixed = 0
        $script:OptimizationsApplied = 0
        $script:DryRun = $false
        Mock Test-IsAdmin { $true }
        if ($_ -eq 'failure') { Mock Repair-WindowsImage { throw 'unavailable' } }
        else { Mock Repair-WindowsImage { [pscustomobject]@{ ImageHealthState = 'Unknown' } } }
        Mock Show-SummaryBlock { Write-Output ($Details -join "`n") }
        Test-SystemImage 6>$null
        $script:IssuesFound | Should -Be 0
        Show-OptimizeSummary | Should -Not -Match 'System health: Good'
    }
}

Describe 'SFC scratch ownership and outcome' {
    BeforeEach {
        $script:DryRun = $false
        $script:IssuesFound = 0
        $script:IssuesFixed = 0
        $script:SfcScratch = $null
        Mock Test-IsAdmin { $true }
        Mock Write-MoleOperation {}
    }
    It 'Preserves an existing fixed-name file and removes its own scratch after <Mode>' -ForEach @(
        @{ Mode = 'success' }, @{ Mode = 'start failure' }, @{ Mode = 'read failure' }
    ) {
        $savedTemp = $env:TEMP
        $script:SfcMode = $Mode
        try {
            $env:TEMP = $TestDrive
            $existing = Join-Path $TestDrive 'sfc_output.txt'
            Set-Content -LiteralPath $existing -Value 'unrelated'
            Mock Start-Process {
                $script:SfcScratch = $RedirectStandardOutput
                Test-Path -LiteralPath $RedirectStandardOutput | Should -BeTrue
                if ($script:SfcMode -eq 'start failure') { throw 'fixture startup failure' }
                [IO.File]::WriteAllBytes($RedirectStandardOutput, [Text.Encoding]::Unicode.GetBytes('did not find any integrity violations'))
                [pscustomobject]@{ ExitCode = 0 }
            }
            if ($Mode -eq 'read failure') { Mock Read-SfcOutput { throw 'fixture read failure' } }
            Test-SystemFiles 6>$null
            Get-Content -LiteralPath $existing | Should -Be 'unrelated'
            $script:SfcScratch | Should -Not -BeNullOrEmpty
            $script:SfcScratch | Should -Not -Be $existing
            Test-Path -LiteralPath $script:SfcScratch | Should -BeFalse
        }
        finally { $env:TEMP = $savedTemp }
    }
    It 'Does not claim a successful repair from stdout when SFC exits nonzero' {
        Mock Start-Process {
            [IO.File]::WriteAllBytes($RedirectStandardOutput, [Text.Encoding]::Unicode.GetBytes('found corrupt files and successfully repaired'))
            [pscustomobject]@{ ExitCode = 5 }
        }
        $output = Test-SystemFiles 6>&1 | Out-String
        $output | Should -Match 'did not complete \(exit code 5\)'
        $output | Should -Not -Match 'Corrupt files were repaired'
        $script:IssuesFixed | Should -Be 0
        Should -Invoke Write-MoleOperation -Exactly -Times 1 -ParameterFilter { $Action -eq 'FAILED' -and $Detail -like '*exit code 5:*' }
    }
}

Describe 'Bounded local Windows Update inspection' {
    BeforeAll {
        # Job cmdlets coerce their typed Job[] argument before Pester's mock runs.
        # Untyped seams keep these tests on disposable data, with no worker launch.
        function Wait-Job { param($Job, $Timeout) throw 'Wait-Job must be mocked' }
        function Receive-Job { param($Job, $ErrorAction) throw 'Receive-Job must be mocked' }
        function Stop-Job { param($Job, $ErrorAction) throw 'Stop-Job must be mocked' }
        function Remove-Job { param($Job, [switch]$Force, $ErrorAction) throw 'Remove-Job must be mocked' }
    }
    BeforeEach {
        $script:IssuesFound = 0
        $script:UpdateJob = [pscustomobject]@{ State = 'Completed' }
        $script:UpdateResult = [pscustomobject]@{ Total = 0; Important = 0 }
        Mock Start-Spinner {}
        Mock Stop-Spinner {}
        Mock Start-Job { $script:UpdateJob }
        Mock Wait-Job { $script:UpdateJob }
        Mock Receive-Job { $script:UpdateResult }
        Mock Stop-Job {}
        Mock Remove-Job {}
        # An unbounded in-process COM query must fail rather than contact Windows Update.
        Mock New-Object { throw 'COM must run in the isolated job' } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }
    }
    It 'Keeps a timed-out query unknown and reclaims its worker' {
        $script:UpdateJob.State = 'Running'
        Mock Wait-Job { $null }
        $output = Test-WindowsUpdate 6>&1 | Out-String
        $output | Should -Match 'Could not check Windows Update status'
        $output | Should -Not -Match 'up to date|No pending updates'
        $script:IssuesFound | Should -Be 0
        Should -Invoke Wait-Job -Exactly -Times 1 -ParameterFilter { $Timeout -eq 5 }
        Should -Invoke Receive-Job -Exactly -Times 0
        Should -Invoke Stop-Job -Exactly -Times 1
        Should -Invoke Remove-Job -Exactly -Times 1
        Should -Invoke Stop-Spinner -Exactly -Times 1
    }
    It 'Reports <Expected> only after a complete result' -ForEach @(
        @{ Total = 0; Important = 0; Expected = 'No pending updates in the local catalog'; Issues = 0 },
        @{ Total = 1; Important = 0; Expected = '1 optional update available'; Issues = 0 },
        @{ Total = 2; Important = 1; Expected = '1 important update available'; Issues = 1 },
        @{ Total = 3; Important = 2; Expected = '2 important updates available'; Issues = 1 }
    ) {
        $script:UpdateResult = [pscustomobject]@{ Total = $Total; Important = $Important }
        $output = Test-WindowsUpdate 6>&1 | Out-String
        $output | Should -Match $Expected
        $script:IssuesFound | Should -Be $Issues
        Should -Invoke Receive-Job -Exactly -Times 1
        Should -Invoke Remove-Job -Exactly -Times 1
    }
    It 'Does not turn a failed or empty job into an up-to-date verdict' -ForEach @('Failed', 'Empty') {
        if ($_ -eq 'Failed') { $script:UpdateJob.State = 'Failed' }
        else { Mock Receive-Job { } }
        $output = Test-WindowsUpdate 6>&1 | Out-String
        $output | Should -Match 'Could not check Windows Update status'
        $script:IssuesFound | Should -Be 0
        Should -Invoke Remove-Job -Exactly -Times 1
    }
    It 'Queries the local catalog and counts a single important result' {
        $script:UpdateSearcher = [pscustomobject]@{ Online = $true; Criteria = $null }
        $script:UpdateSearcher | Add-Member ScriptMethod Search {
            param($criteria)
            $this.Criteria = $criteria
            [pscustomobject]@{ Updates = @([pscustomobject]@{ MsrcSeverity = 'Important' }) }
        }
        $script:UpdateSession = [pscustomobject]@{}
        $script:UpdateSession | Add-Member ScriptMethod CreateUpdateSearcher { $script:UpdateSearcher }
        Mock New-Object { $script:UpdateSession } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }
        Mock Start-Job {
            $script:UpdateResult = & $ScriptBlock
            $script:UpdateJob
        }
        $output = Test-WindowsUpdate 6>&1 | Out-String
        $script:UpdateSearcher.Online | Should -BeFalse
        $script:UpdateSearcher.Criteria | Should -Be 'IsInstalled=0'
        $output | Should -Match '1 important update available'
        $script:IssuesFound | Should -Be 1
    }
    It 'Clears the spinner before writing the result on its line' {
        Mock Stop-Spinner { Write-Host 'SPINNER-STOPPED' }
        $output = Test-WindowsUpdate 6>&1 | Out-String
        $output | Should -Match 'SPINNER-STOPPED[\s\S]*No pending updates'
        Should -Invoke Stop-Spinner -Exactly -Times 1
    }
}
