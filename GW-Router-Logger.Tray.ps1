param(
    [switch] $FirewallOnly,
    [switch] $SelfTest,
    [switch] $ListenerSelfTest,
    [switch] $UpdateCheckSelfTest,
    [switch] $StartListener,
    [int] $FirewallUdpPort = 514,
    [int] $FirewallTcpPort = 0
)

# GW Router Logger tray application.
# This file keeps the listener usable without a console window and leaves the
# original CLI script intact for users who prefer the menu-driven terminal flow.

$script:AppName = 'GW Router Logger'
$script:Version = '1.2.0'
$script:Publisher = 'Ghostwheel'
$script:GitHubOwner = 'GhostwheeI'
$script:GitHubRepo = 'GW-Router-Logger'
$script:DefaultUdpPort = 514
$script:DefaultTcpPort = 514
$script:DefaultTcpEnabled = $false
$script:ActiveLogRotateBytes = 5MB
$script:ActiveLogRotateMinutes = 60
$script:MaxCompressedBytes = 100MB
$script:RecentEventsMax = 12
$script:DnsLookupTimeoutMilliseconds = 250
$script:SourceNameCacheTtlMinutes = 30
$script:TcpClientIdleTimeoutMinutes = 15
$script:StatusLoggingWindowMinutes = 2
$script:AppLogMaxBytes = 1MB
$script:AppLogKeepCount = 3

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:NotifyIcon = $null
$script:ContextMenu = $null
$script:TitleItem = $null
$script:StatusItem = $null
$script:StartItem = $null
$script:StopItem = $null
$script:OpenLatestItem = $null
$script:OpenFolderItem = $null
$script:UiTimer = $null
$script:ListenerPowerShell = $null
$script:ListenerHandle = $null
$script:ListenerRunspace = $null
$script:Runtime = [hashtable]::Synchronized(@{
    Running = $false
    StopRequested = $false
    StartedAt = $null
    LastReceiveTime = $null
    LastSender = ''
    MessageCount = 0
    UdpCount = 0
    TcpCount = 0
    LastError = ''
    StatusText = 'Idle'
})

function Get-ScriptRootPath {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Get-AppDataRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $programDataPath = Join-Path -Path $env:ProgramData -ChildPath 'GW-Router-Logger'
        try {
            if (-not (Test-Path -LiteralPath $programDataPath)) {
                [void] (New-Item -Path $programDataPath -ItemType Directory -Force -ErrorAction Stop)
            }
            $testPath = Join-Path -Path $programDataPath -ChildPath '.write-test'
            Set-Content -LiteralPath $testPath -Value 'test' -Encoding ASCII -ErrorAction Stop
            Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
            return $programDataPath
        }
        catch {
            # Fall back to a per-user app data folder when ProgramData is not writable.
        }
    }
    return Join-Path -Path $env:LOCALAPPDATA -ChildPath 'GW-Router-Logger'
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        [void] (New-Item -Path $Path -ItemType Directory -Force)
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-ConfigPath {
    return Join-Path -Path (Ensure-Directory -Path (Get-AppDataRoot)) -ChildPath 'config.json'
}

function Get-AppLogRoot {
    return Ensure-Directory -Path (Join-Path -Path (Get-AppDataRoot) -ChildPath 'diagnostics')
}

function Get-AppLogPath {
    return Join-Path -Path (Get-AppLogRoot) -ChildPath 'app.log'
}

function Get-AppIconPath {
    return Join-Path -Path (Join-Path -Path (Get-ScriptRootPath) -ChildPath 'assets') -ChildPath 'gw-router-logger.ico'
}

function Get-AppIcon {
    $iconPath = Get-AppIconPath
    if (Test-Path -LiteralPath $iconPath) {
        try {
            return New-Object System.Drawing.Icon($iconPath)
        }
        catch {
            Write-AppLog -Message ('App icon load failed: {0}' -f $_.Exception.Message) -Diagnostic
        }
    }

    return [System.Drawing.SystemIcons]::Application
}

function Get-GitHubLatestReleaseApiUrl {
    return 'https://api.github.com/repos/{0}/{1}/releases/latest' -f $script:GitHubOwner, $script:GitHubRepo
}

function Get-NormalizedVersionString {
    param([string] $VersionText)

    if ([string]::IsNullOrWhiteSpace($VersionText)) {
        return '0.0.0'
    }

    return $VersionText.Trim().TrimStart('v', 'V')
}

function ConvertTo-VersionObject {
    param([string] $VersionText)

    $normalized = Get-NormalizedVersionString -VersionText $VersionText
    $parts = $normalized.Split('.')
    while ($parts.Count -lt 4) {
        $parts += '0'
    }
    return [version] ($parts -join '.')
}

function Test-IsProtectedInstallPath {
    param([string] $InstallPath)

    if ([string]::IsNullOrWhiteSpace($InstallPath)) {
        return $false
    }

    $fullPath = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
    $protectedRoots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($root in $protectedRoots) {
        $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\')
        if ($fullPath.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-LatestReleaseInfo {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    catch {}

    $headers = @{
        'User-Agent' = '{0}/{1}' -f $script:AppName, $script:Version
        'Accept' = 'application/vnd.github+json'
    }

    $release = Invoke-RestMethod -Uri (Get-GitHubLatestReleaseApiUrl) -Headers $headers -ErrorAction Stop
    $asset = $null
    foreach ($candidate in @($release.assets)) {
        if ($candidate.name -match '^GW-Router-Logger-v.*\.zip$') {
            $asset = $candidate
            break
        }
    }

    if (-not $asset) {
        throw 'The latest GitHub release did not include the packaged zip asset.'
    }

    $assetUrl = $asset.browser_download_url
    if ([string]::IsNullOrWhiteSpace($assetUrl)) {
        $assetUrl = $asset.url
    }

    return @{
        TagName = [string] $release.tag_name
        Name = [string] $release.name
        PublishedAt = [string] $release.published_at
        Version = Get-NormalizedVersionString -VersionText ([string] $release.tag_name)
        AssetName = [string] $asset.name
        AssetUrl = [string] $assetUrl
    }
}

function Start-UpdateInstallerProcess {
    param([hashtable] $ReleaseInfo)

    $installRoot = Get-ScriptRootPath
    $helperPath = Join-Path -Path $env:TEMP -ChildPath ('GWRouterLogger-Update-{0}.ps1' -f ([guid]::NewGuid().ToString('N')))
    $helperPathLiteral = $helperPath.Replace("'", "''")
    $helperContent = @'
param(
    [int] `$CurrentPid,
    [string] `$InstallRoot,
    [string] `$AssetUrl,
    [string] `$ExpectedVersion
)

`$ErrorActionPreference = 'Stop'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
catch {}

function Test-IsAdministrator {
    `$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    `$principal = New-Object Security.Principal.WindowsPrincipal(`$identity)
    return `$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsProtectedInstallPath {
    param([string] `$Path)
    if ([string]::IsNullOrWhiteSpace(`$Path)) {
        return `$false
    }
    `$fullPath = [IO.Path]::GetFullPath(`$Path).TrimEnd('\')
    `$roots = @(`$env:ProgramFiles, `${env:ProgramFiles(x86)}) | Where-Object { -not [string]::IsNullOrWhiteSpace(`$_) }
    foreach (`$root in `$roots) {
        `$rootFull = [IO.Path]::GetFullPath(`$root).TrimEnd('\')
        if (`$fullPath.StartsWith(`$rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return `$true
        }
    }
    return `$false
}

for (`$attempt = 0; `$attempt -lt 120; `$attempt++) {
    try {
        if (-not (Get-Process -Id `$CurrentPid -ErrorAction SilentlyContinue)) {
            break
        }
    }
    catch {}
    Start-Sleep -Milliseconds 500
}

