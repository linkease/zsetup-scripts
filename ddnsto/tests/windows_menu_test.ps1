# Regression for the removed menu: explicit management flags still dispatch.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Assert($Ok, $Message) { if (-not $Ok) { throw $Message } }
function Read-Host { throw 'unexpected menu/input' }
function Invoke-DDNSTOManageService($InstallDir, $Action) { return $Action }
function Invoke-DDNSTORepair($InstallDir) { return 'repair' }
function Invoke-DDNSTOLifecycle($InstallDir, $Action, $Token) { return $Action }
function Invoke-DDNSTOInstall($InstallDir, $Action, $Token) {
    if ($Action -eq 'ensure') { Assert ($Token -ceq 'provided') 'default lost credentials' }
    return $Action
}
Assert ((Invoke-DDNSTOEntry -Token provided) -eq 'ensure') 'default ensure dispatch missing'
foreach ($action in @('update','status','start','stop','restart','repair','configure','uninstall')) {
    Assert ((Invoke-DDNSTOEntry -Action $action) -eq $action) 'manual action dispatch missing'
}
Write-Output 'Windows entry: no menu, automatic default and explicit management dispatch passed'
