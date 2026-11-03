function Compare-DDSnapshot {
    [CmdletBinding()]param([Parameter(Mandatory,Position=0)]$BaselineSnapshot,[Parameter(Mandatory,Position=1)]$CurrentSnapshot,$RuleSet,[switch]$AllowPartial)
    $null=Test-DDSnapshot $BaselineSnapshot; $null=Test-DDSnapshot $CurrentSnapshot
    $a=$BaselineSnapshot;$b=$CurrentSnapshot
    if((Get-DDField $a.Metadata 'Legacy' $false) -or (Get-DDField $b.Metadata 'Legacy' $false)){throw 'Legacy snapshots cannot be compared. Capture a new baseline.'}
    if($a.Technology -cne $b.Technology -or $a.Target.Id -cne $b.Target.Id){throw 'Snapshot technology or target identity differs.'}
    $override=$PSBoundParameters.ContainsKey('RuleSet')
    if(-not $override -and $a.RuleSet.Fingerprint -cne $b.RuleSet.Fingerprint){throw 'Snapshot rules differ. Supply an explicit compatible RuleSet override.'}
    $rules=if($override){Resolve-DDRuleSet $RuleSet}else{Resolve-DDRuleSet $a.RuleSet}
    $left=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$right=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($u in $a.Collections){$left.Add($u.Id,$u)};foreach($u in $b.Collections){$right.Add($u.Id,$u)}
    $ids=[System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach($id in $left.get_Keys()){$null=$ids.Add($id)};foreach($id in $right.get_Keys()){$null=$ids.Add($id)}
    $valid=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $coverage=[System.Collections.Generic.List[object]]::new();$complete=$true
    foreach($id in $ids){
        $oldUnit=if($left.ContainsKey($id)){$left[$id]}else{$null};$newUnit=if($right.ContainsKey($id)){$right[$id]}else{$null}
        $reason='';$comparable=$false;$outside=$false
        if($null -eq $oldUnit -or $null -eq $newUnit){$reason='Collection scope differs: unit is missing.'}
        elseif($oldUnit.ScopeFingerprint -cne $newUnit.ScopeFingerprint -or $oldUnit.ContractVersion -cne $newUnit.ContractVersion){$reason='Collection scope or contract version differs.'}
        elseif($oldUnit.Status -eq 'Success' -and $newUnit.Status -eq 'Success'){$comparable=$true;$null=$valid.Add($id)}
        elseif($oldUnit.Status -ceq $newUnit.Status -and $oldUnit.Status -in @('Skipped','NotApplicable')){$outside=$true;$reason="$($oldUnit.Status): $($newUnit.Reason)"}
        else{$reason='Collection incomplete or applicability differs.'}
        if(-not $comparable -and -not $outside){$complete=$false;if(-not $AllowPartial){throw "$id : $reason Use -AllowPartial to compare successful shared units."}}
        $coverage.Add([pscustomobject]@{CollectionId=$id;BaselineStatus=$(if($oldUnit){$oldUnit.Status}else{'Missing'});CurrentStatus=$(if($newUnit){$newUnit.Status}else{'Missing'});Compared=$comparable;Reason=$reason;BaselineScope=(Get-DDField $oldUnit 'Scope');CurrentScope=(Get-DDField $newUnit 'Scope')})
    }
    if((Get-DDHash $a.CollectionProfile) -cne (Get-DDHash $b.CollectionProfile)){
        $complete=$false
        if(-not $AllowPartial){throw 'Requested collection scope/profile differs.'}
        $coverage.Add([pscustomobject]@{CollectionId='Profile';BaselineStatus='Different';CurrentStatus='Different';Compared=$false;Reason='Requested collection profile differs; only matching per-unit scopes compared.'})
    }
    if($valid.Count -eq 0){$complete=$false}
    $oldEntities=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$newEntities=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($pair in @(@{Snapshot=$a;Map=$oldEntities},@{Snapshot=$b;Map=$newEntities})){
        foreach($type in (Get-DDKeys $pair.Snapshot.Entities)){
            foreach($e in $pair.Snapshot.Entities[$type]){
                if($valid.Contains($e.CollectionId)){
                    $ctx=@{Technology=$a.Technology;EntityType=$e.EntityType;Name=$e.Name;Id=$e.Id}
                    $null=ConvertTo-DDCanonical (ConvertTo-DDValue $e.Properties) $rules $ctx
                    $pair.Map.Add((ConvertTo-DDCanonical @($type,$e.Id)),$e)
                }
            }
        }
    }
    $keys=[System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach($key in $oldEntities.get_Keys()){$null=$keys.Add($key)};foreach($key in $newEntities.get_Keys()){$null=$keys.Add($key)}
    $events=[System.Collections.Generic.List[object]]::new()
    foreach($key in $keys){
        if(-not $oldEntities.ContainsKey($key)){$e=$newEntities[$key];Add-DDEvent $events $e '' EntityAdded $null (ConvertTo-DDValue $e.Properties) $rules $a.Technology}
        elseif(-not $newEntities.ContainsKey($key)){$e=$oldEntities[$key];Add-DDEvent $events $e '' EntityRemoved (ConvertTo-DDValue $e.Properties) $null $rules $a.Technology}
        else{
            if($oldEntities[$key].CollectionId -cne $newEntities[$key].CollectionId){throw 'Entity collection ownership differs.'}
            $oldProperties=ConvertTo-DDValue $oldEntities[$key].Properties
            $newProperties=ConvertTo-DDValue $newEntities[$key].Properties
            $context=@{Technology=$a.Technology;EntityType=$newEntities[$key].EntityType;Name=$newEntities[$key].Name;Id=$newEntities[$key].Id}
            # Recompute both hashes with the same effective policy; cached mutable hashes are never authoritative.
            $oldHash=Get-DDTextHash (ConvertTo-DDCanonical $oldProperties $rules $context)
            $newHash=Get-DDTextHash (ConvertTo-DDCanonical $newProperties $rules $context)
            if($oldHash -cne $newHash){Compare-DDValue $oldProperties $newProperties '' $newEntities[$key] $rules $a.Technology $events}
        }
    }
    $changes=@($events|Where-Object ChangeType -Like 'Property*');$added=@($events|Where-Object ChangeType -eq EntityAdded);$removed=@($events|Where-Object ChangeType -eq EntityRemoved)
    $summary=[ordered]@{};foreach($severity in @('Critical','High','Medium','Low')){$summary[$severity]=@($events|Where-Object Severity -eq $severity).Count}
    return [pscustomobject]@{PSTypeName='DriftDetect.Comparison';SchemaVersion='2.0';Technology=$b.Technology;Target=$b.Target;ComputerName=$b.Target.Name;HostName=$b.Target.Name;BaselineSnapshot=$a.SnapshotId;CurrentSnapshot=$b.SnapshotId;BaselineCapturedAt=$a.CapturedAt;CurrentCapturedAt=$b.CapturedAt;BaselineCollectionProfile=(ConvertTo-DDValue $a.CollectionProfile);CurrentCollectionProfile=(ConvertTo-DDValue $b.CollectionProfile);Events=$events.ToArray();Changes=$changes;NewEntities=$added;DeletedEntities=$removed;TotalChanges=$events.Count;TotalModified=$changes.Count;TotalNew=$added.Count;TotalDeleted=$removed.Count;SeveritySummary=$summary;IsComplete=$complete;HasDrift=($events.Count -gt 0);Coverage=$coverage.ToArray();Diagnostics=@(foreach($snapshot in @($a,$b)){foreach($unit in $snapshot.Collections){foreach($diagnostic in $unit.Diagnostics){if($null -ne $diagnostic){$diagnostic}}}});RuleFingerprint=$rules.Fingerprint;RuleOverride=$override}
}
