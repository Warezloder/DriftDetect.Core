BeforeAll {
    Import-Module "$PSScriptRoot/../DriftDetect.Core.psd1" -Force -ErrorAction Stop
    function Entity($props, $id='one', $obs=@{}) { New-DDEntity -EntityType Thing -Id $id -Name $id -CollectionId Main -Properties $props -Observations $obs }
    function Snapshot($entities=@(), $rules=(New-DDRuleSet), $status='Success', $scope=@{}) {
        $collection = New-DDCollection -Id Main -Status $status -Entities $entities -Scope $scope
        New-DDSnapshot -Technology WinServer -Target @{Id='machine-1';Name='server';IdentitySource='Fixture';Version='1';Build='1'} -Collections @($collection) -RuleSet $rules
    }
    function CompareProps($old,$new,$rules=(New-DDRuleSet)) { Compare-DDSnapshot (Snapshot @((Entity $old)) $rules) (Snapshot @((Entity $new)) $rules) }
}
Describe 'Typed configuration comparison' {
    It 'compares dictionary fields whose names shadow dictionary members' {
        (CompareProps @{Keys='constant';Count=1;Setting='old'} @{Keys='constant';Count=1;Setting='new'}).TotalChanges | Should -Be 1
    }
    It 'finds nested changes in arrays of maps' { (CompareProps @{Trusts=@(@{TrustedDomain='a';Direction=1})} @{Trusts=@(@{TrustedDomain='a';Direction=3})}).TotalChanges | Should -Be 1 }
    It 'preserves DNS priority' { (CompareProps @{DNS=@('a','b')} @{DNS=@('b','a')}).TotalChanges | Should -Be 1 }
    It 'compares strings case sensitively' { (CompareProps @{Value='audit'} @{Value='AUDIT'}).TotalChanges | Should -Be 1 }
    It 'distinguishes null from absent' { (CompareProps @{Value=$null} @{}).Events[0].ChangeType | Should -Be PropertyRemoved }
    It 'distinguishes null and empty array' { (CompareProps @{Value=$null} @{Value=@()}).TotalChanges | Should -Be 1 }
    It 'distinguishes empty array and singleton' { (CompareProps @{Value=@()} @{Value=@('x')}).TotalChanges | Should -Be 1 }
    It 'distinguishes false from zero' { (CompareProps @{Value=$false} @{Value=0}).TotalChanges | Should -Be 1 }
    It 'distinguishes strings and numbers' { (CompareProps @{Value='1'} @{Value=1}).TotalChanges | Should -Be 1 }
    It 'equates JSON numeric representations' { (CompareProps @{Value=1} @{Value=1.0}).TotalChanges | Should -Be 0 }
    It 'uses escaped JSON pointers' { (CompareProps @{'a/b~c'=1} @{'a/b~c'=2}).Events[0].PropertyPath | Should -Be '/a~1b~0c' }
    It 'handles set order and duplicates' {
        $rules=New-DDRuleSet -ComparisonPolicies @(@{Id='members';EntityType='Thing';PropertyPath='/Members';Mode='Set'})
        (CompareProps @{Members=@('b','a','a')} @{Members=@('a','b')} $rules).TotalChanges | Should -Be 0
        (Snapshot @((Entity @{Members=@('b','a','a')})) $rules).Entities.Thing[0].Hash | Should -Be (Snapshot @((Entity @{Members=@('a','b')})) $rules).Entities.Thing[0].Hash
    }
    It 'compares keyed members recursively' {
        $rules=New-DDRuleSet -ComparisonPolicies @(@{Id='trust';PropertyPath='/Trusts';Mode='Keyed';Key='Name'})
        $r=CompareProps @{Trusts=@(@{Name='a';Direction=1})} @{Trusts=@(@{Name='a';Direction=3})} $rules
        $r.TotalChanges | Should -Be 1
        $r.Events[0].PropertyPath | Should -Be '/Trusts/a/Direction'
    }
    It 'rejects duplicate keyed members' {
        $rules=New-DDRuleSet -ComparisonPolicies @(@{Id='trust';PropertyPath='/Trusts';Mode='Keyed';Key='Name'})
        { CompareProps @{Trusts=@(@{Name='a'},@{Name='a'})} @{Trusts=@()} $rules } | Should -Throw '*duplicate*'
    }
    It 'ignores observations' { (Compare-DDSnapshot (Snapshot @((Entity @{A=1} one @{Free=1}))) (Snapshot @((Entity @{A=1} one @{Free=2})))).TotalChanges | Should -Be 0 }
    It 'recomputes hashes after caller mutation' {
        $a=Snapshot @((Entity @{Value=1})); $b=Snapshot @((Entity @{Value=1})); $b.Entities.Thing[0].Properties.Value=2
        (Compare-DDSnapshot $a $b).TotalChanges | Should -Be 1
    }
}
Describe 'Snapshot validation and persistence' {
    It 'round trips the deepest supported property values without truncation' {
        $value=@{Leaf='deep'}; 1..63 | ForEach-Object {$value=@{Child=$value}}
        $s=Snapshot @((Entity $value)); $path=Join-Path $TestDrive deep.json
        $null=Export-DDSnapshot $s $path
        (Compare-DDSnapshot $s (Import-DDSnapshot $path)).TotalChanges | Should -Be 0
    }
    It 'preserves date-looking strings and high precision numbers during persistence' {
        $s=Snapshot @((Entity @{Boundary='2026-01-01T12:00:00';Offset='2026-01-01T12:00:00+03:00';Number=[decimal]'1.2345678901234567890123456789';Tiny=1.1e-28}))
        $path=Join-Path $TestDrive strings.json; $null=Export-DDSnapshot $s $path; $loaded=Import-DDSnapshot $path
        $loaded.Entities.Thing[0].Properties.Boundary | Should -BeExactly '2026-01-01T12:00:00'
        (Compare-DDSnapshot $s $loaded).TotalChanges | Should -Be 0
    }
    It 'does not round distinct tiny or high precision floating point numbers together' {
        (CompareProps @{Value=1.1e-28} @{Value=1.4e-28}).TotalChanges | Should -Be 1
        (Get-DDHash (1.1e-28)) | Should -Not -Be (Get-DDHash (1.4e-28))
    }
    It 'keeps map hashes deterministic' { (Get-DDHash @{b=2;a=1}) | Should -Be (Get-DDHash ([ordered]@{a=1;b=2})) }
    It 'round trips nested values and cardinalities through literal paths' {
        $s=Snapshot @((Entity @{Empty=@();Single=@('one');Nested=@{Value=$null};Date=[datetime]'2026-01-01Z'}))
        $path=Join-Path $TestDrive 'snapshot [test].json'; $null=Export-DDSnapshot $s $path; $loaded=Import-DDSnapshot $path
        (Compare-DDSnapshot $s $loaded).TotalChanges | Should -Be 0
        $loaded.Entities.Thing[0].Properties.Single.Count | Should -Be 1
        $loaded.Entities.Thing[0].Properties.Empty.Count | Should -Be 0
    }
    It 'rejects duplicate entity identities' { { Snapshot @((Entity @{}), (Entity @{})) } | Should -Throw '*duplicate*' }
    It 'rejects unknown snapshot schema' { $s=Snapshot; $s.SchemaVersion='9.0'; {Test-DDSnapshot $s} | Should -Throw '*schema*' }
    It 'rejects missing collection references' { $s=Snapshot @((Entity @{})); $s.Entities.Thing[0].CollectionId='missing'; {Test-DDSnapshot $s} | Should -Throw '*collection*' }
    It 'rejects live unsupported objects' { { New-DDEntity Thing one one Main @{Bad=[System.Text.StringBuilder]::new()} } | Should -Throw '*unsupported*' }
    It 'rejects excessive depth' { $v=@{}; $p=$v; 1..70 | ForEach-Object {$p['child']=@{}; $p=$p.child}; {Get-DDHash $v} | Should -Throw '*depth*' }
    It 'imports legacy for reporting but never compares it' {
        $path=Join-Path $TestDrive legacy.json
        @{SchemaVersion='1.0';SnapshotId='old';ComputerName='server';CapturedAt='2026-01-01T00:00:00Z';Entities=@{Thing=@(@{EntityType='Thing';Name='old';Path='one';Properties=@{A=1}})}} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
        $legacy=Import-DDSnapshot $path; $legacy.Metadata.Legacy | Should -BeTrue
        {Compare-DDSnapshot $legacy $legacy -AllowPartial} | Should -Throw '*baseline*'
    }
}
Describe 'Coverage is part of correctness' {
    It 'flattens collection diagnostics without inventing empty entries' {
        $a=Snapshot; $b=Snapshot
        (Compare-DDSnapshot $a $b).Diagnostics.Count | Should -Be 0
        $b.Collections[0].Diagnostics=@(@{Code='Notice';Message='Fixture notice'})
        $r=Compare-DDSnapshot $a $b
        $r.Diagnostics.Count | Should -Be 1; $r.Diagnostics[0].Code | Should -Be Notice
    }
    It 'rejects different targets' { $a=Snapshot; $b=Snapshot; $b.Target.Id='other'; {Compare-DDSnapshot $a $b -AllowPartial} | Should -Throw '*target*' }
    It 'does not turn collection failure into deletion' { {Compare-DDSnapshot (Snapshot @((Entity @{}))) (Snapshot @() (New-DDRuleSet) Failed)} | Should -Throw '*incomplete*' }
    It 'excludes failed units in partial mode' {
        $r=Compare-DDSnapshot (Snapshot @((Entity @{}))) (Snapshot @() (New-DDRuleSet) Failed) -AllowPartial
        $r.TotalDeleted | Should -Be 0; $r.IsComplete | Should -BeFalse; $r.Coverage.Count | Should -Be 1
    }
    It 'recognizes successful zero results as removals' { (Compare-DDSnapshot (Snapshot @((Entity @{}))) (Snapshot)).TotalDeleted | Should -Be 1 }
    It 'rejects different per-unit selections' { {Compare-DDSnapshot (Snapshot @() (New-DDRuleSet) Success @{Filter='a'}) (Snapshot @() (New-DDRuleSet) Success @{Filter='b'})} | Should -Throw '*scope*' }
    It 'does not downgrade completeness for matched inapplicable units when another unit succeeds' {
        $a=Snapshot; $b=Snapshot
        $na=New-DDCollection -Id LocalSAM -Status NotApplicable -Reason 'DomainController'
        $a.Collections+=@($na); $b.Collections+=@($na)
        (Compare-DDSnapshot $a $b).IsComplete | Should -BeTrue
    }
    It 'contains collector failures without persisting their messages' {
        $r=Invoke-DDCollector -Id Main -ScriptBlock {throw 'password=SUPER-SECRET'}
        $r.Status | Should -Be Failed
        ($r|ConvertTo-Json -Depth 10) | Should -Not -Match 'SUPER-SECRET'
    }
    It 'passes arrays as a single collector argument' {
        $r=Invoke-DDCollector -Id Main -ArgumentList @(,@('a','b')) -ScriptBlock {param($paths) New-DDEntity -EntityType Thing -Id one -Name one -CollectionId Main -Properties @{Count=$paths.Count}}
        $r.Entities[0].Properties.Count | Should -Be 2
    }
}
Describe 'Rules and event summaries' {
    It 'rejects ambiguous overlapping segment wildcard policies' {
        {New-DDRuleSet -ComparisonPolicies @(@{Id='set';PropertyPath='/Things/*/Members';Mode='Set'},@{Id='ordered';PropertyPath='/Things/one/Members';Mode='Ordered'})} | Should -Throw '*conflict*'
    }
    It 'counts and scores entity removal' {
        $rules=New-DDRuleSet -SeverityRules @(@{Id='delete';ChangeType='EntityRemoved';Severity='Critical'})
        $r=Compare-DDSnapshot (Snapshot @((Entity @{A=1})) $rules) (Snapshot @() $rules)
        $r.TotalChanges | Should -Be 1; $r.TotalDeleted | Should -Be 1; $r.SeveritySummary.Critical | Should -Be 1; $r.Events[0].OldValue.A | Should -Be 1
    }
    It 'counts and scores additions' { $r=Compare-DDSnapshot (Snapshot) (Snapshot @((Entity @{A=1}))); $r.TotalChanges | Should -Be 1; $r.HasDrift | Should -BeTrue }
    It 'matches entity name plus Value for severity' {
        $rules=New-DDRuleSet -SeverityRules @(@{Id='generic';PropertyPath='/Value';Severity='Medium'},@{Id='specific';EntityName='one';PropertyPath='/Value';Severity='High'})
        (CompareProps @{Value='strict'} @{Value='weak'} $rules).Events[0].Severity | Should -Be High
    }
    It 'rejects conflicting equally ranked rules' {
        { New-DDRuleSet -SeverityRules @(@{Id='a';PropertyPath='/Value';Severity='High'},@{Id='b';PropertyPath='/Value';Severity='Low'}) } | Should -Throw '*conflict*'
    }
    It 'rejects unknown severity' { {New-DDRuleSet -SeverityRules @(@{Id='bad';Severity='Oops'})} | Should -Throw '*severity*' }
    It 'rejects rule drift without explicit override' {
        $a=Snapshot; $rules=New-DDRuleSet -SeverityRules @(@{Id='high';Severity='High'}); $b=Snapshot @() $rules
        {Compare-DDSnapshot $a $b} | Should -Throw '*rule*'
        (Compare-DDSnapshot $a $b -RuleSet $rules).TotalChanges | Should -Be 0
    }
    It 'loads legacy severity rule syntax' {
        $path=Join-Path $TestDrive rules.json; '{"Rules":[{"EntityType":"Thing","Property":"Value","Severity":"High"}]}' | Set-Content $path
        $rules=Import-DDRuleSet $path
        (CompareProps @{Value=1} @{Value=2} $rules).Events[0].Severity | Should -Be High
    }
}
