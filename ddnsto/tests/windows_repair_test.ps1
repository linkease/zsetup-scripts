$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Assert($Ok, $Message) { if (-not $Ok) { throw $Message } }
function Assert-DDNSTOPlatform {}
function Receive-DDNSTOCandidate { throw 'unexpected download' }
function Read-DDNSTOToken { throw 'unexpected token prompt' }
function Get-DDNSTOTask { return $script:task }
function Export-DDNSTOTask { return 'old-task-xml' }
function Stop-DDNSTOTask { $script:task.State = 'Ready' }
function Remove-DDNSTOTask { $script:task = $null }
function Register-DDNSTOTask($Binary, $Config, $Directory) {
    $script:registered++
    $script:task = [pscustomobject]@{ State = 'Ready'; Actions = @([pscustomobject]@{
        Execute = $Binary; Arguments = ('--config "' + $Config + '"'); WorkingDirectory = $Directory
    }) }
}
function Restore-DDNSTOTask($Xml) {
    Assert ($Xml -eq 'old-task-xml') 'lost original task XML'
    if ($script:restoreFail) { throw 'restore failed' }
    $script:restored = $true
    Register-DDNSTOTask (Join-Path $root 'ddnsto_cli.x86_64.exe') (Join-Path $root 'ddnsto.yaml') $root
}
function Start-DDNSTOTask {
    if ($script:startFail) { $script:startFail = $false; throw 'start failed' }
    $script:task.State = 'Running'
}
function Confirm-DDNSTORunning { Assert ($script:task.State -eq 'Running') 'not running' }
function Remove-Item([string]$LiteralPath, [switch]$Force, [switch]$Recurse) {
    if ($script:cleanupFail -and [IO.Path]::GetFileName($LiteralPath).StartsWith('.repair-')) { throw 'cleanup failed' }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Force:$Force -Recurse:$Recurse
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('ddnsto-repair-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $script:registered = 0
    $script:task = $null
    $script:startFail = $false
    $script:restoreFail = $false
    $script:restored = $false
    $script:cleanupFail = $false
    [IO.File]::WriteAllText((Join-Path $root '.installer-windows-v1'), 'ddnsto-windows-v1')
    foreach ($name in @('ddnsto_cli.x86_64.exe', 'ddnsto.yaml', '.ddnsto_boot.cfg')) {
        [IO.File]::WriteAllText((Join-Path $root $name), 'preserve-' + $name)
    }
    $result = Invoke-DDNSTOEntry -Action repair -InstallDir $root
    Assert (($result -join "`n") -match 'operation=repair.*local_service=running.*cloud_status=unverified') 'repair did not succeed'
    Assert ($script:task.State -eq 'Running') 'missing task not recreated'
    Assert ([IO.File]::ReadAllText((Join-Path $root '.installer-windows-v1')) -ceq 'ddnsto-windows-v1') 'repair changed marker'
    foreach ($name in @('ddnsto_cli.x86_64.exe', 'ddnsto.yaml', '.ddnsto_boot.cfg')) {
        Assert (([IO.File]::ReadAllText((Join-Path $root $name))) -eq ('preserve-' + $name)) 'repair changed client files'
    }
    $script:startFail = $true
    $failed = $false
    try { Invoke-DDNSTOEntry -Action repair -InstallDir $root | Out-Null } catch { $failed = $true }
    Assert ($failed -and $script:restored -and $script:task.State -eq 'Running') 'failed repair did not restore running task'
    $script:task = $null
    $script:startFail = $true
    $failed = $false
    try { Invoke-DDNSTOEntry -Action repair -InstallDir $root | Out-Null } catch { $failed = $true }
    Assert ($failed -and $null -eq $script:task) 'failed repair left a newly created task'
    foreach ($arguments in @(@{TokenFile='absent'}, @{Token='secret'}, @{Plan=$true}, @{Method='docker'}, @{Platform='macos'})) {
        $failed = $false
        try { Invoke-DDNSTOEntry -Action repair -InstallDir $root @arguments | Out-Null } catch { $failed = $true }
        Assert $failed 'invalid repair arguments accepted'
    }
    $lockPath = Join-Path $root '.install-lock'
    [IO.File]::WriteAllText($lockPath, 'foreign lock')
    $count = $script:registered
    $failed = $false
    try { Invoke-DDNSTOEntry -Action repair -InstallDir $root | Out-Null } catch { $failed = $true }
    Assert ($failed -and $script:registered -eq $count) 'repair ignored lock'
    Assert (([IO.File]::ReadAllText($lockPath)) -eq 'foreign lock') 'removed foreign lock'
    Remove-Item -LiteralPath $lockPath -Force
    Register-DDNSTOTask 'unrelated.exe' 'other.yaml' $root
    $count = $script:registered
    $failed = $false
    try { Invoke-DDNSTOEntry -Action repair -InstallDir $root | Out-Null } catch { $failed = $true }
    Assert ($failed -and $script:registered -eq $count) 'overwrote unrelated task'
    $script:task = $null
    Remove-Item -LiteralPath (Join-Path $root 'ddnsto_cli.x86_64.exe')
    $failed = $false
    try { Invoke-DDNSTOEntry -Action repair -InstallDir $root | Out-Null } catch { $failed = $true }
    Assert $failed 'repaired without binary'
    Assert (-not (Test-Path -LiteralPath $lockPath)) 'leaked operation lock'
    Assert (@(Get-ChildItem -LiteralPath $root -Force -Filter '.repair-*').Count -eq 0) 'successful recovery leaked backup'
    [IO.File]::WriteAllText((Join-Path $root 'ddnsto_cli.x86_64.exe'), 'old')
    Register-DDNSTOTask (Join-Path $root 'ddnsto_cli.x86_64.exe') (Join-Path $root 'ddnsto.yaml') $root
    $script:startFail = $true
    $script:restoreFail = $true
    $failed = $false
    try { Invoke-DDNSTOEntry -Action repair -InstallDir $root | Out-Null } catch { $failed = $true }
    $backups = @(Get-ChildItem -LiteralPath $root -Force -Filter '.repair-*')
    Assert ($failed -and $backups.Count -eq 1) 'failed recovery did not retain backup'
    Assert (([IO.File]::ReadAllText((Join-Path $backups[0].FullName 'old-task.xml'))) -eq 'old-task-xml') 'backup missing original XML'
    Assert (-not (Test-Path -LiteralPath $lockPath)) 'failed recovery leaked lock'
    $script:restoreFail = $false
    $script:cleanupFail = $true
    $failed = $false
    try { Invoke-DDNSTOEntry -Action repair -InstallDir $root | Out-Null } catch { $failed = $true }
    Assert $failed 'cleanup failure was hidden'
    Assert (-not (Test-Path -LiteralPath $lockPath)) 'backup cleanup failure leaked lock'
    $script:cleanupFail = $false
    Write-Output 'Windows repair: missing task, preservation, rollback, guards and recovery backup passed'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
