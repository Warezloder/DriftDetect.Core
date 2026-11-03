function New-DDSnapshot {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Technology,[Parameter(Mandatory)][System.Collections.IDictionary]$Target,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Collections,[System.Collections.IDictionary]$CollectionProfile=@{},[Parameter(Mandatory)]$RuleSet,[string]$ProviderVersion='2.0.0')
    $rules=Resolve-DDRuleSet $RuleSet
    $groups=[System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $units=[System.Collections.Generic.List[object]]::new()
    foreach($collection in $Collections){
        foreach($entity in @($collection.Entities)){
            $entity=[pscustomobject](ConvertTo-DDValue $entity -MaxDepth 100)
            $context=@{Technology=$Technology;EntityType=$entity.EntityType;Name=$entity.Name;Id=$entity.Id}
            $entity.Hash=Get-DDTextHash (ConvertTo-DDCanonical $entity.Properties $rules $context)
            if(-not $groups.Contains($entity.EntityType)){$groups.Add($entity.EntityType,[System.Collections.Generic.List[object]]::new())}
            $groups[$entity.EntityType].Add($entity)
        }
        $record=[ordered]@{}
        foreach($key in (Get-DDKeys $collection)){if($key -cne 'Entities'){$record[$key]=ConvertTo-DDValue (Get-DDField $collection $key)}}
        $units.Add([pscustomobject]$record)
    }
    foreach($key in @($groups.get_Keys())){$groups[$key]=$groups[$key].ToArray()}
    $s=[pscustomobject]@{PSTypeName='DriftDetect.Snapshot';SchemaVersion='2.0';SnapshotId=[guid]::NewGuid().ToString();CapturedAt=[datetime]::UtcNow.ToString('o');Technology=$Technology;ProviderVersion=$ProviderVersion;Target=(ConvertTo-DDValue $Target);Collections=$units.ToArray();CollectionProfile=(ConvertTo-DDValue $CollectionProfile);RuleSet=$rules;Entities=$groups;Metadata=@{CaptureParameters=(ConvertTo-DDValue $CollectionProfile)}}
    Add-DDTargetAliases $s
    $null=Test-DDSnapshot $s
    return $s
}
function Add-DDTargetAliases($Snapshot){
    if($Snapshot.Technology -ceq 'WinServer'){$aliases=@{ComputerName=$Snapshot.Target.Name;OSVersion=$Snapshot.Target.Version;OSBuild=$Snapshot.Target.Build}}
    elseif($Snapshot.Technology -ceq 'ESXi'){$aliases=@{HostName=$Snapshot.Target.Name;HostVersion=$Snapshot.Target.Version;HostBuild=$Snapshot.Target.Build}}
    else{$aliases=@{}}
    foreach($key in $aliases.get_Keys()){$Snapshot|Add-Member -NotePropertyName $key -NotePropertyValue $aliases[$key] -Force}
}
function Test-DDSnapshot {
    [CmdletBinding()]param([Parameter(Mandatory,Position=0)]$Snapshot)
    if($Snapshot.SchemaVersion -cne '2.0'){throw 'Unsupported snapshot schema. Expected 2.0.'}
    if([string]::IsNullOrWhiteSpace($Snapshot.Technology) -or [string]::IsNullOrWhiteSpace($Snapshot.Target.Id) -or [string]::IsNullOrWhiteSpace($Snapshot.Target.Name)){throw 'Snapshot requires technology and target identity.'}
    $legacy=[bool](Get-DDField $Snapshot.Metadata 'Legacy' $false)
    if(-not $legacy){
        $guid=[guid]::Empty; $date=[datetimeoffset]::MinValue
        if(-not [guid]::TryParse([string]$Snapshot.SnapshotId,[ref]$guid) -or -not [datetimeoffset]::TryParse([string]$Snapshot.CapturedAt,[ref]$date)){throw 'Invalid snapshot ID or timestamp.'}
    }
    if(-not (Test-DDMap $Snapshot.Entities)){throw 'Snapshot Entities must be a map.'}
    $units=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($unit in @($Snapshot.Collections)){
        if([string]::IsNullOrWhiteSpace($unit.Id) -or $units.ContainsKey($unit.Id)){throw 'Duplicate or empty collection ID.'}
        if($unit.Status -cnotin @('Success','Partial','Failed','Skipped','Unsupported','NotApplicable','LegacyUnknown')){throw 'Invalid collection status.'}
        if($unit.Status -eq 'LegacyUnknown' -and -not $legacy){throw 'Legacy collection in non-legacy snapshot.'}
        if($unit.Status -eq 'NotApplicable' -and [string]::IsNullOrWhiteSpace($unit.Reason)){throw 'NotApplicable collection requires evidence in Reason.'}
        if(-not (Test-DDMap $unit.Scope) -or [string]::IsNullOrWhiteSpace($unit.ContractVersion)){throw 'Collection requires scope and contract version.'}
        $actual=Get-DDHash $unit.Scope
        if($actual -cne $unit.ScopeFingerprint){throw 'Collection scope fingerprint does not match scope.'}
        $units.Add($unit.Id,$unit)
    }
    $rules=Resolve-DDRuleSet $Snapshot.RuleSet
    if($rules.Fingerprint -cne $Snapshot.RuleSet.Fingerprint){throw 'Snapshot rule fingerprint is inconsistent.'}
    $ids=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($type in (Get-DDKeys $Snapshot.Entities)){
        $entities=Get-DDField $Snapshot.Entities $type
        if($entities -isnot [array]){throw 'Entity groups must be arrays.'}
        foreach($entity in $entities){
            if($entity.EntityType -cne $type -or [string]::IsNullOrWhiteSpace($entity.Id) -or [string]::IsNullOrWhiteSpace($entity.Name)){throw 'Invalid entity identity.'}
            $key=ConvertTo-DDCanonical @($type,$entity.Id)
            if(-not $ids.Add($key)){throw "Duplicate entity identity: $type/$($entity.Id)"}
            if(-not $units.ContainsKey($entity.CollectionId)){throw 'Entity references an unknown collection.'}
            if($units[$entity.CollectionId].Status -notin @('Success','Partial','LegacyUnknown')){throw 'Unsuccessful collection cannot contain entities.'}
            if(-not (Test-DDMap $entity.Properties) -or -not (Test-DDMap $entity.Observations)){throw 'Entity properties and observations must be maps.'}
            $props=ConvertTo-DDValue $entity.Properties; $null=ConvertTo-DDValue $entity.Observations
            $context=@{Technology=$Snapshot.Technology;EntityType=$entity.EntityType;Name=$entity.Name;Id=$entity.Id}
            $null=ConvertTo-DDCanonical $props $rules $context
        }
    }
    $alias=if($Snapshot.Technology -eq 'WinServer'){'ComputerName'}elseif($Snapshot.Technology -eq 'ESXi'){'HostName'}else{''}
    if($alias -and (Get-DDKeys $Snapshot) -ccontains $alias -and (Get-DDField $Snapshot $alias) -cne $Snapshot.Target.Name){throw 'Target name alias is inconsistent.'}
    $null=ConvertTo-DDValue $Snapshot.CollectionProfile
    return $true
}
function Export-DDSnapshot {
    [CmdletBinding()]param([Parameter(Mandatory,Position=0)]$Snapshot,[Parameter(Mandatory,Position=1)][string]$Path)
    $null=Test-DDSnapshot $Snapshot
    ConvertTo-DDValue $Snapshot -MaxDepth 100 | ConvertTo-Json -Depth 100 -WarningAction Stop | Set-Content -LiteralPath $Path -Encoding utf8 -ErrorAction Stop
    return $Path
}
function Import-DDSnapshot {
    [CmdletBinding()]param([Parameter(Mandatory,Position=0)][string]$Path)
    $data=ConvertFrom-DDJson (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
    if($data.SchemaVersion -ceq '1.0'){return (ConvertFrom-DDLegacySnapshot $data)}
    if($data.SchemaVersion -cne '2.0'){throw 'Unsupported snapshot schema.'}
    $snapshot=[pscustomobject](ConvertTo-DDValue $data -MaxDepth 100)
    $snapshot.PSObject.TypeNames.Insert(0,'DriftDetect.Snapshot')
    $null=Test-DDSnapshot $snapshot
    return $snapshot
}
function ConvertFrom-DDLegacySnapshot($Data){
    $tech=if((Get-DDKeys $Data) -ccontains 'ComputerName'){'WinServer'}elseif((Get-DDKeys $Data) -ccontains 'HostName'){'ESXi'}else{throw 'Legacy snapshot has no recognized target.'}
    $name=if($tech -eq 'WinServer'){$Data.ComputerName}else{$Data.HostName}
    $entities=[ordered]@{}
    foreach($type in (Get-DDKeys $Data.Entities)){
        $items=[System.Collections.Generic.List[object]]::new();$i=0
        foreach($e in $Data.Entities[$type]){$i++;$items.Add((New-DDEntity -EntityType $type -Id "legacy-$i" -Name $e.Name -Path $e.Path -CollectionId Legacy -Properties $e.Properties))}
        $entities[$type]=$items.ToArray()
    }
    $unit=New-DDCollection -Id Legacy -Status Failed -Reason 'Legacy completeness and identity unknown.'
    $unit.Status='LegacyUnknown'
    $s=[pscustomobject]@{SchemaVersion='2.0';SnapshotId=$Data.SnapshotId;CapturedAt=$Data.CapturedAt;Technology=$tech;ProviderVersion='1.0.0';Target=@{Id="legacy:$name";Name=$name;IdentitySource='LegacyUnknown';Version=(Get-DDField $Data $(if($tech -eq 'WinServer'){'OSVersion'}else{'HostVersion'}) '');Build=(Get-DDField $Data $(if($tech -eq 'WinServer'){'OSBuild'}else{'HostBuild'}) '')};Collections=@($unit);CollectionProfile=@{};RuleSet=(New-DDRuleSet);Entities=$entities;Metadata=@{Legacy=$true;OriginalSchemaVersion='1.0';Warning='Capture a new baseline before comparison.'}}
    Add-DDTargetAliases $s
    $null=Test-DDSnapshot $s
    return $s
}
