function Add-DDEvent($Events,$Entity,[string]$Path,[string]$Type,$Old,$New,$Rules,[string]$Technology){
    $context=@{Technology=$Technology;EntityType=$Entity.EntityType;EntityName=$Entity.Name;EntityId=$Entity.Id;PropertyPath=$Path;ChangeType=$Type}
    $rule=Select-DDRule $Rules.SeverityRules $context
    $severity=if($null -eq $rule){'Low'}else{$rule.Severity}
    $Events.Add([pscustomobject]@{EntityType=$Entity.EntityType;EntityId=$Entity.Id;EntityName=$Entity.Name;EntityPath=$Entity.Path;CollectionId=$Entity.CollectionId;PropertyPath=$Path;Property=$Path.TrimStart('/');ChangeType=$Type;OldValue=$Old;NewValue=$New;Severity=$severity})
}
function Compare-DDValue($Old,$New,[string]$Path,$Entity,$Rules,[string]$Technology,$Events){
    $context=@{Technology=$Technology;EntityType=$Entity.EntityType;Name=$Entity.Name;Id=$Entity.Id}
    $oldText=ConvertTo-DDCanonical $Old $Rules $context $Path
    $newText=ConvertTo-DDCanonical $New $Rules $context $Path
    if([string]::Equals($oldText,$newText,[StringComparison]::Ordinal)){return}
    if((Test-DDMap $Old) -and (Test-DDMap $New)){
        $keys=[System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
        foreach($key in (Get-DDKeys $Old)){$null=$keys.Add($key)};foreach($key in (Get-DDKeys $New)){$null=$keys.Add($key)}
        $oldKeys=Get-DDKeys $Old;$newKeys=Get-DDKeys $New
        foreach($key in $keys){
            $child=Join-DDPointer $Path $key
            if($oldKeys -cnotcontains $key){Add-DDEvent $Events $Entity $child PropertyAdded $null (Get-DDField $New $key) $Rules $Technology}
            elseif($newKeys -cnotcontains $key){Add-DDEvent $Events $Entity $child PropertyRemoved (Get-DDField $Old $key) $null $Rules $Technology}
            else{Compare-DDValue (Get-DDField $Old $key) (Get-DDField $New $key) $child $Entity $Rules $Technology $Events}
        }
    }elseif($Old -is [array] -and $New -is [array] -and (Get-DDPolicy $Rules $context $Path).Mode -eq 'Keyed'){
        $policy=Get-DDPolicy $Rules $context $Path
        $oldMap=[System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal);$newMap=[System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        foreach($item in $Old){$oldMap.Add([string](Get-DDField $item $policy.Key),$item)}
        foreach($item in $New){$newMap.Add([string](Get-DDField $item $policy.Key),$item)}
        Compare-DDValue $oldMap $newMap $Path $Entity $Rules $Technology $Events
    }else{Add-DDEvent $Events $Entity $Path PropertyModified $Old $New $Rules $Technology}
}
