# Engineering candidate. Automatic zsetup bootstrap; native canary pending.
param([string]$Token = '', [string]$TokenFile = '', [string]$Version = '4.2.1',
      [string]$InstallDir = "$env:ProgramData\DDNSTO", [string]$Platform = 'auto',
      [string]$Method = 'auto', [switch]$Plan, [string]$Action = 'install')
$ErrorActionPreference = 'Stop'
$script:DDNSTOTaskName = 'DDNSTO'

function Get-DDNSTOHostArchitecture {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'DDNSTO: Windows is required' }
    if ($env:PROCESSOR_ARCHITEW6432) { return $env:PROCESSOR_ARCHITEW6432 }
    return $env:PROCESSOR_ARCHITECTURE
}

function Invoke-DDNSTOEntry {
    param([string]$Token = '', [string]$TokenFile = '', [string]$Version = '4.2.1',
          [string]$InstallDir = "$env:ProgramData\DDNSTO", [string]$Platform = 'auto',
          [string]$Method = 'auto', [switch]$Plan, [string]$Action = 'install')
    if ($Action -notin @('install', 'update', 'status', 'start', 'stop', 'restart', 'repair', 'uninstall', 'configure')) { throw 'DDNSTO: unknown action' }
    if ($Platform -notin @('auto', 'windows')) { throw 'DDNSTO: platform mismatch: this entry requires windows' }
    if ($Method -eq 'docker') { throw 'DDNSTO: Docker installer is not available for Windows' }
    if ($Method -notin @('auto', 'native')) { throw 'DDNSTO: unknown installation method' }
    if ($Plan) {
        if ($Action -ne 'install') { throw 'DDNSTO: -Plan requires the install action' }
        if ($Token -or $TokenFile) { throw 'DDNSTO: -Plan does not accept credentials' }
        if ($Version -ne '4.2.1') { throw 'DDNSTO: no pinned artifact for requested version' }
        if ((Get-DDNSTOHostArchitecture) -ne 'AMD64') { throw 'DDNSTO: unsupported architecture; requires Windows x64' }
        # No admin check, download, token file read, directory or task creation.
        return @('facts_source=local-preflight', 'platform=windows', 'arch=x86_64',
            'client_version=4.2.1', 'zsetup_version=0.4.0',
            'native_status=requires-admin-task-preflight', 'docker_installable=false',
            'installation_performed=false')
    }
    if ($Action -in @('uninstall', 'configure')) {
        return Invoke-DDNSTOLifecycle -InstallDir $InstallDir -Action $Action -Token $Token -TokenFile $TokenFile
    }
    if ($Action -in @('status', 'start', 'stop', 'restart', 'repair')) {
        if ($Token -or $TokenFile) { throw 'DDNSTO: service actions do not accept credentials' }
        if ($Action -eq 'repair') { return Invoke-DDNSTORepair -InstallDir $InstallDir }
        return Invoke-DDNSTOManageService -InstallDir $InstallDir -Action $Action
    }
    Invoke-DDNSTOInstall -Token $Token -TokenFile $TokenFile -Version $Version -InstallDir $InstallDir -Action $Action
}

function Assert-DDNSTOSafePaths($InstallDir) {
    if (-not [IO.Path]::IsPathRooted($InstallDir)) { throw 'DDNSTO: installation path must be absolute' }
    # Check ancestors as well as children: a normal leaf below a junction is unsafe too.
    $ancestor = [IO.Path]::GetFullPath($InstallDir)
    while ($ancestor) {
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'DDNSTO: reparse points are not supported' }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    if (Test-Path -LiteralPath $InstallDir) {
        if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) { throw 'DDNSTO: installation directory required' }
        foreach ($item in @(Get-ChildItem -LiteralPath $InstallDir -Force -Recurse)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'DDNSTO: reparse points are not supported' }
        }
    }
}

function Get-DDNSTOManagedState($InstallDir) {
    Assert-DDNSTOSafePaths $InstallDir
    $marker = Join-Path $InstallDir '.installer-windows-v1'
    $config = Join-Path $InstallDir 'ddnsto.yaml'
    $binary = Join-Path $InstallDir 'ddnsto_cli.x86_64.exe'
    foreach ($path in @($marker, $config)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'DDNSTO: managed configuration and marker required' }
    }
    switch -CaseSensitive ([IO.File]::ReadAllText($marker)) {
        'ddnsto-windows-v1:recovery-required' { return 'recovery-required' }
        'ddnsto-windows-v1' {
            if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'DDNSTO: incomplete previous installation' }
            return 'installed'
        }
        'ddnsto-windows-v1:retained' {
            if ((Test-Path -LiteralPath $binary) -or (Get-DDNSTOTask)) { throw 'DDNSTO: inconsistent retained installation' }
            return 'retained'
        }
        default { throw 'DDNSTO: unknown installation marker' }
    }
}

