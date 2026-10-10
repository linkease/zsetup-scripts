param(
    [string]$Token = '',
    [string]$Version = $(if ($env:DDNSTO_VERSION) { $env:DDNSTO_VERSION } else { '4.2.1' }),
    [string]$BaseUrl = $(if ($env:DDNSTO_RELEASE_BASE) { $env:DDNSTO_RELEASE_BASE } else { 'https://fw.koolcenter.com/binary/ddnsto/windows' }),
    [string]$InstallDir = $(if ($env:DDNSTO_INSTALL_DIR) { $env:DDNSTO_INSTALL_DIR } else { "$env:ProgramData\DDNSTO" }),
    [string]$TaskName = $(if ($env:DDNSTO_TASK_NAME) { $env:DDNSTO_TASK_NAME } else { 'DDNSTO' })
)
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Token)) {
    if ([Console]::IsInputRedirected) { throw 'DDNSTO: token is required' }
    $Token = Read-Host 'DDNSTO token'
}
if ([string]::IsNullOrWhiteSpace($Token)) { throw 'DDNSTO: token is required' }
if ($Token.Contains("`r") -or $Token.Contains("`n")) { throw 'DDNSTO: token must be one line' }

$archiveSha = @{
    '4.2.1' = 'bf77c4a16b6b1914a0015e3491b39649602ce767d908da73d06a9feb1b3455db'
}
if (-not $archiveSha.ContainsKey($Version)) { throw "DDNSTO: no pinned Windows artifact for version $Version" }

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ddnsto-' + [Guid]::NewGuid().ToString('N'))
$archive = Join-Path $temporary "ddnsto_windows_cli_$Version.zip"
$extract = Join-Path $temporary 'extract'
$binary = Join-Path $InstallDir 'ddnsto_cli.x86_64.exe'
$config = Join-Path $InstallDir 'ddnsto.yaml'
$backup = Join-Path $InstallDir 'ddnsto_cli.x86_64.exe.bak'
try {
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/ddnsto_windows_cli_$Version.zip" -OutFile $archive
    $actualSha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha -ne $archiveSha[$Version]) { throw 'DDNSTO: Windows archive checksum mismatch' }
    Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
    $candidate = Join-Path $extract 'ddnsto_cli.x86_64.exe'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'DDNSTO: Windows CLI is missing from archive' }
    $versionInfo = Get-Content -LiteralPath (Join-Path $extract 'version.txt') -Raw
    $binarySha = ([regex]::Match($versionInfo, 'DDNSTO_X86_SHA256=([0-9a-fA-F]{64})')).Groups[1].Value.ToLowerInvariant()
    if (-not $binarySha) { throw 'DDNSTO: Windows binary checksum is missing' }
    if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant() -ne $binarySha) { throw 'DDNSTO: Windows binary checksum mismatch' }
    if (Test-Path -LiteralPath $binary) { Copy-Item -LiteralPath $binary -Destination $backup -Force }
    Copy-Item -LiteralPath $candidate -Destination $binary -Force
    Set-Content -LiteralPath $config -Value @("userToken: $Token", "logPath: $InstallDir\ddnsto.log") -Encoding UTF8
    & icacls.exe $config /inheritance:r /grant:r 'SYSTEM:F' 'Administrators:F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'DDNSTO: failed to protect token configuration' }
    $action = New-ScheduledTaskAction -Execute $binary -Argument "--config `"$config`""
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $trigger = New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Trigger $trigger -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Output "DDNSTO $Version installed at $binary"
    Write-Output "Scheduled task: $TaskName"
} catch {
    if (Test-Path -LiteralPath $backup) { Copy-Item -LiteralPath $backup -Destination $binary -Force }
    throw
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
