@{
    RootModule='DriftDetect.Core.psm1'
    ModuleVersion='1.0.1'
    GUID='794eb27b-64d8-429c-94de-5c89ebd78ca2'
    Author='Warezloder'
    Description='Shared configuration snapshots, coverage-aware comparison, rules and reporting.'
    PowerShellVersion='7.0'
    FunctionsToExport=@('New-DDRuleSet','Import-DDRuleSet','New-DDEntity','New-DDCollection','Invoke-DDCollector','New-DDSnapshot','Test-DDSnapshot','Export-DDSnapshot','Import-DDSnapshot','Compare-DDSnapshot','Get-DDHash','Export-DDConfigurationReport','Export-DDDriftReport')
    CmdletsToExport=@(); VariablesToExport=@(); AliasesToExport=@()
    PrivateData=@{PSData=@{Tags=@('Configuration','Drift','Monitoring');LicenseUri='https://opensource.org/license/mit'}}
}
