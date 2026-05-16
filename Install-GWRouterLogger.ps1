param(
    [string] $InstallPath,
    [switch] $DoNotStartAfterInstall,
    [switch] $ForceReinstall,
    [switch] $InstallTrayMode,
    [switch] $SkipTrayPrompt
)

# Installs GW Router Logger as a normal Windows application entry.
# Administrator installs use Program Files and HKLM. Non-admin installs use
# LocalAppData and HKCU so the app still appears in Apps and Features.

$ErrorActionPreference = 'Stop'
$appName = 'GW Router Logger'
$version = '1.3.0'
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

function Get-ExistingInstallInfo {
    param([string] $RequestedInstallPath)

    $registryNames = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GWRouterLogger',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GWRouterLogger'
    )

    $requestedFullPath = ''
    if (-not [string]::IsNullOrWhiteSpace($RequestedInstallPath)) {
        $requestedFullPath = [IO.Path]::GetFullPath($RequestedInstallPath).TrimEnd('\')
    }

    foreach ($registryName in $registryNames) {
        if (-not (Test-Path -LiteralPath $registryName)) {
            continue
        }

        try {
            $installLocation = Get-ItemPropertyValue -Path $registryName -Name InstallLocation -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($installLocation)) {
                return @{
                    RegistryPath = $registryName
                    InstallLocation = [IO.Path]::GetFullPath($installLocation).TrimEnd('\')
                    Source = 'registry'
                }
            }
        }
        catch {}
    }

    if (-not [string]::IsNullOrWhiteSpace($requestedFullPath) -and (Test-Path -LiteralPath $requestedFullPath)) {
        return @{
            RegistryPath = ''
            InstallLocation = $requestedFullPath
            Source = 'folder'
        }
    }

    return $null
}

function Remove-ExistingInstall {
    param([hashtable] $InstallInfo)

    $existingInstallPath = $InstallInfo.InstallLocation
    $uninstallScript = Join-Path -Path $existingInstallPath -ChildPath 'Uninstall-GWRouterLogger.ps1'
    if (Test-Path -LiteralPath $uninstallScript) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstallScript -Quiet
        return
    }

    throw "Existing installation found at $existingInstallPath but the uninstaller script is missing."
}

function New-AppShortcut {
    param(
        [string] $ShortcutPath,
        [string] $TargetScript,
        [string] $IconPath,
        [switch] $TrayApp,
        [switch] $StartListener
    )

    if ($TrayApp) {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "{0}" -TrayApp' -f $TargetScript
        if ($StartListener) {
            $arguments += ' -StartListener'
        }
        $description = 'Run GW Router Logger in the notification area'
    }
    else {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $TargetScript
        $description = 'Run GW Router Logger in the console'
    }

    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = Split-Path -Parent $TargetScript
    $shortcut.Description = $description
    if (-not [string]::IsNullOrWhiteSpace($IconPath) -and (Test-Path -LiteralPath $IconPath)) {
        $shortcut.IconLocation = $IconPath
    }
    $shortcut.Save()
}

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$isAdmin = Test-IsAdministrator
$installTrayModeSelected = $InstallTrayMode

if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    if ($isAdmin) {
        $InstallPath = Join-Path -Path $env:ProgramFiles -ChildPath 'GW Router Logger'
    }
    else {
        $InstallPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'GW Router Logger'
    }
}

if (-not [string]::IsNullOrWhiteSpace($InstallPath)) {
    $InstallPath = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
}

$existingInstall = Get-ExistingInstallInfo -RequestedInstallPath $InstallPath
if ($existingInstall) {
    if (-not $ForceReinstall) {
        $prompt = 'An installation is already present at {0}. Reinstall now? [y/N]' -f $existingInstall.InstallLocation
        $choice = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice.Trim().ToUpperInvariant() -ne 'Y') {
            Write-Host 'Installation cancelled.'
            exit 0
        }
    }

    Remove-ExistingInstall -InstallInfo $existingInstall
}

