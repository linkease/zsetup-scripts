param(
    [Parameter(Mandatory = $true)][string]$Business,
    [Parameter(Mandatory = $true)][string]$SealedBundle,
    [Parameter(Mandatory = $true)][string]$TestRoot,
    [Parameter(Mandatory = $true)][string]$Zsetup
)

$ErrorActionPreference = 'Stop'
. $Business

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$profile = Join-Path $TestRoot 'profile'
$root = Join-Path $profile 'installed scoop'
$cache = Join-Path $profile 'cache unicode'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$env:USERPROFILE = $profile
$env:ZSETUP_BIN = $Zsetup
$env:ZSETUP_INSTALLER_MODE = '1'
Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue

# The real elevated token must be rejected before a target or staging write.
$rejected = $false
try {
    Invoke-ScoopBusiness -InstallerArguments @('--installer-scope', 'user', '--installer-root', $root, '--installer-cache', $cache, '--installer-bundle', $SealedBundle) | Out-Null
} catch { $rejected = $_.Exception.Message -match 'administrator|elevated' }
Assert-True $rejected 'elevated invocation was not rejected'
Assert-True (-not (Test-Path -LiteralPath $root)) 'elevated rejection wrote the target root'

# Isolate registry PATH while exercising the real filesystem transaction.
$script:FixtureUserPath = 'C:\fixture-bin'
function Test-ScoopAdministrator { return $false }
function Get-ScoopUserPath { return $script:FixtureUserPath }
function Set-ScoopUserPath([string]$Value) { $script:FixtureUserPath = $Value }

$configPath = Join-Path $profile '.config\scoop\config.json'
foreach ($fault in @('after-stage', 'after-root-swap', 'after-config', 'after-path')) {
    $faultRoot = Join-Path $profile ("fault " + $fault)
    $faultCache = Join-Path $profile ("fault-cache " + $fault)
    $script:FixtureUserPath = 'C:\fixture-bin'
    $env:ZSETUP_SCOOP_FAIL_AFTER = $fault
    $failed = $false
    try {
        Invoke-ScoopBusiness -InstallerArguments @('--installer-scope', 'user', '--installer-root', $faultRoot, '--installer-cache', $faultCache, '--installer-bundle', $SealedBundle) | Out-Null
    } catch {
        $failed = $_.Exception.Message -match 'fault injection'
        if (-not $failed) { throw ("unexpected failure before " + $fault + ': ' + $_.Exception.Message) }
    }
    Assert-True $failed ("fault point was not triggered: " + $fault)
    Assert-True (-not (Test-Path -LiteralPath $faultRoot)) ("root was not rolled back: " + $fault)
    Assert-True (-not (Test-Path -LiteralPath $configPath)) ("config was not rolled back: " + $fault)
    Assert-True ($script:FixtureUserPath -eq 'C:\fixture-bin') ("PATH was not rolled back: " + $fault)
}
Remove-Item Env:ZSETUP_SCOOP_FAIL_AFTER -ErrorAction SilentlyContinue

$arguments = @('--installer-scope', 'user', '--installer-root', $root, '--installer-cache', $cache, '--installer-bundle', $SealedBundle)
$first = (Invoke-ScoopBusiness -InstallerArguments $arguments) | ConvertFrom-Json
Assert-True ($first.status -eq 'passed' -and $first.transport -eq 'sealed-bundle') 'sealed install did not pass'
Assert-True (Test-Path -LiteralPath (Join-Path $root 'apps\scoop\current\bin\scoop.ps1') -PathType Leaf) 'Scoop core missing'
Assert-True (Test-Path -LiteralPath (Join-Path $root 'buckets\main\bucket\7zip.json') -PathType Leaf) 'main bucket missing'
Assert-True (Test-Path -LiteralPath (Join-Path $root 'shims\scoop.ps1') -PathType Leaf) 'PowerShell shim missing'
Assert-True (Test-Path -LiteralPath (Join-Path $root 'shims\scoop.cmd') -PathType Leaf) 'cmd shim missing'
Assert-True (Test-Path -LiteralPath (Join-Path $root '.linkease-scoop-receipt.json') -PathType Leaf) 'owned receipt missing'
Assert-True ($script:FixtureUserPath.StartsWith((Join-Path $root 'shims') + ';')) 'user PATH was not updated through the seam'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
Assert-True ($config.root_path -eq $root -and $config.cache_path -eq $cache) 'Scoop config paths mismatch'
$versionOutput = @(& (Join-Path $root 'shims\scoop.ps1') --version *>&1)
Assert-True (($versionOutput -join "`n") -match 'Current Scoop version:') ('scoop --version failed: ' + ($versionOutput -join ' | '))

$second = (Invoke-ScoopBusiness -InstallerArguments $arguments) | ConvertFrom-Json
Assert-True ($second.status -eq 'passed' -and $second.idempotent -eq $true) 'repeat install was not idempotent'
Assert-True ($script:FixtureUserPath.Split(';')[0] -eq (Join-Path $root 'shims')) 'repeat install duplicated or reordered PATH'

