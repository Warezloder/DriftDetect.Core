function New-DDEntity {
    [CmdletBinding()]param(
        [Parameter(Mandatory,Position=0)][ValidateNotNullOrEmpty()][string]$EntityType,
        [Parameter(Mandatory,Position=1)][ValidateNotNullOrEmpty()][string]$Id,
        [Parameter(Mandatory,Position=2)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory,Position=3)][ValidateNotNullOrEmpty()][string]$CollectionId,
        [Parameter(Mandatory,Position=4)][System.Collections.IDictionary]$Properties,
        [string]$Path,[System.Collections.IDictionary]$Observations=@{})
    if(-not $Path){$Path="$EntityType/$Id"}
    $props=ConvertTo-DDValue $Properties
    return [pscustomobject]@{PSTypeName='DriftDetect.Entity';EntityType=$EntityType;Id=$Id;Name=$Name;Path=$Path;CollectionId=$CollectionId;Properties=$props;Observations=(ConvertTo-DDValue $Observations);Hash=(Get-DDHash $props)}
}
function New-DDCollection {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Success','Partial','Failed','Skipped','Unsupported','NotApplicable')][string]$Status,
        [object[]]$Entities=@(),[System.Collections.IDictionary]$Scope=@{},[object[]]$Diagnostics=@(),[string]$Reason='',[string]$ContractVersion='1.0')
    $now=[datetime]::UtcNow.ToString('o')
    return [pscustomobject]@{Id=$Id;Status=$Status;Entities=@($Entities);Scope=(ConvertTo-DDValue $Scope);ScopeFingerprint=(Get-DDHash $Scope);Diagnostics=(ConvertTo-DDValue $Diagnostics);Reason=$Reason;ContractVersion=$ContractVersion;StartedAt=$now;CompletedAt=$now;EntityCount=$Entities.Count}
}
function Invoke-DDCollector {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][scriptblock]$ScriptBlock,[object[]]$ArgumentList=@(),[System.Collections.IDictionary]$Scope=@{},[string]$ContractVersion='1.0')
    $started=[datetime]::UtcNow.ToString('o')
    try{
        $ErrorActionPreference='Stop'
        $entities=@(& $ScriptBlock @ArgumentList)
        foreach($entity in $entities){if($entity.CollectionId -cne $Id){throw 'Collector returned an entity with the wrong collection ID.'}}
        $result=New-DDCollection -Id $Id -Status Success -Entities $entities -Scope $Scope -ContractVersion $ContractVersion
    }catch{
        # Exception text can contain command arguments or remote credentials; do not persist it.
        $result=New-DDCollection -Id $Id -Status Failed -Scope $Scope -ContractVersion $ContractVersion -Reason 'Collection failed.' -Diagnostics @(@{Code='QueryFailed';Message='Collection did not complete. Check access, connectivity, and provider prerequisites.'})
    }
    $result.StartedAt=$started; $result.CompletedAt=[datetime]::UtcNow.ToString('o')
    return $result
}
