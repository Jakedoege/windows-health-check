# Validation

Validated on November 6, 2026.

## Checks performed

- Parsed both PowerShell files with the Windows PowerShell 5.1 parser: no syntax errors.
- Executed the main script with PowerShell 7 on a Windows machine, with network probes disabled: memory, uptime, disk, service, registry, and System-event queries completed; JSON export and structured output worked.
- The project owner ran the main script in Windows PowerShell 5.1 and shared the completed report: all checks completed, including external DNS and TCP probes. This confirms one real-machine run, not broad platform coverage.
- Executed inside a restricted sandbox: blocked CIM/event-log queries appeared as Unknown, while independent checks continued.
- Ran `tests/Smoke.Tests.ps1` with PowerShell 7 outside the sandbox: passed deterministic disk/memory boundary cases, unavailable-subsystem handling, JSON round trip, overwrite protection, threshold validation, pending-reboot detection, event counts, and TCP success/failure against a temporary local listener.

The fixture tests replace Windows data-query commands in their own process/session scope. They do not change the host's services, registry, or event logs. Their network test contacts loopback only; DNS responses are fixtures.

## Not yet verified

- The fixture suite under Windows PowerShell 5.1; only syntax parsing and the owner's main-script run were verified there.
- Windows Server releases, including Server 2025, and other Windows client versions.
- Every combination of enterprise permissions, storage layouts, or networking policies.

## Run the fixture tests

From the repository directory in an authorized Windows PowerShell environment:

```powershell
.\tests\Smoke.Tests.ps1
```

Expect a final `PASS` line. The test suite prints several intentionally unhealthy reports before that line. It creates a uniquely named temporary JSON file and removes it afterward. Local firewall policy may prevent the loopback TCP test; investigate that failure rather than disabling protections.
