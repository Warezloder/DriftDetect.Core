function ConvertTo-DDHtmlText($Value) {
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}
function ConvertTo-DDDisplay($Value){
    if($null -eq $Value){return 'null'}
    if((Test-DDMap $Value) -or $Value -is [array]){return (ConvertTo-Json -InputObject (ConvertTo-DDValue $Value) -Depth 100)}
    return [string]$Value
}
function New-DDHtmlTable($Rows,[string[]]$Columns){
    $builder=[Text.StringBuilder]::new()
    $null=$builder.Append('<div class="table-scroll"><table><thead><tr>')
    foreach($column in $Columns){$null=$builder.Append('<th scope="col">'+(ConvertTo-DDHtmlText $column)+'</th>')}
    $null=$builder.Append('</tr></thead><tbody>')
    foreach($row in @($Rows)){
        $null=$builder.Append('<tr>')
        foreach($column in $Columns){$null=$builder.Append('<td><pre>'+(ConvertTo-DDHtmlText (ConvertTo-DDDisplay (Get-DDField $row $column)))+'</pre></td>')}
        $null=$builder.Append('</tr>')
    }
    $null=$builder.Append('</tbody></table></div>')
    return $builder.ToString()
}
function Write-DDHtml([string]$Title,[string]$Body,[string]$OutputPath){
    if(-not (Get-Module -ListAvailable PSWriteHTML|Where-Object Version -ge ([version]'0.0.170'))){throw 'HTML reports require PSWriteHTML >=0.0.170. Install-Module PSWriteHTML -Scope CurrentUser'}
    Import-Module PSWriteHTML -MinimumVersion 0.0.170 -ErrorAction Stop
    $style=@'
<style>
body{margin:0;background:#f1f5f9;color:#172b40;font:15px/1.55 "Segoe UI",sans-serif}main{max-width:1440px;margin:auto;padding:36px}header{border-bottom:3px solid #187f82;padding-bottom:22px;margin-bottom:24px}h1{font-size:30px;margin:8px 0}h2{font-size:21px;margin-top:30px}p{max-width:1100px}.brand{color:#187f82;font-size:13px;font-weight:700;letter-spacing:2px}.notice{padding:16px 20px;background:#e8f1fa;border-left:4px solid #2974a0;border-radius:4px}.warning{background:#fff1d6;border-color:#bd7816}details{margin:14px 0;background:white;border:1px solid #d7e2ed;border-radius:6px;padding:14px}summary{font-weight:650;cursor:pointer;overflow-wrap:anywhere}.table-scroll{overflow:auto;margin:12px 0}table{border-collapse:collapse;width:100%;background:white}th{background:#e4edf3;text-align:left;font-size:13px}th,td{padding:10px 14px;border-bottom:1px solid #d7e2ed;vertical-align:top}pre{font:13px/1.5 Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere;margin:0;min-width:100px;max-width:600px}input{padding:11px;border:1px solid #9ab1c7;border-radius:5px;width:min(440px,90%)}footer{margin-top:28px;font-size:12px;color:#536a7b}@media(max-width:700px){main{padding:16px}h1{font-size:24px}}@media print{input,label[for=filter]{display:none}details{break-inside:avoid}main{padding:0}.table-scroll{overflow:visible}}
</style>
'@
    $search=@'
<label for="filter">Filter table rows</label><br><input id="filter" type="search" placeholder="Search configuration or changes" aria-label="Filter table rows">
<script>document.addEventListener('DOMContentLoaded',function(){document.getElementById('filter').addEventListener('input',function(){const q=this.value.toLowerCase();document.querySelectorAll('tbody tr').forEach(function(r){r.hidden=!r.textContent.toLowerCase().includes(q);});});});</script>
'@
    $content=$style+'<main><header><div class="brand">DRIFTDETECT</div><h1>'+(ConvertTo-DDHtmlText $Title)+'</h1></header>'+$search+$Body+'<footer>Generated '+[datetime]::UtcNow.ToString('u')+' · DriftDetect.Core 1.0.1</footer></main>'
    # PSWriteHTML supplies the document shell. Literal file writes are ours so brackets are safe.
    $html=New-HTML -TitleText (ConvertTo-DDHtmlText $Title) -HtmlData { $content } -ShowHTML:$false
    $html|Set-Content -LiteralPath $OutputPath -Encoding utf8 -ErrorAction Stop
    return $OutputPath
}
function Export-DDConfigurationReport {
    [CmdletBinding(DefaultParameterSetName='Object')]
    param([Parameter(Mandatory,ParameterSetName='Object',ValueFromPipeline)]$Snapshot,[Parameter(Mandatory,ParameterSetName='Path')][string]$SnapshotPath,[Parameter(Mandatory)][string]$OutputPath,[string]$Title='Configuration Report')
    process{
        if($PSCmdlet.ParameterSetName -eq 'Path'){$Snapshot=Import-DDSnapshot $SnapshotPath}
        $null=Test-DDSnapshot $Snapshot
        $incomplete=@($Snapshot.Collections|Where-Object Status -in @('Partial','Failed','Unsupported','LegacyUnknown')).Count -gt 0
        $status=if($incomplete){'Incomplete capture: review collection coverage before relying on this inventory.'}else{'Capture complete for the requested applicable scope.'}
        if(Get-DDField $Snapshot.Metadata 'Legacy' $false){$status='Legacy snapshot: completeness unknown. Capture a new baseline for comparison.'}
        $body='<p class="notice '+$(if($incomplete){'warning'})+'">'+(ConvertTo-DDHtmlText $status)+'</p>'
        $body+='<p>Full configuration means all data in this snapshot; skipped collectors and excluded fields are not assessed.</p>'
        $body+=New-DDHtmlTable @([ordered]@{Technology=$Snapshot.Technology;Target=$Snapshot.Target.Name;Identity=$Snapshot.Target.Id;Version=$Snapshot.Target.Version;Build=$Snapshot.Target.Build;CapturedAt=$Snapshot.CapturedAt;SnapshotId=$Snapshot.SnapshotId}) @('Technology','Target','Identity','Version','Build','CapturedAt','SnapshotId')
        $body+='<h2>Collection coverage</h2>'+(New-DDHtmlTable $Snapshot.Collections @('Id','Status','EntityCount','Reason','Scope','Diagnostics'))
        $body+='<h2>Selections and exclusions</h2>'+(New-DDHtmlTable @(@{CollectionProfile=$Snapshot.CollectionProfile}) @('CollectionProfile'))
        foreach($type in (Get-DDKeys $Snapshot.Entities)){
            $body+='<h2>'+(ConvertTo-DDHtmlText $type)+'</h2>'
            foreach($entity in $Snapshot.Entities[$type]){
                $body+='<details open><summary>'+(ConvertTo-DDHtmlText $entity.Name)+'</summary><p>'+(ConvertTo-DDHtmlText $entity.Path)+'</p>'
                $rows=@(foreach($key in (Get-DDKeys $entity.Properties)){[pscustomobject]@{Property=$key;Value=(Get-DDField $entity.Properties $key)}})
                $body+=New-DDHtmlTable $rows @('Property','Value')
                if((Get-DDKeys $entity.Observations).Count){
                    $body+='<details><summary>Operational observations (not compared)</summary>'
                    $rows=@(foreach($key in (Get-DDKeys $entity.Observations)){[pscustomobject]@{Observation=$key;Value=(Get-DDField $entity.Observations $key)}})
                    $body+=(New-DDHtmlTable $rows @('Observation','Value'))+'</details>'
                }
                $body+='</details>'
            }
        }
        Write-DDHtml $Title $body $OutputPath
    }
}
function Export-DDDriftReport {
    [CmdletBinding(DefaultParameterSetName='Object')]
    param([Parameter(Mandatory,ParameterSetName='Object',ValueFromPipeline)]$DriftResult,[Parameter(Mandatory,ParameterSetName='Path')][string]$DriftResultPath,[Parameter(Mandatory)][string]$OutputPath,[string]$Title='Configuration Drift Report')
    process{
        if($PSCmdlet.ParameterSetName -eq 'Path'){$DriftResult=ConvertFrom-DDJson (Get-Content -LiteralPath $DriftResultPath -Raw -ErrorAction Stop)}
        $legacy=(Get-DDField $DriftResult 'SchemaVersion' '') -ne '2.0'
        $complete=(-not $legacy -and $DriftResult.IsComplete)
        $status=if($legacy){'Legacy drift result: completeness unknown; original totals and available details retained.'}elseif(-not $complete){'Inconclusive: collection coverage is incomplete. Observed changes are shown below.'}elseif($DriftResult.HasDrift){'Configuration drift detected.'}else{'No configuration drift detected in the compared scope.'}
        $body='<p class="notice '+$(if(-not $complete){'warning'})+'">'+(ConvertTo-DDHtmlText $status)+'</p>'
        $body+='<p>Total changes: '+(ConvertTo-DDHtmlText $DriftResult.TotalChanges)+' · Added entities: '+(ConvertTo-DDHtmlText $DriftResult.TotalNew)+' · Removed entities: '+(ConvertTo-DDHtmlText $DriftResult.TotalDeleted)+'</p>'
        $target=Get-DDField $DriftResult 'Target' @{}
        $targetName=Get-DDField $target 'Name' (Get-DDField $DriftResult 'ComputerName' (Get-DDField $DriftResult 'HostName' ''))
        $body+=New-DDHtmlTable @(@{Target=$targetName;Baseline=$DriftResult.BaselineSnapshot;Current=$DriftResult.CurrentSnapshot;BaselineCapturedAt=$DriftResult.BaselineCapturedAt;CurrentCapturedAt=$DriftResult.CurrentCapturedAt;RuleFingerprint=$DriftResult.RuleFingerprint}) @('Target','Baseline','Current','BaselineCapturedAt','CurrentCapturedAt','RuleFingerprint')
        $summary=@(foreach($s in @('Critical','High','Medium','Low')){@{Severity=$s;Events=(Get-DDField $DriftResult.SeveritySummary $s 0)}})
        $body+='<h2>Severity summary</h2>'+(New-DDHtmlTable $summary @('Severity','Events'))
        $body+='<h2>Selections and exclusions</h2><p>Excluded fields are not assessed for drift. Review the profiles and per-collection scopes below.</p>'+(New-DDHtmlTable @(@{Baseline=(Get-DDField $DriftResult 'BaselineCollectionProfile' @{});Current=(Get-DDField $DriftResult 'CurrentCollectionProfile' @{})}) @('Baseline','Current'))
        $body+='<h2>Collection coverage</h2>'+(New-DDHtmlTable (Get-DDField $DriftResult 'Coverage' @()) @('CollectionId','BaselineStatus','CurrentStatus','Compared','Reason','BaselineScope','CurrentScope'))
        $body+='<h2>Diagnostics</h2>'+(New-DDHtmlTable (Get-DDField $DriftResult 'Diagnostics' @()) @('Code','Message'))
        if($legacy){
            foreach($kind in @('Changes','NewEntities','DeletedEntities')){
                $body+='<h2>'+$kind+'</h2>'+(New-DDHtmlTable (Get-DDField $DriftResult $kind @()) @('EntityType','EntityName','EntityPath','Property','ChangeType','OldValue','NewValue','Severity','Hash'))
            }
        }else{
            $body+='<h2>Configuration changes</h2>'+(New-DDHtmlTable $DriftResult.Events @('Severity','ChangeType','EntityType','EntityName','EntityPath','PropertyPath','OldValue','NewValue'))
        }
        Write-DDHtml $Title $body $OutputPath
    }
}
