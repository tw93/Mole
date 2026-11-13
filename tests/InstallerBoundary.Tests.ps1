BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . "$script:RepoRoot\lib\core\base.ps1"
    . "$script:RepoRoot\lib\core\log.ps1"
    . "$script:RepoRoot\lib\core\ui.ps1"
    . "$script:RepoRoot\lib\core\file_ops.ps1"
    $ast = [Management.Automation.Language.Parser]::ParseFile("$script:RepoRoot\bin\installer.ps1", [ref]$null, [ref]$null)
    foreach ($definition in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ne 'Main' }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    foreach ($assignment in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -like '$script:Installer*' }, $false)) {
        . ([scriptblock]::Create($assignment.Extent.Text))
    }

    $script:MsiClsid = [byte[]](0x84, 0x10, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46)
    # .msp patches share the compound-file header with another root class ID.
    $script:MspClsid = [byte[]](0x86, 0x10, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46)

    function New-CompoundBytes {
        param([byte[]]$Clsid)
        $bytes = New-Object byte[] 1536
        ([byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)).CopyTo($bytes, 0)
        $bytes[0x1C] = 0xFE; $bytes[0x1D] = 0xFF
        $bytes[0x1E] = 9; $bytes[0x1F] = 0
        # First directory sector 0, so the root entry starts at (0 + 1) << 9.
        [BitConverter]::GetBytes([uint32]0).CopyTo($bytes, 0x30)
        $bytes[512 + 0x42] = 5
        if ($Clsid) { $Clsid.CopyTo($bytes, 512 + 0x50) }
        return , $bytes
    }

    function New-Downloads {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        return (New-Item -ItemType Directory -Path (Join-Path $root 'Downloads')).FullName
    }

    function New-Installer {
        param([string]$Folder, [string]$Name = 'setup.msi', [byte[]]$Bytes = (New-CompoundBytes $script:MsiClsid), [int]$AgeDays = 30, [int]$CreatedDaysAgo = -1)
        $path = Join-Path $Folder $Name
        [IO.File]::WriteAllBytes($path, $Bytes)
        $written = [datetime]::UtcNow.AddDays(-$AgeDays)
        $created = if ($CreatedDaysAgo -ge 0) { [datetime]::UtcNow.AddDays(-$CreatedDaysAgo) } else { $written }
        [IO.File]::SetCreationTimeUtc($path, $created)
        [IO.File]::SetLastWriteTimeUtc($path, $written)
        return $path
    }

    function Get-OfferedNames {
        param([string]$Downloads)
        return @((Find-DownloadedInstallers -Downloads $Downloads).Items | ForEach-Object Name)
    }
}

Describe 'Installer discovery' {
    It 'offers an old Windows Installer package in Downloads' {
        $downloads = New-Downloads
        $null = New-Installer -Folder $downloads -Name 'Tool-1.2.msi'
        Get-OfferedNames $downloads | Should -Be @('Tool-1.2.msi')
    }

    It 'reads the class ID, not the extension' {
        $downloads = New-Downloads
        $null = New-Installer -Folder $downloads -Name 'patch.msi' -Bytes (New-CompoundBytes $script:MspClsid)
        $null = New-Installer -Folder $downloads -Name 'report.msi' -Bytes (New-CompoundBytes $null)
        $null = New-Installer -Folder $downloads -Name 'text.msi' -Bytes ([Text.Encoding]::ASCII.GetBytes('not an installer'))
        $null = New-Installer -Folder $downloads -Name 'short.msi' -Bytes ((New-CompoundBytes $script:MsiClsid)[0..600])
        Get-OfferedNames $downloads | Should -BeNullOrEmpty
    }

    It 'accepts a 4096-byte sector database and refuses a reserved directory sector' {
        $downloads = New-Downloads
        $big = New-Object byte[] 12288
        (New-CompoundBytes $null)[0..511].CopyTo($big, 0)
        $big[0x1E] = 12
        $big[4096 + 0x42] = 5
        $script:MsiClsid.CopyTo($big, 4096 + 0x50)
        $null = New-Installer -Folder $downloads -Name 'large-sector.msi' -Bytes $big
        $reserved = New-CompoundBytes $script:MsiClsid
        [BitConverter]::GetBytes([uint32]4294967294).CopyTo($reserved, 0x30)
        $null = New-Installer -Folder $downloads -Name 'reserved.msi' -Bytes $reserved
        Get-OfferedNames $downloads | Should -Be @('large-sector.msi')
    }

    It 'never offers an executable, even one holding an installer database' {
        $downloads = New-Downloads
        $null = New-Installer -Folder $downloads -Name 'setup.exe'
        Get-OfferedNames $downloads | Should -BeNullOrEmpty
    }

    It 'waits two weeks from the later of creation and write time' {
        $downloads = New-Downloads
        $null = New-Installer -Folder $downloads -Name 'old.msi' -AgeDays 15
        $null = New-Installer -Folder $downloads -Name 'recent.msi' -AgeDays 13
        # Copied in yesterday with an old write time: it only just arrived.
        $null = New-Installer -Folder $downloads -Name 'copied.msi' -AgeDays 400 -CreatedDaysAgo 1
        Get-OfferedNames $downloads | Should -Be @('old.msi')
    }

    It 'looks only at plain files directly in Downloads' {
        $downloads = New-Downloads
        $sub = New-Item -ItemType Directory -Path (Join-Path $downloads 'Drivers')
        $null = New-Installer -Folder $sub.FullName -Name 'driver.msi'
        $null = New-Installer -Folder $downloads -Name '.hidden.msi'
        $null = New-Installer -Folder $downloads -Name '.msi'
        $null = New-Item -ItemType Directory -Path (Join-Path $downloads 'folder.msi')
        Get-OfferedNames $downloads | Should -BeNullOrEmpty
    }

    It 'leaves a linked Downloads folder alone' {
        $target = New-Downloads
        $null = New-Installer -Folder $target -Name 'elsewhere.msi'
        $link = Join-Path (Split-Path -Parent (New-Downloads)) 'Linked'
        $null = New-Item -ItemType Junction -Path $link -Target $target
        try { Get-OfferedNames $link | Should -BeNullOrEmpty }
        finally { [IO.Directory]::Delete($link) }
    }

    It 'skips and counts an installer that is open elsewhere' {
        $downloads = New-Downloads
        $path = New-Installer -Folder $downloads -Name 'running.msi'
        $open = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $found = Find-DownloadedInstallers -Downloads $downloads
            @($found.Items).Count | Should -Be 0
            $found.Held | Should -Be 1
        }
        finally { $open.Dispose() }
    }

    It 'opens only the largest candidates when Downloads holds many' {
        $downloads = New-Downloads
        $script:InstallerMaxFiles = 2
        try {
            foreach ($i in 1..4) {
                $bytes = New-CompoundBytes $script:MsiClsid
                $bigger = New-Object byte[] ($bytes.Length + $i * 512)
                $bytes.CopyTo($bigger, 0)
                $null = New-Installer -Folder $downloads -Name "pkg$i.msi" -Bytes $bigger
            }
            (Get-OfferedNames $downloads | Sort-Object) | Should -Be @('pkg3.msi', 'pkg4.msi')
        }
        finally { $script:InstallerMaxFiles = 128 }
    }
}