# Uninstall preserves all data except the managed executable and task. Reinstall
# consumes that explicit retained state; configure changes only the top-level Token.
function Invoke-DDNSTOLifecycle {
    param([string]$InstallDir, [string]$Action, [string]$Token = '', [string]$TokenFile = '', [string]$Version = '4.2.1')
    Assert-DDNSTOPlatform
    if ($Action -notin @('uninstall', 'reinstall', 'configure')) { throw 'DDNSTO: unknown lifecycle action' }
    if ($Action -ne 'configure' -and ($Token -or $TokenFile)) { throw 'DDNSTO: this action preserves credentials' }
    if ($Action -eq 'reinstall' -and $Version -ne '4.2.1') { throw 'DDNSTO: no pinned artifact for requested version' }
    $state = Get-DDNSTOManagedState $InstallDir
    if ($state -eq 'recovery-required') { throw 'DDNSTO: manual recovery from retained backup required' }
    if ($Action -eq 'reinstall' -and $state -ne 'retained') { throw 'DDNSTO: retained installation required' }
    if ($Action -eq 'configure' -and $state -ne 'installed') { throw 'DDNSTO: installed service required for configure' }
    if ($state -eq 'installed') { $null = Assert-DDNSTOManagedTask $InstallDir -AllowMissingTask:($Action -eq 'uninstall') }
    if ($Action -eq 'configure') {
        # Explicit configure plus credentials is the confirmation contract.
        if ($TokenFile) {
            if ($Token) { throw 'DDNSTO: choose Token or TokenFile' }
            try { $Token = [IO.File]::ReadAllText($TokenFile) -replace '\r?\n$', '' }
            catch { throw 'DDNSTO: could not read Token file' }
        }
        if ([string]::IsNullOrWhiteSpace($Token) -or $Token -match '[\x00-\x1f\x7f]') { throw 'DDNSTO: configure requires a nonempty single-line Token or TokenFile' }
    }
    $lockPath = Join-Path $InstallDir '.install-lock'
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $work = Join-Path $InstallDir ('.lifecycle-' + [guid]::NewGuid().ToString('N'))
    $binary = Join-Path $InstallDir 'ddnsto_cli.x86_64.exe'
    $config = Join-Path $InstallDir 'ddnsto.yaml'
    $marker = Join-Path $InstallDir '.installer-windows-v1'
    $changed = $false; $keepBackup = $false; $oldTask = $null; $oldXml = ''; $wasRunning = $false
    try {
        if ((Get-DDNSTOManagedState $InstallDir) -ne $state) { throw 'DDNSTO: installation changed; retry' }
        if ($state -eq 'installed') {
            $oldTask = Assert-DDNSTOManagedTask $InstallDir -AllowMissingTask:($Action -eq 'uninstall')
        }
        if ($state -eq 'retained' -and $Action -eq 'uninstall') {
            return 'operation=none installation=retained local_service=not-installed configuration=retained identity=retained cloud_status=unverified'
        }
        New-Item -ItemType Directory -Path $work | Out-Null
        Copy-Item -LiteralPath $marker -Destination (Join-Path $work 'old-marker')
        Copy-Item -LiteralPath $config -Destination (Join-Path $work 'old.yaml')
        if ($state -eq 'installed') { Copy-Item -LiteralPath $binary -Destination (Join-Path $work 'old.exe') }
        if ($oldTask) {
            $oldXml = Export-DDNSTOTask
            if ([string]::IsNullOrWhiteSpace($oldXml)) { throw 'DDNSTO: could not export previous task' }
            [IO.File]::WriteAllText((Join-Path $work 'old-task.xml'), $oldXml)
            $wasRunning = $oldTask.State -eq 'Running'
        }
        if ($Action -eq 'reinstall') { $candidate = Receive-DDNSTOCandidate $work $Version }
        if ($Action -eq 'configure') {
            $text = [IO.File]::ReadAllText($config)
            # Only rewrite the installer's single-line quoted scalar, not arbitrary YAML.
            $pattern = "(?m)^userToken: '(?:[^'\r\n]|'')*'(?=\r?$)"
            if ([regex]::Matches($text, $pattern).Count -ne 1 -or
                [regex]::Matches($text, '(?m)^\s*userToken\s*:').Count -ne 1) {
                throw 'DDNSTO: configure requires exactly one installer-format single-line quoted userToken field'
            }
            $line = "userToken: '" + $Token.Replace("'", "''") + "'"
            $updated = [regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $line })
            [IO.File]::WriteAllText((Join-Path $work 'new.yaml'), $updated, (New-Object Text.UTF8Encoding($false)))
        }
        $changed = $true
        if ($oldTask) { Stop-DDNSTOTask }
        switch ($Action) {
            'uninstall' {
                Remove-DDNSTOTask
                if (Get-DDNSTOTask) { throw 'DDNSTO: task removal failed' }
                Remove-Item -LiteralPath $binary -Force
                [IO.File]::WriteAllText($marker, 'ddnsto-windows-v1:retained')
            }
            'reinstall' {
                Copy-Item -LiteralPath $candidate -Destination $binary
                Register-DDNSTOTask $binary $config $InstallDir
                Start-DDNSTOTask
                Confirm-DDNSTORunning
                [IO.File]::WriteAllText($marker, 'ddnsto-windows-v1')
            }
            'configure' {
                Copy-Item -LiteralPath (Join-Path $work 'new.yaml') -Destination $config -Force
                # Re-register to enable a previously disabled task; XML is saved for rollback.
                Register-DDNSTOTask $binary $config $InstallDir
                Start-DDNSTOTask
                Confirm-DDNSTORunning
            }
        }
        $changed = $false
    } catch {
        if ($changed) {
            try {
                if (Get-DDNSTOTask) { Stop-DDNSTOTask }
                if ($state -eq 'installed') {
                    Copy-Item -LiteralPath (Join-Path $work 'old.exe') -Destination $binary -Force
                    Copy-Item -LiteralPath (Join-Path $work 'old.yaml') -Destination $config -Force
                    if ($oldTask) {
                        Restore-DDNSTOTask $oldXml
                        if ($wasRunning) { Start-DDNSTOTask; Confirm-DDNSTORunning }
                    } else { Remove-DDNSTOTask }
                } else {
                    Remove-DDNSTOTask
                    if (Get-DDNSTOTask) { throw 'DDNSTO: task removal failed' }
                    if (Test-Path -LiteralPath $binary) { Remove-Item -LiteralPath $binary -Force }
                }
                Copy-Item -LiteralPath (Join-Path $work 'old-marker') -Destination $marker -Force
            } catch {
                $keepBackup = $true
                try { [IO.File]::WriteAllText($marker, 'ddnsto-windows-v1:recovery-required') } catch { }
                Write-Warning "DDNSTO: recovery incomplete; inspect task state and backup at $work"
            }
        }
        throw "DDNSTO: $Action failed; check local state before retrying"
    } finally {
        try {
            if (-not $keepBackup -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
        } finally {
            $lock.Dispose()
            Remove-Item -LiteralPath $lockPath -Force
        }
    }
    if ($Action -eq 'uninstall') { return 'operation=uninstall installation=retained local_service=not-installed configuration=retained identity=retained cloud_status=unverified' }
    return "operation=$Action installation=installed local_service=running cloud_status=unverified"
}

