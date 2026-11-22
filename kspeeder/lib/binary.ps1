$ErrorActionPreference = 'Stop'

function Stop-KSpeederInstall([string]$Message, [int]$Code = 2) {
    [Console]::Error.WriteLine("KSpeeder products: $Message")
    exit $Code
}

function Test-KSpeederSafePath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { return $false }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\')
    if (-not $full -or $full -ieq $root) { return $false }
    $cursor = $full
    while ($cursor -and $cursor -ine $root) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $true
}

function Get-KSpeederOptions([string[]]$InputArguments, [string]$Application) {
    $local = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $HOME }
    $options = [ordered]@{
        Prefix = Join-Path $local "KSpeeder\managed\$Application"
        Work = ''
    }
    for ($index = 0; $index -lt $InputArguments.Count; $index++) {
        $name = $InputArguments[$index]
        switch -CaseSensitive ($name) {
            '--installer-prefix' {
                if (++$index -ge $InputArguments.Count) { Stop-KSpeederInstall 'missing --installer-prefix value' }
                $options.Prefix = $InputArguments[$index]
            }
            '--installer-work-dir' {
                if (++$index -ge $InputArguments.Count) { Stop-KSpeederInstall 'missing --installer-work-dir value' }
                $options.Work = $InputArguments[$index]
            }
            '--installer-scope' {
                if (++$index -ge $InputArguments.Count -or $InputArguments[$index] -cne 'user') {
                    Stop-KSpeederInstall 'Windows binary installation supports user scope only'
                }
            }
            '--' {
                if ($index + 1 -lt $InputArguments.Count) { Stop-KSpeederInstall 'business commands are not run by this installer' }
                $index = $InputArguments.Count
            }
            default { Stop-KSpeederInstall "unsupported installer argument: $name" }
        }
    }
    if (-not (Test-KSpeederSafePath $options.Prefix)) { Stop-KSpeederInstall 'unsafe installer prefix' }
    if ($options.Work -and -not (Test-KSpeederSafePath $options.Work)) { Stop-KSpeederInstall 'unsafe installer work directory' }
    return $options
}

function Invoke-KSpeederDownload([string]$RemoteRoot, [string]$Relative,
        [string]$Destination, [string]$Sha256 = '', [long]$MaxBytes = 33554432) {
    if (-not $env:ZSETUP_BIN) { Stop-KSpeederInstall 'ZSETUP_BIN is required' }
    $bases = @($env:ZSETUP_SOURCE_BASES -split '\s+' | Where-Object { $_ })
    if ($bases.Count -eq 0) {
        $bases = @(
            'https://dl.istoreos.com/binary',
            'https://fw.d4ctech.com/binary',
            'https://fw20.koolcenter.com/binary'
        )
    }
    $fallback = if ($null -ne $env:ZSETUP_SOURCE_FALLBACK) {
        $env:ZSETUP_SOURCE_FALLBACK
    } else { 'https://fw.koolcenter.com/binary' }
    $arguments = @('download', '-o', $Destination, '--max-bytes', [string]$MaxBytes)
    if ($Sha256) { $arguments += @('--sha256', $Sha256) }
    foreach ($base in $bases) {
        $arguments += $base.TrimEnd('/') + '/' + $RemoteRoot.Trim('/') + '/' + $Relative
    }
    if ($fallback) {
        $arguments += @('--fallback-url', ($fallback.TrimEnd('/') + '/' +
            $RemoteRoot.Trim('/') + '/' + $Relative))
    }
    & $env:ZSETUP_BIN @arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Read-KSpeederVersion([string]$Path) {
    $values = @([IO.File]::ReadAllLines($Path) | Where-Object { $_ -cmatch '^VERSION=' })
    if ($values.Count -ne 1) { Stop-KSpeederInstall 'release metadata has no unique VERSION' 11 }
    $version = $values[0].Substring(8)
    if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { Stop-KSpeederInstall 'invalid product version' 11 }
    return $version
}

function Read-KSpeederRelease([string]$Path) {
    $lines = @([IO.File]::ReadAllLines($Path))
    $versions = @($lines | Where-Object { $_ -cmatch '^VERSION=' })
    $releases = @($lines | Where-Object { $_ -cmatch '^RELEASE=' })
    if ($lines.Count -ne 2 -or $versions.Count -ne 1 -or $releases.Count -ne 1) {
        Stop-KSpeederInstall 'release pointer fields are missing or ambiguous' 11
    }
    $version = $versions[0].Substring(8)
    $release = $releases[0].Substring(8)
    if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
        $release -cnotmatch '^[0-9a-f]{64}$') {
        Stop-KSpeederInstall 'invalid release pointer' 11
    }
    return [PSCustomObject]@{ Version = $version; Release = $release }
}

