# Windows Health Check

A small PowerShell tool for a quick look at a Windows machine's health. It reports findings without repairing anything or changing system settings.

## What it checks

- Free space on fixed logical disks
- Physical memory usage and uptime
- Common pending-restart registry indicators
- Configurable Windows services
- Critical events in the System log over a configurable time window
- DNS resolution and a TCP connection to a configurable destination

Readable terminal output is included. JSON export and a structured PowerShell object are optional. A failed or inaccessible check is reported explicitly instead of being treated as healthy.

See [sample output](examples/sample-output.txt) for an illustrative report.

## Requirements

- Windows with Windows PowerShell 5.1 or PowerShell 7
- Windows CIM, registry, and event-log access
- No third-party modules

Start in a normal PowerShell session. Some machines restrict CIM, registry, or event-log access; those checks will show `Unknown`. Only use an elevated session when authorized and needed.

## Quick start

Download the repository, review the script, and open PowerShell in its folder:

```powershell
.\Get-SystemHealth.ps1
```

The default network checks resolve `www.microsoft.com` and attempt a TCP connection to port 443. Use your own approved destination or disable probes:

```powershell
.\Get-SystemHealth.ps1 -SkipNetwork
.\Get-SystemHealth.ps1 -DnsName example.com -TcpHost example.com -TcpPort 443
```

### If PowerShell says scripts are disabled

On a personal computer, after reviewing the script, you can allow local scripts
for the current PowerShell session and unblock this downloaded file:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
Unblock-File -LiteralPath .\Get-SystemHealth.ps1
.\Get-SystemHealth.ps1
```

The Process policy change ends when that PowerShell process closes; unblocking
removes the downloaded-file marker from this specific file. Neither step
overrides organization-enforced Group Policy. On a managed machine, follow
your organization's approved process. You do not need to set an unrestricted
or permanent machine-wide policy to use this tool.

## Examples

```powershell
# Save structured output. The destination directory must already exist.
.\Get-SystemHealth.ps1 -JsonPath .\health.json

# Explicitly replace a previous JSON report.
.\Get-SystemHealth.ps1 -JsonPath .\health.json -Force

# Check services relevant to your machine instead of the defaults.
.\Get-SystemHealth.ps1 -ServiceName EventLog, Winmgmt

# Customize thresholds and the event lookback window.
.\Get-SystemHealth.ps1 -DiskWarningPercent 25 -DiskCriticalPercent 10 -EventHours 48

# Return an object for further filtering; console output is on the host stream.
$report = .\Get-SystemHealth.ps1 -SkipNetwork -PassThru
$report.Checks | Where-Object Status -eq Warning

# Optional exit codes for a scheduler or monitoring wrapper.
powershell.exe -NoProfile -File .\Get-SystemHealth.ps1 -SkipNetwork -FailOnCritical
```

## Status meanings

| Status | Meaning |
| --- | --- |
| OK | The check completed and found no configured warning condition. |
| Warning | A threshold or condition needs review; it is not a diagnosis. |
| Critical | A disk or memory critical threshold was reached. |
| Unknown | A check could not be completed or returned invalid data. |
| Skipped | A check was intentionally disabled. |

Overall status prioritizes Critical, Warning, Unknown, then OK. Always inspect the counts: a Warning summary can also contain Unknown checks.

With `-FailOnCritical`, exit code **2** means a critical threshold, **1** means warning or unknown checks, and **0** means neither. Without that switch, health findings do not explicitly terminate the calling PowerShell session. Parameter, platform, and JSON-write errors are terminating errors.

## Defaults

| Setting | Default |
| --- | --- |
| Disk warning / critical | At or below 20% / 10% free |
| Memory warning / critical | At or above 85% / 95% used |
| Uptime warning | 30 days |
| System event lookback | 24 hours; Critical level only |
| Services | EventLog, Winmgmt, LanmanWorkstation |
| TCP connection timeout | 3,000 ms |

The TCP timeout bounds the connection wait; DNS resolution and other operating-system queries can take longer. Memory and disk comparisons use unrounded measurements; display values are rounded.

## Limits and privacy

This is a point-in-time diagnostic aid, not a full monitoring system. High uptime, stopped services, historical critical events, and pending file renames can be expected in some environments. A failed network probe may reflect destination policy, a proxy, or a firewall rather than a general outage. A successful TCP connection does not validate TLS or application health.

Disk checks cover mounted fixed logical disks reported by Win32_LogicalDisk, not every storage pool, mount-point volume, or RAID controller. Reboot indicators are common heuristics, not an exhaustive servicing check. The tool does not test backup restoreability, patch compliance, antivirus health, or radio equipment.

The script sends no telemetry. Network probes contact only the configured DNS/TCP destinations through the machine's configured networking. JSON files are local and include disk identifiers, boot time, selected services, targets, and diagnostic errors; review them before sharing. Event messages, usernames, and computer names are not deliberately collected, but operating-system error messages can contain environment details.

## Project status

Initial version. Written with AI assistance and reviewed through local validation; it has not been tested across all Windows versions, hardware, and enterprise policies. See [VALIDATION.md](VALIDATION.md) for the actual checks performed. Contributions and reproducible bug reports are welcome; remove private details from examples.

## License

MIT. See [LICENSE](LICENSE).
