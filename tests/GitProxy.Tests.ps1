# Mole Windows - git system proxy tests
# Git does not read the Windows system proxy, so a machine that reaches GitHub
# only through it fails to clone or pull while PowerShell downloads work.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    function git { }

    function Get-FunctionText {
        param([string]$Path, [string]$Name)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true)
        if (-not $definition) { throw "$Name not found in $Path" }
        return $definition.Extent.Text
    }

    $script:Updater = Join-Path $script:WindowsDir "bin\update.ps1"
    $script:QuickInstall = Join-Path $script:WindowsDir "quick-install.ps1"
    foreach ($name in @("Get-MoleSystemProxy", "Get-GitProxyArguments")) {
        . ([scriptblock]::Create((Get-FunctionText -Path $script:Updater -Name $name)))
    }
}

Describe "Get-GitProxyArguments" {
    BeforeEach {
        $script:MoleGitProxyArguments = $null
        $script:SavedProxyEnv = @{}
        foreach ($name in @("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy")) {
            $script:SavedProxyEnv[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        $global:MoleTestGitConfigProxy = $null
        Mock git {
            if ($args[0] -eq "config" -and $global:MoleTestGitConfigProxy) { return $global:MoleTestGitConfigProxy }
            $global:LASTEXITCODE = 1
        }
        Mock Get-MoleSystemProxy { "http://127.0.0.1:7890" }
    }

    AfterEach {
        foreach ($name in $script:SavedProxyEnv.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:SavedProxyEnv[$name])
        }
    }

    It "Passes the system proxy to git when GitHub goes through it" {
        $result = @(Get-GitProxyArguments)
        $result | Should -Be @("-c", "http.proxy=http://127.0.0.1:7890")
    }

    It "Adds nothing when GitHub is reached directly" {
        Mock Get-MoleSystemProxy { $null }
        @(Get-GitProxyArguments).Count | Should -Be 0
    }

    It "Keeps a proxy the user set through the environment" {
        [Environment]::SetEnvironmentVariable("HTTPS_PROXY", "http://10.0.0.1:3128")
        @(Get-GitProxyArguments).Count | Should -Be 0
        Should -Invoke Get-MoleSystemProxy -Times 0
    }

    It "Keeps a proxy the user configured for git" {
        $global:MoleTestGitConfigProxy = "socks5://127.0.0.1:1080"
        @(Get-GitProxyArguments).Count | Should -Be 0
        Should -Invoke Get-MoleSystemProxy -Times 0
    }

    It "Looks the proxy up once per run" {
        $null = Get-GitProxyArguments
        $null = Get-GitProxyArguments
        Should -Invoke Get-MoleSystemProxy -Times 1 -Exactly
    }
}

Describe "Git proxy helpers stay identical in the installer and the updater" {
    It "Defines <_> the same way in both scripts" -ForEach @("Get-MoleSystemProxy", "Get-GitProxyArguments") {
        Get-FunctionText -Path $script:QuickInstall -Name $_ | Should -BeExactly (Get-FunctionText -Path $script:Updater -Name $_)
    }

    # git writes progress such as "From https://github.com/tw93/Mole" to stderr even
    # on success, and Windows PowerShell 5.1 under a Stop preference throws on the
    # first stderr line of a native command merged with 2>&1. update.ps1 lowered the
    # preference for its git calls; quick-install.ps1 did not, so refreshing an
    # existing source install failed with that line as the error (support mail
    # 2026-11-11). One shared definition keeps the two from drifting again.
    It "Defines Invoke-GitCommand the same way in both scripts" {
        Get-FunctionText -Path $script:QuickInstall -Name "Invoke-GitCommand" | Should -BeExactly (Get-FunctionText -Path $script:Updater -Name "Invoke-GitCommand")
    }

    It "Sends the proxy arguments with every git call in <_>" -ForEach @("bin\update.ps1", "quick-install.ps1") {
        $text = Get-FunctionText -Path (Join-Path $script:WindowsDir $_) -Name "Invoke-GitCommand"
        $text | Should -Match ([regex]::Escape('$gitArguments += @(Get-GitProxyArguments)'))
    }
}

Describe "Invoke-GitCommand under Windows PowerShell 5.1" {
    It "Returns git's exit code instead of throwing on its stderr progress in <_>" -ForEach @("bin\update.ps1", "quick-install.ps1") {
        $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        if (-not (Test-Path -LiteralPath $powershell)) { Set-ItResult -Skipped -Because "Windows PowerShell 5.1 is not installed"; return }

        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("mole-git-stderr-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $work | Out-Null
        try {
            # A real native git stand-in: progress on stderr, success exit code.
            Set-Content -LiteralPath (Join-Path $work "git.cmd") -Value "@echo From https://github.com/tw93/Mole 1>&2`r`n@exit /b 0" -Encoding ASCII
            $helper = Get-FunctionText -Path (Join-Path $script:WindowsDir $_) -Name "Invoke-GitCommand"
            $probe = @"
`$ErrorActionPreference = 'Stop'
`$env:PATH = '$work;' + `$env:PATH
function Get-GitProxyArguments { @() }
$helper
try {
    `$result = Invoke-GitCommand -Arguments @('pull', '--ff-only', 'origin', 'windows')
    "exit=`$(`$result.ExitCode) pref=`$ErrorActionPreference"
} catch {
    "threw=`$_"
}
"@
            $probePath = Join-Path $work "probe.ps1"
            Set-Content -LiteralPath $probePath -Value $probe -Encoding UTF8

            $start = New-Object System.Diagnostics.ProcessStartInfo
            $start.FileName = $powershell
            $start.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$probePath`""
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $process = [System.Diagnostics.Process]::Start($start)
            $stdout = $process.StandardOutput.ReadToEnd()
            $null = $process.StandardError.ReadToEnd()
            $process.WaitForExit()

            $stdout.Trim() | Should -Be "exit=0 pref=Stop"
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
