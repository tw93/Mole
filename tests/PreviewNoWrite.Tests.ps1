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
    # The SID, not DOMAIN\name: over SSH USERDOMAIN reads WORKGROUP, icacls cannot map that name, and the
    # deny was never applied (ThinkPad, 2026-11-10). A deny that did not take fails the test instead.
    $script:UserSid = '*' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    function Invoke-NoWriteMole([string[]]$Arguments, [string]$State) {
        $profileRoot = Join-Path ([IO.Path]::GetTempPath()) ("mole-nowrite-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $profileRoot | Out-Null
        $denied = @($profileRoot)
        if ($State -eq 'existing') {
            $denied += New-Item -ItemType Directory -Path (Join-Path $profileRoot '.config\mole'), (Join-Path $profileRoot '.cache\mole') | ForEach-Object FullName
        }
        $user = $script:UserSid
        foreach ($path in $denied) {
            icacls $path /deny "${user}:(OI)(CI)(WD,AD)" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "icacls could not deny writes to $path" }
        }
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

Describe 'Real clean without write access' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'bin\clean.ps1'), [ref]$null, [ref]$null)
        foreach ($name in 'Get-CleanWriteRefusal', 'Test-CleanWriteRefused', 'Test-CleanCanWrite') {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        function New-DeniedFolder {
            $folder = Join-Path ([IO.Path]::GetTempPath()) ("mole-refuse-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $folder | Out-Null
            icacls $folder /deny "$($script:UserSid):(OI)(CI)(WD,AD)" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "icacls could not deny writes to $folder" }
            return $folder
        }
        function Remove-DeniedFolder([string]$Folder) {
            icacls $Folder /remove:d $script:UserSid | Out-Null
            Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Refuses when every checked folder refuses a write' {
        $one = New-DeniedFolder
        $two = New-DeniedFolder
        try {
            # An elevated session holding SeRestorePrivilege (the ThinkPad over SSH) writes through the
            # deny, since CreateDirectory asks with backup intent, so there is nothing to refuse there.
            $through = Join-Path $one 'through'
            try { [System.IO.Directory]::CreateDirectory($through) | Out-Null } catch { $through = '' }
            if ($through) {
                [System.IO.Directory]::Delete($through)
                Set-ItResult -Skipped -Because 'this session writes through a deny ACE (restore privilege)'
                return
            }
            Test-CleanCanWrite -Folders @($one, $two) | Should -BeFalse
        }
        finally { Remove-DeniedFolder $one; Remove-DeniedFolder $two }
    }

    It 'Reads a denied write through the exception PowerShell wraps it in' {
        $denied = [System.UnauthorizedAccessException]::new('Access to the path is denied.')
        $wrapped = [System.Management.Automation.MethodInvocationException]::new('Exception calling Delete', $denied)
        Get-CleanWriteRefusal -Exception $wrapped | Should -Be 'Access is denied'
    }

    It 'Carries on when only one checked folder refuses' {
        $denied = New-DeniedFolder
        $open = Join-Path ([IO.Path]::GetTempPath()) ("mole-open-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $open | Out-Null
        try {
            Test-CleanCanWrite -Folders @($denied, $open) | Should -BeTrue
            @(Get-ChildItem -LiteralPath $open -Force).Count | Should -Be 0
        }
        finally { Remove-DeniedFolder $denied; Remove-Item -LiteralPath $open -Recurse -Force }
    }

    It 'Reads a full disk as no refusal' {
        $full = [System.IO.IOException]::new('There is not enough space on the disk.', -2147024784)
        Get-CleanWriteRefusal -Exception $full | Should -Be ''
    }

    It 'Reads a write-protected volume as a refusal' {
        $locked = [System.IO.IOException]::new('The media is write protected.', -2147024877)
        Get-CleanWriteRefusal -Exception $locked | Should -Not -Be ''
    }

    It 'Asks before a real run and never before a dry run' {
        $source = Get-Content (Join-Path $script:Root 'bin\clean.ps1') -Raw
        $source | Should -Match '(?m)^exit 0\s*$'
        $source | Should -Match 'if \(-not \$effectiveDryRun -and -not \(Test-CleanCanWrite -Folders @\(\$env:LOCALAPPDATA, \$env:APPDATA\)\)\) \{\s+exit 1\s+\}\s+Start-Cleanup -IsDryRun'
    }
}
