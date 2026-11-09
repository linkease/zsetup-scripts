$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Assert($Ok,$Message) { if (-not $Ok) { throw $Message } }
$sentinel='do-not-log-this-credential'
function Get-DDNSTODiagnosticBase { throw 'fixture private logging unavailable' }
# Use the actual public boundary; arbitrary lower-level exceptions must be sanitized.
function Invoke-DDNSTOInstall { throw $sentinel }
try { Invoke-DDNSTOEntry -Token $sentinel; throw 'unexpected success' } catch {
    Assert ($_.Exception.Data['DDNSTOCode'] -eq 2) 'missing failure code'
    Assert ($_.Exception.Message -notmatch $sentinel) 'credential leaked'
    Assert ($_.Exception.Message -match '状态：.*下一步：.*错误码：2') 'incomplete Chinese diagnostic'
    Assert ($_.Exception.Message -match '诊断日志不可用') 'diagnostic failure must be explicit'
}
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../install.ps1'))
Assert ($source -notmatch 'Read-Host|ExecutionPolicy|EncodedCommand|Verb RunAs') 'interactive or unsafe elevation path'
Assert ($source -notmatch 'Write-Warning[^\r\n]*\$work') 'warnings must not print user-controlled backup paths'
$bytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '../install.ps1'))
Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'Windows PowerShell 5.1 needs UTF-8 BOM for Chinese diagnostics'
# A separate interpreter checks the public process exit and stderr contract.
$runner=(Get-Process -Id $PID).Path
$entry=Join-Path $PSScriptRoot '../install.ps1'
$output=& $runner -NoProfile -File $entry -Platform invalid -Token $sentinel 2>&1
Assert ($LASTEXITCODE -eq 2) 'public process returned wrong exit code'
Assert (($output -join "`n") -notmatch $sentinel) 'public error leaked token'
Assert (($output -join "`n") -match '错误码：2') 'public error lost concise diagnostic'
Write-Output 'Windows errors: sanitized Chinese diagnostics and safe privilege fallback passed'
