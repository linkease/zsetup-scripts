param([Parameter(Mandatory=$true)][string]$OwnerRoot,[Parameter(Mandatory=$true)][string]$NativeVersions)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('software-inspect-'+[Guid]::NewGuid().ToString('N'))
$originalScoop=$env:SCOOP;$originalPrefix=$env:TEST_PREFIX
try {
    $core=Join-Path $fixture 'apps/scoop/current'
    $selected=Join-Path $fixture 'apps/sample-tool/1.0.0'
    New-Item -ItemType Directory -Force -Path (Join-Path $core 'bin'),(Join-Path $core 'lib'),$selected|Out-Null
    Copy-Item -LiteralPath $NativeVersions -Destination (Join-Path $core 'lib/versions.ps1')
    $fake=@'
param([string]$Operation,[string]$Name)
if($Operation -eq 'info'){
 [pscustomobject]@{Name=$Name;Version='2.0.0';Source='main';Installed="0.9.0`n1.0.0";Description='private-output-sentinel'}
} elseif($Operation -eq 'prefix'){
 Write-Output $env:TEST_PREFIX
 exit 0
} else {exit 37}
'@
    [IO.File]::WriteAllText((Join-Path $core 'bin/scoop.ps1'),$fake,(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $selected 'manifest.json'),'{"version":"1.0.0"}',(New-Object Text.UTF8Encoding($false)))
    $env:SCOOP=$fixture;$env:TEST_PREFIX=$selected
    $native=Join-Path $PSHOME 'powershell.exe'
    $entry=Join-Path $OwnerRoot 'native-windows.ps1'
    $json='{"software":"sample-tool","provider":"scoop"}'|& $native -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry
    if($LASTEXITCODE -ne 0){throw "query failed: $LASTEXITCODE"}
    $text=$json|Out-String;$r=$text|ConvertFrom-Json
    if($r.installedVersion -cne '1.0.0' -or $r.candidateVersion -cne '2.0.0' -or $r.comparison -cne 'candidate-newer'){throw 'native selected version or comparison is wrong'}
    if($text.Contains('private-output-sentinel')){throw 'arbitrary native output escaped into result'}
    if($r.source.freshness -cne 'cache-unverified'){throw 'cache was mislabeled live'}
    @{status='passed';cases=@('retained-versions-without-current-link','native-exit-isolation','native-version-comparison','bounded-selected-facts');businessMutation=$false}|ConvertTo-Json -Depth 4 -Compress
} finally {
    $env:SCOOP=$originalScoop;$env:TEST_PREFIX=$originalPrefix
    if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
exit 0
