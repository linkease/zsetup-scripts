$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Assert($Ok, $Message) { if (-not $Ok) { throw $Message } }
Assert ([bool](Get-Command Invoke-DDNSTOEntry -ErrorAction SilentlyContinue)) 'missing unified Windows entry'
function Get-DDNSTOHostArchitecture { return 'AMD64' }
function Invoke-DDNSTOInstall { throw 'MUTATION: plan called installer' }
$result = Invoke-DDNSTOEntry -Plan -Platform windows -Method native
Assert (($result -join "`n") -match 'installation_performed=false') 'plan performed installation'
Assert (($result -join "`n") -match 'client_version=4.2.1') 'missing pinned version'
Assert (($result -join "`n") -match 'platform=windows') 'missing platform'
foreach ($case in @(
    @{Platform='linux'}, @{Method='docker'}, @{Method='typo'},
    @{Token='never-print-this'}, @{TokenFile='does-not-exist'}, @{Version='999'}
)) {
    $failed = $false
    try { Invoke-DDNSTOEntry -Plan @case | Out-Null } catch {
        $failed = $true
        Assert ($_.ToString() -notmatch 'MUTATION|never-print-this') 'plan leaked credentials or invoked installation'
    }
    Assert $failed 'invalid plan accepted'
}
function Get-DDNSTOHostArchitecture { return 'ARM64' }
$failed = $false
try { Invoke-DDNSTOEntry -Plan | Out-Null } catch { $failed = $true }
Assert $failed 'unpublished Windows architecture accepted'
Write-Output 'Windows plan: preview, target/method/version/credentials and architecture checks passed'
