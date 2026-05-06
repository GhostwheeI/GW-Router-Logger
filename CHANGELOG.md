# Changelog

## v1.1.0 - 2026-05-06

Tray application release.

### Added

- Notification-area GUI app in `GW-Router-Logger.Tray.ps1`.
- Right-click tray menu with app/version header, dynamic status, configuration, start/stop, latest-log opening, log-folder opening, settings, about, and exit.
- Listener configuration UI for bind IP, UDP/TCP ports, hostname lookup, and log folder.
- Settings UI for Windows startup, diagnostic logging, theme selection, firewall exception setup, network ports, and read-only log size handling defaults.
- Background diagnostic app log with size-controlled rotation.
- JSON configuration file for advanced settings not exposed directly in the tray UI.
- Log-folder move handling when the configured log directory changes.
- Installer and uninstaller scripts that register the app in Windows Apps and Features.

### Changed

- Project version is now `1.1.0`.
- The CLI script remains available and keeps the existing menu-driven workflow.

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