function Read-KSpeederChecksum([string]$Path, [string]$Name) {
    $hashes = @()
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -cmatch '^([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+-]{0,127})$' -and
            $Matches[2] -ceq $Name) { $hashes += $Matches[1] }
    }
    if ($hashes.Count -ne 1) { Stop-KSpeederInstall 'immutable checksum record is missing or ambiguous' 11 }
    return $hashes[0]
}

function Test-KSpeederProduct([string]$Path, [string]$Version) {
    $stdout = $Path + '.stdout-' + [Guid]::NewGuid().ToString('N')
    $stderr = $stdout + '.stderr'
    $process = $null
    try {
        $process = Start-Process -FilePath $Path -ArgumentList 'version' -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
        $ownedHandle = $process.Handle
        if (-not $process.WaitForExit(10000)) { $process.Kill(); $process.WaitForExit(); return $false }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or (Get-Item -LiteralPath $stdout).Length -gt 1024 -or
            (Get-Item -LiteralPath $stderr).Length -gt 1024) { return $false }
        $reported = ([IO.File]::ReadAllText($stdout).Trim() -split '\s+')[0]
        return $reported -ceq $Version
    } catch { return $false }
    finally {
        if ($null -ne $process) {
            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            $process.Dispose()
        }
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-KSpeederBinaryInstall([string]$Application, [string[]]$InputArguments) {
    if ($Application -notin @('ks-cli', 'kspeeder')) { Stop-KSpeederInstall 'unsupported application' }
    if (-not $env:ZSETUP_BIN) { Stop-KSpeederInstall 'ZSETUP_BIN is required' }
    $contextOs = if ($env:ZSETUP_OS) { $env:ZSETUP_OS } else {
        (& $env:ZSETUP_BIN context get os | Out-String).Trim()
    }
    if ($contextOs -cne 'windows') { Stop-KSpeederInstall 'PowerShell entry supports Windows only' }
    $contextArch = if ($env:ZSETUP_ARCH) { $env:ZSETUP_ARCH } else {
        (& $env:ZSETUP_BIN context get arch | Out-String).Trim()
    }
    $arch = switch -CaseSensitive ($contextArch) {
        'x86_64' { 'amd64' }
        'aarch64' { 'arm64' }
        default { Stop-KSpeederInstall 'Windows supports x86_64 and arm64 only' }
    }
    $options = Get-KSpeederOptions $InputArguments $Application
    $prefix = [IO.Path]::GetFullPath($options.Prefix)
    $local = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $HOME }
    $commandDirectory = Join-Path $local 'KSpeeder\bin'
    $command = Join-Path $commandDirectory "$Application.exe"
    if (-not (Test-KSpeederSafePath $commandDirectory)) { Stop-KSpeederInstall 'unsafe command directory' }
    $productName = if ($Application -ceq 'ks-cli') {
        "ks-cli-win-$arch.exe"
    } else { "iStoreEnhance-win.exe.$arch" }

    New-Item -ItemType Directory -Path $prefix -Force -ErrorAction Stop | Out-Null
    if (-not (Test-KSpeederSafePath $prefix)) { Stop-KSpeederInstall 'installer prefix became unsafe' }
    $marker = Join-Path $prefix '.managed'
    if (Test-Path -LiteralPath $marker) {
        if ([IO.File]::ReadAllText($marker).Trim() -cne $Application) { Stop-KSpeederInstall 'prefix belongs to another application' }
    } else { [IO.File]::WriteAllText($marker, $Application + "`n", [Text.UTF8Encoding]::new($false)) }

    $lock = Join-Path $prefix '.install-lock'
    try { New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null }
    catch { Stop-KSpeederInstall 'installation lock is held' 12 }
    $workParent = if ($options.Work) { $options.Work } else { $prefix }
    New-Item -ItemType Directory -Path $workParent -Force -ErrorAction Stop | Out-Null
    $work = Join-Path $workParent ('.download-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
    try {
        $pointer = Join-Path $work 'release.txt'
        Invoke-KSpeederDownload 'kspeeder' 'release.txt' $pointer '' 16384
        $release = Read-KSpeederRelease $pointer
        $version = $release.Version
        $immutableRoot = "kspeeder/releases/$($release.Release)"
        $sums = Join-Path $work 'SHA256SUMS'
        Invoke-KSpeederDownload $immutableRoot 'SHA256SUMS' $sums '' 16384
        $sha256 = Read-KSpeederChecksum $sums $productName
        $download = Join-Path $work 'product.exe'
        Invoke-KSpeederDownload $immutableRoot $productName $download $sha256 33554432
        if (-not (Test-KSpeederProduct $download $version)) { Stop-KSpeederInstall 'downloaded product version check failed' 11 }

        $versionDirectory = Join-Path (Join-Path $prefix 'versions') $version
        $versionBinary = Join-Path $versionDirectory "$Application.exe"
        if (Test-Path -LiteralPath $versionBinary) {
            if ((Get-FileHash -LiteralPath $versionBinary -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sha256 -or
                -not (Test-KSpeederProduct $versionBinary $version)) {
                Stop-KSpeederInstall 'immutable installed version has different bytes' 11
            }
        } else {
            New-Item -ItemType Directory -Path $versionDirectory -Force -ErrorAction Stop | Out-Null
            Move-Item -LiteralPath $download -Destination $versionBinary -ErrorAction Stop
            [IO.File]::WriteAllText($versionBinary + '.verified', $sha256 + "`n", [Text.UTF8Encoding]::new($false))
        }

        New-Item -ItemType Directory -Path $commandDirectory -Force -ErrorAction Stop | Out-Null
        $commandMarker = $command + '.managed'
        if ((Test-Path -LiteralPath $command) -and -not (Test-Path -LiteralPath $commandMarker)) {
            Stop-KSpeederInstall "existing command belongs to another installation: $command"
        }
        $candidate = $command + '.candidate-' + [Guid]::NewGuid().ToString('N')
        Copy-Item -LiteralPath $versionBinary -Destination $candidate -ErrorAction Stop
        Move-Item -LiteralPath $candidate -Destination $command -Force -ErrorAction Stop
        [IO.File]::WriteAllText($commandMarker, $Application + "`n", [Text.UTF8Encoding]::new($false))
        $current = Join-Path $prefix 'current.txt'
        $previous = Join-Path $prefix 'previous.txt'
        if (Test-Path -LiteralPath $current) {
            $old = [IO.File]::ReadAllText($current).Trim()
            if ($old -and $old -cne $version) { [IO.File]::WriteAllText($previous, $old + "`n", [Text.UTF8Encoding]::new($false)) }
        }
        [IO.File]::WriteAllText($current, $version + "`n", [Text.UTF8Encoding]::new($false))
        Write-Output "application=$Application"
        Write-Output "version=$version"
        Write-Output "command=$command"
        Write-Output "prefix=$prefix"
        [Console]::Error.WriteLine('No service was registered or started. Invoke the installed command explicitly.')
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
    }
}
