# Previews and --version must run where Mole cannot write its own state.
# Writes are denied with an ACL on the fixture profile: either the profile root
# (first run, no .config or .cache yet) or the existing Mole directories.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:WindowsDir = $script:Root
    $script:HostExe = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
    . "$script:Root\lib\core\base.ps1"
    . "$script:Root\lib\core\log.ps1"
    . "$script:Root\lib\core\ui.ps1"

    function Invoke-NoWriteMole([string[]]$Arguments, [string]$State) {
        $profileRoot = Join-Path ([IO.Path]::GetTempPath()) ("mole-nowrite-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $profileRoot | Out-Null
        $denied = @($profileRoot)
        if ($State -eq 'existing') {
            $denied += New-Item -ItemType Directory -Path (Join-Path $profileRoot '.config\mole'), (Join-Path $profileRoot '.cache\mole') | ForEach-Object FullName
        }
        $user = "$env:USERDOMAIN\$env:USERNAME"
        foreach ($path in $denied) { icacls $path /deny "${user}:(OI)(CI)(WD,AD)" | Out-Null }
        $savedProfile = $env:USERPROFILE
        try {
            $env:USERPROFILE = $profileRoot
            $output = & $script:HostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Root 'mole.ps1') @Arguments 2>&1 | Out-String
            return @{ ExitCode = $LASTEXITCODE; Output = $output }
        }
        finally {
            $env:USERPROFILE = $savedProfile
            foreach ($path in $denied) { icacls $path /remove:d $user | Out-Null }
            Remove-Item -LiteralPath $profileRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Preview without writable state' {
    BeforeDiscovery {
        $script:Cases = foreach ($state in 'first', 'existing') {
            @{ State = $state; Name = '--version'; Arguments = @('--version'); Expect = 'Mole version' }
            @{ State = $state; Name = 'clean --dry-run'; Arguments = @('clean', '--dry-run'); Expect = 'Dry run complete' }
            @{ State = $state; Name = 'optimize --dry-run'; Arguments = @('optimize', '--dry-run'); Expect = 'Dry run complete' }
            @{ State = $state; Name = 'uninstall --list'; Arguments = @('uninstall', '--list'); Expect = '' }
        }
    }
    It 'Completes mo <Name> on a <State> run' -ForEach $script:Cases {
        $run = Invoke-NoWriteMole -Arguments $Arguments -State $State
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match $Expect
        $run.Output | Should -Not -Match 'denied|error occurred'
        $run.Output | Should -Not -Match 'Detailed file list'
    }
    It 'Names the preview list only when it was written' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'bin\clean.ps1'), [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-CleanupSummary' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        Mock Get-FreeSpace { '10 GB' }
        Mock Show-SummaryBlock { Write-Output ($Details -join "`n") }
        $script:ExportListFile = 'fixture-list.txt'
        $stats = @{ TotalSizeKB = 4; FilesCleaned = 2; TotalItems = 1; OwnerCleanups = 0 }
        $script:ExportListWritten = $true
        (Show-CleanupSummary -Stats $stats -IsDryRun $true | Out-String) | Should -Match 'Detailed file list: fixture-list.txt'
        $script:ExportListWritten = $false
        (Show-CleanupSummary -Stats $stats -IsDryRun $true | Out-String) | Should -Not -Match 'Detailed file list'
    }
}
