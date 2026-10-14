# Engineering candidate. Automatic zsetup bootstrap; native canary pending.
param([string]$Token = '', [string]$TokenFile = '', [string]$Version = '4.2.1',
      [string]$InstallDir = "$env:ProgramData\DDNSTO")
$ErrorActionPreference = 'Stop'
$script:DDNSTOTaskName = 'DDNSTO'

function Assert-DDNSTOPlatform {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'DDNSTO: Windows is required' }
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($arch -ne 'AMD64') { throw 'DDNSTO: this candidate requires Windows x64' }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'DDNSTO: run PowerShell as Administrator'
    }
    foreach ($name in @('Get-ScheduledTask', 'Register-ScheduledTask', 'Export-ScheduledTask', 'icacls.exe')) {
        Get-Command $name -ErrorAction Stop | Out-Null
    }
}
function Protect-DDNSTODirectory($Path) {
    # SID-based ACLs work on non-English Windows installations.
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'DDNSTO: could not protect installation directory' }
}
function Receive-DDNSTOBootstrapFile($Url, $Destination) {
    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
        # Disallow redirects, including HTTPS -> HTTP. Try the next HTTPS mirror.
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -MaximumRedirection 0 -TimeoutSec 120 | Out-Null
    } finally { [Net.ServicePointManager]::SecurityProtocol = $previousTls }
}
function Get-DDNSTONativeVersion($Path) {
    $version = & $Path --version
    if ($LASTEXITCODE -ne 0) { throw 'DDNSTO: zsetup version check failed' }
    return ($version -join "`n").Trim()
}
function Get-DDNSTOZsetup($Work) {
    if ($env:ZSETUP_BIN) {
        if ((Get-DDNSTONativeVersion $env:ZSETUP_BIN) -ne 'zsetup 0.4.0') { throw 'DDNSTO: explicit zsetup must be version 0.4.0' }
        return $env:ZSETUP_BIN
    }
    Write-Host 'DDNSTO: downloading and verifying zsetup 0.4.0...'
    $native = Join-Path $Work 'zsetup.exe'
    $partial = Join-Path $Work 'zsetup.part'
    $verified = $false
    foreach ($base in @('https://dl.istoreos.com/binary', 'https://fw.d4ctech.com/binary', 'https://fw20.koolcenter.com/binary', 'https://fw.koolcenter.com/binary')) {
        try {
            Receive-DDNSTOBootstrapFile "$base/zsetup/0.4.0/zsetup-windows-i686.exe" $partial
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine '858633b03f4808417bc4724f28e8ab0cb17c9f09fe4e665c9532f488cc1f83a3') { throw 'checksum mismatch' }
            $verified = $true
            break
        } catch { continue }
    }
    if (-not $verified) { throw 'DDNSTO: zsetup bootstrap download/checksum failed; old installation unchanged' }
    Move-Item -LiteralPath $partial -Destination $native -Force
    if ((Get-DDNSTONativeVersion $native) -ne 'zsetup 0.4.0') { throw 'DDNSTO: unexpected zsetup version' }
    return $native
}
function Receive-DDNSTOCandidate($Work, $Version) {
    $zsetup = Get-DDNSTOZsetup $Work
    $archive = Join-Path $Work 'client.zip'
    & $zsetup download -o $archive --sha256 bf77c4a16b6b1914a0015e3491b39649602ce767d908da73d06a9feb1b3455db "https://fw.koolcenter.com/binary/ddnsto/windows/ddnsto_windows_cli_$Version.zip" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'DDNSTO: zsetup download or checksum verification failed' }
    $extract = Join-Path $Work 'extract'
    Expand-Archive -LiteralPath $archive -DestinationPath $extract
    $candidate = Join-Path $extract 'ddnsto_cli.x86_64.exe'
    if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ine 'd606a3501b594beb1cab912f87bddc741119e54cc07645cb4c2a741c9f9a6946') {
        throw 'DDNSTO: client checksum mismatch'
    }
    return $candidate
}
function Get-DDNSTOTask { return Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName -eq $script:DDNSTOTaskName } }
function Export-DDNSTOTask { return Export-ScheduledTask -TaskPath '\' -TaskName $script:DDNSTOTaskName }
function Stop-DDNSTOTask {
    Stop-ScheduledTask -TaskPath '\' -TaskName $script:DDNSTOTaskName
    for ($i = 0; $i -lt 20; $i++) {
        if ((Get-DDNSTOTask).State -ne 'Running') { return }
        Start-Sleep -Milliseconds 250
    }
    throw 'DDNSTO: old task did not stop'
}
function Remove-DDNSTOTask {
    if (Get-DDNSTOTask) { Unregister-ScheduledTask -TaskPath '\' -TaskName $script:DDNSTOTaskName -Confirm:$false }
}
function Register-DDNSTOTask($Binary, $Config, $Directory) {
    $action = New-ScheduledTaskAction -Execute $Binary -Argument ('--config "' + $Config + '"') -WorkingDirectory $Directory
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskPath '\' -TaskName $script:DDNSTOTaskName -Action $action -Principal $principal -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings -Force | Out-Null
}
function Restore-DDNSTOTask($Xml) { Register-ScheduledTask -TaskPath '\' -TaskName $script:DDNSTOTaskName -Xml $Xml -Force | Out-Null }
function Start-DDNSTOTask { Start-ScheduledTask -TaskPath '\' -TaskName $script:DDNSTOTaskName }
function Confirm-DDNSTORunning {
    for ($i = 0; $i -lt 3; $i++) {
        Start-Sleep -Seconds 1
        if ((Get-DDNSTOTask).State -ne 'Running') { throw 'DDNSTO: task did not remain running' }
    }
}
function Read-DDNSTOToken {
    if ([Console]::IsInputRedirected) { throw 'DDNSTO: token required; use an interactive terminal or -TokenFile FILE' }
    $secret = Read-Host 'DDNSTO token (paste from console)' -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        $secret.Dispose()
    }
}
function Invoke-DDNSTOInstall {
    param([string]$Token = '', [string]$TokenFile = '', [string]$Version = '4.2.1', [string]$InstallDir)
    Assert-DDNSTOPlatform
    if ($Version -ne '4.2.1') { throw 'DDNSTO: no pinned artifact for requested version' }
    if (-not [IO.Path]::IsPathRooted($InstallDir)) { throw 'DDNSTO: installation path must be absolute' }
    if ($TokenFile) {
        if ($Token) { throw 'DDNSTO: choose Token or TokenFile' }
        $Token = [IO.File]::ReadAllText($TokenFile)
        $Token = $Token -replace '\r?\n$', ''
    }
    if ($Token.Contains("`r") -or $Token.Contains("`n")) { throw 'DDNSTO: token must be one line' }
    $binary = Join-Path $InstallDir 'ddnsto_cli.x86_64.exe'
    $config = Join-Path $InstallDir 'ddnsto.yaml'
    $marker = Join-Path $InstallDir '.installer-windows-v1'
    foreach ($path in @($InstallDir, $binary, $config, $marker)) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'DDNSTO: reparse points are not supported' }
    }
    $oldTask = Get-DDNSTOTask
    $hadOld = Test-Path -LiteralPath $marker -PathType Leaf
    if ($hadOld) {
        if (-not $oldTask -or -not (Test-Path -LiteralPath $binary) -or -not (Test-Path -LiteralPath $config)) { throw 'DDNSTO: incomplete previous installation' }
    } elseif ($oldTask -or (Test-Path -LiteralPath $binary) -or (Test-Path -LiteralPath $config)) {
        throw 'DDNSTO: existing unmanaged installation; migrate it before retrying'
    }
    if (-not $hadOld -and -not $Token -and -not $TokenFile) { $Token = Read-DDNSTOToken }
    if ($Token.Contains("`r") -or $Token.Contains("`n")) { throw 'DDNSTO: token must be one line' }
    $tokenLine = "userToken: '" + $Token.Replace("'", "''") + "'"
    if ($hadOld) {
        if ($Token -and -not ([IO.File]::ReadAllLines($config) -ccontains $tokenLine)) { throw 'DDNSTO: existing token differs; edit configuration explicitly before reinstalling' }
    } elseif ([string]::IsNullOrWhiteSpace($Token)) { throw 'DDNSTO: token is required on first installation' }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Protect-DDNSTODirectory $InstallDir
    $lockPath = Join-Path $InstallDir '.install-lock'
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $work = Join-Path $InstallDir ('.transaction-' + [guid]::NewGuid().ToString('N'))
    $changed = $false
    $keepBackup = $false
    $oldXml = ''
    $wasRunning = $hadOld -and $oldTask.State -eq 'Running'
    try {
        $currentTask = Get-DDNSTOTask
        if ($hadOld -ne (Test-Path -LiteralPath $marker -PathType Leaf) -or
            [bool]$oldTask -ne [bool]$currentTask) { throw 'DDNSTO: installation changed; retry' }
        if ($hadOld) {
            if (-not (Test-Path -LiteralPath $binary -PathType Leaf) -or -not (Test-Path -LiteralPath $config -PathType Leaf)) { throw 'DDNSTO: incomplete previous installation' }
            if ($Token -and -not ([IO.File]::ReadAllLines($config) -ccontains $tokenLine)) { throw 'DDNSTO: existing token differs' }
        } elseif ((Test-Path -LiteralPath $binary) -or (Test-Path -LiteralPath $config)) { throw 'DDNSTO: installation changed; retry' }
        $wasRunning = $hadOld -and $currentTask.State -eq 'Running'
        New-Item -ItemType Directory -Path $work | Out-Null
        $candidate = Receive-DDNSTOCandidate $work $Version
        if ($hadOld) {
            Copy-Item -LiteralPath $binary -Destination (Join-Path $work 'old.exe')
            Copy-Item -LiteralPath $config -Destination (Join-Path $work 'old.yaml')
            $oldXml = Export-DDNSTOTask
            [IO.File]::WriteAllText((Join-Path $work 'old-task.xml'), $oldXml)
        }
        $changed = $true
        if ($hadOld) { Stop-DDNSTOTask }
        Copy-Item -LiteralPath $candidate -Destination $binary -Force
        if (-not $hadOld) {
            $logPath = (Join-Path $InstallDir 'logs').Replace("'", "''")
            [IO.File]::WriteAllText($config, $tokenLine + "`nlogPath: '" + $logPath + "'`n", (New-Object Text.UTF8Encoding($false)))
        }
        Register-DDNSTOTask $binary $config $InstallDir
        Start-DDNSTOTask
        Confirm-DDNSTORunning
        [IO.File]::WriteAllText($marker, 'ddnsto-windows-v1')
        $changed = $false
        Write-Output "DDNSTO $Version local_service=running cloud_status=unverified"
        Write-Output 'Confirm device online in the DDNSTO console: https://www.ddnsto.com/'
    } catch {
        if ($changed) {
            try {
                if (Get-DDNSTOTask) { Stop-DDNSTOTask }
                if ($hadOld) {
                    Copy-Item -LiteralPath (Join-Path $work 'old.exe') -Destination $binary -Force
                    Copy-Item -LiteralPath (Join-Path $work 'old.yaml') -Destination $config -Force
                    Restore-DDNSTOTask $oldXml
                    if ($wasRunning) { Start-DDNSTOTask; Confirm-DDNSTORunning }
                } else {
                    Remove-DDNSTOTask
                    foreach ($file in @($binary, $config, $marker)) {
                        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
                    }
                }
            } catch {
                $keepBackup = $true
                Write-Warning "DDNSTO: recovery incomplete; backup retained at $work"
            }
        }
        throw 'DDNSTO: installation failed; check download, permissions and task state before retrying'
    } finally {
        $lock.Dispose()
        Remove-Item -LiteralPath $lockPath -Force
        if (-not $keepBackup -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
    }
}
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DDNSTOInstall -Token $Token -TokenFile $TokenFile -Version $Version -InstallDir $InstallDir
}
