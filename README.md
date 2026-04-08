# GW Router Logger

Menu-driven PowerShell syslog collector for residential or small-network router logging on Windows.

## Features

- Runs in a normal PowerShell window with a guided menu flow
- Verifies administrator rights and attempts self-elevation
- Suggests the local IPv4 address on the adapter using the default gateway
- Defaults to residential-friendly router logging (`UDP 514`)
- Shows live listener status, recent events, and last received source details
- Writes logs into `GW-ROUTER-LOGS` beside the script by default
- Stores per-source logs and server/runtime logs separately
- Rotates active logs by size or age, compresses archives, and enforces a 100 MB compressed cap
- Uses built-in validation and fallbacks for pathing, firewall handling, and other Windows environment differences

## Files

- `GW-Router-Logger.ps1`: main script
- `GW-ROUTER-LOGS/`: runtime log output folder created by the script

## Requirements

- Windows PowerShell 5.1 or later recommended
- Administrator rights
- Windows machine reachable by the router or device sending syslog

## Usage

1. Open PowerShell as Administrator.
2. Run:

```powershell
.\GW-Router-Logger.ps1
```

3. Use the menu to:
   - start the log listener
   - change defaults
   - open the default log folder

## Default Behavior

- Suggests the primary LAN address tied to the active default gateway
- Uses `UDP 514` and `TCP disabled` when you accept router defaults
- Saves logs to:

```text
<script folder>\GW-ROUTER-LOGS
```

## Notes

- `Q` stops the listener cleanly from inside the script.
- `Ctrl+C` cancels the running script from PowerShell.
- If no logs arrive after the wait period, the script offers basic troubleshooting guidance.

## GitHub

This repository is ready to be published as a standalone GitHub project once local GitHub authentication is valid.
