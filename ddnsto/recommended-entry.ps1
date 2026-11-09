# Stable Windows PowerShell 5.1 template. No remote expressions or downloaded
# native executable are used to establish trust. Lifecycle belongs to install.ps1.
param([string]$Token, [string]$TokenFile, [string]$Version,
      [string]$InstallDir, [string]$Platform, [string]$Method,
      [switch]$Plan, [string]$Action)
Set-PSDebug -Off
$ErrorActionPreference = 'Stop'
$forward = @{} + $PSBoundParameters
$base = '@@SOURCE_URL@@'
$cacheKey = '@@CACHE_KEY@@'
$script:entryCode = 11
$script:entryMessage = $null
$work = $null
$lease = $null

function Stop-Recommendation([string]$Reason, [string]$Next, [int]$Code = 11) {
    $script:entryCode = $Code
    $script:entryMessage = "DDNSTO：$Reason；状态=推荐入口未执行安装；下一步=$Next；code=$Code"
    throw $script:entryMessage
}

function Assert-SafePath([string]$Path, [switch]$Private) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Stop-Recommendation '缓存含重解析路径' '选择本人私有目录' 12
    }
    $acl = Get-Acl -LiteralPath $Path
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trusted = @($sid, 'S-1-5-18', 'S-1-5-32-544') # user, SYSTEM, administrators
    if (-not $Private) {
        # Windows volume roots may be owned/maintained by TrustedInstaller.
        # Trust its exact service SID only for ancestors, never private cache
        # objects. Do not trust arbitrary service SIDs or localized names.
        $trusted += 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    }
    # An untrusted ancestor owner can rewrite its DACL even when no ACE grants
    # write access today. Ownership is required at every level, not just cache.
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) {
        Stop-Recommendation '缓存所有者不安全' '选择本人私有目录' 12
    }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        # InheritOnly applies to descendants, not the object being inspected.
        # Each existing descendant is checked separately along the path.
        if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.IdentityReference.Value -in $trusted) { continue }
        # Ancestors may permit creating new children (e.g. volume root), but
        # must not permit deleting/replacing existing children or changing ACLs.
        $mask = [Security.AccessControl.FileSystemRights]::Delete -bor
                [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
                [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                [Security.AccessControl.FileSystemRights]::TakeOwnership
        if ($Private) { $mask = $mask -bor [Security.AccessControl.FileSystemRights]::Write }
        if ($rule.FileSystemRights -band $mask) {
            Stop-Recommendation '缓存权限不安全' '移除其他用户的写入权限' 12
        }
    }
}

function New-PrivateDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetOwner($sid)
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        # Windows PowerShell/.NET Framework creates the directory with its ACL,
        # avoiding a create-then-protect interval.
        [IO.Directory]::CreateDirectory($Path, $acl) | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Stop-Recommendation '缓存路径不是目录' '选择本人私有目录' 12
    }
    Assert-SafePath $Path -Private
}

function Receive-Bounded([string]$Url, [string]$Path, [int]$Limit) {
    $response = $null; $stream = $null; $file = $null
    try {
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.AllowAutoRedirect = $false
        $request.Timeout = 20000
        $request.ReadWriteTimeout = 5000
        try { $response = $request.GetResponse() }
        catch [Net.WebException] {
            if ($_.Exception.Response) { $response = $_.Exception.Response }
            elseif ($_.Exception.Status -in @([Net.WebExceptionStatus]::NameResolutionFailure,
                        [Net.WebExceptionStatus]::ConnectFailure, [Net.WebExceptionStatus]::Timeout)) { return $false }
            else { Stop-Recommendation 'HTTPS 校验失败' '检查证书和网络' }
        }
        $status = [int]$response.StatusCode
        if ($status -in @(404, 500, 502, 503, 504)) { return $false }
        if ($status -ne 200 -or $response.ContentLength -gt $Limit) {
            Stop-Recommendation '推荐源响应异常' '检查发布路径、大小及重定向' }
        $stream = $response.GetResponseStream()
        $file = [IO.File]::Open($Path, 'Create', 'Write', 'None')
        $buffer = New-Object byte[] 8192
        $total = 0
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            try { $count = $stream.Read($buffer, 0, [Math]::Min($buffer.Length, $Limit - $total + 1)) }
            catch {
                # PowerShell wraps Read exceptions. .NET Framework and .NET
                # may report timeout via WebException or IOException/SocketException.
                # Classify typed timeouts only; integrity, TLS and other I/O
                # failures must not turn into permission to use stale cache.
                $readError = $_.Exception
                while ($readError) {
                    if ($readError -is [TimeoutException] -or
                        ($readError -is [Net.WebException] -and $readError.Status -eq [Net.WebExceptionStatus]::Timeout) -or
                        ($readError -is [Net.Sockets.SocketException] -and $readError.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut)) {
                        return $false
                    }
                    $readError = $readError.InnerException
                }
                throw
            }
            $total += $count
            if ($total -gt $Limit) {
                Stop-Recommendation '下载超过大小限制' '核对发布文件后重试' }
            if ($timer.Elapsed.TotalSeconds -gt 20) { return $false }
            if ($count -eq 0) { break }
            $file.Write($buffer, 0, $count)
        }
        return $true
    } finally {
        if ($file) { $file.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Close() }
    }
}

