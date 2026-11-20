$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
. (Join-Path $PSScriptRoot 'windows_task_fixture.ps1')
function Assert($Ok,$Message) { if (-not $Ok) { throw $Message } }
function Start-Sleep { $script:sample++ }
function Get-DDNSTOTask { [pscustomobject]@{State='Running'; Actions=@(New-DDNSTOFixtureAction $binary (Join-Path $root 'ddnsto.yaml') $root)} }
function Get-CimInstance {
    param($ClassName,$Filter,$Property,$ErrorAction)
    Assert ($Property -notcontains 'CommandLine') 'must not collect command-line secrets'
    $id=42; $created=[datetime]'2026-01-01'; $path=$binary
    switch ($script:scenario) {
        'respawn' { $id += $script:sample }
        'pid-reuse' { $created=$created.AddSeconds($script:sample) }
        'foreign' { $path=$binary+'.foreign' }
        'missing' { return }
        'unknown-time' { $created=$null }
        'denied' { throw 'sensitive exception must not reach output' }
    }
    $p=[pscustomobject]@{ProcessId=$id; CreationDate=$created; ExecutablePath=$path}
    $p
    if ($script:scenario -eq 'duplicates') { $p }
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ddnsto-stability-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
$binary=Join-Path $root 'ddnsto_cli.x86_64.exe'
try {
[IO.File]::WriteAllText((Join-Path $root 'ddnsto.yaml'), "# ddnsto-business-environment-v1=production`nuserToken: 'fixture'`n")
foreach ($script:scenario in @('stable','respawn','pid-reuse','foreign','missing','unknown-time','denied','duplicates')) {
    $script:sample=0; $failed=$false
    try { Confirm-DDNSTORunning $binary } catch { $failed=$true }
    Assert ($failed -eq ($script:scenario -ne 'stable')) "stability result wrong: $script:scenario"
}
Write-Output 'Windows stability: path, PID, creation time, respawn, inaccessible and ambiguous processes passed'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
