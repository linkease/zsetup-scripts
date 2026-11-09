$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Assert($Ok,$Message) { if (-not $Ok) { throw $Message } }
$root=Join-Path ([IO.Path]::GetTempPath()) ('ddnsto-diagnostics-test-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
function Get-DDNSTODiagnosticBase { return $root }
# Only the Windows atomic ACL syscall is replaced on Linux; real file handles,
# event serialization, entry failure handling and collision checks run below.
function New-DDNSTOPrivateDiagnosticDirectory($Path) {
    if ($script:deny) { throw 'sensitive ACL failure' }
    New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    if ($script:collision) { [IO.File]::WriteAllText((Join-Path $Path 'events.jsonl'),'do-not-overwrite') }
}
function Invoke-DDNSTOInstall {
    Write-DDNSTODiagnosticEvent 'download'
    Write-DDNSTODiagnosticEvent 'secret-token config-content raw-exception'
    Write-DDNSTODiagnosticEvent 'failed' 999
    if ($script:writeFail) { $script:DDNSTODiagnostic.Stream.Dispose() }
    if ($script:businessSuccess) { return 'business-success' }
    throw 'secret-token config-content raw-exception'
}
try {
    $script:deny=$false; $script:collision=$false; $script:businessSuccess=$false; $script:writeFail=$false
    for ($i=0; $i -lt 2; $i++) {
        $failed=$false
        try { Invoke-DDNSTOEntry -Token 'secret-token' | Out-Null } catch {
            $failed=$true
            Assert ($_.Exception.Data['DDNSTOCode'] -eq 2) 'original exit classification changed'
            Assert ($_.Exception.Message -match '诊断日志：') 'missing Chinese log pointer'
            Assert ($_.Exception.Message -notmatch 'secret-token|raw-exception|config-content') 'secret in error'
        }
        Assert $failed 'expected business failure'
    }
    $logs=@(Get-ChildItem $root -Recurse -Filter events.jsonl)
    Assert ($logs.Count -eq 2) 'each run needs a separate log'
    foreach ($log in $logs) {
        $text=[IO.File]::ReadAllText($log.FullName)
        Assert ($text -notmatch 'secret-token|raw-exception|config-content') 'secret in event log'
        $events=@([IO.File]::ReadAllLines($log.FullName) | ForEach-Object { $_ | ConvertFrom-Json })
        Assert (($events.event -join ',') -eq 'started,preflight,download,failed') 'missing structured events'
        Assert ($events[-1].code -eq 2) 'missing failure code'
        foreach ($event in $events) { Assert (($event.PSObject.Properties.Name -join ',') -eq 'time,event,code') 'unexpected log fields' }
        # The writer must close on failure.
        $handle=[IO.File]::Open($log.FullName,'Open','ReadWrite','None'); $handle.Dispose()
    }
    $script:collision=$true
    try { Invoke-DDNSTOEntry -Token 'secret-token' | Out-Null } catch { Assert ($_.Exception.Message -match '诊断日志不可用') 'collision must report unavailable log' }
    Assert (@(Get-ChildItem $root -Recurse -Filter events.jsonl | Where-Object { [IO.File]::ReadAllText($_.FullName) -ceq 'do-not-overwrite' }).Count -eq 1) 'existing log overwritten'
    $script:collision=$false; $script:deny=$true
    try { Invoke-DDNSTOEntry -Token 'secret-token' | Out-Null } catch { Assert ($_.Exception.Message -match '诊断日志不可用') 'ACL failure must be best effort' }
    $script:businessSuccess=$true
    Assert ((Invoke-DDNSTOEntry -Token 'secret-token') -eq 'business-success') 'logging failure broke successful action'
    $script:deny=$false
    Assert ((Invoke-DDNSTOEntry -Token 'secret-token') -eq 'business-success') 'logging changed business output'
    $successLogs=@(Get-ChildItem $root -Recurse -Filter events.jsonl | Where-Object { [IO.File]::ReadAllText($_.FullName) -match '"event":"succeeded"' })
    Assert ($successLogs.Count -eq 1) 'success event missing'
    $script:deny=$false; $script:businessSuccess=$false; $script:writeFail=$true
    try { Invoke-DDNSTOEntry -Token 'secret-token' | Out-Null } catch {
        Assert ($_.Exception.Data['DDNSTOCode'] -eq 2) 'log write failure masked business failure'
        Assert ($_.Exception.Message -match '记录可能不完整') 'partial log not reported'
    }
    $script:writeFail=$false
    $before=@(Get-ChildItem $root).Count
    function Get-DDNSTOHostArchitecture { return 'AMD64' }
    Invoke-DDNSTOEntry -Plan | Out-Null
    Assert (@(Get-ChildItem $root).Count -eq $before) 'plan created diagnostic files'
    $alias=Join-Path $root 'alias'
    New-Item -ItemType SymbolicLink -Path $alias -Target $root | Out-Null
    function Get-DDNSTODiagnosticBase { return $alias }
    try { Invoke-DDNSTOEntry -Token 'secret-token' | Out-Null } catch { Assert ($_.Exception.Message -match '诊断日志不可用') 'reparse parent accepted' }
    Remove-Item -LiteralPath $alias -Force
    function Get-DDNSTODiagnosticBase { return $root }
    function Invoke-DDNSTOInstall { Stop-DDNSTOError 3 '测试拒绝' '未修改' '核对账号' }
    try { Invoke-DDNSTOEntry -Token 'secret-token' | Out-Null } catch { Assert ($_.Exception.Data['DDNSTOCode'] -eq 3) 'known failure code lost' }
    Assert (@(Get-ChildItem $root -Recurse -Filter events.jsonl | Where-Object { [IO.File]::ReadAllText($_.FullName) -match '"event":"failed","code":3' }).Count -eq 1) 'known failure event missing'
    Write-Output 'Windows diagnostics: per-run events, redaction, collisions, failure isolation, handles, plan and reparse guard passed'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
