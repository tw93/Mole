# Only entrypoint functions run here; all maintenance work is mocked.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    function Import-EntryMain([string]$Name) {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root "bin\$Name.ps1"),[ref]$null,[ref]$null)
        $definition = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Main'},$true)
        Set-Item function:script:Main ([scriptblock]::Create($definition.Body.Extent.Text.TrimStart('{').TrimEnd('}')))
    }
    function Start-Cleanup { param($IsDryRun,$IncludeSystem,$IncludeGameMedia,$IncludeGpuShaders) }
    function Get-SystemHealth { @{} }
    function Start-Spinner { param($Message) }
    function Stop-Spinner {}
    function Clear-MoleScreen {}
    function Show-SystemHealth { param($Health) }
    function Optimize-DiskDrive {}
    function Clear-DnsCache {}
    function Optimize-Network {}
    function Get-StartupPrograms {}
    function Test-DiskHealth { $true }
    function Test-WindowsUpdate {}
    function Test-SystemImage {}
    function Test-IsAdmin { $false }
    function Show-OptimizeSummary {}
}
Describe 'Environment dry-run at command entrypoints' {
    BeforeEach {
        $script:SavedDryRun=$env:MOLE_DRY_RUN
        $DebugMode=$false; $ShowHelp=$false; $Whitelist=$false; $System=$false; $GameMedia=$false; $GpuShaders=$false
        $script:Icons=@{DryRun='preview'}
        Mock Clear-MoleScreen {}
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
        # A real run probes first, and this test must not depend on the runner's folders.
        Set-Item function:script:Test-CleanCanWrite { $true }
        Mock Start-Cleanup {}
        Main
        Should -Invoke Start-Cleanup -Times 1 -Exactly -ParameterFilter { -not $IsDryRun }
    }
    It 'Passes GPU shader caches through only when asked' {
        Import-EntryMain clean
        $DryRun=$true; $env:MOLE_DRY_RUN=$null
        Mock Start-Cleanup {}
        Main
        Should -Invoke Start-Cleanup -Times 1 -Exactly -ParameterFilter { -not $IncludeGpuShaders }
        $GpuShaders=$true
        Main
        Should -Invoke Start-Cleanup -Times 1 -Exactly -ParameterFilter { $IncludeGpuShaders }
    }
    It 'Keeps environment-only optimize in preview mode' {
        Import-EntryMain optimize
        $DryRun=$false; $env:MOLE_DRY_RUN='1'
        Mock Optimize-DiskDrive { $script:ObservedDryRun=$script:DryRun }
        Main 6>$null
        $script:ObservedDryRun | Should -BeTrue
    }
}
Describe 'GPU shader caches wait for --gpu-shaders' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'bin\clean.ps1'),[ref]$null,[ref]$null)
        $flow = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-Cleanup'},$true)
        Set-Item function:script:Invoke-CleanFlow ([scriptblock]::Create($flow.Body.Extent.Text.TrimStart('{').TrimEnd('}')))
        foreach ($name in 'Clear-MoleScreen','Get-WindowsVersion','Get-FreeSpace','Reset-CleanupStats','Set-DryRunMode','Invoke-UserCleanup','Clear-BrowserCaches','Clear-GPUShaderCaches','Clear-AppCaches','Invoke-DevToolsCleanup','Invoke-AppCleanup','Invoke-SystemCleanup','Get-CleanupStats','Show-CleanupSummary','Write-MoleError') {
            Set-Item "function:script:$name" {}
        }
    }
    BeforeEach {
        $script:Icons=@{Solid='-';Admin='-';Success='-'}
        $script:CurrentSection=@{Active=$true}
        Mock Clear-MoleScreen {}
        Mock Get-WindowsVersion { [pscustomobject]@{Name='Windows'} }
        Mock Clear-GPUShaderCaches {}
        Mock Invoke-UserCleanup {}
        Mock Clear-AppCaches {}
    }
    It 'Skips them in an ordinary clean and keeps the other sections' {
        Invoke-CleanFlow -IsDryRun $false -IncludeSystem $false -IncludeGameMedia $false -IncludeGpuShaders $false 6>$null
        Should -Invoke Clear-GPUShaderCaches -Times 0 -Exactly
        Should -Invoke Invoke-UserCleanup -Times 1 -Exactly
        Should -Invoke Clear-AppCaches -Times 1 -Exactly
    }
    It 'Cleans them when asked' {
        Invoke-CleanFlow -IsDryRun $false -IncludeSystem $false -IncludeGameMedia $false -IncludeGpuShaders $true 6>$null
        Should -Invoke Clear-GPUShaderCaches -Times 1 -Exactly
    }
}
