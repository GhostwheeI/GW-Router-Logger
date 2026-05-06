# GW Router Logger

`GW Router Logger` is a PowerShell syslog collector for Windows, designed for home labs, residential routers, and small-network troubleshooting.

Current release: `v1.1.1`

It focuses on the things that usually break first on normal Windows machines: elevation, pathing, firewall access, bind-address selection, log rollover, and clear on-screen status.

## Why this exists

A lot of router logging tools assume too much:

- that the right IP is obvious
- that the log folder is writable
- that Windows Firewall is already configured
- that the user knows whether to use UDP or TCP
- that the machine is set up like a clean lab environment

This script does the opposite. It guides setup, validates inputs, uses practical defaults, and stays usable from a regular PowerShell window.

## Highlights

- Menu-driven workflow instead of parameter-heavy startup
- Notification-area GUI app with right-click controls
- Apps and Features uninstall registration through the installer
- Administrator check with self-elevation attempt
- Residential-friendly defaults: `UDP 514`, `TCP disabled`
- Automatic suggestion of the local IPv4 address tied to the active default gateway
- Live status dashboard with message counts, sender tracking, and recent events
- Per-source log files plus a server/runtime log
- Rolling archive management with compression and a compressed retention cap
- Cached, bounded hostname lookup so slow reverse DNS does not stall the listener
- Stale TCP client cleanup for long-running sessions
- Path validation and fallback handling for less predictable Windows environments
- Built to stay readable and maintainable for later troubleshooting or feature additions

## Requirements

- Windows PowerShell 5.1 or later
- Administrator rights
- A router, firewall, switch, or other device capable of sending syslog to this machine

## Quick Start

### Tray app

1. Run PowerShell.
2. Change into the script folder.
3. Install the app:

```powershell
.\Install-GWRouterLogger.ps1
```

4. Open **GW Router Logger** from the Start Menu.
5. Right-click the tray icon and choose **Configure**.

The tray menu shows the app name and version, live status, listener controls, log shortcuts, settings, about, and exit. The listener can be started or stopped from the right-click menu.

The installer registers the app in Windows **Apps and Features**. Uninstalling from Windows runs `Uninstall-GWRouterLogger.ps1` and removes the app files and shortcuts. Logs and configuration are preserved unless the uninstaller is run manually with `-RemoveData`.

### CLI script

1. Open PowerShell as Administrator.
2. Change into the script folder.
3. Run:

```powershell
.\GW-Router-Logger.ps1
```

4. In most residential setups:
   - accept the suggested local IP
   - accept the common router defaults
   - accept the default log path

## Default behavior

By default, the script:

- suggests the local address on the adapter currently using the default gateway
- assumes the most common router syslog setup: `UDP 514`
- leaves hostname lookup disabled by default for reliability
- stores logs beside the script in:

```text
GW-ROUTER-LOGS
```

- writes:
  - per-source logs under `sources`
  - server/runtime logs under `server`
- rotates active logs by size or age
- compresses rotated logs
- prunes old compressed archives until retained compressed logs are at or below the configured cap

The tray app stores its configuration in:

```text
C:\ProgramData\GW-Router-Logger\config.json
```

If `C:\ProgramData` is not writable, it falls back to the current user's local app data folder.

Advanced defaults that are not exposed in the tray UI can be edited in that JSON config file. The size handling defaults are visible in Settings but intentionally disabled for editing until a later version.

## Log layout

```text
GW-ROUTER-LOGS\
  sources\
  server\
```

## Runtime controls

Tray app controls are primarily in the right-click menu:

- `Configure` sets listener IP, UDP/TCP ports, hostname lookup, and log folder
- `Start` and `Stop` control the listener
- `Open Latest Log` opens the newest `.log` file in Notepad
- `Open Log Folder` opens the configured log folder
- `Settings` controls Windows startup, diagnostic logging, theme, firewall exception setup, network ports, and log folder

While the listener is running:

- `Q` stops the listener cleanly
- `O` opens the log folder
- `Ctrl+C` cancels the script from PowerShell

## Project goals

- Work on normal Windows machines without extra modules
- Be understandable to someone reading the script later
- Prefer validation and fallback behavior over hidden assumptions
- Be useful as a practical router logging tool, not just a demo

## Notes

- The script is intentionally PowerShell-first and Windows-focused.
- The UI is designed to be readable during real use, not overloaded with animation while logs are arriving.
- Defaults can be adjusted from the built-in `Change defaults` menu.

## License

This project is released under the MIT License. See [LICENSE](LICENSE).
