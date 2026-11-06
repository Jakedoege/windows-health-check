#Requires -Version 5.1
# Self-contained checks: no Pester dependency and no changes to system settings.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptUnderTest = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-SystemHealth.ps1'
$FixtureFailure = $false
$MemoryFreeKb = 512000
$RebootPending = $false
$EventCount = 0
$FixtureDisks = @(
    [pscustomobject]@{ DeviceID = 'C:'; Size = 100GB; FreeSpace = 10GB },
    [pscustomobject]@{ DeviceID = 'D:'; Size = 100GB; FreeSpace = 20GB }
)
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}
function Get-CimInstance {
    param($ClassName, $Filter, $ErrorAction)
    if ($FixtureFailure) { throw 'Fixture: access denied' }
    if ($ClassName -eq 'Win32_OperatingSystem') {
        return [pscustomobject]@{
            TotalVisibleMemorySize = 1024000; FreePhysicalMemory = $MemoryFreeKb
            LastBootUpTime = (Get-Date).AddDays(-2)
        }
    }
    $FixtureDisks
}
function Get-Service {
    param($Name, $ErrorAction)
    if ($Name -eq 'missing-fixture') { throw 'Fixture: service missing' }
    [pscustomobject]@{ Status = 'Running' }
}
function Test-Path {
    param($LiteralPath, $PathType, $ErrorAction)
    if ($LiteralPath -like 'HKLM:*') { return $false }
    if ($PathType) { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType }
    Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
function Get-ItemProperty {
    param($LiteralPath, $ErrorAction)
    if ($RebootPending) { return [pscustomobject]@{ PendingFileRenameOperations = @('fixture') } }
    [pscustomobject]@{}
}
function Get-WinEvent {
    param($FilterHashtable, $ErrorAction)
    if ($FixtureFailure) { throw 'Fixture: log access denied' }
    for ($i = 0; $i -lt $EventCount; $i++) { [pscustomobject]@{ Id = 41 } }
}
function Resolve-DnsName {
    param($Name, [switch]$DnsOnly, $ErrorAction)
    [pscustomobject]@{ Type = 'A' }
}

$reportPath = Join-Path ([IO.Path]::GetTempPath()) ('windows-health-test-' + [guid]::NewGuid().ToString('N') + '.json')
$listener = $null
try {
    $report = & $scriptUnderTest -SkipNetwork -PassThru -JsonPath $reportPath
    Assert-True ($report.OverallStatus -eq 'Critical') '10% free disk must be critical at the boundary'
    Assert-True (@($report.Checks | Where-Object { $_.Name -eq 'D:' -and $_.Status -eq 'Warning' }).Count -eq 1) '20% free disk must warn at the boundary'
    Assert-True ($report.Counts.Skipped -eq 2) 'both network checks must be skipped'
    $json = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    Assert-True ($json.SchemaVersion -eq '1.0' -and $json.Checks.Count -eq $report.Checks.Count) 'JSON round trip must preserve checks'
    $rejected = $false
    try { & $scriptUnderTest -SkipNetwork -JsonPath $reportPath | Out-Null } catch { $rejected = $_.Exception.Message -like '*already exists*' }
    Assert-True $rejected 'existing output must not be overwritten without Force'

    $FixtureDisks = @([pscustomobject]@{ DeviceID = 'C:'; Size = 100GB; FreeSpace = 50GB })
    $MemoryFreeKb = 51200 # Exactly 95% used.
    $RebootPending = $true
    $EventCount = 2
    $report = & $scriptUnderTest -SkipNetwork -PassThru
    Assert-True (@($report.Checks | Where-Object { $_.Category -eq 'Memory' -and $_.Status -eq 'Critical' }).Count -eq 1) '95% memory must be critical'
    Assert-True (@($report.Checks | Where-Object { $_.Name -eq 'Reboot indicators' -and $_.Status -eq 'Warning' }).Count -eq 1) 'pending file operations must warn'
    Assert-True (@($report.Checks | Where-Object { $_.Category -eq 'Events' -and $_.Data.Count -eq 2 }).Count -eq 1) 'critical event count must be reported'

    $FixtureFailure = $true
    $report = & $scriptUnderTest -SkipNetwork -PassThru -ServiceName EventLog, missing-fixture
    Assert-True ($report.Counts.Unknown -ge 4) 'unavailable data must stay Unknown'
    Assert-True (@($report.Checks | Where-Object { $_.Name -eq 'EventLog' -and $_.Status -eq 'OK' }).Count -eq 1) 'one failed subsystem must not suppress other checks'
    $FixtureFailure = $false

    $rejected = $false
    try { & $scriptUnderTest -DiskWarningPercent 10 -DiskCriticalPercent 20 | Out-Null } catch { $rejected = $_.Exception.Message -like '*must be lower*' }
    Assert-True $rejected 'invalid threshold order must be rejected'

    # Only loopback is contacted. DNS is a fixture, not an external lookup.
    $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([Net.IPAddress]::Loopback), 0
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $report = & $scriptUnderTest -PassThru -TcpHost 127.0.0.1 -TcpPort $port -DnsName fixture.invalid
    Assert-True (@($report.Checks | Where-Object { $_.Name -eq 'TCP' -and $_.Status -eq 'OK' }).Count -eq 1) 'TCP check must connect to a real local listener'
    $listener.Stop()
    $listener = $null
    $report = & $scriptUnderTest -PassThru -TcpHost 127.0.0.1 -TcpPort $port -DnsName fixture.invalid
    Assert-True (@($report.Checks | Where-Object { $_.Name -eq 'TCP' -and $_.Status -eq 'Warning' }).Count -eq 1) 'closed TCP endpoint must warn'
    Write-Host 'PASS: boundaries, isolation, JSON, overwrite protection, parameter validation, and loopback TCP checks.'
} finally {
    if ($null -ne $listener) { $listener.Stop() }
    if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $reportPath) {
        Remove-Item -LiteralPath $reportPath -Force
    }
}
