# Tests bootstrap orchestration without executing a Windows PE on Linux.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Assert($Ok, $Message) { if (-not $Ok) { throw $Message } }
Assert ([bool](Get-Command Get-DDNSTOZsetup -ErrorAction SilentlyContinue)) 'missing automatic zsetup bootstrap'
function Receive-DDNSTOBootstrapFile($Url, $Destination) {
    $script:Urls += $Url
    [IO.File]::WriteAllText($Destination, 'native fixture')
}
function Get-FileHash($LiteralPath, $Algorithm) {
    $digest = if ($script:BadHash) { '0' * 64 } else { '858633b03f4808417bc4724f28e8ab0cb17c9f09fe4e665c9532f488cc1f83a3' }
    return [pscustomobject]@{ Hash = $digest }
}
function Get-DDNSTONativeVersion($Path) { $script:Executed = $true; return 'zsetup 0.4.0' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('ddnsto-bootstrap-' + [guid]::NewGuid().ToString('N'))
$savedNative = $env:ZSETUP_BIN
try {
    $env:ZSETUP_BIN = ''
    New-Item -ItemType Directory -Path $root | Out-Null
    $script:Urls = @()
    $script:BadHash = $false
    $script:Executed = $false
    $native = Get-DDNSTOZsetup $root
    Assert (Test-Path -LiteralPath $native) 'bootstrap did not provide native binary'
    Assert ($script:Executed) 'verified native version was not checked'
    Assert ($script:Urls[0] -match '/zsetup/0.4.0/zsetup-windows-i686.exe$') 'wrong native release'
    $script:BadHash = $true
    $script:Executed = $false
    $failed = $false
    try { Get-DDNSTOZsetup $root | Out-Null } catch { $failed = $true }
    Assert ($failed -and -not $script:Executed) 'checksum mismatch must not execute native'
    Write-Output 'Windows bootstrap: cold start and checksum rejection passed'
} finally {
    $env:ZSETUP_BIN = $savedNative
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
