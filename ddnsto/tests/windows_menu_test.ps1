$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Assert($Ok, $Message) { if (-not $Ok) { throw $Message } }
function Assert-DDNSTOPlatform {}
function Test-DDNSTOInteractive { return $true }
function Read-Host($Prompt, [switch]$AsSecureString) {
    Assert (-not $AsSecureString) 'Token must be visible'
    if ($Prompt -match 'token') { return 'menu-secret' }
    return $script:choice
}
function Invoke-DDNSTOEntry($Action, $InstallDir, $Token) {
    Assert ($InstallDir -eq $root) 'menu lost installation directory'
    if ($Action -eq 'configure') { Assert ($Token -eq 'menu-secret') 'menu did not collect credentials' }
    elseif ($Token) { throw 'unexpected menu credentials' }
    return $Action
}
function Receive-DDNSTOCandidate { throw 'unexpected download' }
function Get-DDNSTOTask { return $script:task }
$root = Join-Path ([IO.Path]::GetTempPath()) ('ddnsto-menu-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $root '.installer-windows-v1'), 'ddnsto-windows-v1')
    [IO.File]::WriteAllText((Join-Path $root 'ddnsto.yaml'), "userToken: 'old'")
    [IO.File]::WriteAllText((Join-Path $root 'ddnsto_cli.x86_64.exe'), 'binary')
    $script:task = [pscustomobject]@{ State='Running'; Actions=@([pscustomobject]@{
        Execute=(Join-Path $root 'ddnsto_cli.x86_64.exe'); Arguments=('--config "' + (Join-Path $root 'ddnsto.yaml') + '"'); WorkingDirectory=$root
    }) }
    $choices = @{'2'='status'; '3'='start'; '4'='stop'; '5'='restart'; '6'='repair'; '7'='configure'; '8'='uninstall'}
    foreach ($key in $choices.Keys) {
        $script:choice = $key
        Assert ((Invoke-DDNSTOInstall -InstallDir $root) -eq $choices[$key]) "menu choice $key not dispatched"
    }
    foreach ($script:choice in @('', '0')) {
        Assert (((Invoke-DDNSTOInstall -InstallDir $root) -join "`n") -match 'operation=none') 'default must exit'
    }
    $script:choice = 'bad'; $failed = $false
    try { Invoke-DDNSTOInstall -InstallDir $root | Out-Null } catch { $failed = $true }
    Assert $failed 'invalid menu accepted'
    Assert ((Read-DDNSTOToken) -eq 'menu-secret') 'visible Token input missing'
    Write-Output 'Windows menu: explicit actions, default exit and visible Token input passed'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
