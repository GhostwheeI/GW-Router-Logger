# Changelog

## v1.0.0 - 2026-04-27

Initial public release.

### Added

- Menu-driven PowerShell syslog listener for Windows.
- Residential router defaults using UDP 514.
- Automatic local IP suggestion from the active default gateway adapter.
- Live console dashboard with message counts, last sender, last protocol, and recent activity.
- Per-source logs and server/runtime logs.
- Rolling log compression with size and age rotation.
- Compressed archive retention cap.
- Firewall rule creation with `Get-NetFirewallRule` and `netsh` fallback.
- Script-root default log directory: `GW-ROUTER-LOGS`.
- Change Defaults menu for common runtime assumptions.

### Reliability

- Bounded and cached reverse DNS lookups to avoid stalling log receive loops.
- Hostname lookup disabled by default for safer residential behavior.
- TCP client idle cleanup for long-running sessions.
- Archive pruning runs at startup and after actual rotations instead of every write.
- Age-based rotation uses file creation time so append writes do not reset the rotation window.