`$tempRoot = Join-Path -Path `$env:TEMP -ChildPath ('GWRouterLogger-Update-' + [guid]::NewGuid().ToString('N'))
`$zipPath = Join-Path -Path `$tempRoot -ChildPath 'update.zip'
New-Item -Path `$tempRoot -ItemType Directory -Force | Out-Null

try {
    Invoke-WebRequest -Uri `$AssetUrl -OutFile `$zipPath -UseBasicParsing -ErrorAction Stop
    Expand-Archive -LiteralPath `$zipPath -DestinationPath `$tempRoot -Force
    `$installerPath = Join-Path -Path `$tempRoot -ChildPath 'Install-GWRouterLogger.ps1'
    if (-not (Test-Path -LiteralPath `$installerPath)) {
        throw 'The update package did not contain Install-GWRouterLogger.ps1.'
    }

    `$arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', `$installerPath,
        '-InstallPath', `$InstallRoot,
        '-ForceReinstall'
    )

    if ((Test-IsProtectedInstallPath -Path `$InstallRoot) -and -not (Test-IsAdministrator)) {
        `$process = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList `$arguments -Verb RunAs -Wait -PassThru
    }
    else {
        `$process = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList `$arguments -Wait -PassThru
    }

    if (`$process.ExitCode -ne 0) {
        throw ('Installer exited with code {0}.' -f `$process.ExitCode)
    }
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void] [System.Windows.Forms.MessageBox]::Show(
        ('Update to version {0} failed: {1}' -f `$ExpectedVersion, `$_.Exception.Message),
        'GW Router Logger',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
}
finally {
    if (Test-Path -LiteralPath `$tempRoot) {
        Remove-Item -LiteralPath `$tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath '__HELPER_PATH__') {
        Remove-Item -LiteralPath '__HELPER_PATH__' -Force -ErrorAction SilentlyContinue
    }
}
'@
    $helperContent = $helperContent.Replace('__HELPER_PATH__', $helperPathLiteral)

    Set-Content -LiteralPath $helperPath -Value $helperContent -Encoding UTF8
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', $helperPath,
        '-CurrentPid', [string] $PID,
        '-InstallRoot', $installRoot,
        '-AssetUrl', $ReleaseInfo.AssetUrl,
        '-ExpectedVersion', $ReleaseInfo.Version
    )
    Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function Rotate-AppLog {
    $path = Get-AppLogPath
    if (-not (Test-Path -LiteralPath $path)) {
        return
    }

    $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $item -or $item.Length -lt $script:AppLogMaxBytes) {
        return
    }

    for ($index = $script:AppLogKeepCount - 1; $index -ge 1; $index--) {
        $older = '{0}.{1}' -f $path, $index
        $newer = '{0}.{1}' -f $path, ($index + 1)
        if (Test-Path -LiteralPath $older) {
            Move-Item -LiteralPath $older -Destination $newer -Force -ErrorAction SilentlyContinue
        }
    }

    Move-Item -LiteralPath $path -Destination ($path + '.1') -Force -ErrorAction SilentlyContinue
}