# A managed 0.1.0 receipt must enter the transaction, preserve unrelated Scoop
# state, roll back exactly on failure, then become an idempotent 0.1.1 install.
$receiptPath = Join-Path $root '.linkease-scoop-receipt.json'
$oldReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
$oldReceipt.installer_version = '0.1.0'
Write-ScoopJson $receiptPath $oldReceipt
$appMarker = Join-Path $root 'apps\fixture\1.0.0\keep.txt'
$bucketMarker = Join-Path $root 'buckets\fixture\keep.txt'
$persistMarker = Join-Path $root 'persist\fixture\state\keep.txt'
$persistJunction = Join-Path $root 'apps\fixture\1.0.0\state'
New-Item -ItemType Directory -Path (Split-Path -Parent $appMarker), (Split-Path -Parent $bucketMarker) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $persistMarker) -Force | Out-Null
[IO.File]::WriteAllText($appMarker, 'keep-app', $script:ScoopUtf8)
[IO.File]::WriteAllText($bucketMarker, 'keep-bucket', $script:ScoopUtf8)
[IO.File]::WriteAllText($persistMarker, 'keep-persist', $script:ScoopUtf8)
New-Item -ItemType Junction -Path $persistJunction -Target (Split-Path -Parent $persistMarker) | Out-Null
$env:ZSETUP_SCOOP_FAIL_AFTER = 'after-root-swap'
$upgradeFailed = $false
try { Invoke-ScoopBusiness -InstallerArguments $arguments | Out-Null } catch {
    $upgradeFailed = $_.Exception.Message -match 'fault injection'
    if (-not $upgradeFailed) { throw }
}
Remove-Item Env:ZSETUP_SCOOP_FAIL_AFTER -ErrorAction SilentlyContinue
Assert-True $upgradeFailed '0.1.0 upgrade fault was not triggered'
$rolledBackReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
Assert-True ($rolledBackReceipt.installer_version -eq '0.1.0') 'failed upgrade did not restore the 0.1.0 receipt'
Assert-True ((Get-Content -LiteralPath $appMarker -Raw) -eq 'keep-app') 'failed upgrade changed an installed app'
Assert-True ((Get-Content -LiteralPath $bucketMarker -Raw) -eq 'keep-bucket') 'failed upgrade changed an unrelated bucket'
Assert-True ((Get-Content -LiteralPath (Join-Path $persistJunction 'keep.txt') -Raw) -eq 'keep-persist') 'failed upgrade changed a persisted junction'

$upgrade = (Invoke-ScoopBusiness -InstallerArguments $arguments) | ConvertFrom-Json
Assert-True ($upgrade.status -eq 'passed' -and $upgrade.idempotent -eq $false) '0.1.0 to 0.1.1 upgrade did not transact'
$upgradedReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
Assert-True ($upgradedReceipt.installer_version -eq '0.1.1') 'upgrade receipt did not become 0.1.1'
Assert-True ((Get-Content -LiteralPath $appMarker -Raw) -eq 'keep-app') 'upgrade changed an installed app'
Assert-True ((Get-Content -LiteralPath $bucketMarker -Raw) -eq 'keep-bucket') 'upgrade changed an unrelated bucket'
$upgradedJunction = Get-Item -LiteralPath $persistJunction -Force
Assert-True ($upgradedJunction.LinkType -eq 'Junction') 'upgrade did not preserve the persisted junction type'
Assert-True (@($upgradedJunction.Target).Count -eq 1 -and [IO.Path]::GetFullPath([string]$upgradedJunction.Target[0]) -eq [IO.Path]::GetFullPath((Split-Path -Parent $persistMarker))) 'upgrade changed the persisted junction target'
Assert-True ((Get-Content -LiteralPath (Join-Path $persistJunction 'keep.txt') -Raw) -eq 'keep-persist') 'upgrade changed persisted data'

$outside = Join-Path $profile 'outside junction target'
$outsideMarker = Join-Path $outside 'keep.txt'
$outsideJunction = Join-Path $root 'apps\fixture\1.0.0\outside'
$securityStage = Join-Path $profile 'security stage'
New-Item -ItemType Directory -Path $outside, $securityStage -Force | Out-Null
[IO.File]::WriteAllText($outsideMarker, 'outside-keep', $script:ScoopUtf8)
New-Item -ItemType Junction -Path $outsideJunction -Target $outside | Out-Null
$outsideRejected = $false
try { Copy-ScoopOwnedTree $root $securityStage | Out-Null } catch { $outsideRejected = $_.Exception.Message -match 'outside the owned root' }
if (Test-Path -LiteralPath $outsideJunction) { [IO.Directory]::Delete($outsideJunction) }
Remove-Item -LiteralPath $securityStage -Recurse -Force -ErrorAction SilentlyContinue
Assert-True $outsideRejected 'upgrade copy accepted a junction outside the owned root'
Assert-True ((Get-Content -LiteralPath $outsideMarker -Raw) -eq 'outside-keep') 'rejected junction changed outside data'

$third = (Invoke-ScoopBusiness -InstallerArguments $arguments) | ConvertFrom-Json
Assert-True ($third.status -eq 'passed' -and $third.idempotent -eq $true) 'upgraded 0.1.1 install was not idempotent'

$unowned = Join-Path $profile 'unowned scoop'
New-Item -ItemType Directory -Path $unowned -Force | Out-Null
Set-Content -LiteralPath (Join-Path $unowned 'foreign.txt') -Value 'foreign'
$unownedRejected = $false
try {
    Invoke-ScoopBusiness -InstallerArguments @('--installer-scope', 'user', '--installer-root', $unowned, '--installer-cache', $cache, '--installer-bundle', $SealedBundle) | Out-Null
} catch { $unownedRejected = $_.Exception.Message -match 'unowned' }
Assert-True $unownedRejected 'non-empty unowned installation was not rejected'
Assert-True ((Get-Content -LiteralPath (Join-Path $unowned 'foreign.txt') -Raw).Trim() -eq 'foreign') 'unowned content was changed'

[ordered]@{
    schema_version = 1
    status = 'passed'
    elevated_rejected_before_write = $true
    sealed_install = $first
    repeat_install = $second
    upgrade_install = $upgrade
    rollback_faults = @('after-stage', 'after-root-swap', 'after-config', 'after-path')
    unowned_rejected = $true
    root = $root
    cache = $cache
} | ConvertTo-Json -Depth 10