function Assert-DDNSTOManagedTask($InstallDir, [switch]$AllowMissingTask) {
    if ((Get-DDNSTOManagedState $InstallDir) -ne 'installed') { throw 'DDNSTO: installed service required' }
    $binary = Join-Path $InstallDir 'ddnsto_cli.x86_64.exe'
    $config = Join-Path $InstallDir 'ddnsto.yaml'
    foreach ($path in @($InstallDir, $binary, $config, (Join-Path $InstallDir '.installer-windows-v1'))) {
        if (-not (Test-Path -LiteralPath $path)) { throw 'DDNSTO: complete managed installation required' }
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'DDNSTO: reparse points are not supported'
        }
        if ($path -ne $InstallDir -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'DDNSTO: installation files must be regular files'
        }
    }
    $task = Get-DDNSTOTask
    if (-not $task -and $AllowMissingTask) { return $null }
    if (-not $task -or @($task.Actions).Count -ne 1 -or
        $task.Actions[0].Execute -ne $binary -or
        $task.Actions[0].Arguments -ne ('--config "' + $config + '"') -or
        $task.Actions[0].WorkingDirectory -ne $InstallDir) {
        throw 'DDNSTO: task does not match this managed installation'
    }
    return $task
}

function Invoke-DDNSTORepair {
    param([string]$InstallDir)
    Assert-DDNSTOPlatform
    if (-not [IO.Path]::IsPathRooted($InstallDir)) { throw 'DDNSTO: installation path must be absolute' }
    $null = Assert-DDNSTOManagedTask $InstallDir -AllowMissingTask
    $lockPath = Join-Path $InstallDir '.install-lock'
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $work = Join-Path $InstallDir ('.repair-' + [guid]::NewGuid().ToString('N'))
    $changed = $false
    $keepBackup = $false
    $oldTask = $null
    $oldXml = ''
    $wasRunning = $false
    try {
        # Recheck ownership under the same lock used by install/update/manage.
        $oldTask = Assert-DDNSTOManagedTask $InstallDir -AllowMissingTask
        $wasRunning = $oldTask -and $oldTask.State -eq 'Running'
        New-Item -ItemType Directory -Path $work | Out-Null
        if ($oldTask) {
            $oldXml = Export-DDNSTOTask
            if ([string]::IsNullOrWhiteSpace($oldXml)) { throw 'DDNSTO: could not export previous task' }
            [IO.File]::WriteAllText((Join-Path $work 'old-task.xml'), $oldXml)
        }
        $changed = $true
        if ($oldTask) { Stop-DDNSTOTask }
        Register-DDNSTOTask (Join-Path $InstallDir 'ddnsto_cli.x86_64.exe') (Join-Path $InstallDir 'ddnsto.yaml') $InstallDir
        $null = Assert-DDNSTOManagedTask $InstallDir
        Start-DDNSTOTask
        Confirm-DDNSTORunning
        $changed = $false
    } catch {
        if ($changed) {
            try {
                if (Get-DDNSTOTask) { Stop-DDNSTOTask }
                if ($oldTask) {
                    Restore-DDNSTOTask $oldXml
                    if ($wasRunning) { Start-DDNSTOTask; Confirm-DDNSTORunning }
                } else {
                    Remove-DDNSTOTask
                    if (Get-DDNSTOTask) { throw 'DDNSTO: newly created task could not be removed' }
                }
            } catch {
                $keepBackup = $true
                Write-Warning "DDNSTO: repair recovery incomplete; inspect task state and backup at $work"
            }
        }
        throw 'DDNSTO: repair failed; client configuration was not rewritten; check task state before retrying'
    } finally {
        try {
            if (-not $keepBackup -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
        } finally {
            $lock.Dispose()
            Remove-Item -LiteralPath $lockPath -Force
        }
    }
    return 'operation=repair local_service=running cloud_status=unverified'
}

function Invoke-DDNSTOManageService {
    param([string]$InstallDir, [string]$Action)
    Assert-DDNSTOPlatform
    if (-not [IO.Path]::IsPathRooted($InstallDir)) { throw 'DDNSTO: installation path must be absolute' }
    if ($Action -eq 'status') {
        $state = Get-DDNSTOManagedState $InstallDir
        if ($state -eq 'retained') { return 'installation=retained local_service=not-installed configuration=retained identity=retained cloud_status=unverified' }
        if ($state -eq 'recovery-required') { return 'installation=recovery-required local_service=unknown cloud_status=unverified' }
    }
    $task = Assert-DDNSTOManagedTask $InstallDir
    if ($Action -ne 'status') {
        $lockPath = Join-Path $InstallDir '.install-lock'
        # Acquire outside try/finally: never remove a lock held by another caller.
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $null = Assert-DDNSTOManagedTask $InstallDir
            if ($Action -eq 'stop') {
                Disable-ScheduledTask -TaskPath '\' -TaskName $script:DDNSTOTaskName | Out-Null
                Stop-DDNSTOTask
            } else {
                Enable-ScheduledTask -TaskPath '\' -TaskName $script:DDNSTOTaskName | Out-Null
                if ($Action -eq 'restart') { Stop-DDNSTOTask }
                Start-DDNSTOTask
                Confirm-DDNSTORunning
            }
            $task = Assert-DDNSTOManagedTask $InstallDir
        } finally {
            $lock.Dispose()
            Remove-Item -LiteralPath $lockPath -Force
        }
    }
    $state = switch ([string]$task.State) {
        'Running' { 'running' }
        'Ready' { 'stopped' }
        'Disabled' { 'stopped' }
        'Queued' { 'starting' }
        default { throw 'DDNSTO: unknown scheduled task state' }
    }
    if ($Action -eq 'stop' -and $state -ne 'stopped') { throw 'DDNSTO: task did not stop' }
    return "local_service=$state cloud_status=unverified"
}

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
function Test-DDNSTOInteractive { return -not [Console]::IsInputRedirected }
function Read-DDNSTOToken {
    if (-not (Test-DDNSTOInteractive)) { throw 'DDNSTO: token required; use an interactive terminal or -TokenFile FILE' }
    return Read-Host 'DDNSTO token (visible; paste from console)'
}
function Invoke-DDNSTOInstall {
    param([string]$Token = '', [string]$TokenFile = '', [string]$Version = '4.2.1', [string]$InstallDir, [string]$Action = 'install')
    if ($Action -notin @('install', 'update')) { throw 'DDNSTO: unknown action' }
    if ($Action -eq 'update' -and ($Token -or $TokenFile)) { throw 'DDNSTO: update preserves existing Token; do not supply credentials' }
    Assert-DDNSTOPlatform
    if ($Version -ne '4.2.1') { throw 'DDNSTO: no pinned artifact for requested version' }
    if (-not [IO.Path]::IsPathRooted($InstallDir)) { throw 'DDNSTO: installation path must be absolute' }
    Assert-DDNSTOSafePaths $InstallDir
    if (Test-Path -LiteralPath (Join-Path $InstallDir '.installer-windows-v1')) {
        if ((Get-DDNSTOManagedState $InstallDir) -eq 'retained') {
            if ($Action -ne 'install') { throw 'DDNSTO: retained configuration requires -Action install' }
            return Invoke-DDNSTOLifecycle -InstallDir $InstallDir -Action reinstall -Token $Token -TokenFile $TokenFile -Version $Version
        }
        $null = Assert-DDNSTOManagedTask $InstallDir
    }
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
    if (-not $hadOld -and (Test-Path -LiteralPath $InstallDir) -and
        @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) {
        throw 'DDNSTO: nonempty unmanaged directory; migrate it before retrying'
    }
    if ($Action -eq 'update' -and -not $hadOld) { throw 'DDNSTO: no existing installation; install first' }
    if ($hadOld -and $Action -eq 'install') {
        if ($Token -or $TokenFile) { throw 'DDNSTO: existing installation preserves Token; use -Action update without credentials' }
        $choice = '0'
        if (Test-DDNSTOInteractive) {
            Write-Host 'Existing DDNSTO installation. 0) Exit (default) 1) Update 2) Status 3) Start 4) Stop 5) Restart 6) Repair 7) Change Token 8) Uninstall (retain configuration and identity)'
            $choice = Read-Host 'Choose [0]'
        }
        if ($choice -eq '' -or $choice -eq '0') {
            return @('operation=none installation=existing cloud_status=unverified', 'No changes made. Use -Action update to update explicitly.')
        }
        $actions = @{'2'='status'; '3'='start'; '4'='stop'; '5'='restart'; '6'='repair'; '7'='configure'; '8'='uninstall'}
        if ($actions.ContainsKey($choice)) {
            if ($choice -eq '7') { return Invoke-DDNSTOEntry -InstallDir $InstallDir -Action configure -Token (Read-DDNSTOToken) }
            return Invoke-DDNSTOEntry -InstallDir $InstallDir -Action $actions[$choice]
        }
        if ($choice -ne '1') { throw 'DDNSTO: invalid action; no changes made' }
        $Action = 'update'
    }
    if (-not $hadOld -and -not $Token -and -not $TokenFile) { $Token = Read-DDNSTOToken }
    if ($Token.Contains("`r") -or $Token.Contains("`n")) { throw 'DDNSTO: token must be one line' }
    $tokenLine = "userToken: '" + $Token.Replace("'", "''") + "'"
    if ($hadOld) {
        if ($Token -and -not ([IO.File]::ReadAllLines($config) -ccontains $tokenLine)) { throw 'DDNSTO: existing token differs; edit configuration explicitly before reinstalling' }
    } elseif ([string]::IsNullOrWhiteSpace($Token)) { throw 'DDNSTO: token is required on first installation' }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $lockPath = Join-Path $InstallDir '.install-lock'
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $work = Join-Path $InstallDir ('.transaction-' + [guid]::NewGuid().ToString('N'))
    $changed = $false
    $keepBackup = $false
    $oldXml = ''
    $wasRunning = $hadOld -and $oldTask.State -eq 'Running'
    try {
        Assert-DDNSTOSafePaths $InstallDir
        Protect-DDNSTODirectory $InstallDir
        $currentTask = Get-DDNSTOTask
        if ($hadOld -ne (Test-Path -LiteralPath $marker -PathType Leaf) -or
            [bool]$oldTask -ne [bool]$currentTask) { throw 'DDNSTO: installation changed; retry' }
        if ($hadOld) {
            $null = Assert-DDNSTOManagedTask $InstallDir
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
    Invoke-DDNSTOEntry -Token $Token -TokenFile $TokenFile -Version $Version -InstallDir $InstallDir -Platform $Platform -Method $Method -Plan:$Plan -Action $Action
}
