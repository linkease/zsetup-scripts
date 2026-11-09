# Local process integration for the Windows installer's bounded version probe.
# Linux fixture executables exercise ProcessStartInfo without a Windows client.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Assert($Ok,$Message) { if (-not $Ok) { throw $Message } }
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    Write-Output 'SKIP: shell process fixtures require Linux; Windows native client canary remains separate'
    exit 0
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ddnsto-version-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
$binary=Join-Path $root 'client'
try {
    foreach ($case in @(
        @{Body='printf "4.2.10\n"'; Good=$true},
        @{Body='printf "4.2.10\n"; head -c 4096 /dev/zero >&2'; Good=$true},
        @{Body='printf "4.2.10\n"; head -c 4097 /dev/zero >&2'; Good=$false},
        @{Body='printf "4.2.10\n"; head -c 5000 /dev/zero >&2'; Good=$false},
        @{Body='head -c 5000 /dev/zero | tr "\000" " "; printf "4.2.10\n"'; Good=$false},
        @{Body='printf "4.2.8\n"; exit 7'; Good=$false},
        @{Body='printf "not-a-version\n"'; Good=$false},
        @{Body='printf "4.2.8\n5.0.0\n"'; Good=$false},
        @{Body='exec sleep 30'; Good=$false}
    )) {
        [IO.File]::WriteAllText($binary, "#!/bin/sh`n"+'[ "$1" = "-v" ] || exit 9'+"`n"+$case.Body+"`n", (New-Object Text.UTF8Encoding($false)))
        & chmod 700 $binary
        $failed=$false; $watch=[Diagnostics.Stopwatch]::StartNew()
        try { $version=Get-DDNSTOClientVersion $binary } catch {
            $failed=$true
            Assert ($_.Exception.Data['DDNSTOCode'] -eq 4) 'version failure lacks code'
        }
        Assert ($failed -ne $case.Good) 'version result wrong'
        if ($case.Good) { Assert ($version -ceq '4.2.10') 'numeric version altered' }
        Assert ($watch.Elapsed.TotalSeconds -lt 10) 'version probe not bounded'
    }
    Write-Output 'Windows version probe: numeric output, invalid output, failure exit and timeout passed (Linux process fixtures)'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