function Read-Recommendation([string]$Path) {
    Assert-SafePath $Path -Private
    $info = Get-Item -LiteralPath $Path
    if ($info.PSIsContainer -or $info.Length -gt 128) { Stop-Recommendation '清单大小无效' '重新取得完整推荐' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    # ASCII-only strict LF framing; no JSON duplicate keys, shell parsing or eval.
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    $match = [regex]::Match($text, '\Addnsto-recommendation-v1-powershell\n([0-9a-f]{64})\n([1-9][0-9]{0,6})\n\z')
    if (-not $match.Success -or [int]$match.Groups[2].Value -gt 8388608) {
        Stop-Recommendation '推荐清单非法' '联系发布者核对清单' }
    return @{ Digest = $match.Groups[1].Value; Size = [int]$match.Groups[2].Value }
}

function Test-Installer([string]$Path, $Metadata) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    Assert-SafePath $Path -Private
    if ((Get-Item -LiteralPath $Path).Length -ne $Metadata.Size) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $Metadata.Digest
}

function Show-Offline {
    [Console]::Error.WriteLine('DDNSTO：推荐源暂不可用；状态=离线使用已校验缓存（可能非最新）；下一步=联网后重试；code=0')
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Stop-Recommendation '不支持此系统' '使用对应平台入口' 2 }
    if ($base -notmatch '^https://') { Stop-Recommendation '入口尚未打包' '使用已审核的发布入口' 2 }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $root = $env:DDNSTO_RECOMMEND_CACHE
    if (-not $root) { $root = Join-Path $env:LOCALAPPDATA 'DDNSTO-Recommendation' }
    if (-not [IO.Path]::IsPathRooted($root) -or $root.StartsWith('\\') -or
        $root -match '(^|[\\/])\.\.?([\\/]|$)') {
        Stop-Recommendation '缓存路径无效' '使用本地绝对私有目录' 12 }
    $root = [IO.Path]::GetFullPath($root)
    $parent = [IO.Directory]::GetParent($root)
    while ($parent) {
        Assert-SafePath $parent.FullName
        $parent = $parent.Parent
    }
    New-PrivateDirectory $root
    $cache = Join-Path $root $cacheKey
    New-PrivateDirectory $cache
    $lockPath = Join-Path $cache 'lock'
    if (Test-Path -LiteralPath $lockPath) { Assert-SafePath $lockPath -Private }
    $lease = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    $work = Join-Path $cache ('attempt-' + [Guid]::NewGuid().ToString('N'))
    New-PrivateDirectory $work
    $manifest = Join-Path $work 'recommended.txt'
    $scriptPath = Join-Path $work 'install.ps1'
    $cachedManifest = Join-Path $cache 'recommended.txt'
    $online = Receive-Bounded "$base/recommended-powershell.txt" $manifest 128
    if ($online) {
        $metadata = Read-Recommendation $manifest
    } else {
        $metadata = Read-Recommendation $cachedManifest
        Copy-Item -LiteralPath $cachedManifest -Destination $manifest
    }
    $cachedScript = Join-Path $cache ($metadata.Digest + '.ps1')
    if ($online) {
        $received = Receive-Bounded "$base/immutable/$($metadata.Digest)/install.ps1" $scriptPath $metadata.Size
    } else { $received = $false }
    if (-not $received) {
        if (-not (Test-Installer $cachedScript $metadata)) {
            Stop-Recommendation '源不可用且无完整匹配缓存' '检查网络后重试' }
        Copy-Item -LiteralPath $cachedScript -Destination $scriptPath
        Show-Offline
    }
    if (-not (Test-Installer $scriptPath $metadata)) {
        Stop-Recommendation '安装脚本校验失败' '联系发布者核对摘要和大小' }
    # File.Replace is atomic for an existing target on the same volume.
    $stage = Join-Path $work 'cached.ps1'
    Copy-Item -LiteralPath $scriptPath -Destination $stage
    if (Test-Path -LiteralPath $cachedScript) { [IO.File]::Replace($stage, $cachedScript, $null) }
    else { [IO.File]::Move($stage, $cachedScript) }
    if (Test-Path -LiteralPath $cachedManifest) { [IO.File]::Replace($manifest, $cachedManifest, $null) }
    else { [IO.File]::Move($manifest, $cachedManifest) }
    $lease.Dispose(); $lease = $null
    # Hashtable splatting binds named parameters without reinterpreting strings.
    # Let explicit executor exit codes propagate; exceptions become a redacted
    # error below. Do not dot-source or build a command with Invoke-Expression.
    $script:entryCode = 1
    $script:entryMessage = $null
    $global:LASTEXITCODE = 0
    & $scriptPath @forward
    $executorSucceeded = $?
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if (-not $executorSucceeded) { Stop-Recommendation '安装执行失败' '检查本地服务状态后重试' 1 }
    exit 0
} catch {
    # Never echo exception text/InvocationInfo from an installer or OS API:
    # either may contain paths or a supplied token. Only our own fixed messages.
    if ($script:entryMessage) {
        [Console]::Error.WriteLine($script:entryMessage)
    } else {
        [Console]::Error.WriteLine("DDNSTO：推荐入口或执行器失败；状态=未确认本地服务运行；下一步=检查网络、私有缓存和服务状态；code=$script:entryCode")
    }
    exit $script:entryCode
} finally {
    if ($lease) { $lease.Dispose() }
    if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
