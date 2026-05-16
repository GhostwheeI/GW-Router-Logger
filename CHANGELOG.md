# Changelog

## v1.3.4 - 2026-05-16

Windows startup listener fix.

### Changed

- `Start with Windows` now creates a startup shortcut that includes `-StartListener` when the app is already configured.
- Tray startup now re-syncs the startup shortcut from the saved config on launch, so existing installs repair older startup shortcuts automatically.

## v1.3.3 - 2026-05-16

Version source-of-truth release.

### Changed

- The app, tray module, and installer now read the version from a single tracked `VERSION` file instead of keeping separate hardcoded version strings.
- Apps and Features registration now uses that same shared version value.
- Install packages now include the `VERSION` file so installed copies report the expected current version after updating.

## v1.3.2 - 2026-05-16

Updater restart reliability release.

### Changed

- Successful in-app updates now explicitly restart tray mode after reinstall instead of relying on the installer restart as an indirect side effect.
- The update helper now suppresses the installer's auto-start and launches the updated tray app itself once the reinstall completes.

## v1.3.1 - 2026-05-16

Router log cleanup release.

### Changed

- Router traffic in the selected log folder now goes to one fixed log file: `router-current.log`.
- Legacy `sources` logs are merged into the single router log during layout migration.
- Legacy `server` logs are moved into the internal runtime diagnostics area under `C:\ProgramData\GW-Router-Logger\diagnostics\listener-runtime`.
- Tray self-test no longer recreates `sources` and `server` inside the chosen router log folder.

## v1.3.0 - 2026-05-16

Single-entrypoint tray integration release.

### Added

- Optional tray-mode install prompt in `Install-GWRouterLogger.ps1` with a short explanation of what the tray mode provides.
- Internal tray support module loaded through `GW-Router-Logger.ps1 -TrayApp` instead of a second user-facing script entry.

### Changed

- The main script is now the only launch target for installed shortcuts.
- Tray self-updates now reinstall tray mode without re-prompting during the handoff.
- Installer-created shortcuts now point either to console mode or tray mode depending on the selected install option.
- Uninstall cleanup now stops tray instances launched through `GW-Router-Logger.ps1 -TrayApp`.

## v1.2.1 - 2026-05-16

Startup and log-layout polish release.

### Changed

- Tray startup now pre-checks UDP/TCP port availability and shows a plain-language warning when the selected port is already in use.
- The chosen log folder is now dedicated to router-received logs instead of being split into `sources` and `server`.
- Legacy `sources` and `server` log folders are migrated automatically into the new layout.
- Internal runtime/server logs are now stored outside the selected router log folder.

## v1.2.0 - 2026-05-16

Updater and installer polish release.

### Added

- `Check for Updates ...` tray-menu action in its own section above Settings.
- GitHub release check against `GhostwheeI/GW-Router-Logger` with packaged zip asset detection.
- Helper-driven self-update handoff that closes the running tray app, downloads the approved release, and reinstalls it.
- Desktop launch shortcut created during install.

### Changed

- Installer now starts the tray app automatically after install by default.
- Installer now prompts for reinstall when an existing installation is detected, with `-ForceReinstall` available for scripted use.
- Uninstaller now removes the Desktop shortcut as part of cleanup.

## v1.1.1 - 2026-05-06

Icon polish release.

### Added

- Custom multi-size Windows icon for the tray app, Start Menu shortcuts, and Apps and Features entry.
- 256px PNG preview source for the app icon under `assets`.

### Changed

- Tray app now loads `assets\gw-router-logger.ico` instead of the generic Windows application icon.
- Installer now copies the icon assets and applies the icon to created shortcuts and uninstall metadata.

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
