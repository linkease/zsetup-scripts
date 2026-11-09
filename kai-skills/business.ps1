$ErrorActionPreference = 'Stop'
$script:KaiSkillsUtf8 = [Text.UTF8Encoding]::new($false)

function Stop-KaiSkills([string]$Message, [int]$Code = 2) {
    [Console]::Error.WriteLine("kai-skills: $Message")
    exit $Code
}

function Test-KaiSkillsId([string]$Value) {
    return $Value -cmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$'
}

function Get-KaiSkillsArguments([string[]]$InputArguments) {
    $result = [ordered]@{
        Skill = ''; System = ''; Mode = 'on-device'; Consumer = 'codex'; Scope = 'user'
        Target = ''; Architecture = ''; Action = 'Install'; UpdateShared = $false
    }
    for ($index = 0; $index -lt $InputArguments.Count; $index++) {
        $name = $InputArguments[$index]
        switch -CaseSensitive ($name) {
            '--skill' { if (++$index -ge $InputArguments.Count) { Stop-KaiSkills 'missing --skill value' }; $result.Skill = $InputArguments[$index] }
            '--system' { if (++$index -ge $InputArguments.Count) { Stop-KaiSkills 'missing --system value' }; $result.System = $InputArguments[$index] }
            '--mode' { if (++$index -ge $InputArguments.Count) { Stop-KaiSkills 'missing --mode value' }; $result.Mode = $InputArguments[$index] }
            '--consumer' { if (++$index -ge $InputArguments.Count) { Stop-KaiSkills 'missing --consumer value' }; $result.Consumer = $InputArguments[$index] }
            '--scope' { if (++$index -ge $InputArguments.Count) { Stop-KaiSkills 'missing --scope value' }; $result.Scope = $InputArguments[$index] }
            { $_ -in @('--target-skills', '--target') } { if (++$index -ge $InputArguments.Count) { Stop-KaiSkills 'missing target value' }; $result.Target = $InputArguments[$index] }
            '--architecture' { if (++$index -ge $InputArguments.Count) { Stop-KaiSkills 'missing architecture value' }; $result.Architecture = $InputArguments[$index] }
            '--dry-run' { $result.Action = 'Plan' }
            '--upgrade' { $result.Action = 'Upgrade' }
            '--uninstall' { $result.Action = 'Uninstall' }
            '--update-shared' { $result.UpdateShared = $true }
            '--json' { }
            '--copy' { }
            default { Stop-KaiSkills "unknown option $name" }
        }
    }
    if ($result.Skill -and $result.System) { Stop-KaiSkills 'choose only one selection' }
    if (-not $result.Skill -and -not $result.System) { Stop-KaiSkills 'choose --skill or --system' }
    if ($result.Skill -and -not (Test-KaiSkillsId $result.Skill)) { Stop-KaiSkills 'invalid skill id' }
    if ($result.System -and $result.System -cne 'windows') { Stop-KaiSkills 'Windows installer only supports --system windows' }
    if ($result.Mode -cne 'on-device') { Stop-KaiSkills 'only on-device mode is published' }
    if ($result.Consumer -notin @('codex', 'claude', 'opencode')) { Stop-KaiSkills 'unsupported consumer' }
    if ($result.Scope -notin @('user', 'project')) { Stop-KaiSkills 'scope must be user or project' }
    if ($result.UpdateShared -and $result.Action -cne 'Upgrade') { Stop-KaiSkills '--update-shared requires --upgrade' }
    return $result
}

