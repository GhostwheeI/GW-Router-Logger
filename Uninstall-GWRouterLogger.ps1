param(
    [switch] $Quiet,
    [switch] $RemoveData
)

# Removes the installed GW Router Logger app entry and shortcuts. Runtime logs
# and configuration are preserved unless -RemoveData is explicitly supplied.

$ErrorActionPreference = 'Stop'
$appName = 'GW Router Logger'
$registryNames = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GWRouterLogger',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GWRouterLogger'
)

function Get-InstalledPath {
    foreach ($registryName in $registryNames) {
        try {
            if (Test-Path -LiteralPath $registryName) {
                $location = Get-ItemPropertyValue -Path $registryName -Name InstallLocation -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($location)) {
                    return $location
                }
            }
        }
        catch {}
    }

    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Test-SafeInstallPath {
    param([string] $Path)

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $allowedRoots = @(
        [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\'),
        [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
    )

    foreach ($root in $allowedRoots) {
        if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -and $full -like '*GW Router Logger*') {
            return $true
        }
    }

    return $false
}

function Stop-RunningTray {
    param([string] $InstallPath)

    $escaped = $InstallPath.Replace('\', '\\')
    $processes = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -match 'GW-Router-Logger\.Tray\.ps1' -and
            $_.CommandLine -match [regex]::Escape($InstallPath)
        }

    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

$installPath = Get-InstalledPath
Stop-RunningTray -InstallPath $installPath

$programs = [Environment]::GetFolderPath('Programs')
$shortcutFolder = Join-Path -Path $programs -ChildPath 'GW Router Logger'
if (Test-Path -LiteralPath $shortcutFolder) {
    Remove-Item -LiteralPath $shortcutFolder -Recurse -Force -ErrorAction SilentlyContinue
}

$startupShortcut = Join-Path -Path ([Environment]::GetFolderPath('Startup')) -ChildPath 'GW Router Logger.lnk'
if (Test-Path -LiteralPath $startupShortcut) {
    Remove-Item -LiteralPath $startupShortcut -Force -ErrorAction SilentlyContinue
}

foreach ($registryName in $registryNames) {
    if (Test-Path -LiteralPath $registryName) {
        Remove-Item -LiteralPath $registryName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ((Test-Path -LiteralPath $installPath) -and (Test-SafeInstallPath -Path $installPath)) {
    Remove-Item -LiteralPath $installPath -Recurse -Force -ErrorAction SilentlyContinue
}

if ($RemoveData) {
    $dataPath = Join-Path -Path $env:ProgramData -ChildPath 'GW-Router-Logger'
    if (Test-Path -LiteralPath $dataPath) {
        Remove-Item -LiteralPath $dataPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not $Quiet) {
    Write-Host "$appName has been uninstalled."
    if (-not $RemoveData) {
        Write-Host 'Configuration and logs were preserved. Run the uninstaller with -RemoveData to remove them.'
    }
}