if (-not $SkipTrayPrompt -and -not $PSBoundParameters.ContainsKey('InstallTrayMode')) {
    Write-Host 'Optional tray mode keeps GW Router Logger in the Windows notification area.'
    Write-Host 'It gives you the right-click GUI, background listener controls, and startup behavior without leaving a console window open.'
    $trayChoice = Read-Host 'Install the optional tray mode too? [Y/n]'
    if ([string]::IsNullOrWhiteSpace($trayChoice) -or $trayChoice.Trim().ToUpperInvariant() -eq 'Y') {
        $installTrayModeSelected = $true
    }
    else {
        $installTrayModeSelected = $false
    }
}

$installRoot = Ensure-Directory -Path $InstallPath
$files = @(
    'GW-Router-Logger.TrayMode.psm1',
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

$sourceAssets = Join-Path -Path $sourceRoot -ChildPath 'assets'
if (Test-Path -LiteralPath $sourceAssets) {
    Copy-Item -LiteralPath $sourceAssets -Destination (Join-Path -Path $installRoot -ChildPath 'assets') -Recurse -Force
}

$programs = [Environment]::GetFolderPath('Programs')
$shortcutFolder = Ensure-Directory -Path (Join-Path -Path $programs -ChildPath 'GW Router Logger')
$desktopPath = [Environment]::GetFolderPath('Desktop')
$launcherScript = Join-Path -Path $installRoot -ChildPath 'GW-Router-Logger.ps1'
$iconPath = Join-Path -Path (Join-Path -Path $installRoot -ChildPath 'assets') -ChildPath 'gw-router-logger.ico'

if ($installTrayModeSelected) {
    New-AppShortcut -ShortcutPath (Join-Path -Path $shortcutFolder -ChildPath 'GW Router Logger.lnk') -TargetScript $launcherScript -IconPath $iconPath -TrayApp
    New-AppShortcut -ShortcutPath (Join-Path -Path $shortcutFolder -ChildPath 'GW Router Logger - Start Listener.lnk') -TargetScript $launcherScript -IconPath $iconPath -TrayApp -StartListener
    New-AppShortcut -ShortcutPath (Join-Path -Path $desktopPath -ChildPath 'GW Router Logger.lnk') -TargetScript $launcherScript -IconPath $iconPath -TrayApp
}
else {
    $trayShortcut = Join-Path -Path $shortcutFolder -ChildPath 'GW Router Logger - Start Listener.lnk'
    if (Test-Path -LiteralPath $trayShortcut) {
        Remove-Item -LiteralPath $trayShortcut -Force -ErrorAction SilentlyContinue
    }
    New-AppShortcut -ShortcutPath (Join-Path -Path $shortcutFolder -ChildPath 'GW Router Logger.lnk') -TargetScript $launcherScript -IconPath $iconPath
    New-AppShortcut -ShortcutPath (Join-Path -Path $desktopPath -ChildPath 'GW Router Logger.lnk') -TargetScript $launcherScript -IconPath $iconPath
}

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
New-ItemProperty -Path $uninstallRoot -Name DisplayIcon -Value $iconPath -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name UninstallString -Value $uninstallCommand -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name QuietUninstallString -Value ($uninstallCommand + ' -Quiet') -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name EstimatedSize -Value $estimatedSize -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallRoot -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null

Write-Host ("Installed {0} v{1} to {2}" -f $appName, $version, $installRoot)
Write-Host 'The app is now registered in Apps and Features.'
if ($installTrayModeSelected) {
    Write-Host 'Created tray shortcuts in Start Menu and on Desktop.'
}
else {
    Write-Host 'Created console shortcuts in Start Menu and on Desktop.'
}

if ($installTrayModeSelected -and -not $DoNotStartAfterInstall) {
    Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-Sta',
        '-File', ('"{0}"' -f $launcherScript),
        '-TrayApp'
    ) -WindowStyle Hidden
}
