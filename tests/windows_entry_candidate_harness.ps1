# Lab-only transport seam: stage local reviewed installer bytes, keep real ACL,
# manifest/SHA checks and business operations. Does not publish or change TLS trust.
param([string]$SourceRoot, [string]$Token, [string]$Action = 'ensure', [switch]$Plan)
$ErrorActionPreference = 'Stop'
$script:CandidateRoot = $SourceRoot
$source = [IO.File]::ReadAllText((Join-Path $SourceRoot 'recommended-entry.ps1'))
$source = $source.Replace('@@SOURCE_URL@@', 'https://candidate.invalid/ddnsto').Replace('@@CACHE_KEY@@', 'windows-validation-20261118')
$transport = @'
function Receive-Bounded([string]$Url, [string]$Destination, [int]$Limit) {
    $candidate = Join-Path $script:CandidateRoot 'install.ps1'
    $digest = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    $size = (Get-Item -LiteralPath $candidate).Length
    if ($Url -eq 'https://candidate.invalid/ddnsto/recommended-powershell.txt') {
        [IO.File]::WriteAllText($Destination, "ddnsto-recommendation-v1-powershell`n$digest`n$size`n", [Text.Encoding]::ASCII)
    } elseif ($Url -eq "https://candidate.invalid/ddnsto/immutable/$digest/install.ps1") {
        Copy-Item -LiteralPath $candidate -Destination $Destination
    } else { throw 'Unexpected lab source' }
    if ((Get-Item -LiteralPath $Destination).Length -gt $Limit) { throw 'Lab size exceeded' }
    return $true
}
'@
$offset = $source.IndexOf("`ntry {`n")
if ($offset -lt 0) { throw 'Missing wrapper main boundary' }
$source = $source.Insert($offset, "`n" + $transport + "`n")
& ([scriptblock]::Create($source)) -Token $Token -Action $Action -Plan:$Plan
