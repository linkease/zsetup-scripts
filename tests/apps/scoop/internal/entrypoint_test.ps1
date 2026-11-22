param(
    [Parameter(Mandatory = $true)][string]$Entry,
    [Parameter(Mandatory = $true)][string]$Zsetup
)

$ErrorActionPreference = 'Stop'
$env:ZSETUP_INSTALLER_MODE = '1'
$env:ZSETUP_BIN = $Zsetup
$output = (& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Entry --explain --json -- alpha beta) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "generated entry exited $LASTEXITCODE" }
if (-not $output) { throw 'generated entry swallowed the business JSON output' }
$plan = $output | ConvertFrom-Json
if ($plan.schema_version -ne 1 -or $plan.milestone -ne 'M5' -or $plan.executable -ne $false) {
    throw 'generated entry returned an unexpected plan'
}
if (@($plan.arguments).Count -ne 2 -or $plan.arguments[0] -cne 'alpha' -or $plan.arguments[1] -cne 'beta') {
    throw 'generated entry changed literal arguments'
}
