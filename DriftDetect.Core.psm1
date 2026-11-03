#Requires -Version 7.0
$ErrorActionPreference='Stop'
foreach ($file in @('Private/Values.ps1','Private/Rules.ps1','Private/Comparison.ps1','Public/Collection.ps1','Public/Snapshot.ps1','Public/Compare.ps1','Public/Reports.ps1')) {
    $source=Join-Path $PSScriptRoot $file
    if (Test-Path -LiteralPath $source) { . $source }
}
Export-ModuleMember -Function @('New-DDRuleSet','Import-DDRuleSet','New-DDEntity','New-DDCollection','Invoke-DDCollector','New-DDSnapshot','Test-DDSnapshot','Export-DDSnapshot','Import-DDSnapshot','Compare-DDSnapshot','Get-DDHash','Export-DDConfigurationReport','Export-DDDriftReport')
