# Local fixture only: no native client, network, host task or global env changes.
$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../templates/install.ps1.in'))
$source = $source.Replace('@@windows.client_version@@', '4.2.8').Replace('@@windows.binary_sha256@@', 'fixture-sha')
$source = $source.Replace('@@windows.archive_sha256@@', ('a' * 64))
. ([scriptblock]::Create($source))
$realStop = ${function:Stop-DDNSTOTask}
function Assert($Ok, $Message) { if (-not $Ok) { throw $Message } }
function Fails($Body, $Pattern) {
    $caught = $false
    try { & $Body | Out-Null } catch { $caught = $true; if ($Pattern) { Assert ($_.Exception.Message -match $Pattern) $_.Exception.Message } }
    Assert $caught 'expected refusal'
}
function Assert-DDNSTOPlatform {}
function Protect-DDNSTODirectory($Path) {}
function New-DDNSTODiagnostic { return $null }
function Get-DDNSTOTask { return $script:task }
function New-ScheduledTaskAction($Execute, $Argument, $WorkingDirectory) { [pscustomobject]@{Execute=$Execute; Arguments=$Argument; WorkingDirectory=$WorkingDirectory} }
function New-ScheduledTaskPrincipal { return 'SYSTEM' }
function New-ScheduledTaskSettingsSet { return 'settings' }
function New-ScheduledTaskTrigger { return 'startup' }
function Register-ScheduledTask($TaskPath, $TaskName, $Action, $Principal, $Trigger, $Settings, [switch]$Force) {
    $script:task = [pscustomobject]@{State='Ready'; Actions=@($Action)}
}
function Export-DDNSTOTask { $script:task | ConvertTo-Json -Depth 5 -Compress }
function Restore-DDNSTOTask($Xml) { $script:task = $Xml | ConvertFrom-Json }
function Stop-DDNSTOTask { $script:stops++; $script:task.State='Ready' }
function Remove-DDNSTOTask { $script:task=$null }
function Enable-ScheduledTask {}
function Disable-ScheduledTask {}
function Start-DDNSTOTask {
    if ($script:failStart) {
        $script:failStart=$false
        [IO.File]::WriteAllText((Join-Path $root '.ddnsto_boot.cfg'), 'changed-by-failed-client')
        throw 'fixture start failure'
    }
    $script:task.State='Running'
}
function Confirm-DDNSTORunning($Binary) {
    Assert ($script:task.State -eq 'Running') 'not running'
    $directory=[IO.Path]::GetDirectoryName($Binary); $config=Join-Path $directory 'ddnsto.yaml'
    $environment=Get-DDNSTORecordedEnvironment $config
    $expected=if ($environment) { Get-DDNSTOEnvironmentAction $Binary $config $directory $environment } else {
        [pscustomobject]@{Execute=$Binary;Arguments=('--config "'+$config+'"');WorkingDirectory=$directory}
    }
    Assert (Test-DDNSTOTaskAction $script:task $expected) 'wrong task environment'
}
function Get-DDNSTOClientVersion { '4.2.8' }
function Get-FileHash { [pscustomobject]@{Hash=$script:candidateHash} }
function Receive-DDNSTOCandidate($Work, $Version) {
    $script:downloads++
    $path=Join-Path $Work 'candidate.exe'; [IO.File]::WriteAllText($path, 'fixture'); return $path
}
function TaskCommand {
    $arg=$script:task.Actions[0].Arguments
    [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($arg -split ' ')[-1]))
}
$root=Join-Path ([IO.Path]::GetTempPath()) ("ddnsto-env-'quoted-"+[guid]::NewGuid())
$originalAmbient=$env:DDNSTO_TEST_SERVER_ASSIGNMENT_JSON
try {
    $script:task=$null; $script:stops=0; $script:downloads=0; $script:candidateHash='fixture-sha'
    $env:DDNSTO_TEST_SERVER_ASSIGNMENT_JSON='ambient-test-must-not-inherit'
    Invoke-DDNSTOInstall -InstallDir $root -Token 'owner' | Out-Null
    Assert ((TaskCommand) -match 'tunnel.kooldns.cn:4445') 'default production not persisted'
    Assert ((TaskCommand) -notmatch 'ambient-test') 'ambient environment leaked into task'
    Assert ($env:DDNSTO_TEST_SERVER_ASSIGNMENT_JSON -eq 'ambient-test-must-not-inherit') 'caller env mutated'
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseInput((TaskCommand), [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) 'quoted install path produced invalid launcher'
    Assert ((TaskCommand).Contains($root.Replace("'", "''"))) 'path not single-quote escaped'
    $cfg=Join-Path $root 'ddnsto.yaml'; $identity=Join-Path $root '.ddnsto_boot.cfg'
    [IO.File]::WriteAllText($identity, 'keep-identity')
    $productionConfig=[IO.File]::ReadAllText($cfg)
    $oldTask=Export-DDNSTOTask
    Fails { Invoke-DDNSTOInstall -InstallDir $root -Token owner -Environment test } 'E_ENV_MISMATCH'
    Assert ($script:stops -eq 0 -and $script:downloads -eq 1) 'mismatch changed service/downloaded'
    Fails { Invoke-DDNSTOEntryCore -InstallDir $root -Action restart -Environment test -SwitchEnvironment } 'E_ENV_SWITCH_ACTION'
    $script:candidateHash='unsupported'
    Fails { Invoke-DDNSTOInstall -InstallDir $root -Token owner -Environment test -SwitchEnvironment } 'E_ENV_CAPABILITY'
    Assert ($script:stops -eq 0) 'unsupported client stopped before capability guard'
    $script:candidateHash='fixture-sha'; $script:failStart=$true
    Fails { Invoke-DDNSTOInstall -InstallDir $root -Token owner -Environment test -SwitchEnvironment } ''
    Assert ([IO.File]::ReadAllText($cfg) -ceq $productionConfig) 'rollback lost environment/config'
    Assert ([IO.File]::ReadAllText($identity) -ceq 'keep-identity') 'rollback lost identity'
    Assert ((Export-DDNSTOTask) -ceq $oldTask) 'rollback lost old task'
    Invoke-DDNSTOInstall -InstallDir $root -Token owner -Environment test -SwitchEnvironment | Out-Null
    Assert ($script:downloads -eq 1) 'same-version switch downloaded/downgraded client'
    Assert ((TaskCommand) -match 'wss://web.toany.net:9445/ws/control') 'test environment not persisted'
    Assert ([IO.File]::ReadAllText($identity) -ceq 'keep-identity') 'switch changed identity'
    Invoke-DDNSTOInstall -InstallDir $root -Token owner -Environment test | Out-Null
    foreach ($action in @('stop','start','restart','repair')) {
        Invoke-DDNSTOEntryCore -InstallDir $root -Action $action -Environment test | Out-Null
        Assert ((TaskCommand) -match 'tunnel.toany.net') "environment lost on $action"
    }
    Invoke-DDNSTOEntryCore -InstallDir $root -Action configure -Token new-owner -Environment test | Out-Null
    Assert ((TaskCommand) -match 'tunnel.toany.net') 'configure reset environment'
    Assert ([IO.File]::ReadAllText($cfg).Contains("userToken: 'new-owner'")) 'configure failed'
    $goodConfig=[IO.File]::ReadAllText($cfg)
    $before=$script:stops
    foreach ($bad in @("bootConfigPath: 'elsewhere'", "'bootConfigPath': 'elsewhere'", '"bootConfigPath": "elsewhere"', '{"bootConfigPath":"elsewhere"}', "remoteAddr: 'custom:4445'", 'serverAddr: custom', 'serverAssignment: {}', 'serverDomain: custom', 'controlWssURLs: []', 'publicWssURLs: []')) {
        [IO.File]::WriteAllText($cfg, $goodConfig+"`n"+$bad+"`n")
        Fails { Invoke-DDNSTOInstall -InstallDir $root -Action update -Environment test } 'E_ENV_UNKNOWN'
    }
    Assert ($script:stops -eq $before) 'unknown config stopped service'
    [IO.File]::WriteAllText($cfg, $goodConfig.Replace('=test', '=production'))
    Fails { Invoke-DDNSTOInstall -InstallDir $root -Action update } 'task does not match'
    [IO.File]::WriteAllText($cfg, $goodConfig)
    Invoke-DDNSTOEntryCore -InstallDir $root -Action uninstall -Environment test | Out-Null
    Invoke-DDNSTOInstall -InstallDir $root -Token new-owner -Environment test | Out-Null
    Assert ((TaskCommand) -match 'tunnel.toany.net') 'retained reinstall lost environment'
    Invoke-DDNSTOInstall -InstallDir $root -Token new-owner -Environment production -SwitchEnvironment | Out-Null
    Assert ((TaskCommand) -match 'tunnel.kooldns.cn') 'switch back failed'
    # Real stop helper: task stopped but its child survives. Never kill by name.
    function Stop-ScheduledTask { $script:task.State='Ready' }
    function Start-Sleep {}
    function Get-CimInstance {
        if ($script:orphan) { [pscustomobject]@{ProcessId=123;ExecutablePath=(Join-Path $root 'ddnsto_cli.x86_64.exe')} }
    }
    $script:orphan=$true
    Fails { & $realStop } 'old task/client did not stop'
    $script:orphan=$false
    & $realStop
    # Missing environment records default to production, with or without boot data.
    [IO.File]::WriteAllText($cfg, "userToken: 'new-owner'`n")
    $script:task=[pscustomobject]@{State='Running'; Actions=@([pscustomobject]@{Execute=(Join-Path $root 'ddnsto_cli.x86_64.exe');Arguments=('--config "'+$cfg+'"');WorkingDirectory=$root})}
    $before=$script:stops
    $legacyConfig=[IO.File]::ReadAllText($cfg)
    foreach ($hasIdentity in @($true, $false)) {
        if (-not $hasIdentity) { Remove-Item -LiteralPath $identity -Force }
        Invoke-DDNSTOInstall -InstallDir $root -Action update | Out-Null
        Invoke-DDNSTOInstall -InstallDir $root -Token new-owner | Out-Null
        Fails { Invoke-DDNSTOInstall -InstallDir $root -Action update -Environment test } 'E_ENV_MISMATCH'
    }
    Assert ($script:stops -eq $before) 'same-version legacy service was stopped'
    Assert ([IO.File]::ReadAllText($cfg) -ceq $legacyConfig) 'same-version legacy config was rewritten'
    # Environment detection is not a whole-YAML validator; ownership stays strict.
    [IO.File]::WriteAllText($cfg, $legacyConfig+"---`noptions:`n  values: [one, two]`n")
    Invoke-DDNSTOInstall -InstallDir $root -Action update | Out-Null
    Fails { Invoke-DDNSTOInstall -InstallDir $root -Token new-owner } '归属|YAML'
    [IO.File]::WriteAllText($cfg, $legacyConfig)
    Fails { Invoke-DDNSTOInstall -InstallDir $root -Token wrong-owner } 'Token 不同'
    $ownedArguments=$script:task.Actions[0].Arguments
    $script:task.Actions[0].Arguments+=' --extra'
    Fails { Invoke-DDNSTOInstall -InstallDir $root -Action update } 'task does not match'
    $script:task.Actions[0].Arguments=$ownedArguments
    Assert ($script:stops -eq $before) 'ownership refusal stopped service'
    Assert (-not (Test-Path -LiteralPath (Join-Path $root '.install-lock'))) 'transaction lock leaked'
    Invoke-DDNSTOInstall -InstallDir $root -Action update -Environment test -SwitchEnvironment | Out-Null
    Assert ((TaskCommand) -match 'tunnel.toany.net') 'legacy explicit switch failed'
    $script:task=$null
    $freshRoot=Join-Path $root 'fresh-test'
    Invoke-DDNSTOInstall -InstallDir $freshRoot -Token owner -Environment test | Out-Null
    Assert ((TaskCommand) -match 'tunnel.toany.net:4445') 'fresh test install did not persist environment'
    Assert ((Get-DDNSTORecordedEnvironment (Join-Path $freshRoot 'ddnsto.yaml')) -eq 'test') 'fresh test record missing'
    Write-Output 'Windows environment fixtures passed (not real SYSTEM/task/network acceptance)'
} finally {
    $env:DDNSTO_TEST_SERVER_ASSIGNMENT_JSON=$originalAmbient
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
