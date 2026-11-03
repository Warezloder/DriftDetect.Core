BeforeAll {
    Import-Module "$PSScriptRoot/../DriftDetect.Core.psd1" -Force -ErrorAction Stop
}
Describe 'Remoted collection normalization' {
    It 'preserves nested empty singleton and ordered lists after CLIXML transport' {
        $plain=@{Empty=@();Single=@('one');Dns=@(@{AddressFamily='2';ServerAddresses=@('10.0.0.10','10.0.0.11')})}
        $remote=[System.Management.Automation.PSSerializer]::Deserialize([System.Management.Automation.PSSerializer]::Serialize($plain,100))
        $entity=New-DDEntity NetworkAdapter nic nic Network $remote
        $entity.Properties.Empty -is [array] | Should -BeTrue
        $entity.Properties.Empty.Count | Should -Be 0
        $entity.Properties.Single -is [array] | Should -BeTrue
        $entity.Properties.Single.Count | Should -Be 1
        $entity.Properties.Dns[0].ServerAddresses[1] | Should -Be '10.0.0.11'
        ($entity.Properties | ConvertTo-Json -Depth 20) | Should -Not -Match 'SyncRoot|Capacity|IsSynchronized'
        (Get-DDHash $remote) | Should -Be (Get-DDHash $plain)
    }
    It 'ignores collection allocation capacity while preserving actual map keys' {
        $list=[System.Collections.ArrayList]@('one'); $list.Capacity=32
        $remote=[System.Management.Automation.PSSerializer]::Deserialize([System.Management.Automation.PSSerializer]::Serialize(@{List=$list;Map=[pscustomobject]@{Count=7;Capacity=8;SyncRoot='real-value'}},100))
        $entity=New-DDEntity Thing one one Main $remote
        $entity.Properties.List -is [array] | Should -BeTrue
        $entity.Properties.List.Count | Should -Be 1
        $entity.Properties.Map.Count | Should -Be 7
        $entity.Properties.Map.Capacity | Should -Be 8
        $entity.Properties.Map.SyncRoot | Should -Be 'real-value'
    }
}
