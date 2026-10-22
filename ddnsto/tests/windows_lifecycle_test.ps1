$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Assert($Ok, $Message) { if (-not $Ok) { throw $Message } }
function Fails($Body) { $failed = $false; try { & $Body | Out-Null } catch { $failed = $true }; Assert $failed 'expected refusal/failure' }
function Assert-DDNSTOPlatform {}
function Protect-DDNSTODirectory($Path) {}
function Read-DDNSTOToken { throw 'unexpected prompt' }
function Get-DDNSTOTask { return $script:task }
function Export-DDNSTOTask { return $script:task | ConvertTo-Json -Depth 5 -Compress }
function Restore-DDNSTOTask($Xml) { if ($script:restoreFail) { throw 'restore failed' }; $script:task = $Xml | ConvertFrom-Json }
function Stop-DDNSTOTask {
    $script:stopCalls++
    if ($script:stopFail) { $script:stopFail = $false; throw 'stop failed' }
    $script:task.State = 'Ready'
}
function Remove-DDNSTOTask { $script:task = $null; if ($script:removeFail) { throw 'remove failed after removal' } }
function Register-DDNSTOTask($Binary, $Config, $Directory) {
    $script:task = [pscustomobject]@{ State = 'Ready'; Actions = @([pscustomobject]@{
        Execute = $Binary; Arguments = ('--config "' + $Config + '"'); WorkingDirectory = $Directory
    }) }
    if ($script:registerFail) { $script:registerFail = $false; throw 'register failed after mutation' }
}
function Start-DDNSTOTask {
    if ($script:startFail) { $script:startFail = $false; throw 'start failed' }
    $script:task.State = 'Running'
}
function Confirm-DDNSTORunning { Assert ($script:task.State -eq 'Running') 'not running' }
function Receive-DDNSTOCandidate($Work, $Version) {
    if ($script:downloadFail) { throw 'download failed' }
    $p = Join-Path $Work 'candidate.exe'; [IO.File]::WriteAllText($p, 'verified candidate'); return $p
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('ddnsto-lifecycle-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
$cfg = Join-Path $root 'ddnsto.yaml'
$marker = Join-Path $root '.installer-windows-v1'
$binary = Join-Path $root 'ddnsto_cli.x86_64.exe'
$identity = Join-Path $root '.ddnsto_boot.cfg'
$original = "userToken: 'old-secret'`r`nrouterName: keep`r`n"
try {
    [IO.File]::WriteAllText($cfg, $original)
    [IO.File]::WriteAllText($marker, 'ddnsto-windows-v1')
    [IO.File]::WriteAllText($binary, 'original binary')
    [IO.File]::WriteAllText($identity, 'original identity')
    Register-DDNSTOTask $binary $cfg $root
    Start-DDNSTOTask
    $result = Invoke-DDNSTOEntry -Action uninstall -InstallDir $root
    Assert ($result -match 'installation=retained') 'missing retained result'
    Assert ($null -eq $script:task -and -not (Test-Path $binary)) 'uninstall left task/binary'
    Assert ([IO.File]::ReadAllText($cfg) -ceq $original) 'uninstall changed configuration'
    Assert ([IO.File]::ReadAllText($identity) -ceq 'original identity') 'uninstall changed identity'
    Assert ([IO.File]::ReadAllText($marker) -ceq 'ddnsto-windows-v1:retained') 'retained marker missing'
    Assert ((Invoke-DDNSTOEntry -Action status -InstallDir $root) -match 'local_service=not-installed') 'retained status wrong'
    Invoke-DDNSTOEntry -Action uninstall -InstallDir $root | Out-Null
    foreach ($action in @('start', 'stop', 'restart', 'repair', 'configure', 'update')) {
        Fails { Invoke-DDNSTOEntry -Action $action -InstallDir $root }
    }
    [IO.File]::WriteAllText((Join-Path $root '.install-lock'), 'retained-lock')
    Fails { Invoke-DDNSTOEntry -Action install -InstallDir $root }
    Assert ([IO.File]::ReadAllText((Join-Path $root '.install-lock')) -ceq 'retained-lock') 'reinstall removed foreign lock'
    Remove-Item -LiteralPath (Join-Path $root '.install-lock') -Force
    Fails { Invoke-DDNSTOEntry -Action install -Token secret -InstallDir $root }
    $script:downloadFail = $true
    Fails { Invoke-DDNSTOEntry -Action install -InstallDir $root }
    $script:downloadFail = $false
    $script:registerFail = $true
    Fails { Invoke-DDNSTOEntry -Action install -InstallDir $root }
    Assert ($null -eq $script:task -and -not (Test-Path $binary)) 'registration failure left task/binary'
    $script:startFail = $true
    Fails { Invoke-DDNSTOEntry -Action install -InstallDir $root }
    Assert ($null -eq $script:task -and -not (Test-Path $binary)) 'failed reinstall left task/binary'
    Assert ([IO.File]::ReadAllText($marker) -ceq 'ddnsto-windows-v1:retained') 'failed reinstall lost retained state'
    Invoke-DDNSTOEntry -Action install -InstallDir $root | Out-Null
    Assert ($script:task.State -eq 'Running') 'reinstall not running'
    Assert ([IO.File]::ReadAllText($cfg) -ceq $original) 'reinstall rewrote configuration'
    $script:stopFail = $true
    Fails { Invoke-DDNSTOEntry -Action uninstall -InstallDir $root }
    Assert ($script:task.State -eq 'Running' -and (Test-Path $binary)) 'stop failure broke installation'
    $script:removeFail = $true
    Fails { Invoke-DDNSTOEntry -Action uninstall -InstallDir $root }
    Assert ($script:task.State -eq 'Running' -and (Test-Path $binary)) 'uninstall rollback failed'
    Assert ([IO.File]::ReadAllText($marker) -ceq 'ddnsto-windows-v1') 'uninstall rollback lost active marker'
    $script:removeFail = $false
    Fails { Invoke-DDNSTOEntry -Action configure -InstallDir $root }
    $script:startFail = $true
    Fails { Invoke-DDNSTOEntry -Action configure -Token "new:'secret" -InstallDir $root }
    Assert ([IO.File]::ReadAllText($cfg) -ceq $original) 'configure rollback changed bytes'
    Assert ($script:task.State -eq 'Running') 'configure rollback lost running state'
    $result = Invoke-DDNSTOEntry -Action configure -Token "new:'secret" -InstallDir $root
    Assert ($result -match 'operation=configure' -and $result -notmatch 'secret') 'configure result leaks token or missing'
    Assert ([IO.File]::ReadAllText($cfg) -ceq "userToken: 'new:''secret'`r`nrouterName: keep`r`n") 'configure changed unrelated fields'
    Assert ([IO.File]::ReadAllText($identity) -ceq 'original identity') 'configure changed identity'
    foreach ($bad in @(
        "userToken: 'old`n  continued'`nrouterName: keep`n",
        "userToken: `"old`r`n  continued`"`r`nrouterName: keep`r`n",
        "userToken: old`n  continued`nrouterName: keep`n",
        "userToken: 'a'`nuserToken: 'b'`n",
        "userToken: |`n  old-value`n"
    )) {
        [IO.File]::WriteAllText($cfg, $bad)
        $stopsBefore = $script:stopCalls
        Fails { Invoke-DDNSTOEntry -Action configure -Token x -InstallDir $root }
        Assert ([IO.File]::ReadAllText($cfg) -ceq $bad) 'invalid configuration was modified'
        Assert ($script:stopCalls -eq $stopsBefore) 'unsupported YAML stopped the existing task'
        Assert (-not (Test-Path (Join-Path $root '.install-lock'))) 'unsupported YAML leaked lock'
        Assert (@(Get-ChildItem $root -Force -Filter '.lifecycle-*').Count -eq 0) 'unsupported YAML leaked work directory'
    }
    [IO.File]::WriteAllText($cfg, $original)
    $script:task.State = 'Disabled'
    $script:startFail = $true
    Fails { Invoke-DDNSTOEntry -Action configure -Token x -InstallDir $root }
    Assert ($script:task.State -eq 'Disabled') 'configure rollback lost disabled state'
    $tokenFile = Join-Path $root 'input-token'
    [IO.File]::WriteAllText($tokenFile, "file-secret`r`n")
    Invoke-DDNSTOEntry -Action configure -TokenFile $tokenFile -InstallDir $root | Out-Null
    Assert ([IO.File]::ReadAllText($cfg) -match "userToken: 'file-secret'") 'TokenFile not applied'
    foreach ($action in @('uninstall', 'configure')) {
        Fails { Invoke-DDNSTOEntry -Action $action -Token x -TokenFile $tokenFile -InstallDir $root }
        Fails { Invoke-DDNSTOEntry -Action $action -Plan -InstallDir $root }
    }
    foreach ($action in @('uninstall', 'configure', 'install', 'update', 'repair')) {
        [IO.File]::WriteAllText((Join-Path $root '.install-lock'), 'foreign')
        $args = @{Action=$action; InstallDir=$root}; if ($action -eq 'configure') { $args.Token='x' }
        if ($action -ne 'install') { Fails { Invoke-DDNSTOEntry @args } }
        Assert ([IO.File]::ReadAllText((Join-Path $root '.install-lock')) -eq 'foreign') 'foreign lock removed'
        Remove-Item -LiteralPath (Join-Path $root '.install-lock') -Force
    }
    $script:task.Actions[0].Execute = 'foreign.exe'
    foreach ($action in @('uninstall', 'configure', 'update')) {
        $args = @{Action=$action; InstallDir=$root}; if ($action -eq 'configure') { $args.Token='x' }
        Fails { Invoke-DDNSTOEntry @args }
    }
    Register-DDNSTOTask $binary $cfg $root
    [IO.File]::WriteAllText($marker, 'unknown-owner')
    Fails { Invoke-DDNSTOEntry -Action uninstall -InstallDir $root }
    [IO.File]::WriteAllText($marker, 'ddnsto-windows-v1')
    Remove-Item -LiteralPath $identity -Force
    $alias = Join-Path $root 'alias'
    New-Item -ItemType SymbolicLink -Path $alias -Target $root | Out-Null
    Fails { Invoke-DDNSTOEntry -Action install -InstallDir (Join-Path $alias 'nested') -Token x }
    Remove-Item -LiteralPath $alias -Force
    # Missing task can still be explicitly uninstalled, then reinstalled.
    $script:task = $null
    Invoke-DDNSTOEntry -Action uninstall -InstallDir $root | Out-Null
    Invoke-DDNSTOEntry -Action install -InstallDir $root | Out-Null
    New-Item -ItemType SymbolicLink -Path $identity -Target $cfg | Out-Null
    Fails { Invoke-DDNSTOEntry -Action uninstall -InstallDir $root }
    Remove-Item -LiteralPath $identity -Force
    $script:removeFail = $true; $script:restoreFail = $true
    Fails { Invoke-DDNSTOEntry -Action uninstall -InstallDir $root }
    Assert (@(Get-ChildItem $root -Force -Filter '.lifecycle-*').Count -eq 1) 'recovery failure lost backup'
    Assert (-not (Test-Path (Join-Path $root '.install-lock'))) 'lock leaked'
    Assert ((Invoke-DDNSTOEntry -Action status -InstallDir $root) -match 'installation=recovery-required') 'recovery failure not reported by status'
    Fails { Invoke-DDNSTOEntry -Action uninstall -InstallDir $root }
    $script:task = $null
    $unknown = Join-Path $root 'unknown'
    New-Item -ItemType Directory -Path $unknown | Out-Null
    [IO.File]::WriteAllText((Join-Path $unknown 'foreign-data'), 'keep')
    Fails { Invoke-DDNSTOEntry -Action install -InstallDir $unknown -Token x }
    Assert ([IO.File]::ReadAllText((Join-Path $unknown 'foreign-data')) -ceq 'keep') 'unmanaged data changed'
    Write-Output 'Windows lifecycle: uninstall/reinstall/configure, preservation, rollback, ownership and lock passed'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
