# Only entrypoint functions run here; all maintenance work is mocked.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    function Import-EntryMain([string]$Name) {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root "bin\$Name.ps1"),[ref]$null,[ref]$null)
        $definition = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Main'},$true)
        Set-Item function:script:Main ([scriptblock]::Create($definition.Body.Extent.Text.TrimStart('{').TrimEnd('}')))
    }
    function Start-Cleanup { param($IsDryRun,$IncludeSystem,$IncludeGameMedia) }
    function Get-SystemHealth { @{} }
    function Start-Spinner { param($Message) }
    function Stop-Spinner {}
    function Show-SystemHealth { param($Health) }
    function Optimize-DiskDrive {}
    function Clear-DnsCache {}
    function Optimize-Network {}
    function Get-StartupPrograms {}
    function Test-DiskHealth {}
    function Test-WindowsUpdate {}
    function Test-SystemImage {}
    function Test-IsAdmin { $false }
    function Show-OptimizeSummary {}
}
Describe 'Environment dry-run at command entrypoints' {
    BeforeEach {
        $script:SavedDryRun=$env:MOLE_DRY_RUN
        $DebugMode=$false; $ShowHelp=$false; $Whitelist=$false; $System=$false; $GameMedia=$false
        $script:Icons=@{DryRun='preview'}
        Mock Clear-Host {}
    }
    AfterEach { $env:MOLE_DRY_RUN=$script:SavedDryRun }
    It 'Keeps environment-only clean in preview mode' {
        Import-EntryMain clean
        $DryRun=$false; $env:MOLE_DRY_RUN='1'
        Mock Start-Cleanup {}
        Main
        Should -Invoke Start-Cleanup -Times 1 -Exactly -ParameterFilter { $IsDryRun }
        $env:MOLE_DRY_RUN | Should -Be '1'
    }
    It 'Keeps explicit clean preview when the environment says zero' {
        Import-EntryMain clean
        $DryRun=$true; $env:MOLE_DRY_RUN='0'
        Mock Start-Cleanup {}
        Main
        Should -Invoke Start-Cleanup -Times 1 -Exactly -ParameterFilter { $IsDryRun }
    }
    It 'Keeps ordinary clean outside preview' {
        Import-EntryMain clean
        $DryRun=$false; $env:MOLE_DRY_RUN=$null
        Mock Start-Cleanup {}
        Main
        Should -Invoke Start-Cleanup -Times 1 -Exactly -ParameterFilter { -not $IsDryRun }
    }
    It 'Keeps environment-only optimize in preview mode' {
        Import-EntryMain optimize
        $DryRun=$false; $env:MOLE_DRY_RUN='1'
        Mock Optimize-DiskDrive { $script:ObservedDryRun=$script:DryRun }
        Main 6>$null
        $script:ObservedDryRun | Should -BeTrue
    }
}
