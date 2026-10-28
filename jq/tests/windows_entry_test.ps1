# Native public-entry regression. Run with PS5.1 and PS7; no package downloads.
param(
    [Parameter(Mandatory=$true)][string]$Entry,
    [Parameter(Mandatory=$true)][string]$Core,
    [Parameter(Mandatory=$true)][string]$Bash
)
$ErrorActionPreference = 'Stop'
$work = Join-Path ([IO.Path]::GetTempPath()) ('jq-entry-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work) | Out-Null
$engine = (Get-Process -Id $PID).Path
$entry64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Entry))
$saved = @{}
foreach ($key in @('ZSETUP_BIN','ZSETUP_BASH_BIN','ZSETUP_OS','ZSETUP_ARCH','ZSETUP_INSTALLER_MODE')) {
    $saved[$key] = [Environment]::GetEnvironmentVariable($key)
}
function Invoke-Entry([string[]]$Arguments) {
    $json64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($Arguments) -Compress)))
    $script = '$a=[string[]]([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('''+$json64+'''))|ConvertFrom-Json);$e=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('''+$entry64+'''));& $e @a;exit $LASTEXITCODE'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $engine
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $info
    try {
        [void]$p.Start()
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(15000)) { $p.Kill(); $p.WaitForExit(); throw 'Public entry timed out' }
        return @{code=$p.ExitCode;out=$stdout.Result;err=$stderr.Result}
    } finally { $p.Dispose() }
}
try {
    $env:ZSETUP_BIN = $Core
    $env:ZSETUP_BASH_BIN = $Bash
    $help = Invoke-Entry @('--help')
    if ($help.code -ne 0 -or $help.out -notmatch 'Installs only a pinned, verified jq') {
        throw ('Public --help failed: code='+$help.code+' '+$help.err)
    }
    $plan = Invoke-Entry @('--plan')
    if ($plan.code -ne 0 -or $plan.out -notmatch 'platform=windows' -or $plan.out -notmatch 'artifact=jq-windows-') {
        throw ('Public --plan failed: code='+$plan.code+' '+$plan.err)
    }
    $invalid = Invoke-Entry @('')
    if ($invalid.code -ne 2) { throw 'Empty argument was lost instead of being rejected with exit 2' }
    # External native executable fixture records the public process argv verbatim.
    $fixture = Join-Path $work 'argv fixture.exe'
    Add-Type -OutputAssembly $fixture -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.Text;
public static class JqEntryArgvFixture {
    public static int Main(string[] args) {
        foreach (string arg in args) Console.WriteLine("ARG="+Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
        return 37;
    }
}
'@
    $env:ZSETUP_BASH_BIN = $fixture
    $values = @('', 'space text', ([string][char]0x4E2D + [char]0x6587), 'a"b', 'a\"b', 'trailing\', '$(literal)', '; echo literal')
    $result = Invoke-Entry $values
    if ($result.code -ne 37) { throw ('Native exit 37 was lost: '+$result.code+' '+$result.err) }
    $actual = @($result.out -split '\r?\n' | Where-Object { $_.StartsWith('ARG=') } | ForEach-Object {
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Substring(4)))
    })
    if ($actual.Count -lt $values.Count) { throw ('Native argv count mismatch: actual='+$actual.Count+' expected='+$values.Count+' outputBytes='+$result.out.Length) }
    $offset = $actual.Count - $values.Count
    for ($i=0; $i -lt $values.Count; $i++) {
        if ($actual[$offset+$i] -cne $values[$i]) { throw ('Native argument was changed at index '+$i) }
    }
    [Console]::WriteLine('jq-public-entry: help, plan, empty argument, literal argv and exit 37 passed')
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    Remove-Item -LiteralPath $work -Recurse -Force
}
