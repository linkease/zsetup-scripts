# Actual ACL/collision acceptance on Windows; Linux still compiles the P/Invoke helper.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Assert($Ok,$Message) { if (-not $Ok) { throw $Message } }
Initialize-DDNSTODiagnosticNative
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Output 'Windows diagnostic native helper compiled; SKIP actual Windows ACL/syscall validation on Linux'
    exit 0
}
$log=New-DDNSTODiagnostic
Assert ($null -ne $log) 'native private log creation failed'
$directory=[IO.Path]::GetDirectoryName($log.Path)
try {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try { $allowed=@('S-1-5-18',$identity.User.Value) } finally { $identity.Dispose() }
    $acl=Get-Acl -LiteralPath $directory
    Assert $acl.AreAccessRulesProtected 'directory inherited public permissions'
    foreach ($path in @($directory,$log.Path)) {
        $rules=(Get-Acl -LiteralPath $path).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) {
            Assert ($rule.IdentityReference.Value -in $allowed) 'unexpected principal can access log'
            Assert ($rule.AccessControlType -eq 'Allow') 'unexpected ACL type'
        }
    }
    $before=(Get-Acl -LiteralPath $directory).Sddl
    $failed=$false
    try { New-DDNSTOPrivateDiagnosticDirectory $directory } catch { $failed=$true }
    Assert $failed 'native directory creation accepted collision'
    Assert ((Get-Acl -LiteralPath $directory).Sddl -ceq $before) 'collision changed existing ACL'
    $script:DDNSTODiagnostic=$log
    Write-DDNSTODiagnosticEvent 'started'
    Write-DDNSTODiagnosticEvent 'failed' 3
    Assert ([IO.File]::ReadAllText($log.Path) -match '"event":"failed","code":3') 'native log not readable'
    Write-Output 'Windows diagnostic native ACL, directory collision and file writes passed'
} finally {
    $log.Stream.Dispose(); $script:DDNSTODiagnostic=$null
    Remove-Item -LiteralPath $directory -Recurse -Force
}
