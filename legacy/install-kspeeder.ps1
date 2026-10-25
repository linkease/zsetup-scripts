param(
  [string]$LocalDir = ""
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
  $principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
  return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Add-SystemPathEntry {
  param([string]$PathEntry)

  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $entries = @()
  if ($machinePath) {
    $entries = $machinePath -split ';' | Where-Object { $_ -ne "" }
  }
  foreach ($entry in $entries) {
    if ($entry.TrimEnd('\') -ieq $PathEntry.TrimEnd('\')) {
      return
    }
  }
  $newPath = if ($machinePath) { "$machinePath;$PathEntry" } else { $PathEntry }
  [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
  $env:Path = "$env:Path;$PathEntry"
  Write-Host "已加入系统 PATH: $PathEntry"
}

function Test-ForceDockerInstall {
  $value = $env:KSPEEDER_INSTALL_FORCE_DOCKER
  if (-not $value) {
    return $false
  }
  return @("1", "true", "yes", "y", "on") -contains $value.Trim().ToLowerInvariant()
}

function Test-YesInstall {
  $value = $env:KSPEEDER_INSTALL_YES
  if (-not $value) {
    return $false
  }
  return @("1", "true", "yes", "y", "on") -contains $value.Trim().ToLowerInvariant()
}

function Get-InstallerArgs {
  param(
    [switch]$ForceDocker,
    [switch]$Yes,
    [string]$VersionUrl = "",
    [string]$Listen = "",
    [string]$Admin = "",
    [string]$CachePath = ""
  )

  if (-not $ForceDocker -and -not $Yes -and -not $VersionUrl -and -not $Listen -and -not $Admin -and -not $CachePath) {
    return @("installer")
  }

  $installerArgs = @("installer", "install")
  if ($Yes) {
    $installerArgs += "--yes"
  }
  if ($VersionUrl) {
    $installerArgs += @("--version-url", $VersionUrl)
  }
  if ($Listen) {
    $installerArgs += @("--listen", $Listen)
  }
  if ($Admin) {
    $installerArgs += @("--admin", $Admin)
  }
  if ($CachePath) {
    $installerArgs += @("--cache-path", $CachePath)
  }
  if ($ForceDocker) {
    $installerArgs += "--force-docker"
  }
  return $installerArgs
}

function Invoke-KSInstaller {
  param(
    [string]$Target,
    [switch]$ForceDocker,
    [switch]$Yes,
    [string]$VersionUrl = "",
    [string]$Listen = "",
    [string]$Admin = "",
    [string]$CachePath = ""
  )

  if ($ForceDocker) {
    Write-Host "已启用 KSPEEDER_INSTALL_FORCE_DOCKER，将使用 Docker Compose 安装 KSpeeder。"
  }
  $installerArgs = Get-InstallerArgs -ForceDocker:$ForceDocker -Yes:$Yes -VersionUrl $VersionUrl -Listen $Listen -Admin $Admin -CachePath $CachePath
  & $Target @installerArgs
  if ($LASTEXITCODE -ne $null) {
    exit $LASTEXITCODE
  }
}

function Install-KSCLI {
  param([string]$SourcePath)

  $targetDir = Join-Path $env:ProgramData "KSpeeder\bin"
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
  $target = Join-Path $targetDir "ks-cli.exe"
  Copy-Item -Force $SourcePath $target
  Add-SystemPathEntry -PathEntry $targetDir
  Write-Host "ks-cli 已安装到: $target"
  return $target
}

function Invoke-ElevatedInstall {
  param([string]$SourcePath)

  $scriptPath = Join-Path $env:TEMP ("install-kspeeder-elevated-{0}.ps1" -f ([Guid]::NewGuid().ToString("N")))
  $script = @'
param(
  [Parameter(Mandatory = $true)]
  [string]$SourcePath,
  [switch]$ForceDocker,
  [switch]$Yes,
  [string]$VersionUrl = "",
  [string]$Listen = "",
  [string]$Admin = "",
  [string]$CachePath = ""
)

$ErrorActionPreference = "Stop"

function Add-SystemPathEntry {
  param([string]$PathEntry)

  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $entries = @()
  if ($machinePath) {
    $entries = $machinePath -split ';' | Where-Object { $_ -ne "" }
  }
  foreach ($entry in $entries) {
    if ($entry.TrimEnd('\') -ieq $PathEntry.TrimEnd('\')) {
      return
    }
  }
  $newPath = if ($machinePath) { "$machinePath;$PathEntry" } else { $PathEntry }
  [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
  $env:Path = "$env:Path;$PathEntry"
  Write-Host "已加入系统 PATH: $PathEntry"
}

function Invoke-KSInstaller {
  param(
    [string]$Target,
    [switch]$ForceDocker,
    [switch]$Yes,
    [string]$VersionUrl = "",
    [string]$Listen = "",
    [string]$Admin = "",
    [string]$CachePath = ""
  )

  if ($ForceDocker) {
    Write-Host "已启用 KSPEEDER_INSTALL_FORCE_DOCKER，将使用 Docker Compose 安装 KSpeeder。"
  }
  if (-not $ForceDocker -and -not $Yes -and -not $VersionUrl -and -not $Listen -and -not $Admin -and -not $CachePath) {
    $installerArgs = @("installer")
  } else {
    $installerArgs = @("installer", "install")
    if ($Yes) {
      $installerArgs += "--yes"
    }
    if ($VersionUrl) {
      $installerArgs += @("--version-url", $VersionUrl)
    }
    if ($Listen) {
      $installerArgs += @("--listen", $Listen)
    }
    if ($Admin) {
      $installerArgs += @("--admin", $Admin)
    }
    if ($CachePath) {
      $installerArgs += @("--cache-path", $CachePath)
    }
    if ($ForceDocker) {
      $installerArgs += "--force-docker"
    }
  }
  & $Target @installerArgs
  if ($LASTEXITCODE -ne $null) {
    exit $LASTEXITCODE
  }
}

$targetDir = Join-Path $env:ProgramData "KSpeeder\bin"
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
$target = Join-Path $targetDir "ks-cli.exe"
Copy-Item -Force $SourcePath $target
Add-SystemPathEntry -PathEntry $targetDir
Write-Host "ks-cli 已安装到: $target"
Invoke-KSInstaller -Target $target -ForceDocker:$ForceDocker -Yes:$Yes -VersionUrl $VersionUrl -Listen $Listen -Admin $Admin -CachePath $CachePath
'@
  Set-Content -Path $scriptPath -Value $script -Encoding UTF8
  try {
    Write-Host "需要管理员权限，正在请求提升权限..."
    $quotedScriptPath = '"' + $scriptPath.Replace('"', '\"') + '"'
    $quotedSourcePath = '"' + $SourcePath.Replace('"', '\"') + '"'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath -SourcePath $quotedSourcePath"
    if (Test-ForceDockerInstall) {
      $arguments = "$arguments -ForceDocker"
    }
    if (Test-YesInstall) {
      $arguments = "$arguments -Yes"
    }
    if ($env:KSPEEDER_INSTALL_VERSION_URL) {
      $quotedVersionUrl = '"' + $env:KSPEEDER_INSTALL_VERSION_URL.Replace('"', '\"') + '"'
      $arguments = "$arguments -VersionUrl $quotedVersionUrl"
    }
    if ($env:KSPEEDER_INSTALL_LISTEN) {
      $quotedListen = '"' + $env:KSPEEDER_INSTALL_LISTEN.Replace('"', '\"') + '"'
      $arguments = "$arguments -Listen $quotedListen"
    }
    if ($env:KSPEEDER_INSTALL_ADMIN) {
      $quotedAdmin = '"' + $env:KSPEEDER_INSTALL_ADMIN.Replace('"', '\"') + '"'
      $arguments = "$arguments -Admin $quotedAdmin"
    }
    if ($env:KSPEEDER_INSTALL_CACHE_PATH) {
      $quotedCachePath = '"' + $env:KSPEEDER_INSTALL_CACHE_PATH.Replace('"', '\"') + '"'
      $arguments = "$arguments -CachePath $quotedCachePath"
    }
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
      throw "提升权限后的安装流程退出码: $($process.ExitCode)"
    }
  } finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $scriptPath
  }
}

$baseUrl = "https://kspeeder.com/bin"
$arch = $env:PROCESSOR_ARCHITECTURE

switch ($arch) {
  "AMD64" { $arch = "amd64" }
  "ARM64" { $arch = "arm64" }
  default { throw "Unsupported arch: $arch" }
}

$filename = "ks-cli-win-$arch.exe"
$url = "$baseUrl/$filename"

if ($LocalDir) {
  $source = Join-Path $LocalDir $filename
  if (-not (Test-Path $source)) {
    throw "Local ks-cli not found: $source"
  }
} else {
  $source = Join-Path $env:TEMP $filename
  Write-Host "正在下载 ks-cli: $url"
  try {
    Start-BitsTransfer -Source $url -Destination $source
  } catch {
    Write-Host "BITS 下载失败，尝试使用 Invoke-WebRequest..."
    Invoke-WebRequest -Uri $url -OutFile $source
  }
  $size = (Get-Item $source).Length
  if ($size -gt 0) {
    $mb = [Math]::Round($size / 1MB, 2)
    Write-Host "已下载: ${mb} MB"
  }
}

if (-not (Test-IsAdministrator)) {
  try {
    Invoke-ElevatedInstall -SourcePath $source
    exit 0
  } catch {
    Write-Error "提升权限失败，请以管理员身份运行 PowerShell 后重试: $source installer"
    exit 1
  }
}

$target = Install-KSCLI -SourcePath $source
Invoke-KSInstaller -Target $target -ForceDocker:(Test-ForceDockerInstall) -Yes:(Test-YesInstall) -VersionUrl $env:KSPEEDER_INSTALL_VERSION_URL -Listen $env:KSPEEDER_INSTALL_LISTEN -Admin $env:KSPEEDER_INSTALL_ADMIN -CachePath $env:KSPEEDER_INSTALL_CACHE_PATH