function Invoke-KaiSkillsDownload([string]$Relative, [string]$Destination,
        [string]$Sha256, [long]$Size) {
    $bases = @($env:ZSETUP_SOURCE_BASES -split '\s+' | Where-Object { $_ })
    if ($bases.Count -eq 0) { Stop-KaiSkills 'source group is required' }
    $arguments = @('download', '-o', $Destination, '--sha256', $Sha256,
        '--size', [string]$Size, '--max-bytes', [string]$Size)
    foreach ($base in $bases) { $arguments += $base.TrimEnd('/') + '/kai/kai-skills/' + $Relative }
    if ($env:ZSETUP_SOURCE_FALLBACK) {
        $arguments += @('--fallback-url', ($env:ZSETUP_SOURCE_FALLBACK.TrimEnd('/') +
            '/kai/kai-skills/' + $Relative))
    }
    if ($env:KAI_SKILLS_TRACE) {
        [Console]::Error.WriteLine(($arguments | ConvertTo-Json -Compress))
    }
    & $env:ZSETUP_BIN @arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Invoke-KaiSkillsBusiness([string[]]$InputArguments) {
    if (-not $env:ZSETUP_BIN) { Stop-KaiSkills 'ZSETUP_BIN is required' }
    if ($env:KAI_SKILLS_REQUESTED_RELEASE -and
        $env:KAI_SKILLS_REQUESTED_RELEASE -cne $script:KaiSkillsRelease) {
        Stop-KaiSkills "entrypoint release $($env:KAI_SKILLS_REQUESTED_RELEASE) does not match configured release $($script:KaiSkillsRelease)"
    }
    $options = Get-KaiSkillsArguments $InputArguments
    $work = Join-Path ([IO.Path]::GetTempPath()) ('kai-skills-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
    try {
        $manifestPath = Join-Path $work 'release-manifest.json'
        Invoke-KaiSkillsDownload $script:KaiSkillsManifestPath $manifestPath `
            $script:KaiSkillsManifestSha256 $script:KaiSkillsManifestSize
        $manifest = [IO.File]::ReadAllText($manifestPath, $script:KaiSkillsUtf8) |
            ConvertFrom-Json -ErrorAction Stop
        if ($manifest.schemaVersion -ne 3 -or $manifest.distribution -cne 'kai-skills-zsetup' -or
            $manifest.version -cne $script:KaiSkillsRelease -or
            $manifest.minimumZsetupVersion -cne '0.6.0' -or $manifest.archiveFormat -cne 'tar.gz') {
            Stop-KaiSkills 'manifest contract mismatch' 11
        }
        $kind = if ($options.Skill) { 'skill' } else { 'system' }
        $identity = if ($options.Skill) { $options.Skill } else { 'windows' }
        $records = @($manifest.artifacts | Where-Object { $_.kind -ceq $kind -and $_.id -ceq $identity })
        if ($records.Count -ne 1) { Stop-KaiSkills 'selection is not published' 11 }
        $record = $records[0]
        if ($record.path -cnotmatch ('^' + $kind + 's/[a-z0-9-]+\.tar\.gz$') -or
            $record.sha256 -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            $record.root -notmatch '^[A-Za-z0-9._-]+$' -or
            [long]$record.size -le 0 -or [long]$record.expandedSize -le 0 -or
            [long]$record.fileCount -le 0) { Stop-KaiSkills 'invalid artifact record' 11 }
        $archive = Join-Path $work 'package.tar.gz'
        Invoke-KaiSkillsDownload ("releases/$($script:KaiSkillsRelease)/$($record.path)") `
            $archive $record.sha256.Substring(7) ([long]$record.size)
        $stage = Join-Path $work 'extracted'
        & $env:ZSETUP_BIN archive extract -i $archive -o $stage --root $record.root `
            --max-bytes ([string]$record.expandedSize) --max-files ([string]$record.fileCount) `
            --min-free-bytes $(if ($env:KAI_SKILLS_MIN_FREE_BYTES) { $env:KAI_SKILLS_MIN_FREE_BYTES } else { '16777216' })
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        $package = Join-Path $stage $record.root
        $installer = Join-Path $package 'install.ps1'
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf) -or
            (Get-Item -LiteralPath $installer -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Stop-KaiSkills 'native package installer is missing or unsafe' 11
        }
        $child = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $installer, '-Action', $options.Action)
        if ($options.Skill) { $child += @('-Skill', $options.Skill) }
        else { $child += @('-Platform', 'windows', '-All', '-Mode', 'on-device') }
        $child += @('-Consumer', $options.Consumer, '-Scope', $options.Scope)
        if ($options.Target) { $child += @('-TargetSkills', $options.Target) }
        if ($options.Architecture) { $child += @('-Architecture', $options.Architecture) }
        if ($options.UpdateShared) { $child += '-UpdateShared' }
        $env:KAI_SKILLS_RELEASE = $script:KaiSkillsRelease
        & powershell.exe @child
        exit $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-KaiSkillsBusiness @($args)