Describe 'Installer removal' {
    BeforeEach {
        Reset-CleanupStats
        Set-DryRunMode -Enabled $false
        $script:InstallerItemsRecycled = 0
        $script:InstallerBytesRecycled = 0
        $script:InstallerItemsHeld = 0
        $script:InstallerItemsKept = 0
        $env:MO_NO_OPLOG = '1'
    }
    AfterEach { Remove-Item Env:\MO_NO_OPLOG -ErrorAction SilentlyContinue }

    It 'moves a listed installer to the Recycle Bin and nowhere else' {
        $downloads = New-Downloads
        $path = New-Installer -Folder $downloads
        $items = @((Find-DownloadedInstallers -Downloads $downloads).Items)
        Mock Move-MoleItemToRecycleBin { $script:RecycledPath = $Path }
        Remove-DownloadedInstallers -Items $items -Downloads $downloads
        $script:RecycledPath | Should -Be $path
        $script:InstallerItemsRecycled | Should -Be 1
    }

    It 'keeps an installer rewritten after the list' {
        $downloads = New-Downloads
        $path = New-Installer -Folder $downloads
        $items = @((Find-DownloadedInstallers -Downloads $downloads).Items)
        [IO.File]::SetLastWriteTimeUtc($path, [datetime]::UtcNow.AddDays(-20))
        Mock Move-MoleItemToRecycleBin { throw 'must not recycle' }
        Remove-DownloadedInstallers -Items $items -Downloads $downloads
        Should -Invoke Move-MoleItemToRecycleBin -Times 0
        $script:InstallerItemsRecycled | Should -Be 0
        $script:InstallerItemsKept | Should -Be 1
    }

    It 'keeps an installer opened after the list' {
        $downloads = New-Downloads
        $path = New-Installer -Folder $downloads
        $items = @((Find-DownloadedInstallers -Downloads $downloads).Items)
        Mock Move-MoleItemToRecycleBin { throw 'must not recycle' }
        $open = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { Remove-DownloadedInstallers -Items $items -Downloads $downloads }
        finally { $open.Dispose() }
        Should -Invoke Move-MoleItemToRecycleBin -Times 0
        $script:InstallerItemsHeld | Should -Be 1
    }

    It 'only reports in a dry run' {
        $downloads = New-Downloads
        $path = New-Installer -Folder $downloads
        $items = @((Find-DownloadedInstallers -Downloads $downloads).Items)
        Set-DryRunMode -Enabled $true
        Mock Move-MoleItemToRecycleBin { throw 'must not recycle' }
        Remove-DownloadedInstallers -Items $items -Downloads $downloads
        Should -Invoke Move-MoleItemToRecycleBin -Times 0
        $script:InstallerItemsRecycled | Should -Be 1
    }
}