function Write-AppLog {
    param(
        [string] $Message,
        [switch] $Diagnostic
    )

    try {
        $config = $script:CachedConfig
        if ($Diagnostic -and $config -and -not [bool] $config.DiagnosticLogging) {
            return
        }

        Rotate-AppLog
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
        Add-Content -LiteralPath (Get-AppLogPath) -Value $line -Encoding UTF8
    }
    catch {
        # Diagnostic logging must never break the tray app.
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DefaultLogRoot {
    $scriptDefault = Join-Path -Path (Get-ScriptRootPath) -ChildPath 'GW-ROUTER-LOGS'
    try {
        Ensure-Directory -Path $scriptDefault | Out-Null
        $testPath = Join-Path -Path $scriptDefault -ChildPath '.write-test'
        Set-Content -LiteralPath $testPath -Value 'test' -Encoding ASCII -ErrorAction Stop
        Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
        return $scriptDefault
    }
    catch {
        return Join-Path -Path (Get-AppDataRoot) -ChildPath 'GW-ROUTER-LOGS'
    }
}

function ConvertTo-PlainHashtable {
    param([object] $InputObject)

    $result = @{}
    if (-not $InputObject) {
        return $result
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }
    return $result
}

function Get-DefaultConfig {
    $bindAddress = Get-SuggestedBindAddress
    if ([string]::IsNullOrWhiteSpace($bindAddress)) {
        $bindAddress = '0.0.0.0'
    }

    return @{
        IsConfigured = $false
        BindAddress = $bindAddress
        UdpEnabled = $true
        UdpPort = $script:DefaultUdpPort
        TcpEnabled = $script:DefaultTcpEnabled
        TcpPort = $script:DefaultTcpPort
        ResolveHostNames = $false
        LogRoot = Get-DefaultLogRoot
        StartWithWindows = $false
        DiagnosticLogging = $false
        Theme = 'Auto'
        MaxCompressedBytes = $script:MaxCompressedBytes
        ActiveLogRotateBytes = $script:ActiveLogRotateBytes
        ActiveLogRotateMinutes = $script:ActiveLogRotateMinutes
        RecentEventsMax = $script:RecentEventsMax
        DnsLookupTimeoutMilliseconds = $script:DnsLookupTimeoutMilliseconds
        SourceNameCacheTtlMinutes = $script:SourceNameCacheTtlMinutes
        TcpClientIdleTimeoutMinutes = $script:TcpClientIdleTimeoutMinutes
    }
}

function Repair-Config {
    param([hashtable] $Config)

    $defaults = Get-DefaultConfig
    foreach ($key in $defaults.Keys) {
        if (-not $Config.ContainsKey($key) -or $null -eq $Config[$key]) {
            $Config[$key] = $defaults[$key]
        }
    }

    $Config.UdpPort = [int] $Config.UdpPort
    $Config.TcpPort = [int] $Config.TcpPort
    $Config.MaxCompressedBytes = [int64] $Config.MaxCompressedBytes
    $Config.ActiveLogRotateBytes = [int64] $Config.ActiveLogRotateBytes
    $Config.ActiveLogRotateMinutes = [int] $Config.ActiveLogRotateMinutes
    $Config.RecentEventsMax = [int] $Config.RecentEventsMax
    $Config.DnsLookupTimeoutMilliseconds = [int] $Config.DnsLookupTimeoutMilliseconds
    $Config.SourceNameCacheTtlMinutes = [int] $Config.SourceNameCacheTtlMinutes
    $Config.TcpClientIdleTimeoutMinutes = [int] $Config.TcpClientIdleTimeoutMinutes
    return $Config
}

function Get-AppConfig {
    $path = Get-ConfigPath
    if (Test-Path -LiteralPath $path) {
        try {
            $loaded = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
            $script:CachedConfig = Repair-Config -Config (ConvertTo-PlainHashtable -InputObject $loaded)
            return $script:CachedConfig
        }
        catch {
            Write-AppLog -Message ('Config load failed: {0}' -f $_.Exception.Message)
        }
    }

    $script:CachedConfig = Repair-Config -Config (Get-DefaultConfig)
    Save-AppConfig -Config $script:CachedConfig
    return $script:CachedConfig
}

function Save-AppConfig {
    param([hashtable] $Config)

    $script:CachedConfig = Repair-Config -Config $Config
    $json = $script:CachedConfig | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath (Get-ConfigPath) -Value $json -Encoding UTF8
    Sync-StartupShortcut -Config $script:CachedConfig
}

function Get-StartupShortcutPath {
    $startup = [Environment]::GetFolderPath('Startup')
    return Join-Path -Path $startup -ChildPath 'GW Router Logger.lnk'
}

function Sync-StartupShortcut {
    param([hashtable] $Config)

    try {
        $shortcutPath = Get-StartupShortcutPath
        if (-not [bool] $Config.StartWithWindows) {
            if (Test-Path -LiteralPath $shortcutPath) {
                Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
            }
            return
        }

        $wsh = New-Object -ComObject WScript.Shell
        $shortcut = $wsh.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "{0}"' -f $PSCommandPath
        $shortcut.WorkingDirectory = Get-ScriptRootPath
        $shortcut.Description = 'Start GW Router Logger in the notification area'
        $iconPath = Get-AppIconPath
        if (Test-Path -LiteralPath $iconPath) {
            $shortcut.IconLocation = $iconPath
        }
        $shortcut.Save()
    }
    catch {
        Write-AppLog -Message ('Startup shortcut update failed: {0}' -f $_.Exception.Message)
        [void] [System.Windows.Forms.MessageBox]::Show(
            'The startup shortcut could not be updated. Try running the app once as Administrator.',
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    }
}

function Get-SuggestedBindAddress {
    try {
        $interfaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
        foreach ($adapter in $interfaces) {
            if ($adapter.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) {
                continue
            }

            $properties = $adapter.GetIPProperties()
            if (-not $properties.GatewayAddresses -or $properties.GatewayAddresses.Count -eq 0) {
                continue
            }

            foreach ($unicast in $properties.UnicastAddresses) {
                if ($unicast.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    return $unicast.Address.IPAddressToString
                }
            }
        }
    }
    catch {
        Write-AppLog -Message ('Gateway address detection failed: {0}' -f $_.Exception.Message) -Diagnostic
    }

    return ''
}

function Get-LocalIPv4Addresses {
    $addresses = New-Object System.Collections.ArrayList
    [void] $addresses.Add('0.0.0.0')

    try {
        $interfaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
        foreach ($adapter in $interfaces) {
            if ($adapter.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) {
                continue
            }
            foreach ($unicast in $adapter.GetIPProperties().UnicastAddresses) {
                if ($unicast.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $address = $unicast.Address.IPAddressToString
                    if (-not $addresses.Contains($address)) {
                        [void] $addresses.Add($address)
                    }
                }
            }
        }
    }
    catch {
        Write-AppLog -Message ('IPv4 enumeration failed: {0}' -f $_.Exception.Message) -Diagnostic
    }

    return @($addresses)
}

function Get-ThemeColors {
    param([string] $Theme)

    $effective = $Theme
    if ($effective -eq 'Auto') {
        $effective = 'Light'
        try {
            $value = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
            if ([int] $value -eq 0) {
                $effective = 'Dark'
            }
        }
        catch {
            $effective = 'Light'
        }
    }

    if ($effective -eq 'Dark') {
        return @{
            Back = [System.Drawing.Color]::FromArgb(32, 32, 32)
            Panel = [System.Drawing.Color]::FromArgb(45, 45, 45)
            Fore = [System.Drawing.Color]::Gainsboro
            Accent = [System.Drawing.Color]::FromArgb(0, 120, 212)
        }
    }

    return @{
        Back = [System.Drawing.Color]::White
        Panel = [System.Drawing.Color]::FromArgb(245, 245, 245)
        Fore = [System.Drawing.Color]::FromArgb(24, 24, 24)
        Accent = [System.Drawing.Color]::FromArgb(0, 95, 184)
    }
}

function Apply-ThemeToControl {
    param(
        [System.Windows.Forms.Control] $Control,
        [hashtable] $Colors
    )

    $Control.BackColor = $Colors.Back
    $Control.ForeColor = $Colors.Fore
    foreach ($child in $Control.Controls) {
        if ($child -is [System.Windows.Forms.Button]) {
            $child.BackColor = $Colors.Panel
            $child.ForeColor = $Colors.Fore
            $child.FlatStyle = [System.Windows.Forms.FlatStyle]::System
        }
        elseif ($child -is [System.Windows.Forms.GroupBox] -or $child -is [System.Windows.Forms.Panel]) {
            $child.BackColor = $Colors.Back
            $child.ForeColor = $Colors.Fore
        }
        else {
            $child.BackColor = $Colors.Back
            $child.ForeColor = $Colors.Fore
        }
        Apply-ThemeToControl -Control $child -Colors $Colors
    }
}

function New-Label {
    param(
        [string] $Text,
        [int] $X,
        [int] $Y,
        [int] $Width = 120,
        [int] $Height = 23
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    return $label
}

function New-Button {
    param(
        [string] $Text,
        [int] $X,
        [int] $Y,
        [int] $Width = 120,
        [int] $Height = 28
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, $Height)
    return $button
}

function Assert-Port {
    param(
        [int] $Port,
        [string] $Name
    )

    if ($Port -lt 0 -or $Port -gt 65535) {
        throw "$Name must be between 0 and 65535."
    }
}

function Move-LogRoot {
    param(
        [string] $OldPath,
        [string] $NewPath
    )

    $oldFull = [IO.Path]::GetFullPath($OldPath)
    $newFull = [IO.Path]::GetFullPath($NewPath)
    if ($oldFull.TrimEnd('\') -ieq $newFull.TrimEnd('\')) {
        Ensure-Directory -Path $newFull | Out-Null
        return
    }

    Ensure-Directory -Path $newFull | Out-Null
    if (-not (Test-Path -LiteralPath $oldFull)) {
        return
    }

    $children = @(Get-ChildItem -LiteralPath $oldFull -Force -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        $target = Join-Path -Path $newFull -ChildPath $child.Name
        Move-Item -LiteralPath $child.FullName -Destination $target -Force -ErrorAction Stop
    }
}

function Get-LatestLogPath {
    param([hashtable] $Config)

    if (-not (Test-Path -LiteralPath $Config.LogRoot)) {
        return ''
    }

    $latest = Get-ChildItem -LiteralPath $Config.LogRoot -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($latest) {
        return $latest.FullName
    }
    return ''
}

function Open-LatestLog {
    $config = Get-AppConfig
    $path = Get-LatestLogPath -Config $config
    if ([string]::IsNullOrWhiteSpace($path)) {
        [void] [System.Windows.Forms.MessageBox]::Show(
            'No log file exists yet.',
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return
    }

    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $path) | Out-Null
}

function Open-LogFolder {
    $config = Get-AppConfig
    Ensure-Directory -Path $config.LogRoot | Out-Null
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $config.LogRoot) | Out-Null
}

function Ensure-FirewallRule {
    param(
        [ValidateSet('UDP', 'TCP')] [string] $Protocol,
        [int] $Port
    )

    if ($Port -le 0) {
        return
    }

    $ruleName = 'GW Router Logger {0} {1}' -f $Protocol, $Port
    try {
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($existing) {
            return
        }

        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol $Protocol -LocalPort $Port -Profile Any | Out-Null
        return
    }
    catch {
        $args = @(
            'advfirewall', 'firewall', 'add', 'rule',
            ('name="{0}"' -f $ruleName),
            'dir=in',
            'action=allow',
            ('protocol={0}' -f $Protocol),
            ('localport={0}' -f $Port)
        )
        $process = Start-Process -FilePath 'netsh.exe' -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -ne 0) {
            throw "netsh failed while adding firewall rule $ruleName."
        }
    }
}

function Add-FirewallRulesForConfig {
    param([hashtable] $Config)

    if (-not (Test-IsAdministrator)) {
        $args = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $PSCommandPath),
            '-FirewallOnly',
            '-FirewallUdpPort', ([string] $(if ([bool] $Config.UdpEnabled) { [int] $Config.UdpPort } else { 0 })),
            '-FirewallTcpPort', ([string] $(if ([bool] $Config.TcpEnabled) { [int] $Config.TcpPort } else { 0 }))
        )
        Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args -Verb RunAs | Out-Null
        return
    }

    if ([bool] $Config.UdpEnabled) {
        Ensure-FirewallRule -Protocol 'UDP' -Port ([int] $Config.UdpPort)
    }
    if ([bool] $Config.TcpEnabled) {
        Ensure-FirewallRule -Protocol 'TCP' -Port ([int] $Config.TcpPort)
    }
}

function Invoke-FirewallOnlyMode {
    if (-not (Test-IsAdministrator)) {
        throw 'Firewall setup requires Administrator rights.'
    }

    if ($FirewallUdpPort -gt 0) {
        Ensure-FirewallRule -Protocol 'UDP' -Port $FirewallUdpPort
    }
    if ($FirewallTcpPort -gt 0) {
        Ensure-FirewallRule -Protocol 'TCP' -Port $FirewallTcpPort
    }
}

function New-ListenerScriptBlock {
    return {
        param(
            [hashtable] $Settings,
            [hashtable] $Runtime
        )

        Add-Type -AssemblyName System.IO.Compression.FileSystem

        function Ensure-Directory {
            param([string] $Path)
            if (-not (Test-Path -LiteralPath $Path)) {
                [void] (New-Item -Path $Path -ItemType Directory -Force)
            }
            return (Resolve-Path -LiteralPath $Path).Path
        }

        function Get-SafeFileName {
            param([string] $Value)
            $invalid = [IO.Path]::GetInvalidFileNameChars()
            $builder = New-Object System.Text.StringBuilder
            foreach ($character in $Value.ToCharArray()) {
                if ($invalid -contains $character) {
                    [void] $builder.Append('_')
                }
                else {
                    [void] $builder.Append($character)
                }
            }
            $safe = $builder.ToString().Trim()
            if ([string]::IsNullOrWhiteSpace($safe)) {
                return 'unknown'
            }
            return $safe
        }

        function Get-SafeLogPath {
            param(
                [string] $Directory,
                [string] $BaseName,
                [string] $Suffix
            )
            Ensure-Directory -Path $Directory | Out-Null
            return Join-Path -Path $Directory -ChildPath ((Get-SafeFileName -Value $BaseName) + $Suffix)
        }

        function Rotate-And-CompressLog {
            param(
                [string] $LogFilePath,
                [string] $ArchiveDirectory
            )

            if (-not (Test-Path -LiteralPath $LogFilePath)) {
                return $false
            }

            $fileInfo = Get-Item -LiteralPath $LogFilePath
            $ageMinutes = ((Get-Date).ToUniversalTime() - $fileInfo.CreationTimeUtc).TotalMinutes
            if ($fileInfo.Length -lt [int64] $Settings.ActiveLogRotateBytes -and $ageMinutes -lt [int] $Settings.ActiveLogRotateMinutes) {
                return $false
            }

            Ensure-Directory -Path $ArchiveDirectory | Out-Null
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $baseName = '{0}-{1}' -f $fileInfo.BaseName, $timestamp
            $rotatedPath = Get-SafeLogPath -Directory $ArchiveDirectory -BaseName $baseName -Suffix '.log'
            $zipPath = Get-SafeLogPath -Directory $ArchiveDirectory -BaseName $baseName -Suffix '.zip'

            Move-Item -LiteralPath $LogFilePath -Destination $rotatedPath -Force
            $zipArchive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                [void] [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zipArchive,
                    $rotatedPath,
                    ([IO.Path]::GetFileName($rotatedPath)),
                    [System.IO.Compression.CompressionLevel]::Optimal
                )
            }
            finally {
                $zipArchive.Dispose()
            }
            Remove-Item -LiteralPath $rotatedPath -Force -ErrorAction SilentlyContinue
            return $true
        }

        function Enforce-CompressedArchiveCap {
            param([string] $RootPath)
            $archives = @(Get-ChildItem -LiteralPath $RootPath -Recurse -File -Filter '*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)
            $totalBytes = 0
            foreach ($archive in $archives) {
                $totalBytes += [int64] $archive.Length
            }

            foreach ($archive in $archives) {
                if ($totalBytes -le [int64] $Settings.MaxCompressedBytes) {
                    break
                }
                $length = [int64] $archive.Length
                Remove-Item -LiteralPath $archive.FullName -Force -ErrorAction SilentlyContinue
                $totalBytes -= $length
            }
        }

        $sourceNameCache = @{}

        function Resolve-SourceIdentity {
            param([string] $Address)

            if (-not [bool] $Settings.ResolveHostNames) {
                return $Address
            }

            if ($sourceNameCache.ContainsKey($Address)) {
                $entry = $sourceNameCache[$Address]
                if (((Get-Date) - $entry.Time).TotalMinutes -lt [int] $Settings.SourceNameCacheTtlMinutes) {
                    return $entry.Name
                }
            }

            $name = $Address
            try {
                $async = [Net.Dns]::BeginGetHostEntry($Address, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne([int] $Settings.DnsLookupTimeoutMilliseconds)) {
                    $hostEntry = [Net.Dns]::EndGetHostEntry($async)
                    if ($hostEntry -and -not [string]::IsNullOrWhiteSpace($hostEntry.HostName)) {
                        $name = $hostEntry.HostName
                    }
                }
            }
            catch {
                $name = $Address
            }

            $sourceNameCache[$Address] = @{
                Name = $name
                Time = Get-Date
            }
            return $name
        }

        function Write-LogRecord {
            param(
                [string] $Category,
                [string] $SourceName,
                [string] $Message
            )

            if ($Category -eq 'server') {
                $targetPath = Get-SafeLogPath -Directory $Settings.ServerLogRoot -BaseName 'server-current' -Suffix '.log'
                $archiveRoot = Join-Path -Path $Settings.ServerLogRoot -ChildPath 'archive'
            }
            else {
                $targetPath = Get-SafeLogPath -Directory $Settings.SourceLogRoot -BaseName ($SourceName + '-current') -Suffix '.log'
                $archiveRoot = Join-Path -Path $Settings.SourceLogRoot -ChildPath 'archive'
            }

            $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
            Add-Content -LiteralPath $targetPath -Value $line -Encoding UTF8
            if (Rotate-And-CompressLog -LogFilePath $targetPath -ArchiveDirectory $archiveRoot) {
                Enforce-CompressedArchiveCap -RootPath $Settings.LogRoot
            }
        }

        function Get-SyslogSummary {
            param([string] $RawMessage)
            $trimmed = $RawMessage.Trim()
            if ($trimmed.Length -le 160) {
                return $trimmed
            }
            return $trimmed.Substring(0, 160)
        }

        function Register-ReceivedMessage {
            param(
                [string] $Protocol,
                [string] $Address,
                [string] $RawMessage
            )

            $sourceIdentity = Resolve-SourceIdentity -Address $Address
            $Runtime.LastReceiveTime = Get-Date
            $Runtime.LastSender = $sourceIdentity
            $Runtime.MessageCount = [int64] $Runtime.MessageCount + 1
            if ($Protocol -eq 'UDP') {
                $Runtime.UdpCount = [int64] $Runtime.UdpCount + 1
            }
            else {
                $Runtime.TcpCount = [int64] $Runtime.TcpCount + 1
            }

            $messageLine = '{0} [{1}] {2}' -f $Address, $Protocol, $RawMessage.Trim()
            Write-LogRecord -Category 'source' -SourceName $sourceIdentity -Message $messageLine
            Write-LogRecord -Category 'server' -SourceName 'server' -Message ('Received {0} message from {1}: {2}' -f $Protocol, $sourceIdentity, (Get-SyslogSummary -RawMessage $RawMessage))
        }

        function Get-CompletedTcpMessages {
            param([string] $Buffer)

            $messages = New-Object System.Collections.ArrayList
            $remaining = $Buffer
            while ($remaining -match "^(.*?)(`r`n|`n)(.*)$") {
                if (-not [string]::IsNullOrWhiteSpace($matches[1])) {
                    [void] $messages.Add($matches[1])
                }
                $remaining = $matches[3]
            }

            return @{
                Messages = @($messages)
                Remaining = $remaining
            }
        }

        function Test-TcpClientClosed {
            param([System.Net.Sockets.TcpClient] $TcpClient)
            try {
                $socket = $TcpClient.Client
                return ($socket.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and $socket.Available -eq 0)
            }
            catch {
                return $true
            }
        }

        $udpClient = $null
        $tcpListener = $null
        $tcpClients = New-Object System.Collections.ArrayList

        try {
            $Settings.LogRoot = Ensure-Directory -Path $Settings.LogRoot
            $Settings.SourceLogRoot = Ensure-Directory -Path (Join-Path -Path $Settings.LogRoot -ChildPath 'sources')
            $Settings.ServerLogRoot = Ensure-Directory -Path (Join-Path -Path $Settings.LogRoot -ChildPath 'server')
            Enforce-CompressedArchiveCap -RootPath $Settings.LogRoot

            $bindIp = [System.Net.IPAddress]::Parse($Settings.BindAddress)
            if ([bool] $Settings.UdpEnabled) {
                $udpEndpoint = New-Object System.Net.IPEndPoint $bindIp, ([int] $Settings.UdpPort)
                $udpClient = New-Object System.Net.Sockets.UdpClient
                $udpClient.Client.Bind($udpEndpoint)
                Write-LogRecord -Category 'server' -SourceName 'server' -Message ('UDP listener started on {0}:{1}.' -f $Settings.BindAddress, $Settings.UdpPort)
            }

            if ([bool] $Settings.TcpEnabled) {
                $tcpListener = New-Object System.Net.Sockets.TcpListener $bindIp, ([int] $Settings.TcpPort)
                $tcpListener.Start()
                Write-LogRecord -Category 'server' -SourceName 'server' -Message ('TCP listener started on {0}:{1}.' -f $Settings.BindAddress, $Settings.TcpPort)
            }

            $Runtime.Running = $true
            $Runtime.StopRequested = $false
            $Runtime.StartedAt = Get-Date
            $Runtime.StatusText = 'Listening'
            $Runtime.LastError = ''

            while (-not [bool] $Runtime.StopRequested) {
                if ($udpClient) {
                    while ($udpClient.Available -gt 0) {
                        $remoteEndpoint = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0
                        $receivedBytes = $udpClient.Receive([ref] $remoteEndpoint)
                        $message = [Text.Encoding]::UTF8.GetString($receivedBytes)
                        Register-ReceivedMessage -Protocol 'UDP' -Address $remoteEndpoint.Address.IPAddressToString -RawMessage $message
                    }
                }

                if ($tcpListener) {
                    while ($tcpListener.Pending()) {
                        $accepted = $tcpListener.AcceptTcpClient()
                        $accepted.NoDelay = $true
                        $accepted.ReceiveTimeout = 100
                        $clientState = @{
                            Client = $accepted
                            Stream = $accepted.GetStream()
                            Address = $accepted.Client.RemoteEndPoint.Address.IPAddressToString
                            Buffer = ''
                            LastActivity = Get-Date
                        }
                        [void] $tcpClients.Add($clientState)
                        Write-LogRecord -Category 'server' -SourceName 'server' -Message ('TCP client connected: {0}' -f $clientState.Address)
                    }
                }

                for ($index = $tcpClients.Count - 1; $index -ge 0; $index--) {
                    $clientState = $tcpClients[$index]
                    $removeClient = $false
                    try {
                        $idleMinutes = ((Get-Date) - $clientState.LastActivity).TotalMinutes
                        if ($idleMinutes -ge [int] $Settings.TcpClientIdleTimeoutMinutes) {
                            if ($clientState.Buffer) {
                                Register-ReceivedMessage -Protocol 'TCP' -Address $clientState.Address -RawMessage $clientState.Buffer
                            }
                            Write-LogRecord -Category 'server' -SourceName 'server' -Message ('TCP client idle timeout: {0}' -f $clientState.Address)
                            $removeClient = $true
                        }
                        elseif (Test-TcpClientClosed -TcpClient $clientState.Client) {
                            if ($clientState.Buffer) {
                                Register-ReceivedMessage -Protocol 'TCP' -Address $clientState.Address -RawMessage $clientState.Buffer
                            }
                            $removeClient = $true
                        }
                        elseif ($clientState.Stream.DataAvailable) {
                            $readBuffer = New-Object byte[] 4096
                            $bytesRead = $clientState.Stream.Read($readBuffer, 0, $readBuffer.Length)
                            if ($bytesRead -gt 0) {
                                $clientState.LastActivity = Get-Date
                                $clientState.Buffer += [Text.Encoding]::UTF8.GetString($readBuffer, 0, $bytesRead)
                                $parsed = Get-CompletedTcpMessages -Buffer $clientState.Buffer
                                foreach ($message in $parsed.Messages) {
                                    Register-ReceivedMessage -Protocol 'TCP' -Address $clientState.Address -RawMessage $message
                                }
                                $clientState.Buffer = $parsed.Remaining
                            }
                        }
                    }
                    catch {
                        $Runtime.LastError = 'TCP client error: ' + $_.Exception.Message
                        Write-LogRecord -Category 'server' -SourceName 'server' -Message $Runtime.LastError
                        $removeClient = $true
                    }

                    if ($removeClient) {
                        try { $clientState.Stream.Dispose() } catch {}
                        try { $clientState.Client.Dispose() } catch {}
                        $tcpClients.RemoveAt($index)
                    }
                }

                Start-Sleep -Milliseconds 100
            }
        }
        catch {
            $Runtime.LastError = $_.Exception.Message
            $Runtime.StatusText = 'Stopped'
            throw
        }
        finally {
            foreach ($clientState in @($tcpClients)) {
                try {
                    if ($clientState.Buffer) {
                        Register-ReceivedMessage -Protocol 'TCP' -Address $clientState.Address -RawMessage $clientState.Buffer
                    }
                }
                catch {}
                try { $clientState.Stream.Dispose() } catch {}
                try { $clientState.Client.Dispose() } catch {}
            }
            if ($udpClient) {
                try { $udpClient.Dispose() } catch {}
            }
            if ($tcpListener) {
                try { $tcpListener.Stop() } catch {}
            }
            try {
                Write-LogRecord -Category 'server' -SourceName 'server' -Message 'Listener stopped.'
            }
            catch {}
            $Runtime.Running = $false
            $Runtime.StopRequested = $false
            if (-not $Runtime.LastError) {
                $Runtime.StatusText = 'Stopped'
            }
        }
    }
}

function Get-EffectiveStatus {
    $config = Get-AppConfig
    if (-not [bool] $config.IsConfigured) {
        return 'Idle'
    }

    if ([bool] $script:Runtime.Running) {
        if ($script:Runtime.LastReceiveTime) {
            $minutes = ((Get-Date) - [datetime] $script:Runtime.LastReceiveTime).TotalMinutes
            if ($minutes -le $script:StatusLoggingWindowMinutes) {
                return 'Logging'
            }
        }
        return 'Listening'
    }

    return 'Stopped'
}

function Update-MenuState {
    if (-not $script:StatusItem) {
        return
    }

    if ($script:ListenerHandle -and $script:ListenerHandle.IsCompleted) {
        try {
            $script:ListenerPowerShell.EndInvoke($script:ListenerHandle)
        }
        catch {
            $script:Runtime.LastError = $_.Exception.Message
            Write-AppLog -Message ('Listener stopped with error: {0}' -f $_.Exception.Message)
            if ($script:NotifyIcon) {
                $script:NotifyIcon.ShowBalloonTip(5000, $script:AppName, ('Listener stopped: {0}' -f $_.Exception.Message), [System.Windows.Forms.ToolTipIcon]::Error)
            }
        }
        finally {
            if ($script:ListenerPowerShell) {
                $script:ListenerPowerShell.Dispose()
            }
            if ($script:ListenerRunspace) {
                $script:ListenerRunspace.Dispose()
            }
            $script:ListenerPowerShell = $null
            $script:ListenerHandle = $null
            $script:ListenerRunspace = $null
            $script:Runtime.Running = $false
        }
    }

    $status = Get-EffectiveStatus
    $script:Runtime.StatusText = $status
    $script:StatusItem.Text = 'Status: ' + $status
    $script:StartItem.Enabled = (-not [bool] $script:Runtime.Running)
    $script:StopItem.Enabled = [bool] $script:Runtime.Running
    $script:OpenLatestItem.Enabled = -not [string]::IsNullOrWhiteSpace((Get-LatestLogPath -Config (Get-AppConfig)))
    if ($script:NotifyIcon) {
        $script:NotifyIcon.Text = ('{0} - {1}' -f $script:AppName, $status)
    }
}

function Start-Listener {
    $config = Get-AppConfig
    if (-not [bool] $config.IsConfigured) {
        Show-ConfigureForm -StartAfterSave
        $config = Get-AppConfig
        if (-not [bool] $config.IsConfigured) {
            return
        }
    }

    if ([bool] $script:Runtime.Running) {
        return
    }

    if (-not [bool] $config.UdpEnabled -and -not [bool] $config.TcpEnabled) {
        [void] [System.Windows.Forms.MessageBox]::Show(
            'Enable UDP, TCP, or both before starting the listener.',
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    $settings = $config.Clone()
    $settings.SourceLogRoot = Join-Path -Path $settings.LogRoot -ChildPath 'sources'
    $settings.ServerLogRoot = Join-Path -Path $settings.LogRoot -ChildPath 'server'

    $script:Runtime.StopRequested = $false
    $script:Runtime.LastError = ''
    $script:Runtime.LastReceiveTime = $null
    $script:Runtime.LastSender = ''
    $script:Runtime.MessageCount = 0
    $script:Runtime.UdpCount = 0
    $script:Runtime.TcpCount = 0

    try {
        $script:ListenerRunspace = [runspacefactory]::CreateRunspace()
        $script:ListenerRunspace.ApartmentState = 'MTA'
        $script:ListenerRunspace.ThreadOptions = 'ReuseThread'
        $script:ListenerRunspace.Open()
        $script:ListenerPowerShell = [PowerShell]::Create()
        $script:ListenerPowerShell.Runspace = $script:ListenerRunspace
        [void] $script:ListenerPowerShell.AddScript((New-ListenerScriptBlock)).AddArgument($settings).AddArgument($script:Runtime)
        $script:ListenerHandle = $script:ListenerPowerShell.BeginInvoke()
        Write-AppLog -Message 'Listener start requested.'
    }
    catch {
        Write-AppLog -Message ('Listener start failed: {0}' -f $_.Exception.Message)
        [void] [System.Windows.Forms.MessageBox]::Show(
            ('Listener could not start: {0}' -f $_.Exception.Message),
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }

    Update-MenuState
}

function Stop-Listener {
    if (-not [bool] $script:Runtime.Running -and -not $script:ListenerHandle) {
        return
    }

    $script:Runtime.StopRequested = $true
    Write-AppLog -Message 'Listener stop requested.' -Diagnostic
    Update-MenuState
}

function Exit-App {
    Stop-Listener
    if ($script:UiTimer) {
        $script:UiTimer.Stop()
    }
    if ($script:NotifyIcon) {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
    }
    [System.Windows.Forms.Application]::Exit()
}

function Invoke-CheckForUpdates {
    try {
        Write-AppLog -Message 'Checking GitHub for updates.' -Diagnostic
        $releaseInfo = Get-LatestReleaseInfo
        $currentVersion = ConvertTo-VersionObject -VersionText $script:Version
        $latestVersion = ConvertTo-VersionObject -VersionText $releaseInfo.Version
        if ($latestVersion -le $currentVersion) {
            [void] [System.Windows.Forms.MessageBox]::Show(
                ('You are already on the latest version ({0}).' -f $script:Version),
                $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        $message = @"
A newer version is available.

Current version: $script:Version
Latest version: $($releaseInfo.Version)
Published: $($releaseInfo.PublishedAt)

Download and install the update now?
"@
        $choice = [System.Windows.Forms.MessageBox]::Show(
            $message,
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }

        Write-AppLog -Message ('Starting update install for version {0}.' -f $releaseInfo.Version)
        Start-UpdateInstallerProcess -ReleaseInfo $releaseInfo
        Exit-App
    }
    catch {
        Write-AppLog -Message ('Update check failed: {0}' -f $_.Exception.Message)
        [void] [System.Windows.Forms.MessageBox]::Show(
            ('Update check failed: {0}' -f $_.Exception.Message),
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

function Show-AboutForm {
    $config = Get-AppConfig
    $text = @"
$script:AppName $script:Version

Notification-area syslog collector for Windows.

Log folder:
$($config.LogRoot)

Config:
$(Get-ConfigPath)
"@
    [void] [System.Windows.Forms.MessageBox]::Show(
        $text,
        ('About {0}' -f $script:AppName),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

function Show-ConfigureForm {
    param([switch] $StartAfterSave)

    $config = (Get-AppConfig).Clone()
    $colors = Get-ThemeColors -Theme $config.Theme

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Configure Listener'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(520, 330)

    $bindLabel = New-Label -Text 'Listen IP' -X 18 -Y 22 -Width 120
    $bindCombo = New-Object System.Windows.Forms.ComboBox
    $bindCombo.Location = New-Object System.Drawing.Point(150, 20)
    $bindCombo.Size = New-Object System.Drawing.Size(250, 24)
    $bindCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    foreach ($address in (Get-LocalIPv4Addresses)) {
        [void] $bindCombo.Items.Add($address)
    }
    $bindCombo.Text = [string] $config.BindAddress

    $suggestButton = New-Button -Text 'Suggest' -X 410 -Y 18 -Width 80
    $suggestButton.Add_Click({
        $suggested = Get-SuggestedBindAddress
        if (-not [string]::IsNullOrWhiteSpace($suggested)) {
            $bindCombo.Text = $suggested
        }
    })

    $udpCheck = New-Object System.Windows.Forms.CheckBox
    $udpCheck.Text = 'UDP'
    $udpCheck.Location = New-Object System.Drawing.Point(150, 65)
    $udpCheck.Size = New-Object System.Drawing.Size(55, 24)
    $udpCheck.Checked = [bool] $config.UdpEnabled

    $udpPort = New-Object System.Windows.Forms.NumericUpDown
    $udpPort.Location = New-Object System.Drawing.Point(210, 65)
    $udpPort.Size = New-Object System.Drawing.Size(90, 24)
    $udpPort.Minimum = 0
    $udpPort.Maximum = 65535
    $udpPort.Value = [int] $config.UdpPort
    $udpRec = New-Label -Text '(Recommended)' -X 310 -Y 65 -Width 130

    $tcpCheck = New-Object System.Windows.Forms.CheckBox
    $tcpCheck.Text = 'TCP'
    $tcpCheck.Location = New-Object System.Drawing.Point(150, 100)
    $tcpCheck.Size = New-Object System.Drawing.Size(55, 24)
    $tcpCheck.Checked = [bool] $config.TcpEnabled

    $tcpPort = New-Object System.Windows.Forms.NumericUpDown
    $tcpPort.Location = New-Object System.Drawing.Point(210, 100)
    $tcpPort.Size = New-Object System.Drawing.Size(90, 24)
    $tcpPort.Minimum = 0
    $tcpPort.Maximum = 65535
    $tcpPort.Value = [int] $config.TcpPort
    $tcpRec = New-Label -Text '(Recommended)' -X 310 -Y 100 -Width 130

    $hostCheck = New-Object System.Windows.Forms.CheckBox
    $hostCheck.Text = 'Resolve source names'
    $hostCheck.Location = New-Object System.Drawing.Point(150, 138)
    $hostCheck.Size = New-Object System.Drawing.Size(210, 24)
    $hostCheck.Checked = [bool] $config.ResolveHostNames

    $logLabel = New-Label -Text 'Log folder' -X 18 -Y 178 -Width 120
    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(150, 176)
    $logBox.Size = New-Object System.Drawing.Size(260, 24)
    $logBox.Text = [string] $config.LogRoot

    $browseButton = New-Button -Text 'Browse' -X 420 -Y 174 -Width 70
    $browseButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.SelectedPath = $logBox.Text
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $logBox.Text = $dialog.SelectedPath
        }
        $dialog.Dispose()
    })

    $startCheck = New-Object System.Windows.Forms.CheckBox
    $startCheck.Text = 'Start listener after saving'
    $startCheck.Location = New-Object System.Drawing.Point(150, 220)
    $startCheck.Size = New-Object System.Drawing.Size(220, 24)
    $startCheck.Checked = [bool] $StartAfterSave

    $saveButton = New-Button -Text 'Save' -X 285 -Y 280 -Width 90
    $cancelButton = New-Button -Text 'Cancel' -X 395 -Y 280 -Width 90
    $cancelButton.Add_Click({ $form.Close() })
    $saveButton.Add_Click({
        try {
            Assert-Port -Port ([int] $udpPort.Value) -Name 'UDP port'
            Assert-Port -Port ([int] $tcpPort.Value) -Name 'TCP port'
            if (-not $udpCheck.Checked -and -not $tcpCheck.Checked) {
                throw 'Enable UDP, TCP, or both.'
            }

            $oldLogRoot = [string] $config.LogRoot
            $newLogRoot = [string] $logBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($newLogRoot)) {
                throw 'Choose a log folder.'
            }

            Move-LogRoot -OldPath $oldLogRoot -NewPath $newLogRoot
            $config.IsConfigured = $true
            $config.BindAddress = [string] $bindCombo.Text.Trim()
            $config.UdpEnabled = [bool] $udpCheck.Checked
            $config.UdpPort = [int] $udpPort.Value
            $config.TcpEnabled = [bool] $tcpCheck.Checked
            $config.TcpPort = [int] $tcpPort.Value
            $config.ResolveHostNames = [bool] $hostCheck.Checked
            $config.LogRoot = [IO.Path]::GetFullPath($newLogRoot)
            Save-AppConfig -Config $config
            Write-AppLog -Message 'Configuration saved.'
            $form.Tag = @{
                StartAfterSave = [bool] $startCheck.Checked
            }
            $form.Close()
        }
        catch {
            [void] [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }
    })

    $form.Controls.AddRange(@(
        $bindLabel, $bindCombo, $suggestButton,
        (New-Label -Text 'Network' -X 18 -Y 68 -Width 120),
        $udpCheck, $udpPort, $udpRec,
        $tcpCheck, $tcpPort, $tcpRec,
        $hostCheck,
        $logLabel, $logBox, $browseButton,
        $startCheck, $saveButton, $cancelButton
    ))

    Apply-ThemeToControl -Control $form -Colors $colors
    [void] $form.ShowDialog()

    if ($form.Tag -and [bool] $form.Tag.StartAfterSave) {
        Start-Listener
    }
    Update-MenuState
    $form.Dispose()
}

function Show-SettingsForm {
    $config = (Get-AppConfig).Clone()
    $colors = Get-ThemeColors -Theme $config.Theme

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Settings'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(560, 520)

    $startCheck = New-Object System.Windows.Forms.CheckBox
    $startCheck.Text = 'Start with Windows'
    $startCheck.Location = New-Object System.Drawing.Point(20, 20)
    $startCheck.Size = New-Object System.Drawing.Size(220, 24)
    $startCheck.Checked = [bool] $config.StartWithWindows

    $diagCheck = New-Object System.Windows.Forms.CheckBox
    $diagCheck.Text = 'Diagnostic logging'
    $diagCheck.Location = New-Object System.Drawing.Point(20, 52)
    $diagCheck.Size = New-Object System.Drawing.Size(220, 24)
    $diagCheck.Checked = [bool] $config.DiagnosticLogging

    $themeLabel = New-Label -Text 'Theme' -X 20 -Y 90 -Width 90
    $themeCombo = New-Object System.Windows.Forms.ComboBox
    $themeCombo.Location = New-Object System.Drawing.Point(130, 88)
    $themeCombo.Size = New-Object System.Drawing.Size(140, 24)
    $themeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void] $themeCombo.Items.AddRange(@('Auto', 'Light', 'Dark'))
    $themeCombo.SelectedItem = [string] $config.Theme

    $networkGroup = New-Object System.Windows.Forms.GroupBox
    $networkGroup.Text = 'Network Configuration'
    $networkGroup.Location = New-Object System.Drawing.Point(18, 130)
    $networkGroup.Size = New-Object System.Drawing.Size(520, 135)

    $udpCheck = New-Object System.Windows.Forms.CheckBox
    $udpCheck.Text = 'UDP'
    $udpCheck.Location = New-Object System.Drawing.Point(18, 32)
    $udpCheck.Size = New-Object System.Drawing.Size(60, 24)
    $udpCheck.Checked = [bool] $config.UdpEnabled

    $udpPort = New-Object System.Windows.Forms.NumericUpDown
    $udpPort.Location = New-Object System.Drawing.Point(88, 32)
    $udpPort.Size = New-Object System.Drawing.Size(90, 24)
    $udpPort.Minimum = 0
    $udpPort.Maximum = 65535
    $udpPort.Value = [int] $config.UdpPort

    $tcpCheck = New-Object System.Windows.Forms.CheckBox
    $tcpCheck.Text = 'TCP'
    $tcpCheck.Location = New-Object System.Drawing.Point(18, 66)
    $tcpCheck.Size = New-Object System.Drawing.Size(60, 24)
    $tcpCheck.Checked = [bool] $config.TcpEnabled

    $tcpPort = New-Object System.Windows.Forms.NumericUpDown
    $tcpPort.Location = New-Object System.Drawing.Point(88, 66)
    $tcpPort.Size = New-Object System.Drawing.Size(90, 24)
    $tcpPort.Minimum = 0
    $tcpPort.Maximum = 65535
    $tcpPort.Value = [int] $config.TcpPort

    $firewallButton = New-Button -Text 'Add Exception to Firewall for this App' -X 205 -Y 48 -Width 280 -Height 30
    $firewallButton.Add_Click({
        try {
            $tempConfig = $config.Clone()
            $tempConfig.UdpEnabled = [bool] $udpCheck.Checked
            $tempConfig.UdpPort = [int] $udpPort.Value
            $tempConfig.TcpEnabled = [bool] $tcpCheck.Checked
            $tempConfig.TcpPort = [int] $tcpPort.Value
            Add-FirewallRulesForConfig -Config $tempConfig
            [void] [System.Windows.Forms.MessageBox]::Show(
                'Firewall exception request has been sent.',
                $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
        catch {
            [void] [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })

    $networkGroup.Controls.AddRange(@(
        $udpCheck, $udpPort, (New-Label -Text '(Recommended)' -X 190 -Y 32 -Width 120),
        $tcpCheck, $tcpPort, (New-Label -Text '(Recommended)' -X 190 -Y 66 -Width 120),
        $firewallButton
    ))

    $sizeGroup = New-Object System.Windows.Forms.GroupBox
    $sizeGroup.Text = 'Log Size Handling'
    $sizeGroup.Location = New-Object System.Drawing.Point(18, 285)
    $sizeGroup.Size = New-Object System.Drawing.Size(520, 118)
    $sizeGroup.Enabled = $false

    $rotateSize = New-Object System.Windows.Forms.NumericUpDown
    $rotateSize.Location = New-Object System.Drawing.Point(210, 28)
    $rotateSize.Size = New-Object System.Drawing.Size(90, 24)
    $rotateSize.Minimum = 1
    $rotateSize.Maximum = 1024
    $rotateSize.Value = [int] ([int64] $config.ActiveLogRotateBytes / 1MB)

    $rotateAge = New-Object System.Windows.Forms.NumericUpDown
    $rotateAge.Location = New-Object System.Drawing.Point(210, 58)
    $rotateAge.Size = New-Object System.Drawing.Size(90, 24)
    $rotateAge.Minimum = 1
    $rotateAge.Maximum = 10080
    $rotateAge.Value = [int] $config.ActiveLogRotateMinutes

    $archiveCap = New-Object System.Windows.Forms.NumericUpDown
    $archiveCap.Location = New-Object System.Drawing.Point(210, 88)
    $archiveCap.Size = New-Object System.Drawing.Size(90, 24)
    $archiveCap.Minimum = 1
    $archiveCap.Maximum = 10240
    $archiveCap.Value = [int] ([int64] $config.MaxCompressedBytes / 1MB)

    $sizeGroup.Controls.AddRange(@(
        (New-Label -Text 'Rotate active logs at MB' -X 18 -Y 28 -Width 180), $rotateSize,
        (New-Label -Text 'Rotate active logs at minutes' -X 18 -Y 58 -Width 180), $rotateAge,
        (New-Label -Text 'Compressed archive cap MB' -X 18 -Y 88 -Width 180), $archiveCap
    ))

    $logLabel = New-Label -Text 'Log folder' -X 20 -Y 425 -Width 90
    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(130, 423)
    $logBox.Size = New-Object System.Drawing.Size(300, 24)
    $logBox.Text = [string] $config.LogRoot
    $browseButton = New-Button -Text 'Browse' -X 440 -Y 421 -Width 80
    $browseButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.SelectedPath = $logBox.Text
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $logBox.Text = $dialog.SelectedPath
        }
        $dialog.Dispose()
    })

    $saveButton = New-Button -Text 'Save' -X 335 -Y 475 -Width 90
    $cancelButton = New-Button -Text 'Cancel' -X 445 -Y 475 -Width 90
    $cancelButton.Add_Click({ $form.Close() })
    $saveButton.Add_Click({
        try {
            if (-not $udpCheck.Checked -and -not $tcpCheck.Checked) {
                throw 'Enable UDP, TCP, or both before saving.'
            }

            $oldLogRoot = [string] $config.LogRoot
            $newLogRoot = [string] $logBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($newLogRoot)) {
                throw 'Choose a log folder.'
            }
            Move-LogRoot -OldPath $oldLogRoot -NewPath $newLogRoot

            $config.StartWithWindows = [bool] $startCheck.Checked
            $config.DiagnosticLogging = [bool] $diagCheck.Checked
            $config.Theme = [string] $themeCombo.SelectedItem
            $config.UdpEnabled = [bool] $udpCheck.Checked
            $config.UdpPort = [int] $udpPort.Value
            $config.TcpEnabled = [bool] $tcpCheck.Checked
            $config.TcpPort = [int] $tcpPort.Value
            $config.LogRoot = [IO.Path]::GetFullPath($newLogRoot)
            Save-AppConfig -Config $config
            Write-AppLog -Message 'Settings saved.'
            $form.Close()
        }
        catch {
            [void] [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }
    })

    $form.Controls.AddRange(@(
        $startCheck, $diagCheck, $themeLabel, $themeCombo,
        $networkGroup, $sizeGroup,
        $logLabel, $logBox, $browseButton,
        $saveButton, $cancelButton
    ))

    Apply-ThemeToControl -Control $form -Colors $colors
    [void] $form.ShowDialog()
    Update-MenuState
    $form.Dispose()
}

function Build-ContextMenu {
    $script:ContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:TitleItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:TitleItem.Text = ('{0} v{1}' -f $script:AppName, $script:Version)
    $script:TitleItem.Enabled = $false

    $script:StatusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:StatusItem.Text = 'Status: Idle'
    $script:StatusItem.Enabled = $false

    $configure = New-Object System.Windows.Forms.ToolStripMenuItem
    $configure.Text = 'Configure'
    $configure.Add_Click({ Show-ConfigureForm })

    $script:StartItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:StartItem.Text = 'Start'
    $script:StartItem.Add_Click({ Start-Listener })

    $script:StopItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:StopItem.Text = 'Stop'
    $script:StopItem.Add_Click({ Stop-Listener })

    $script:OpenLatestItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:OpenLatestItem.Text = 'Open Latest Log'
    $script:OpenLatestItem.Add_Click({ Open-LatestLog })

    $script:OpenFolderItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:OpenFolderItem.Text = 'Open Log Folder'
    $script:OpenFolderItem.Add_Click({ Open-LogFolder })

    $updateItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $updateItem.Text = 'Check for Updates ...'
    $updateItem.Add_Click({ Invoke-CheckForUpdates })

    $settings = New-Object System.Windows.Forms.ToolStripMenuItem
    $settings.Text = 'Settings'
    $settings.Add_Click({ Show-SettingsForm })

    $about = New-Object System.Windows.Forms.ToolStripMenuItem
    $about.Text = 'About'
    $about.Add_Click({ Show-AboutForm })

    $exit = New-Object System.Windows.Forms.ToolStripMenuItem
    $exit.Text = 'Exit'
    $exit.Add_Click({ Exit-App })

    [void] $script:ContextMenu.Items.Add($script:TitleItem)
    [void] $script:ContextMenu.Items.Add($script:StatusItem)
    [void] $script:ContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void] $script:ContextMenu.Items.Add($configure)
    [void] $script:ContextMenu.Items.Add($script:StartItem)
    [void] $script:ContextMenu.Items.Add($script:StopItem)
    [void] $script:ContextMenu.Items.Add($script:OpenLatestItem)
    [void] $script:ContextMenu.Items.Add($script:OpenFolderItem)
    [void] $script:ContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void] $script:ContextMenu.Items.Add($updateItem)
    [void] $script:ContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void] $script:ContextMenu.Items.Add($settings)
    [void] $script:ContextMenu.Items.Add($about)
    [void] $script:ContextMenu.Items.Add($exit)

    $script:ContextMenu.Add_Opening({ Update-MenuState })
}

function Invoke-SelfTest {
    $config = Get-AppConfig
    Ensure-Directory -Path $config.LogRoot | Out-Null
    Ensure-Directory -Path (Join-Path -Path $config.LogRoot -ChildPath 'sources') | Out-Null
    Ensure-Directory -Path (Join-Path -Path $config.LogRoot -ChildPath 'server') | Out-Null
    Write-AppLog -Message 'Self-test diagnostic log entry.' -Diagnostic
    'SELFTEST_OK'
}

function Invoke-ListenerSelfTest {
    $originalConfig = (Get-AppConfig).Clone()
    $config = $originalConfig.Clone()
    $config.IsConfigured = $true
    $config.BindAddress = '127.0.0.1'
    $config.UdpEnabled = $true
    $config.UdpPort = 5514
    $config.TcpEnabled = $true
    $config.TcpPort = 5515
    $config.DiagnosticLogging = $true
    $config.LogRoot = Join-Path -Path (Get-AppDataRoot) -ChildPath 'SelfTestLogs'
    Save-AppConfig -Config $config

    try {
        Start-Listener
        Start-Sleep -Milliseconds 700

        $udp = New-Object System.Net.Sockets.UdpClient
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes('<13>GW Router Logger UDP self-test')
            [void] $udp.Send($bytes, $bytes.Length, '127.0.0.1', 5514)
        }
        finally {
            $udp.Dispose()
        }

        $tcpConnected = $false
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $tcp.Connect('127.0.0.1', 5515)
                $stream = $tcp.GetStream()
                $bytes = [Text.Encoding]::UTF8.GetBytes("<13>GW Router Logger TCP self-test`n")
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
                $tcpConnected = $true
                break
            }
            catch {
                Start-Sleep -Milliseconds 250
            }
            finally {
                $tcp.Dispose()
            }
        }

        if (-not $tcpConnected) {
            throw 'Listener self-test could not connect to the local TCP listener on port 5515.'
        }

        Start-Sleep -Seconds 2
        Stop-Listener
        Start-Sleep -Seconds 1
        Update-MenuState

        $allLogs = @(Get-ChildItem -LiteralPath $config.LogRoot -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue)
        if ($allLogs.Count -eq 0) {
            throw 'Listener self-test did not create any log files.'
        }

        $matchedLog = $null
        foreach ($logFile in $allLogs) {
            $content = Get-Content -LiteralPath $logFile.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -match 'self-test') {
                $matchedLog = $logFile.FullName
                break
            }
        }

        if (-not $matchedLog) {
            throw 'Listener self-test log files did not contain the expected test message.'
        }

        'LISTENER_SELFTEST_OK'
    }
    finally {
        Stop-Listener
        Save-AppConfig -Config $originalConfig
    }
}

function Invoke-UpdateCheckSelfTest {
    $releaseInfo = Get-LatestReleaseInfo
    if ([string]::IsNullOrWhiteSpace($releaseInfo.Version)) {
        throw 'Release info did not include a version.'
    }
    if ([string]::IsNullOrWhiteSpace($releaseInfo.AssetUrl)) {
        throw 'Release info did not include a downloadable zip asset.'
    }
    'UPDATE_CHECK_OK {0} {1}' -f $releaseInfo.Version, $releaseInfo.AssetName
}

if ($FirewallOnly) {
    Invoke-FirewallOnlyMode
    exit 0
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

if ($ListenerSelfTest) {
    Invoke-ListenerSelfTest
    exit 0
}

if ($UpdateCheckSelfTest) {
    Invoke-UpdateCheckSelfTest
    exit 0
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\GW-Router-Logger-Tray', [ref] $createdNew)
if (-not $createdNew) {
    [void] [System.Windows.Forms.MessageBox]::Show(
        'GW Router Logger is already running.',
        $script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    exit 0
}

try {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
    Get-AppConfig | Out-Null

    Build-ContextMenu
    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:NotifyIcon.Icon = Get-AppIcon
    $script:NotifyIcon.Text = $script:AppName
    $script:NotifyIcon.ContextMenuStrip = $script:ContextMenu
    $script:NotifyIcon.Visible = $true

    $script:UiTimer = New-Object System.Windows.Forms.Timer
    $script:UiTimer.Interval = 1000
    $script:UiTimer.Add_Tick({ Update-MenuState })
    $script:UiTimer.Start()

    Update-MenuState
    Write-AppLog -Message ('Tray startup reached. StartListener={0}' -f [bool] $StartListener)
    if ($StartListener) {
        Start-Listener
    }
    Write-AppLog -Message 'Tray application started.' -Diagnostic
    [System.Windows.Forms.Application]::Run()
}
finally {
    Stop-Listener
    if ($script:UiTimer) {
        $script:UiTimer.Stop()
        $script:UiTimer.Dispose()
    }
    if ($script:NotifyIcon) {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
    }
    if ($mutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
