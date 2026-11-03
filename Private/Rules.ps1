$script:DDSelectors=@('Technology','EntityType','EntityName','EntityId','PropertyPath','ChangeType')
function Test-DDSelectorMatch($Rule,$Context,[switch]$Policy) {
    foreach($name in $script:DDSelectors){
        $expected=Get-DDField $Rule $name '*'
        if($expected -eq '*'){continue}
        $actual=Get-DDField $Context $name ''
        if($Policy -and $name -eq 'PropertyPath' -and $expected.Contains('*')){
            $pattern='^'+([regex]::Escape($expected).Replace('\*','[^/]+'))+'$'
            if(-not [regex]::IsMatch([string]$actual,$pattern)){return $false}
        }elseif(-not [string]::Equals([string]$expected,[string]$actual,[StringComparison]::Ordinal)){return $false}
    }
    return $true
}
function Select-DDRule($Rules,$Context,[switch]$Policy){
    $matches=@($Rules|Where-Object {Test-DDSelectorMatch $_ $Context -Policy:$Policy}|Sort-Object @{e={$_.Priority};Descending=$true},@{e={$_.Specificity};Descending=$true})
    if($matches.Count){return $matches[0]}
    return $null
}
function Get-DDPolicy($Rules,$Entity,[string]$Path){
    if($null -eq $Rules -or $null -eq $Entity){return @{Mode='Ordered'}}
    $context=@{Technology=(Get-DDField $Entity 'Technology' '*');EntityType=$Entity.EntityType;EntityName=$Entity.Name;EntityId=$Entity.Id;PropertyPath=$Path;ChangeType='*'}
    $rule=Select-DDRule $Rules.ComparisonPolicies $context -Policy
    if($null -eq $rule){return @{Mode='Ordered'}}
    return $rule
}
function ConvertTo-DDRules($Entries,[string]$Kind){
    $result=[System.Collections.Generic.List[object]]::new(); $ids=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $index=0
    foreach($entry in @($Entries)){
        if(-not (Test-DDMap $entry)){throw 'Rule must be a map.'}
        $index++; $rule=[ordered]@{Id=[string](Get-DDField $entry 'Id' "$Kind-$index");Priority=[int](Get-DDField $entry 'Priority' 0);Specificity=0}
        if(-not $ids.Add($rule.Id)){throw "Duplicate rule Id $($rule.Id)."}
        foreach($selector in $script:DDSelectors){$rule[$selector]=[string](Get-DDField $entry $selector '*');if($rule[$selector] -ne '*'){$rule.Specificity++}}
        if($rule.PropertyPath -ne '*' -and $rule.PropertyPath -ne '' -and -not $rule.PropertyPath.StartsWith('/')){throw "Invalid rule property path: $($rule.PropertyPath)"}
        if($rule.ChangeType -notin @('*','EntityAdded','EntityRemoved','PropertyAdded','PropertyRemoved','PropertyModified')){throw 'Invalid rule change type.'}
        if($Kind -eq 'Severity'){
            $rule['Severity']=[string]$entry.Severity
            if($rule.Severity -cnotin @('Critical','High','Medium','Low')){throw 'Invalid severity in rule.'}
        }else{
            foreach($segment in $rule.PropertyPath.Split('/')){if($segment.Contains('*') -and $segment -cne '*'){throw 'Policy path wildcards must occupy an entire segment.'}}
            $rule['Mode']=[string]$entry.Mode; $rule['Key']=[string](Get-DDField $entry 'Key' '')
            if($rule.Mode -cnotin @('Ordered','Set','Keyed')){throw 'Invalid array comparison mode.'}
            if($rule.Mode -eq 'Keyed' -and [string]::IsNullOrWhiteSpace($rule.Key)){throw 'Keyed policies require Key.'}
        }
        $result.Add($rule)
    }
    for($i=0;$i -lt $result.Count;$i++){
        for($j=$i+1;$j -lt $result.Count;$j++){
            $a=$result[$i];$b=$result[$j]
            if($a.Priority -ne $b.Priority -or $a.Specificity -ne $b.Specificity){continue}
            $overlap=$true
            foreach($key in $script:DDSelectors){
                if($a[$key] -eq '*' -or $b[$key] -eq '*'){continue}
                if($Kind -eq 'Policy' -and $key -eq 'PropertyPath'){
                    $left=$a[$key].Split('/'); $right=$b[$key].Split('/')
                    if($left.Count -ne $right.Count){$overlap=$false;continue}
                    for($part=0;$part -lt $left.Count;$part++){if($left[$part] -cne '*' -and $right[$part] -cne '*' -and $left[$part] -cne $right[$part]){$overlap=$false}}
                }elseif($a[$key] -cne $b[$key]){$overlap=$false}
            }
            $effectA=if($Kind -eq 'Severity'){$a.Severity}else{"$($a.Mode):$($a.Key)"}
            $effectB=if($Kind -eq 'Severity'){$b.Severity}else{"$($b.Mode):$($b.Key)"}
            if($overlap -and $effectA -cne $effectB){throw "Conflicting rules '$($a.Id)' and '$($b.Id)'."}
        }
    }
    return ,$result.ToArray()
}
function New-DDRuleSet {
    [CmdletBinding()]param([object[]]$SeverityRules=@(),[object[]]$ComparisonPolicies=@(),[string]$Version='1.0')
    $rules=[ordered]@{SchemaVersion='1.0';RuleSetVersion=$Version;SeverityRules=(ConvertTo-DDRules $SeverityRules Severity);ComparisonPolicies=(ConvertTo-DDRules $ComparisonPolicies Policy)}
    $rules['Fingerprint']=Get-DDHash $rules
    return [pscustomobject]$rules
}
function Resolve-DDRuleSet($RuleSet){
    if($null -eq $RuleSet){return (New-DDRuleSet)}
    if((Get-DDField $RuleSet 'SchemaVersion' '1.0') -cne '1.0'){throw 'Unsupported rule schema.'}
    if((Get-DDKeys $RuleSet) -ccontains 'Rules'){
        $entries=@();$i=0
        foreach($rule in $RuleSet.Rules){$i++;$property=if($rule.Property -eq '*'){'*'}else{Join-DDPointer '' $rule.Property};$entries+=@{Id="legacy-$i";EntityType=$rule.EntityType;PropertyPath=$property;Severity=$rule.Severity}}
        return (New-DDRuleSet -SeverityRules $entries)
    }
    return (New-DDRuleSet -SeverityRules (Get-DDField $RuleSet 'SeverityRules' @()) -ComparisonPolicies (Get-DDField $RuleSet 'ComparisonPolicies' @()) -Version (Get-DDField $RuleSet 'RuleSetVersion' '1.0'))
}
function Import-DDRuleSet {
    [CmdletBinding()]param([Parameter(Mandatory,Position=0)][string]$Path)
    return (Resolve-DDRuleSet (ConvertFrom-DDJson (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)))
}
