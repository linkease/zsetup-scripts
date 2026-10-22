# Run with pwsh or Windows PowerShell 5.1. Native OS/task APIs are isolated.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
if (-not (Get-Command Invoke-DDNSTOInstall -ErrorAction SilentlyContinue)) { throw 'missing transactional installer' }
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Assert-DDNSTOPlatform { }
function Protect-DDNSTODirectory($Path) { $script:Protected++ }
function Read-DDNSTOToken { $script:Prompted = $true; return "test:'token" }
function Receive-DDNSTOCandidate($Work, $Version) {
    if ($script:DownloadFail) { throw 'fixture download failure' }
    $path = Join-Path $Work 'ddnsto_cli.x86_64.exe'
    [IO.File]::WriteAllText($path, 'new binary')
    return $path
}
function Get-DDNSTOTask { return $script:Task }
function Export-DDNSTOTask { return $script:TaskXml }
function Stop-DDNSTOTask { $script:Stopped = $true; $script:Task.State = 'Ready' }
function Remove-DDNSTOTask { $script:Task = $null }
function Register-DDNSTOTask($Binary, $Config, $Directory) {
    Assert ($null -eq $script:Task -or $script:Stopped) 'must stop old task before replacing it'
    $script:Task = [pscustomobject]@{ State = 'Ready'; Actions = @([pscustomobject]@{
        Execute = $Binary; Arguments = ('--config "' + $Config + '"'); WorkingDirectory = $Directory
    }) }
    $script:TaskXml = 'new task'
}
function Restore-DDNSTOTask($Xml) {
    $script:TaskXml = $Xml
    $script:Task = [pscustomobject]@{ State = 'Ready'; Actions = @([pscustomobject]@{
        Execute = (Join-Path $root 'ddnsto_cli.x86_64.exe'); Arguments = ('--config "' + (Join-Path $root 'ddnsto.yaml') + '"'); WorkingDirectory = $root
    }) }
}
function Start-DDNSTOTask {
    if ($script:StartFail) { $script:StartFail = $false; throw 'fixture start failure' }
    $script:Task.State = 'Running'
}
function Confirm-DDNSTORunning { Assert ($script:Task.State -eq 'Running') 'not running' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('ddnsto-test-' + [guid]::NewGuid().ToString('N'))
try {
    $script:Task = $null
    $script:TaskXml = ''
    $script:DownloadFail = $false
    $script:StartFail = $false
    $script:Stopped = $false
    $script:Prompted = $false
    Invoke-DDNSTOInstall -InstallDir $root
    Assert $script:Prompted 'first install must prompt for token'
    $cfg = Join-Path $root 'ddnsto.yaml'
    $binary = Join-Path $root 'ddnsto_cli.x86_64.exe'
    $content = [IO.File]::ReadAllText($cfg) + "routerName: keep-name`n"
    [IO.File]::WriteAllText($cfg, $content)
    $identity = Join-Path $root '.ddnsto_boot.cfg'
    [IO.File]::WriteAllText($identity, 'keep-identity')
    $script:DownloadFail = $true
    $unchangedTask = $script:TaskXml
    $defaultRepeat = Invoke-DDNSTOInstall -InstallDir $root
    Assert (($defaultRepeat -join "`n") -match 'operation=none') 'default repeat must be a no-op'
    Assert ($script:TaskXml -eq $unchangedTask -and -not $script:Stopped) 'default repeat changed service'
    $script:DownloadFail = $false
    $script:Prompted = $false
    Invoke-DDNSTOInstall -InstallDir $root -Action update
    Assert (-not $script:Prompted) 'managed repeat must not prompt again'
    Assert ([IO.File]::ReadAllText($cfg) -eq $content) 'repeat overwrote configuration'
    Assert ([IO.File]::ReadAllText($identity) -eq 'keep-identity') 'repeat overwrote identity'
    [IO.File]::WriteAllText($binary, 'old binary')
    $script:TaskXml = 'old task'
    $script:StartFail = $true
    $failed = $false
    try { Invoke-DDNSTOInstall -InstallDir $root -Action update } catch { $failed = $true }
    Assert $failed 'start failure reported success'
    Assert ([IO.File]::ReadAllText($binary) -eq 'old binary') 'binary not restored'
    Assert ([IO.File]::ReadAllText($cfg) -eq $content) 'config not restored'
    Assert ($script:TaskXml -eq 'old task' -and $script:Task.State -eq 'Running') 'task not restored'
    $script:DownloadFail = $true
    $script:Stopped = $false
    $failed = $false
    try { Invoke-DDNSTOInstall -InstallDir $root -Action update } catch { $failed = $true }
    Assert ($failed -and -not $script:Stopped) 'download failure stopped service'
    $script:DownloadFail = $false
    $failed = $false
    try { Invoke-DDNSTOInstall -InstallDir $root -Token "bad`nvalue" } catch { $failed = $true }
    Assert $failed 'multiline token accepted'
    $lockPath = Join-Path $root '.install-lock'
    [IO.File]::WriteAllText($lockPath, 'other installer')
    $protectedBefore = $script:Protected
    $failed = $false
    try { Invoke-DDNSTOInstall -InstallDir $root -Action update } catch { $failed = $true }
    Assert ($failed -and (Test-Path -LiteralPath $lockPath)) 'competing installer removed lock'
    Assert ($script:Protected -eq $protectedBefore) 'competing installer changed directory ACL before acquiring lock'
    Remove-Item -LiteralPath $lockPath -Force
    $firstRoot = Join-Path $root 'fresh'
    New-Item -ItemType Directory -Path $firstRoot | Out-Null
    $firstIdentity = Join-Path $firstRoot '.ddnsto_boot.cfg'
    [IO.File]::WriteAllText($firstIdentity, 'preexisting identity')
    $script:Task = $null
    $script:StartFail = $true
    $failed = $false
    try { Invoke-DDNSTOInstall -Token 'first-token' -InstallDir $firstRoot } catch { $failed = $true }
    Assert $failed 'first start failure reported success'
    Assert (-not (Test-Path -LiteralPath (Join-Path $firstRoot 'ddnsto_cli.x86_64.exe'))) 'failed first install left binary'
    Assert (-not (Test-Path -LiteralPath (Join-Path $firstRoot 'ddnsto.yaml'))) 'failed first install left config'
    Assert ($null -eq $script:Task) 'failed first install left task'
    Assert ([IO.File]::ReadAllText($firstIdentity) -eq 'preexisting identity') 'failed first install removed identity'
    $cleanRoot = Join-Path $root 'clean-first-install'
    $script:StartFail = $true
    $failed = $false
    try { Invoke-DDNSTOInstall -Token 'first-token' -InstallDir $cleanRoot } catch { $failed = $true }
    Assert ($failed -and -not $script:StartFail) 'clean first installation did not exercise start failure'
    Assert ($null -eq $script:Task) 'failed clean first install left task'
    foreach ($name in @('ddnsto_cli.x86_64.exe', 'ddnsto.yaml', '.installer-windows-v1', '.install-lock')) {
        Assert (-not (Test-Path -LiteralPath (Join-Path $cleanRoot $name))) 'failed clean first install left managed file'
    }
    Write-Output 'Windows behavior: install, repeat, preservation, rollback and early failure passed'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
