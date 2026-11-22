# Generated public entry embeds the same reviewed POSIX installer; no extra download.
# jq is a native Windows executable. Installation policy runs in Git Bash.
$ErrorActionPreference = 'Stop'
$jqArguments = @($args)
# Windows PowerShell 5.1's native binder rewrites embedded Bash quotes and
# drops empty arguments. Build the Windows argv directly for both PS5 and PS7.
function ConvertTo-JqNativeArgument([string]$Value) {
    $quoted = [Regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $quoted = [Regex]::Replace($quoted, '(\\+)$', '$1$1')
    return '"' + $quoted + '"'
}
$bashCandidates = @()
if ($env:ZSETUP_BASH_BIN) { $bashCandidates += $env:ZSETUP_BASH_BIN }
if ($env:ProgramFiles) { $bashCandidates += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe') }
if ($env:LOCALAPPDATA) { $bashCandidates += (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe') }
$jqBash = $bashCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $jqBash) { throw 'Git Bash is required. Install Git.Git first or set ZSETUP_BASH_BIN to Git Bash; Windows native validation remains pending.' }
if (-not $env:ZSETUP_BIN) {
    $jqCore = Get-Command zsetup.exe -ErrorAction SilentlyContinue
    if (-not $jqCore) { throw 'Install native zsetup first, or set ZSETUP_BIN to its trusted executable.' }
    $env:ZSETUP_BIN = $jqCore.Source
}
$jqSavedOs = $env:ZSETUP_OS
$jqSavedArch = $env:ZSETUP_ARCH
$jqSavedMode = $env:ZSETUP_INSTALLER_MODE
$jqStage = Join-Path ([IO.Path]::GetTempPath()) ('zsetup-jq-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($jqStage) | Out-Null
$jqScript = Join-Path $jqStage 'jq-install.sh'
try {
    [IO.File]::WriteAllBytes($jqScript, [Convert]::FromBase64String('@JQ_BASH_PAYLOAD@'))
    $env:ZSETUP_OS = 'windows'
    $jqArchitecture = & $env:ZSETUP_BIN context get arch
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $env:ZSETUP_ARCH = ($jqArchitecture | Out-String).Trim()
    $env:ZSETUP_INSTALLER_MODE = '1'
    $jqStart = New-Object Diagnostics.ProcessStartInfo
    $jqStart.FileName = $jqBash
    $jqStart.UseShellExecute = $false
    $jqArgv = @('--noprofile', '--norc', '-c', 'exec sh "$(cygpath -u "$1")" "${@:2}"', 'jq-installer', $jqScript) + $jqArguments
    $jqStart.Arguments = (@($jqArgv | ForEach-Object { ConvertTo-JqNativeArgument ([string]$_) }) -join ' ')
    $jqProcess = New-Object Diagnostics.Process
    $jqProcess.StartInfo = $jqStart
    try {
        [void]$jqProcess.Start()
        $jqProcess.WaitForExit()
        $jqExitCode = $jqProcess.ExitCode
    } finally {
        if ($jqProcess.Id -and -not $jqProcess.HasExited) { $jqProcess.Kill(); $jqProcess.WaitForExit() }
        $jqProcess.Dispose()
    }
} finally {
    $env:ZSETUP_OS = $jqSavedOs
    $env:ZSETUP_ARCH = $jqSavedArch
    $env:ZSETUP_INSTALLER_MODE = $jqSavedMode
    Remove-Item -LiteralPath $jqStage -Recurse -Force
}
exit $jqExitCode
