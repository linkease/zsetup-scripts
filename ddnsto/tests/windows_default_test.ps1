$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Assert($Ok, $Message) { if (-not $Ok) { throw $Message } }
function Fails($Body) { $failed=$false; try { & $Body | Out-Null } catch { $failed=$true }; Assert $failed 'expected refusal' }
function Assert-DDNSTOPlatform {}
function Protect-DDNSTODirectory($Path) {}
function Read-Host { $script:prompts++; throw 'unexpected prompt' }
function Get-DDNSTOTask { $script:task }
function Get-DDNSTOClientVersion($Path) { return $script:version }
function Receive-DDNSTOCandidate($Work, $Version) {
    $script:downloads++
    $p=Join-Path $Work 'candidate.exe'; [IO.File]::WriteAllText($p, 'new'); return $p
}
function Register-DDNSTOTask($Binary, $Config, $Directory) {
    $script:task=[pscustomobject]@{State='Ready'; Actions=@([pscustomobject]@{
        Execute=$Binary; Arguments=('--config "'+$Config+'"'); WorkingDirectory=$Directory
    })}
}
function Export-DDNSTOTask { $script:task | ConvertTo-Json -Depth 5 }
function Restore-DDNSTOTask($Xml) { $script:task=$Xml | ConvertFrom-Json }
function Stop-DDNSTOTask { $script:stops++; $script:task.State='Ready' }
function Enable-ScheduledTask { $script:task.Settings.Enabled=$true }
function Get-CimInstance { [pscustomobject]@{ProcessId=123; CreationDate=[datetime]'2026-01-01'; ExecutablePath=$script:task.Actions[0].Execute} }
function Start-DDNSTOTask { $script:task.State='Running' }
function Remove-DDNSTOTask { $script:task=$null }
# Exercise the real stability loop with only its clock/task dependencies replaced.
function Start-Sleep { if ($script:unstable) { $script:task.State='Ready' } }
$root=Join-Path ([IO.Path]::GetTempPath()) ('ddnsto-default-'+[guid]::NewGuid())
try {
    $script:downloads=0; $script:stops=0; $script:prompts=0; $script:task=$null; $script:version='4.2.7'
    Fails { Invoke-DDNSTOEntry -InstallDir $root }
    Assert (-not (Test-Path $root)) 'missing token mutated filesystem'
    $result=Invoke-DDNSTOEntry -InstallDir $root -Token "same:'secret"
    Assert ($result -match '安装成功') 'fresh success must be Chinese'
    $cfg=Join-Path $root 'ddnsto.yaml'; $binary=Join-Path $root 'ddnsto_cli.x86_64.exe'
    $original=[IO.File]::ReadAllText($cfg)+"routerName: keep`n"
    [IO.File]::WriteAllText($cfg,$original)
    $identity=Join-Path $root '.ddnsto_boot.cfg'; [IO.File]::WriteAllText($identity,'identity')
    Invoke-DDNSTOEntry -InstallDir $root -Token "same:'secret" | Out-Null
    Assert ($script:downloads -eq 2) 'same token did not automatically upgrade'
    Assert ([IO.File]::ReadAllText($cfg) -ceq $original) 'configuration changed'
    Assert ([IO.File]::ReadAllText($identity) -ceq 'identity') 'identity changed'
    Fails { Invoke-DDNSTOEntry -Action install -InstallDir $root -Token "same:'secret" }
    Assert ($script:downloads -eq 2) 'explicit install replaced existing installation'
    foreach ($script:version in @('4.2.8','4.2.10','5.0.0')) {
        foreach ($state in @('Running','Ready','Disabled')) {
            $script:task.State=$state
            $script:task | Add-Member -NotePropertyName Settings -NotePropertyValue ([pscustomobject]@{Enabled=$false}) -Force
            $result=Invoke-DDNSTOEntry -InstallDir $root -Token "same:'secret"
            Assert ($script:task.Settings.Enabled) 'running but disabled task was not enabled'
            Assert ($result -match '启动成功|已稳定运行') 'start/running success must be Chinese'
            Assert ($script:task.State -eq 'Running') 'repeat did not start task'
            Assert ($script:downloads -eq 2) 'equal/newer version replaced'
        }
    }
    $before=$script:stops
    foreach ($bad in @("userToken: 'other'", "userToken: 'same:''secret'`nuserToken: 'other'", "userToken: 'same:''secret'`n'userToken': 'other'", "userToken: 'same:''secret'`n---`nuserToken: 'other'", "userToken: 'same:''secret'`n<<: *other", "userToken: |`n  same:'secret", "userToken: 'same:''secret'`n  continued", "routerName: keep")) {
        [IO.File]::WriteAllText($cfg,$bad)
        Fails { Invoke-DDNSTOEntry -InstallDir $root -Token "same:'secret" }
        Assert ([IO.File]::ReadAllText($cfg) -ceq $bad) 'unknown ownership changed config'
    }
    Assert ($script:downloads -eq 2 -and $script:stops -eq $before) 'ownership refusal mutated installation'
    [IO.File]::WriteAllText($cfg,$original)
    $script:version='unknown'
    Fails { Invoke-DDNSTOEntry -InstallDir $root -Token "same:'secret" }
    Assert ($script:downloads -eq 2) 'unknown version downloaded replacement'
    $script:version='4.2.8'; $script:unstable=$true
    Fails { Invoke-DDNSTOEntry -InstallDir $root -Token "same:'secret" }
    $script:unstable=$false
    $tokenFile=Join-Path $root 'token-input'; [IO.File]::WriteAllText($tokenFile,"same:'secret`r`n")
    Invoke-DDNSTOEntry -InstallDir $root -TokenFile $tokenFile | Out-Null
    Fails { Invoke-DDNSTOEntry -InstallDir $root -Token 'x' -TokenFile $tokenFile }
    Fails { Invoke-DDNSTOEntry -InstallDir $root -Token "bad`tvalue" }
    $script:version='4.2.7'; $script:unstable=$true
    Fails { Invoke-DDNSTOEntry -InstallDir $root -Token "same:'secret" }
    Assert ([IO.File]::ReadAllText((Join-Path $root '.installer-windows-v1')) -ceq 'ddnsto-windows-v1:recovery-required') 'failed rollback must block subsequent automatic install'
    $script:unstable=$false
    Fails { Invoke-DDNSTOEntry -InstallDir $root -Token "same:'secret" }
    [IO.File]::WriteAllText((Join-Path $root '.installer-windows-v1'),'legacy')
    Fails { Invoke-DDNSTOEntry -InstallDir $root -Token "same:'secret" }
    Assert ($script:prompts -eq 0) 'installer attempted interactive input'
    Write-Output 'Windows default: automatic install/upgrade/start, no downgrade, ownership and stability passed'
} finally { if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
