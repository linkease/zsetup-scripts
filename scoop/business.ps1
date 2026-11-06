function Invoke-ScoopBusiness {
    param([string[]]$InstallerArguments)

    if ($InstallerArguments.Count -lt 3 -or
        $InstallerArguments[0] -cne '--explain' -or
        $InstallerArguments[1] -cne '--json' -or
        $InstallerArguments[2] -cne '--') {
        throw 'scoop: M5 candidate only supports --explain --json -- ARGS; installation is introduced by M6'
    }
    $literal = @()
    if ($InstallerArguments.Count -gt 3) {
        $literal = @($InstallerArguments[3..($InstallerArguments.Count - 1)])
    }
    [ordered]@{
        schema_version = 1
        operation = 'scoop-install-plan'
        milestone = 'M5'
        executable = $false
        arguments = $literal
    } | ConvertTo-Json -Depth 4 -Compress
}

