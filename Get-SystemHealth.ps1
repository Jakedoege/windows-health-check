#Requires -Version 5.1
<#
.SYNOPSIS
    Reports Windows health without changing system settings.
.DESCRIPTION
    Checks disk space, memory, uptime, reboot indicators, services, critical
    events, DNS, and TCP connectivity. Network probes can be disabled.
    Optional JSON output contains structured results, not event messages.
.EXAMPLE
    .\Get-SystemHealth.ps1
.EXAMPLE
    .\Get-SystemHealth.ps1 -SkipNetwork -JsonPath .\health.json
.EXAMPLE
    .\Get-SystemHealth.ps1 -DnsName example.com -TcpHost example.com -TcpPort 443
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 99)][int]$DiskWarningPercent = 20,
    [ValidateRange(1, 99)][int]$DiskCriticalPercent = 10,
    [ValidateRange(1, 99)][int]$MemoryWarningPercent = 85,
    [ValidateRange(1, 99)][int]$MemoryCriticalPercent = 95,
    [ValidateRange(1, 3650)][int]$UptimeWarningDays = 30,
    [ValidateRange(1, 720)][int]$EventHours = 24,
    [ValidateNotNullOrEmpty()][string[]]$ServiceName = @('EventLog', 'Winmgmt', 'LanmanWorkstation'),
    [ValidateNotNullOrEmpty()][string]$DnsName = 'www.microsoft.com',
    [ValidateNotNullOrEmpty()][string]$TcpHost = 'www.microsoft.com',
    [ValidateRange(1, 65535)][int]$TcpPort = 443,
    [ValidateRange(100, 60000)][int]$TcpTimeoutMs = 3000,
    [switch]$SkipNetwork,
    [string]$JsonPath,
    [switch]$Force,
    [switch]$PassThru,
    [switch]$FailOnCritical
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows.' }
if ($DiskCriticalPercent -ge $DiskWarningPercent) {
    throw 'DiskCriticalPercent must be lower than DiskWarningPercent.'
}
if ($MemoryWarningPercent -ge $MemoryCriticalPercent) {
    throw 'MemoryWarningPercent must be lower than MemoryCriticalPercent.'
}

$checks = New-Object 'System.Collections.Generic.List[object]'
function Add-HealthCheck {
    param(
        [string]$Category, [string]$Name,
        [ValidateSet('OK', 'Warning', 'Critical', 'Unknown', 'Skipped')][string]$Status,
        [string]$Detail, [object]$Data = $null
    )
    $checks.Add([pscustomobject][ordered]@{
        Category = $Category; Name = $Name; Status = $Status
        Detail = $Detail; Data = $Data
    })
}

# CIM is queried once for memory and boot time; one failed query does not hide
# independent disk, service, event, registry, or network results.
try {
    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $totalKb = [double]$osInfo.TotalVisibleMemorySize
    $freeKb = [double]$osInfo.FreePhysicalMemory
    if ($totalKb -le 0 -or $freeKb -lt 0 -or $freeKb -gt $totalKb) {
        throw 'Windows returned invalid physical-memory measurements.'
    }
    $usedPercent = 100 * (1 - $freeKb / $totalKb)
    $status = 'OK'
    if ($usedPercent -ge $MemoryCriticalPercent) { $status = 'Critical' }
    elseif ($usedPercent -ge $MemoryWarningPercent) { $status = 'Warning' }
    Add-HealthCheck Memory 'Physical memory' $status ('{0:N1}% in use' -f $usedPercent) ([ordered]@{
        UsedPercent = [math]::Round($usedPercent, 2)
        TotalGiB = [math]::Round($totalKb / 1MB, 2)
        FreeGiB = [math]::Round($freeKb / 1MB, 2)
    })
} catch {
    Add-HealthCheck Memory 'Physical memory' Unknown ('Unable to read memory: ' + $_.Exception.Message)
}
try {
    if (-not (Get-Variable osInfo -ErrorAction SilentlyContinue)) {
        throw 'Operating-system information is unavailable.'
    }
    $bootTime = [datetime]$osInfo.LastBootUpTime
    $uptime = (Get-Date) - $bootTime
    if ($uptime.TotalSeconds -lt 0) { throw 'Boot time is in the future.' }
    $status = 'OK'
    if ($uptime.TotalDays -ge $UptimeWarningDays) { $status = 'Warning' }
    Add-HealthCheck System Uptime $status ('{0:N1} days since boot' -f $uptime.TotalDays) ([ordered]@{
        Days = [math]::Round($uptime.TotalDays, 2); LastBootUtc = $bootTime.ToUniversalTime().ToString('o')
    })
} catch {
    Add-HealthCheck System Uptime Unknown ('Unable to read uptime: ' + $_.Exception.Message)
}

