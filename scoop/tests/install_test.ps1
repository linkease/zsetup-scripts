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
    } catch { $failed = $_.Exception.Message -match 'fault injection' }
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

$second = (Invoke-ScoopBusiness -InstallerArguments $arguments) | ConvertFrom-Json
Assert-True ($second.status -eq 'passed' -and $second.idempotent -eq $true) 'repeat install was not idempotent'
Assert-True ($script:FixtureUserPath.Split(';')[0] -eq (Join-Path $root 'shims')) 'repeat install duplicated or reordered PATH'

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
    rollback_faults = @('after-stage', 'after-root-swap', 'after-config', 'after-path')
    unowned_rejected = $true
    root = $root
    cache = $cache
} | ConvertTo-Json -Depth 10
