param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$Entry,
    [Parameter(Mandatory = $true)][string]$SealedBundle,
    [Parameter(Mandatory = $true)][string]$Zsetup,
    [Parameter(Mandatory = $true)][string]$Ca,
    [Parameter(Mandatory = $true)][string]$Pfx
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Quote-Native([string]$Value) {
    $quoted = [Regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $quoted = [Regex]::Replace($quoted, '(\\+)$', '$1$1')
    return '"' + $quoted + '"'
}
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $File; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8; $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $start.Arguments = (@($Arguments | ForEach-Object { Quote-Native ([string]$_) }) -join ' ')
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        [void]$process.Start(); $out = $process.StandardOutput.ReadToEnd(); $err = $process.StandardError.ReadToEnd(); $process.WaitForExit()
        return [ordered]@{ exit_code = $process.ExitCode; stdout = $out; stderr = $err }
    } finally { if ($process.Id -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
}

New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null
$profile = Join-Path $RunRoot 'profile'
$root = Join-Path $profile 'scoop via zsetup'
$cache = Join-Path $profile 'cache via zsetup'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$entryHash = (Get-FileHash -LiteralPath $Entry -Algorithm SHA256).Hash.ToLowerInvariant()
$entrySize = (Get-Item -LiteralPath $Entry).Length
$indexPath = Join-Path $RunRoot 'index.json'
$index = [ordered]@{
    schema_version = 1
    entries = @([ordered]@{
        application = 'scoop'; os = 'windows'; package_manager = '*'; arch = 'x86_64'
        urls = @('https://127.0.0.1:64444/scoop/0.1.0/scoop-install.ps1'); fallback_url = $null
        sha256 = $entryHash; background = $false; min_version = '0.1.0'
    })
}
[IO.File]::WriteAllText($indexPath, (($index | ConvertTo-Json -Depth 8) + "`n"), $utf8)

$server = Start-Job -ArgumentList $Pfx, $Entry -ScriptBlock {
    param($PfxPath, $PayloadPath)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 64444)
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxPath, 'm5-fixture')
    try {
        $listener.Start(); $client = $listener.AcceptTcpClient()
        try {
            $stream = [Net.Security.SslStream]::new($client.GetStream(), $false)
            try {
                $stream.AuthenticateAsServer($certificate, $false, [Security.Authentication.SslProtocols]::Tls12, $false)
                $request = [Collections.Generic.List[byte]]::new(); $tail = ''
                while ($request.Count -lt 8192 -and $tail -ne "`r`n`r`n") {
                    $value = $stream.ReadByte(); if ($value -lt 0) { break }; $request.Add([byte]$value)
                    $tail += [char]$value; if ($tail.Length -gt 4) { $tail = $tail.Substring($tail.Length - 4) }
                }
                $requestText = [Text.Encoding]::ASCII.GetString($request.ToArray())
                if ($requestText -notmatch '^GET /scoop/0\.1\.0/scoop-install\.ps1 HTTP/1\.[01]\r\n') { throw 'unexpected zsetup fixture request' }
                $payload = [IO.File]::ReadAllBytes($PayloadPath)
                $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n")
                $stream.Write($header, 0, $header.Length); $stream.Write($payload, 0, $payload.Length); $stream.Flush()
            } finally { $stream.Dispose() }
        } finally { $client.Dispose() }
    } finally { $listener.Stop(); $certificate.Dispose() }
}
try {
    Start-Sleep -Milliseconds 800
    $env:USERPROFILE = $profile
    $env:ZSETUP_CA_FILE = $Ca
    $env:ZSETUP_CONFIG_CACHE = Join-Path $RunRoot 'lkg.json'
    $env:ZSETUP_MANAGED_ROOT = Join-Path $RunRoot 'managed'
    $env:ZSETUP_CACHE_DIR = Join-Path $RunRoot 'installer-cache'
    $arguments = @('install', '--index', $indexPath, 'scoop', '--foreground', '--', '--installer-scope', 'user', '--installer-root', $root, '--installer-cache', $cache, '--installer-bundle', $SealedBundle, '--installer-allow-admin')
    $result = Invoke-Native $Zsetup $arguments
    [IO.File]::WriteAllText((Join-Path $RunRoot 'zsetup.stdout'), $result.stdout, $utf8)
    [IO.File]::WriteAllText((Join-Path $RunRoot 'zsetup.stderr'), $result.stderr, $utf8)
    Assert-True ($result.exit_code -eq 0) ("zsetup install failed: " + $result.stderr)
    $receipt = $result.stdout | ConvertFrom-Json -ErrorAction Stop
    Assert-True ($receipt.status -eq 'passed' -and $receipt.transport -eq 'sealed-bundle') 'zsetup did not return the M6 install receipt'
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'shims\scoop.ps1') -PathType Leaf) 'zsetup installation shim missing'
    Assert-True ((Get-FileHash -LiteralPath (Get-ChildItem -LiteralPath (Join-Path $RunRoot 'installer-cache') -Filter 'scoop-*.ps1' -Recurse | Select-Object -First 1).FullName -Algorithm SHA256).Hash.ToLowerInvariant() -eq $entryHash) 'zsetup cached entry mismatch'
} finally {
    if ($server) {
        if ($server.State -eq 'Running') { try { $client = [Net.Sockets.TcpClient]::new(); $client.Connect('127.0.0.1', 64444); $client.Dispose() } catch {} }
        Wait-Job $server -Timeout 5 -ErrorAction SilentlyContinue | Out-Null
        Stop-Job $server -ErrorAction SilentlyContinue; Remove-Job $server -Force -ErrorAction SilentlyContinue
    }
}

[ordered]@{
    schema_version = 1; status = 'passed'; transport = 'local-https-entry-plus-sealed-business'
    zsetup_version = (& $Zsetup --version).Trim(); zsetup_sha256 = (Get-FileHash $Zsetup -Algorithm SHA256).Hash.ToLowerInvariant()
    entry_sha256 = $entryHash; sealed_bundle_sha256 = (Get-FileHash $SealedBundle -Algorithm SHA256).Hash.ToLowerInvariant()
    root = $root; cache = $cache; explicit_admin_override = $true
} | ConvertTo-Json -Depth 5
