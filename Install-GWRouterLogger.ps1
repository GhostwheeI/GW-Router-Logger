param(
    [string] $InstallPath,
    [switch] $StartAfterInstall
)

# Installs GW Router Logger as a normal Windows application entry.
# Administrator installs use Program Files and HKLM. Non-admin installs use
# LocalAppData and HKCU so the app still appears in Apps and Features.

$ErrorActionPreference = 'Stop'
$appName = 'GW Router Logger'
$version = '1.1.0'
$publisher = 'Ghostwheel'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Directory {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [void] (New-Item -Path $Path -ItemType Directory -Force)
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function New-AppShortcut {
    param(
        [string] $ShortcutPath,
        [string] $TargetScript,
        [switch] $StartListener
    )

    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "{0}"' -f $TargetScript
    if ($StartListener) {
        $arguments += ' -StartListener'
    }

    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = Split-Path -Parent $TargetScript
    $shortcut.Description = 'Run GW Router Logger in the notification area'
    $shortcut.Save()
}

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$isAdmin = Test-IsAdministrator

if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    if ($isAdmin) {
        $InstallPath = Join-Path -Path $env:ProgramFiles -ChildPath 'GW Router Logger'
    }
    else {
        $InstallPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'GW Router Logger'
    }
}

$installRoot = Ensure-Directory -Path $InstallPath
$files = @(
    'GW-Router-Logger.Tray.ps1',
    'GW-Router-Logger.ps1',
    'Uninstall-GWRouterLogger.ps1',
    'README.md',
    'CHANGELOG.md',
    'LICENSE'
)

foreach ($file in $files) {
    $source = Join-Path -Path $sourceRoot -ChildPath $file
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Required install file is missing: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path -Path $installRoot -ChildPath $file) -Force
}

$programs = [Environment]::GetFolderPath('Programs')
$shortcutFolder = Ensure-Directory -Path (Join-Path -Path $programs -ChildPath 'GW Router Logger')
$trayScript = Join-Path -Path $installRoot -ChildPath 'GW-Router-Logger.Tray.ps1'
New-AppShortcut -ShortcutPath (Join-Path -Path $shortcutFolder -ChildPath 'GW Router Logger.lnk') -TargetScript $trayScript
New-AppShortcut -ShortcutPath (Join-Path -Path $shortcutFolder -ChildPath 'GW Router Logger - Start Listener.lnk') -TargetScript $trayScript -StartListener

$uninstallScript = Join-Path -Path $installRoot -ChildPath 'Uninstall-GWRouterLogger.ps1'
$uninstallCommand = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe", $uninstallScript
$estimatedSize = [int] ((Get-ChildItem -LiteralPath $installRoot -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1KB)

if ($isAdmin) {
    $uninstallRoot = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GWRouterLogger'
}
else {
    $uninstallRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GWRouterLogger'
}

if (-not (Test-Path -LiteralPath $uninstallRoot)) {
    [void] (New-Item -Path $uninstallRoot -Force)
}

New-ItemProperty -Path $uninstallRoot -Name DisplayName -Value $appName -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name DisplayVersion -Value $version -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name Publisher -Value $publisher -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name InstallLocation -Value $installRoot -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name DisplayIcon -Value "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name UninstallString -Value $uninstallCommand -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name QuietUninstallString -Value ($uninstallCommand + ' -Quiet') -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name EstimatedSize -Value $estimatedSize -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null

Write-Host ("Installed {0} v{1} to {2}" -f $appName, $version, $installRoot)
Write-Host 'The app is now registered in Apps and Features.'

if ($StartAfterInstall) {
    Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-Sta',
        '-File', ('"{0}"' -f $trayScript)
    ) -WindowStyle Hidden
}
