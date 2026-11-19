param([string]$SourceRoot)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$source = [IO.File]::ReadAllText((Join-Path $SourceRoot 'recommended-entry.ps1'))
$root = Join-Path $env:TEMP ('ddnsto-entry-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$failures = 0
try {
    try {
        $work = $root
        $scriptPath = Join-Path $root 'install.ps1'
        $cachedScript = Join-Path $root 'cached-target.ps1'
        $manifest = Join-Path $root 'manifest.txt'
        $cachedManifest = Join-Path $root 'cached-manifest.txt'
        [IO.File]::WriteAllText($scriptPath, 'new-script')
        [IO.File]::WriteAllText($cachedScript, 'old-script')
        [IO.File]::WriteAllText($manifest, 'new-manifest')
        [IO.File]::WriteAllText($cachedManifest, 'old-manifest')
        $cacheBlock = $source.Substring($source.IndexOf('    # File.Replace'))
        $cacheBlock = $cacheBlock.Substring(0, $cacheBlock.IndexOf('    $lease.Dispose()'))
        & ([scriptblock]::Create($cacheBlock))
        if ([IO.File]::ReadAllText($cachedScript) -ne 'new-script' -or [IO.File]::ReadAllText($cachedManifest) -ne 'new-manifest') { throw 'cache content mismatch' }
        'PASS cache replacement'
    } catch { $failures++; 'FAIL cache replacement: ' + $_.Exception.Message }
    try {
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'install.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count) { throw 'generated installer has parser errors' }
        'PASS generated installer parser'
    } catch { $failures++; 'FAIL generated installer parser' }
    $invoke = $source.Substring($source.IndexOf('    # Hashtable splatting'))
    $invoke = $invoke.Substring(0, $invoke.IndexOf('} catch {'))
    foreach ($code in @(0, 23)) {
        try {
            [IO.File]::WriteAllText($scriptPath, ('param($Token) if($Token -cne "literal''token"){exit 99}; exit ' + $code))
            $body = '$ErrorActionPreference="Stop"; $scriptPath=''' + $scriptPath.Replace("'", "''") + '''; $forward=@{Token="literal''token"}; try {' + $invoke + '} catch { exit 1 }'
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
            & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -EncodedCommand $encoded
            if ($LASTEXITCODE -ne $code) { throw "expected $code got $LASTEXITCODE" }
            "PASS executor exit $code and literal token"
        } catch { $failures++; 'FAIL executor: ' + $_.Exception.Message }
    }
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
if ($failures) { exit 1 }
