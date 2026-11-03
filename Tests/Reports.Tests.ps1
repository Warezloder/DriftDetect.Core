BeforeAll {
    Import-Module "$PSScriptRoot/../DriftDetect.Core.psd1" -Force
    $script:danger='<script>alert("unsafe")</script>'
    $e=New-DDEntity -EntityType Service -Id svc -Name $script:danger -CollectionId Services -Properties @{StartType='Automatic';Nested=@{Value=$script:danger}} -Observations @{Running=$true}
    $script:baseline=New-DDSnapshot -Technology WinServer -Target @{Id='test';Name=$script:danger;IdentitySource='Fixture';Version='1';Build='1'} -Collections @((New-DDCollection -Id Services -Status Success -Entities @($e))) -RuleSet (New-DDRuleSet)
    $script:empty=New-DDSnapshot -Technology WinServer -Target @{Id='test';Name=$script:danger;IdentitySource='Fixture';Version='1';Build='1'} -Collections @((New-DDCollection -Id Services -Status Success)) -RuleSet (New-DDRuleSet)
}
Describe 'Shared configuration and drift reports' {
    It 'discloses field exclusions and selection scope even for clean results' {
        $s=New-DDSnapshot -Technology WinServer -Target @{Id='test';Name='test'} -Collections @((New-DDCollection -Id Tasks -Status Success -Scope @{TaskArgumentAllowList=@();ArgumentCoverage='Omitted argument drift is not assessed.'})) -CollectionProfile @{ExcludedFields=@('LicenseKey');Exclusions=@('Omitted argument drift is not assessed.')} -RuleSet (New-DDRuleSet)
        $r=Compare-DDSnapshot $s $s
        $r.Coverage[0].CurrentScope.ArgumentCoverage | Should -Match 'not assessed'
        $drift=Join-Path $TestDrive excluded.html; $config=Join-Path $TestDrive exclusions-config.html
        $null=Export-DDDriftReport -DriftResult $r -OutputPath $drift
        $null=Export-DDConfigurationReport -Snapshot $s -OutputPath $config
        foreach($p in @($drift,$config)){
            $html=Get-Content -LiteralPath $p -Raw
            $html | Should -Match 'LicenseKey'; $html | Should -Match 'Omitted argument drift is not assessed'
        }
    }
    It 'shows every captured field and encodes untrusted text using literal output paths' {
        $path=Join-Path $TestDrive 'configuration [1].html'
        Export-DDConfigurationReport -Snapshot $script:baseline -OutputPath $path -Title $script:danger | Should -Be $path
        $html=Get-Content -LiteralPath $path -Raw
        $html | Should -Match 'StartType'; $html | Should -Match 'Automatic'; $html | Should -Match 'Operational observations'; $html | Should -Match 'Collection coverage'
        $html | Should -Not -Match ([regex]::Escape($script:danger)); $html | Should -Match '&lt;script&gt;'
        $html | Should -Not -Match '<(?:script|link)[^>]+(?:src|href)=["'']https?://'
        $html | Should -Not -Match 'System.Collections.Hashtable'
    }
    It 'renders removed configuration and corrected totals' {
        $r=Compare-DDSnapshot $script:baseline $script:empty
        $path=Join-Path $TestDrive drift.html; $null=Export-DDDriftReport -DriftResult $r -OutputPath $path
        $html=Get-Content $path -Raw
        $html | Should -Match 'EntityRemoved'; $html | Should -Match 'Automatic'; $html | Should -Match 'Total changes: 1'
    }
    It 'renders zero change results with coverage' {
        $r=Compare-DDSnapshot $script:baseline $script:baseline
        $path=Join-Path $TestDrive clean.html; $null=Export-DDDriftReport -DriftResult $r -OutputPath $path
        (Get-Content $path -Raw) | Should -Match 'No configuration drift detected in the compared scope'
    }
    It 'labels an incomplete zero-change result inconclusive' {
        $broken=New-DDSnapshot -Technology WinServer -Target @{Id='test';Name=$script:danger;IdentitySource='Fixture'} -Collections @((New-DDCollection -Id Services -Status Failed)) -RuleSet (New-DDRuleSet)
        $r=Compare-DDSnapshot $script:baseline $broken -AllowPartial
        $path=Join-Path $TestDrive partial.html; $null=Export-DDDriftReport -DriftResult $r -OutputPath $path
        (Get-Content $path -Raw) | Should -Match 'Inconclusive'
    }
    It 'supports snapshot and drift JSON inputs' {
        $p=Join-Path $TestDrive snapshot.json; $null=Export-DDSnapshot $script:baseline $p
        $null=Export-DDConfigurationReport -SnapshotPath $p -OutputPath (Join-Path $TestDrive loaded.html)
        $r=Compare-DDSnapshot $script:empty $script:baseline
        $rp=Join-Path $TestDrive result.json; $r | ConvertTo-Json -Depth 100 | Set-Content $rp
        $out=Join-Path $TestDrive loaded-drift.html; $null=Export-DDDriftReport -DriftResultPath $rp -OutputPath $out
        (Get-Content $out -Raw) | Should -Match 'EntityAdded'
    }
    It 'labels old drift reports legacy without inventing details' {
        $legacy=[pscustomobject]@{ComputerName='old';Changes=@();NewEntities=@(@{EntityType='Service';EntityName='legacy';Hash='oldhash'});DeletedEntities=@();TotalChanges=0;TotalNew=1;TotalDeleted=0;SeveritySummary=@{Critical=0;High=0;Medium=0;Low=0}}
        $path=Join-Path $TestDrive legacy.html; $null=Export-DDDriftReport -DriftResult $legacy -OutputPath $path
        (Get-Content $path -Raw) | Should -Match 'Legacy.*completeness unknown'
    }
}
