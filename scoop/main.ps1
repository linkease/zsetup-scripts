$script:ScoopEntryArguments = @($args)
try {
    if ($env:ZSETUP_INSTALLER_MODE -cne '1') {
        $env:ZSETUP_BIN = Get-ZsetupBootstrap
        $env:ZSETUP_SOURCE_BASES = $script:BootstrapPrimaryBases -join ' '
        $env:ZSETUP_SOURCE_FALLBACK = $script:BootstrapFallbackBase
    }
    if (-not $env:ZSETUP_BIN -or -not [IO.Path]::IsPathRooted($env:ZSETUP_BIN)) {
        throw 'scoop: trusted absolute ZSETUP_BIN is required'
    }
    Invoke-ScoopBusiness -InstallerArguments $script:ScoopEntryArguments
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 17
}