try {
    $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)
    if ($disks.Count -eq 0) { throw 'No fixed logical disks were returned.' }
    foreach ($disk in $disks) {
        $size = [double]$disk.Size
        $free = [double]$disk.FreeSpace
        if ($size -le 0 -or $null -eq $disk.FreeSpace -or $free -lt 0 -or $free -gt $size) {
            Add-HealthCheck Disk ([string]$disk.DeviceID) Unknown 'Disk size or free-space measurement is unavailable.'
            continue
        }
        $freePercent = 100 * $free / $size
        $status = 'OK'
        if ($freePercent -le $DiskCriticalPercent) { $status = 'Critical' }
        elseif ($freePercent -le $DiskWarningPercent) { $status = 'Warning' }
        Add-HealthCheck Disk ([string]$disk.DeviceID) $status ('{0:N1}% free ({1:N1} GiB)' -f $freePercent, ($free / 1GB)) ([ordered]@{
            FreePercent = [math]::Round($freePercent, 2)
            FreeGiB = [math]::Round($free / 1GB, 2); SizeGiB = [math]::Round($size / 1GB, 2)
        })
    }
} catch {
    Add-HealthCheck Disk 'Fixed disks' Unknown ('Unable to query disks: ' + $_.Exception.Message)
}

foreach ($name in $ServiceName) {
    try {
        $service = Get-Service -Name $name -ErrorAction Stop
        $status = 'OK'
        if ($service.Status -ne 'Running') { $status = 'Warning' }
        Add-HealthCheck Services $name $status ([string]$service.Status)
    } catch {
        Add-HealthCheck Services $name Unknown ('Unable to query service: ' + $_.Exception.Message)
    }
}

# These are common reboot indicators, not an exhaustive Windows servicing API.
try {
    $indicators = New-Object 'System.Collections.Generic.List[string]'
    $registryKeys = [ordered]@{
        'Component servicing' = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'Windows Update' = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    }
    foreach ($entry in $registryKeys.GetEnumerator()) {
        if (Test-Path -LiteralPath $entry.Value -ErrorAction Stop) { $indicators.Add($entry.Key) }
    }
    $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
    $renameProperty = $sessionManager.PSObject.Properties['PendingFileRenameOperations']
    if ($null -ne $renameProperty -and @($renameProperty.Value | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        $indicators.Add('Pending file rename operations')
    }
    if ($indicators.Count -gt 0) {
        Add-HealthCheck System 'Reboot indicators' Warning ($indicators -join '; ') @($indicators.ToArray())
    } else {
        Add-HealthCheck System 'Reboot indicators' OK 'No common reboot indicators found; this is not an exhaustive check.'
    }
} catch {
    Add-HealthCheck System 'Reboot indicators' Unknown ('Unable to complete registry checks: ' + $_.Exception.Message)
}

try {
    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'; Level = 1; StartTime = (Get-Date).AddHours(-$EventHours)
        } -ErrorAction Stop)
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
    }
    $status = 'OK'
    if ($events.Count -gt 0) { $status = 'Warning' }
    Add-HealthCheck Events 'Critical System events' $status ('{0} critical event(s) in the last {1} hours; historical events do not prove a current outage.' -f $events.Count, $EventHours) ([ordered]@{
        Count = $events.Count; LookbackHours = $EventHours
    })
} catch {
    Add-HealthCheck Events 'Critical System events' Unknown ('Unable to query System log: ' + $_.Exception.Message)
}

