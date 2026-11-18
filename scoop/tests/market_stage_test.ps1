param([Parameter(Mandatory=$true)][string]$Business,[Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop'
. $Business
$root=Join-Path $TestRoot 'owned';$work=Join-Path $TestRoot 'stage'
New-Item -ItemType Directory -Path (Join-Path $root 'shims'),$work -Force | Out-Null
Write-ScoopJson (Join-Path $root '.linkease-scoop-receipt.json') @{owner='linkease-zsetup'}
New-Item -ItemType Directory -Path (Join-Path $root 'buckets\main') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $root 'buckets\main\keep.json'),'bucket state',[Text.UTF8Encoding]::new($false))
$shim=Join-Path $root 'shims\existing-tool.cmd'
[IO.File]::WriteAllText($shim,'existing shim',[Text.UTF8Encoding]::new($false))
# This isolates the owned-tree transaction. Archive/network behavior has its own
# native tests; these fixture bytes are never claimed as installed software.
function Expand-VerifiedScoopArchive([string]$Archive,[string]$Destination,[string]$Prefix,[long]$Size,[string]$Sha256) {New-Item -ItemType Directory -Path $Destination -Force | Out-Null}
$stage=New-ScoopStage $root $work @{Core='fixture';Main='fixture';Transport='fixture'}
$copied=Join-Path $stage.path 'shims\existing-tool.cmd'
if(!(Test-Path -LiteralPath $copied) -or [IO.File]::ReadAllText($copied) -cne 'existing shim'){throw 'Managed Scoop upgrade removed an installed application shim'}
if(!(Test-Path -LiteralPath (Join-Path $stage.path 'buckets\main\keep.json'))){throw 'Managed Scoop upgrade replaced the existing main bucket'}
'{"status":"passed","evidenceKind":"native-powershell-fixture","check":"owned-shim-preservation"}'
