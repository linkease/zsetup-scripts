# Tests DDNSTO delegation to the shared latest-stable Windows bootstrap.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Assert($Ok, $Message) { if (-not $Ok) { throw $Message } }

Assert ([bool](Get-Command Get-DDNSTOZsetup -ErrorAction SilentlyContinue)) 'missing DDNSTO bootstrap adapter'
Assert ([bool](Get-Command Get-ZsetupBootstrap -ErrorAction SilentlyContinue)) 'missing shared bootstrap'
$root = Join-Path ([IO.Path]::GetTempPath()) ('ddnsto-bootstrap-' + [guid]::NewGuid().ToString('N'))
$script:BootstrapCalled = $false
function Get-ZsetupBootstrap {
    $script:BootstrapCalled = $true
    return (Join-Path $root 'latest-stable-zsetup.exe')
}
$native = Get-DDNSTOZsetup $root
Assert $script:BootstrapCalled 'DDNSTO did not delegate to the shared bootstrap'
Assert ($native -eq (Join-Path $root 'latest-stable-zsetup.exe')) 'DDNSTO rewrote the shared selection'

function Get-ZsetupBootstrap { throw 'fixture stable channel unavailable' }
$failed = $false
try { Get-DDNSTOZsetup $root | Out-Null } catch { $failed = $true }
Assert $failed 'shared bootstrap failure must stop DDNSTO'
Write-Output 'Windows bootstrap: latest stable delegation and failure propagation passed'
