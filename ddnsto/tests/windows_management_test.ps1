$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Assert($Ok, $Message) { if (-not $Ok) { throw $Message } }
function Assert-DDNSTOPlatform {}
function Receive-DDNSTOCandidate { throw 'unexpected download' }
function Invoke-DDNSTOInstall { throw 'unexpected installation' }
function Get-DDNSTOTask { return $script:task }
function Disable-ScheduledTask { $script:enabled = $false }
function Enable-ScheduledTask { $script:enabled = $true }
function Stop-DDNSTOTask { $script:task.State = 'Ready' }
function Start-DDNSTOTask { $script:task.State = 'Running' }
function Confirm-DDNSTORunning { Assert ($script:task.State -eq 'Running') 'not running' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('ddnsto-manage-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $root '.installer-windows-v1'), 'ddnsto-windows-v1')
    foreach ($name in @('ddnsto_cli.x86_64.exe', 'ddnsto.yaml')) {
        [IO.File]::WriteAllText((Join-Path $root $name), 'unchanged')
    }
    $script:task = [pscustomobject]@{ State = 'Running'; Actions = @([pscustomobject]@{
        Execute = (Join-Path $root 'ddnsto_cli.x86_64.exe')
        Arguments = ('--config "' + (Join-Path $root 'ddnsto.yaml') + '"')
        WorkingDirectory = $root
    }) }
    $script:enabled = $true
    foreach ($action in @('status', 'stop', 'start', 'restart')) {
        $result = Invoke-DDNSTOEntry -Action $action -InstallDir $root
        Assert (($result -join "`n") -match 'cloud_status=unverified') 'missing independent cloud status'
        Assert ($script:enabled -eq ($action -ne 'stop')) 'wrong startup state'
        Assert (([IO.File]::ReadAllText((Join-Path $root 'ddnsto.yaml'))) -eq 'unchanged') 'changed config'
    }
    foreach ($args in @(@{TokenFile='missing'}, @{Plan=$true}, @{Method='docker'})) {
        $failed = $false
        try { Invoke-DDNSTOEntry -Action status -InstallDir $root @args | Out-Null } catch { $failed = $true }
        Assert $failed 'invalid management arguments accepted'
    }
    $lockPath = Join-Path $root '.install-lock'
    [IO.File]::WriteAllText($lockPath, 'other owner')
    $failed = $false
    try { Invoke-DDNSTOEntry -Action stop -InstallDir $root | Out-Null } catch { $failed = $true }
    Assert $failed 'ignored installation lock'
    Assert (([IO.File]::ReadAllText($lockPath)) -eq 'other owner') 'removed foreign lock'
    Remove-Item -LiteralPath $lockPath -Force
    $script:task.Actions[0].Execute = 'unmanaged.exe'
    $failed = $false
    try { Invoke-DDNSTOEntry -Action stop -InstallDir $root | Out-Null } catch { $failed = $true }
    Assert $failed 'managed unrelated task'
    Write-Output 'Windows management: lifecycle, config preservation, arguments, lock and ownership passed'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
