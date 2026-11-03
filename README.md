---
title: DriftDetect.Core
tags: [powershell, driftdetect]
---

# DriftDetect.Core 1.0.1

Common snapshots, collection coverage, typed comparison, JSON persistence and HTML reporting. Requires PowerShell 7.0+. HTML export alone requires PSWriteHTML >=0.0.170.

Version 1.0.1 fixes CLIXML-remoted lists that also identify as PowerShell custom objects: collection interfaces take precedence over object properties. Empty, singleton, and ordered lists retain their array shape, without allocation metadata. Persisted snapshots are not rewritten; adapters must version affected collection contracts and require fresh baselines when capture shape changes.

## Local use

Place all three sibling module directories under a directory in PSModulePath. For this checkout, a process-only development setup is:

~~~powershell
$env:PSModulePath = 'C:\Tools\Repositories\DriftDetect;' + $env:PSModulePath
Import-Module DriftDetect.WinServer
Import-Module DriftDetect.ESXi
~~~

No global installation, PowerCLI connection or PSWriteHTML import is needed for offline JSON and comparison.

## Common contract

Providers return entities with stable Id, EntityType, CollectionId, configuration Properties and operational Observations. Collection units explicitly record Success, Partial, Failed, Skipped, Unsupported or NotApplicable. Successful empty queries differ from failed queries.

~~~powershell
$rules = New-DDRuleSet -SeverityRules @(
    @{ Id='removed'; ChangeType='EntityRemoved'; Severity='High' }
)
$entity = New-DDEntity -EntityType Service -Id ssh -Name SSH -CollectionId Services -Properties @{ Policy='Off' } -Observations @{ Running=$false }
$unit = New-DDCollection -Id Services -Status Success -Entities @($entity)
$snapshot = New-DDSnapshot -Technology ESXi -Target @{ Id='host-uuid'; Name='esxi.example'; IdentitySource='HardwareUUID' } -Collections @($unit) -RuleSet $rules
Export-DDSnapshot -Snapshot $snapshot -Path .\snapshot.json
Export-DDConfigurationReport -Snapshot $snapshot -OutputPath .\configuration.html
~~~

Schema 2.0 includes effective rules, per-unit scope fingerprints, target identity, and coverage. Duplicate entity identities and invalid values are rejected. JSON uses literal paths, UTF-8, and a maximum supported value nesting depth of 64.

## Comparison

~~~powershell
$a = Import-DDSnapshot .\baseline.json
$b = Import-DDSnapshot .\current.json
$drift = Compare-DDSnapshot $a $b
Export-DDDriftReport -DriftResult $drift -OutputPath .\drift.html
~~~

Strict comparison refuses different targets, incompatible scopes/rules, or incomplete applicable collection units. **-AllowPartial** compares only successful units with matching scope and contract versions. Inspect **IsComplete** alongside **HasDrift**: zero observed changes in an incomplete comparison is inconclusive.

**TotalChanges** counts all events, including whole-entity additions/removals. TotalModified, TotalNew, and TotalDeleted partition that count. Changes, NewEntities, and DeletedEntities remain compatibility views. SeveritySummary includes all event types.

Maps compare recursively with case-sensitive keys and strings. Null, absent, empty arrays/strings, booleans, numeric values and numeric strings remain distinct. Equivalent JSON numeric representations compare equally. Array policies are Ordered (default), Set (ignores order and duplicate identical entries), and Keyed (matches map members by a scalar key). Observations never cause configuration drift.

## Declarative rules

~~~powershell
$rules = New-DDRuleSet -ComparisonPolicies @(
    @{ Id='members'; EntityType='LocalAccount'; PropertyPath='/Members'; Mode='Set' }
    @{ Id='trusts'; EntityType='Domain'; PropertyPath='/Trusts'; Mode='Keyed'; Key='TrustedDomain' }
) -SeverityRules @(
    @{ Id='password'; EntityType='AdvancedSetting'; EntityName='Security.PasswordQualityControl'
       PropertyPath='/Value'; Severity='High' }
)
~~~

Severity selectors are Technology, EntityType, EntityName, EntityId, PropertyPath, and ChangeType. Omitted selectors mean *. Paths use JSON Pointer escaping. Highest Priority wins, then most specific match; equal ranked contradictory rules are errors. Comparison policy paths may use * for keyed member segments. Rules contain data, never commands.

Rules are embedded in snapshots. Policy changes require an explicit override applied to both snapshots; this cannot recover omitted data. Import-DDRuleSet also translates legacy severity-only files.

## Reports and migration

Configuration reports contain all captured settings, separate observations, and coverage. Drift reports contain coverage, events, old/new values and severity. Both retain selection/exclusion notices, embed assets, escape untrusted text and support filtering without network access. Date-looking configuration strings remain strings during JSON import.

> [!warning]
> Schema 1 snapshots remain readable for inspection/reporting, but cannot be compared. Capture a fresh baseline with the same scope as subsequent captures. Legacy drift-result reports mark completeness unknown.

Technology packages 2.0 retain cmdlet names and parameters but replace public classes with plain common objects. Replace the snapshot Export method with Export-DDSnapshot. Retained Classes directories are inactive legacy source.

The Windows adapter omits task arguments unless the exact full task path appears in TaskArgumentAllowList. Omitted arguments have no persisted content or hash and are not compared. An allowlist authorizes persistence of reviewed non-secret arguments.

## Verification

Run tools/Test-DriftDetect.ps1 from the workspace parent. It stages fresh packages, runs Pester, and retains XML/JSON evidence under artifacts/test-runs. No credentials or live connections are needed. Automated collector tests mock platform commands; live-server and minimum-version runtime validation are separate.

The final combined implementation suite passed 142 tests. The Windows provider suite also passed 23 tests under Windows PowerShell 5.1. See [review resolutions and evidence](../review-artifacts/implementation-review-resolutions.md). Generate synthetic examples with tools/New-SampleReports.ps1; HTML/JSON examples are under artifacts/examples.
