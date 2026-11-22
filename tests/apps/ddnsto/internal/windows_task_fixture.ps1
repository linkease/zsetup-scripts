# Shared action fixture: keep canonical environment launcher and legacy tasks
# distinct. Never pretend powershell.exe is the DDNSTO client process.
function New-DDNSTOFixtureAction($Binary, $Config, $Directory) {
    $environment = if (Test-Path -LiteralPath $Config) { Get-DDNSTORecordedEnvironment $Config } else { '' }
    if ($environment) { return Get-DDNSTOEnvironmentAction $Binary $Config $Directory $environment }
    return [pscustomobject]@{Execute=$Binary; Arguments=('--config "'+$Config+'"'); WorkingDirectory=$Directory}
}