if ($SkipNetwork) {
    Add-HealthCheck Network DNS Skipped 'Network probes disabled.'
    Add-HealthCheck Network TCP Skipped 'Network probes disabled.'
} else {
    try {
        $answers = @(Resolve-DnsName -Name $DnsName -DnsOnly -ErrorAction Stop |
            Where-Object { $_.Type -in @('A', 'AAAA') })
        if ($answers.Count -eq 0) { throw 'No A or AAAA records returned.' }
        Add-HealthCheck Network DNS OK ('{0}: {1} address record(s)' -f $DnsName, $answers.Count)
    } catch {
        Add-HealthCheck Network DNS Warning ('DNS probe failed for {0}: {1}' -f $DnsName, $_.Exception.Message)
    }
    $client = New-Object System.Net.Sockets.TcpClient
    $waitHandle = $null
    try {
        $connection = $client.BeginConnect($TcpHost, $TcpPort, $null, $null)
        $waitHandle = $connection.AsyncWaitHandle
        if (-not $waitHandle.WaitOne($TcpTimeoutMs, $false)) { throw 'Connection attempt timed out.' }
        $client.EndConnect($connection)
        Add-HealthCheck Network TCP OK ('Connected to {0}:{1}' -f $TcpHost, $TcpPort)
    } catch {
        Add-HealthCheck Network TCP Warning ('TCP probe failed for {0}:{1}: {2}' -f $TcpHost, $TcpPort, $_.Exception.Message)
    } finally {
        $client.Close()
        if ($null -ne $waitHandle) { $waitHandle.Close() }
    }
}

$counts = [ordered]@{}
foreach ($level in @('OK', 'Warning', 'Critical', 'Unknown', 'Skipped')) {
    $counts[$level] = @($checks | Where-Object { $_.Status -eq $level }).Count
}
$overall = 'OK'
if ($counts.Unknown -gt 0) { $overall = 'Unknown' }
if ($counts.Warning -gt 0) { $overall = 'Warning' }
if ($counts.Critical -gt 0) { $overall = 'Critical' }
$report = [pscustomobject][ordered]@{
    SchemaVersion = '1.0'; GeneratedAtUtc = [datetime]::UtcNow.ToString('o')
    OverallStatus = $overall; Counts = [pscustomobject]$counts
    Checks = $checks.ToArray()
}

Write-Host ''
Write-Host ('Windows Health Check | {0}' -f $overall)
Write-Host ('OK: {0}  Warning: {1}  Critical: {2}  Unknown: {3}  Skipped: {4}' -f $counts.OK, $counts.Warning, $counts.Critical, $counts.Unknown, $counts.Skipped)
foreach ($check in $checks) {
    Write-Host ('[{0}] {1} / {2}: {3}' -f $check.Status.ToUpperInvariant(), $check.Category, $check.Name, $check.Detail)
}

if ($JsonPath) {
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JsonPath)
    $parentPath = Split-Path -Parent $resolvedPath
    if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) { throw 'The JSON output directory must already exist.' }
    if ((Test-Path -LiteralPath $resolvedPath) -and -not $Force) { throw 'JSON output already exists. Choose another path or use -Force.' }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedPath -Encoding UTF8
    Write-Host ('JSON saved to {0}' -f $resolvedPath)
}
if ($PassThru) { Write-Output $report }
if ($FailOnCritical) {
    if ($counts.Critical -gt 0) { exit 2 }
    if ($counts.Warning -gt 0 -or $counts.Unknown -gt 0) { exit 1 }
    exit 0
}
