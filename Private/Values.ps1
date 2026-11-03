function Test-DDMap($Value) {
    # CLIXML-remoted lists also satisfy -is [pscustomobject]. Classify their
    # collection interface first so allocation metadata never becomes data.
    return ($Value -is [System.Collections.IDictionary] -or
        ($Value -is [pscustomobject] -and $Value -isnot [System.Collections.IList]))
}
function Get-DDKeys($Value) {
    [string[]]$keys=@(if ($Value -is [System.Collections.IDictionary]) {$Value.get_Keys()} else {$Value.PSObject.Properties.Name})
    [array]::Sort($keys,[StringComparer]::Ordinal)
    return ,$keys
}
function Get-DDField($Value,[string]$Name,$Default=$null) {
    if ($null -eq $Value) { return ,$Default }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach($key in $Value.get_Keys()) {if ([string]::Equals([string]$key,$Name,[StringComparison]::Ordinal)) {return ,$Value[$key]}}
    } else {
        foreach($prop in $Value.PSObject.Properties) {if ([string]::Equals($prop.Name,$Name,[StringComparison]::Ordinal)) {return ,$prop.Value}}
    }
    return ,$Default
}
function ConvertTo-DDValue {
    param([AllowNull()]$Value,[int]$Depth=0,[int]$MaxDepth=64)
    if($Depth -gt $MaxDepth){throw "Value exceeds maximum depth $MaxDepth."}
    if($null -eq $Value){return $null}
    if($Value -is [datetime]){return $Value.ToUniversalTime().ToString('o',[cultureinfo]::InvariantCulture)}
    if($Value -is [datetimeoffset]){return $Value.UtcDateTime.ToString('o',[cultureinfo]::InvariantCulture)}
    if($Value -is [byte[]]){return [ordered]@{Encoding='base64';Data=[convert]::ToBase64String($Value)}}
    if($Value -is [string] -or $Value -is [bool]){return $Value}
    if($Value -is [char] -or $Value -is [guid] -or $Value -is [enum]){return [string]$Value}
    if($Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
        if([double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value)){throw 'Non-finite numbers are unsupported.'}
        return $Value
    }
    if(Test-DDMap $Value) {
        $map=[System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        foreach($key in (Get-DDKeys $Value)) {$map.Add($key,(ConvertTo-DDValue (Get-DDField $Value $key) ($Depth+1) $MaxDepth))}
        return ,$map
    }
    if($Value -is [array] -or $Value -is [System.Collections.IList]) {
        $items=[System.Collections.Generic.List[object]]::new()
        foreach($item in $Value){$items.Add((ConvertTo-DDValue $item ($Depth+1) $MaxDepth))}
        return ,$items.ToArray()
    }
    throw "Unsupported snapshot value type: $($Value.GetType().FullName). Project objects into plain data."
}
function Join-DDPointer([string]$Path,[string]$Key) { return $Path+'/'+$Key.Replace('~','~0').Replace('/','~1') }
function ConvertTo-DDNumberText([string]$Text) {
    # Normalize decimal notation without converting through a bounded decimal type.
    $m=[regex]::Match($Text,'^(?<sign>-?)(?<whole>\d+)(?:\.(?<fraction>\d+))?(?:[eE](?<exponent>[+-]?\d+))?$')
    if(-not $m.Success){throw 'Invalid numeric value.'}
    $digits=($m.Groups['whole'].Value+$m.Groups['fraction'].Value).TrimStart('0')
    if(-not $digits){return '0'}
    $exponent=0
    if($m.Groups['exponent'].Success){$exponent=[int]$m.Groups['exponent'].Value}
    $exponent-=$m.Groups['fraction'].Length
    $trimmed=$digits.TrimEnd('0'); $exponent+=$digits.Length-$trimmed.Length
    return $m.Groups['sign'].Value+$trimmed+'e'+$exponent.ToString([cultureinfo]::InvariantCulture)
}
function ConvertFrom-DDJsonElement($Element,[int]$Depth=0) {
    if($Depth -gt 100){throw 'JSON envelope exceeds maximum depth 100.'}
    switch([string]$Element.ValueKind){
        Object {
            $map=[System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            foreach($property in $Element.EnumerateObject()){
                if($map.Contains($property.Name)){throw 'Duplicate JSON property.'}
                $map.Add($property.Name,(ConvertFrom-DDJsonElement $property.Value ($Depth+1)))
            }
            return ,$map
        }
        Array {
            $items=[System.Collections.Generic.List[object]]::new()
            foreach($item in $Element.EnumerateArray()){$items.Add((ConvertFrom-DDJsonElement $item ($Depth+1)))}
            return ,$items.ToArray()
        }
        String {return $Element.GetString()}
        Number {
            $integer=0L; if($Element.TryGetInt64([ref]$integer)){return $integer}
            $decimalValue=0D
            if($Element.TryGetDecimal([ref]$decimalValue) -and (ConvertTo-DDNumberText $Element.GetRawText()) -ceq (ConvertTo-DDNumberText $decimalValue.ToString('G29',[cultureinfo]::InvariantCulture))){return $decimalValue}
            $number=$Element.GetDouble()
            if([double]::IsNaN($number) -or [double]::IsInfinity($number)){throw 'Non-finite numbers are unsupported.'}
            return $number
        }
        True {return $true}
        False {return $false}
        Null {return $null}
        default {throw 'Unsupported JSON token.'}
    }
}
function ConvertFrom-DDJson([string]$Json) {
    # System.Text.Json is part of the PowerShell 7 runtime. It never infers dates from strings.
    $options=[System.Text.Json.JsonDocumentOptions]::new(); $options.MaxDepth=100
    $document=[System.Text.Json.JsonDocument]::Parse($Json,$options)
    try{return ,(ConvertFrom-DDJsonElement $document.RootElement)}finally{$document.Dispose()}
}
function ConvertTo-DDCanonical {
    param([AllowNull()]$Value,$Rules=$null,$Entity=$null,[string]$Path='',[int]$Depth=0)
    if($Depth -gt 64){throw 'Value exceeds maximum depth 64.'}
    if($null -eq $Value){return 'null'}
    if(Test-DDMap $Value){
        $parts=[System.Collections.Generic.List[string]]::new()
        foreach($key in (Get-DDKeys $Value)){
            $label=ConvertTo-Json -InputObject $key -Compress
            $parts.Add($label+':'+(ConvertTo-DDCanonical (Get-DDField $Value $key) $Rules $Entity (Join-DDPointer $Path $key) ($Depth+1)))
        }
        return '{'+($parts -join ',')+'}'
    }
    if($Value -is [array] -or $Value -is [System.Collections.IList]){
        $policy=Get-DDPolicy $Rules $Entity $Path
        $parts=[System.Collections.Generic.List[string]]::new()
        $seen=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $i=0
        foreach($item in $Value){
            $member=[string]$i
            if($policy.Mode -eq 'Keyed'){
                if(-not (Test-DDMap $item)){throw "Keyed array $Path requires map members."}
                $key=Get-DDField $item $policy.Key
                if($null -eq $key -or (Test-DDMap $key) -or $key -is [array]){throw "Keyed array $Path requires scalar key $($policy.Key)."}
                $member=[string]$key
                if(-not $seen.Add($member)){throw "Duplicate keyed array member at $Path."}
            }
            $parts.Add((ConvertTo-DDCanonical $item $Rules $Entity (Join-DDPointer $Path $member) ($Depth+1))); $i++
        }
        [string[]]$sorted=$parts.ToArray()
        if($policy.Mode -in @('Set','Keyed')){[array]::Sort($sorted,[StringComparer]::Ordinal)}
        if($policy.Mode -eq 'Set'){
            $set=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $sorted=@($sorted|Where-Object {$set.Add($_)})
        }
        return '['+($sorted -join ',')+']'
    }
    if($Value -is [string]){return (ConvertTo-Json -InputObject $Value -Compress)}
    if($Value -is [bool]){if($Value){return 'true'}else{return 'false'}}
    if($Value -is [decimal]){return (ConvertTo-DDNumberText $Value.ToString('G29',[cultureinfo]::InvariantCulture))}
    if($Value -is [double] -or $Value -is [single]){
        $number=$Value.ToString('R',[cultureinfo]::InvariantCulture)
        return (ConvertTo-DDNumberText $number)
    }
    return (ConvertTo-DDNumberText $Value.ToString([cultureinfo]::InvariantCulture))
}
function Get-DDHash {
    [CmdletBinding()]param([Parameter(Mandatory,Position=0)][AllowNull()]$Value)
    $normalized=ConvertTo-DDValue $Value
    return (Get-DDTextHash (ConvertTo-DDCanonical $normalized))
}
function Get-DDTextHash([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','')}
    finally{$sha.Dispose()}
}
