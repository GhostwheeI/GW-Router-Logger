param(
    [switch] $TrayApp,
    [switch] $FirewallOnly,
    [switch] $SelfTest,
    [switch] $ListenerSelfTest,
    [switch] $UpdateCheckSelfTest,
    [switch] $StartListener,
    [int] $FirewallUdpPort = 514,
    [int] $FirewallTcpPort = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# GW Router Logger
# This script is intentionally organized as small functions so that later features can be
# added without rewriting the listener loop, menu flow, or log retention logic.
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}
catch {
    throw 'The built-in compression assembly could not be loaded. This script requires standard .NET compression support.'
}

# These script-scoped values act as the main tuning points for future maintenance.
# Keeping them together makes it easier to adjust behavior without searching the file.
$script:AppName = 'GW Router Logger'
$script:Version = '1.3.0'
$script:MaxCompressedBytes = 100MB
$script:ActiveLogRotateBytes = 5MB
$script:ActiveLogRotateMinutes = 60
$script:RecentEventsMax = 12
$script:StatusRefreshMilliseconds = 2000
$script:DefaultUdpPort = 514
$script:DefaultTcpPort = 514
$script:DefaultResolveHostNames = $false
$script:DnsLookupTimeoutMilliseconds = 250
$script:SourceNameCacheTtlMinutes = 30
$script:TcpClientIdleTimeoutMinutes = 15
$script:LastSettings = $null
$script:SourceNameCache = @{}

if ($TrayApp -or $FirewallOnly -or $SelfTest -or $ListenerSelfTest -or $UpdateCheckSelfTest -or $StartListener) {
    $trayModulePath = Join-Path -Path (Split-Path -Path $PSCommandPath -Parent) -ChildPath 'GW-Router-Logger.TrayMode.psm1'
    if (-not (Test-Path -LiteralPath $trayModulePath)) {
        throw "Tray support module is missing: $trayModulePath"
    }

    Import-Module -Name $trayModulePath -Force -DisableNameChecking
    Start-GWRouterLoggerTrayApp `
        -FirewallOnly:$FirewallOnly `
        -SelfTest:$SelfTest `
        -ListenerSelfTest:$ListenerSelfTest `
        -UpdateCheckSelfTest:$UpdateCheckSelfTest `
        -StartListener:$StartListener `
        -FirewallUdpPort $FirewallUdpPort `
        -FirewallTcpPort $FirewallTcpPort
    return
}

function Write-Rule {
    param(
        [int] $Width = 72,
        [ConsoleColor] $Color = [ConsoleColor]::DarkCyan
    )

    Write-UiLine (''.PadLeft($Width, '=')) $Color
}

function Write-TitleBlock {
    param(
        [string] $Title,
        [string] $Subtitle = ''
    )

    Write-Rule
    Write-UiLine ('  {0}' -f $Title) Cyan
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        Write-UiLine ('  {0}' -f $Subtitle) DarkGray
    }
    Write-Rule
}

function Show-StartupSplash {
    Clear-Host
    Write-Rule -Width 78 -Color DarkCyan
    Write-UiLine '   _______          _______   _______  _        _______  _______ ' Cyan
    Write-UiLine '  (  ____ \|\     /|(  ___  )(  ____ \| \    /\(  ____ )(  ____ \' Cyan
    Write-UiLine '  | (    \/| )   ( || (   ) || (    \/|  \  / /| (    )|| (    \/' Cyan
    Write-UiLine '  | |      | | _ | || (___) || (_____ |  (_/ / | (____)|| (__    ' Cyan
    Write-UiLine '  | | ____ | |( )| ||  ___  |(_____  )|   _ (  |     __)|  __)   ' Cyan
    Write-UiLine '  | | \_  )| || || || (   ) |      ) ||  ( \ \ | (\ (   | (      ' Cyan
    Write-UiLine '  | (___) || () () || )   ( |/\____) ||  /  \ \| ) \ \__| (____/\' Cyan
    Write-UiLine '  (_______)(_______)|/     \|\_______)|_/    \/|/   \__/(_______/' Cyan
    Write-Rule -Width 78 -Color DarkCyan
    Write-UiLine '  GW ROUTER LOGGER' White
    Write-UiLine ('  Version {0}' -f $script:Version) DarkGray
    Write-UiLine '  Residential-friendly PowerShell syslog collector' DarkGray
    Write-Host
    Write-LabelValue -Label 'Mode' -Value 'Menu-driven foreground listener' -ValueColor Gray
    Write-LabelValue -Label 'Defaults' -Value 'Router-friendly setup with defensive validation' -ValueColor Gray
    Write-LabelValue -Label 'Storage' -Value 'Rolling compressed logs capped at 100 MB' -ValueColor Gray
    Write-Host
    Write-UiLine '  Starting...' DarkCyan
    Start-Sleep -Milliseconds 900
}

function Write-LabelValue {
    param(
        [string] $Label,
        [string] $Value,
        [ConsoleColor] $ValueColor = [ConsoleColor]::Gray
    )

    Write-Host ('{0,-15}' -f $Label) -NoNewline
    Write-Host ' ' -NoNewline
    $original = [Console]::ForegroundColor
    try {
        [Console]::ForegroundColor = $ValueColor
        Write-Host $Value
    }
    finally {
        [Console]::ForegroundColor = $original
    }
}

function Get-StatusColor {
    param([string] $Status)

    switch ($Status) {
        'Running' { return [ConsoleColor]::Green }
        'Starting' { return [ConsoleColor]::Yellow }
        'Stopped' { return [ConsoleColor]::DarkGray }
        default { return [ConsoleColor]::Gray }
    }
}

function Write-UiLine {
    param(
        [string] $Message,
        [ConsoleColor] $Color = [ConsoleColor]::Gray
    )

    $original = [Console]::ForegroundColor
    try {
        [Console]::ForegroundColor = $Color
        Write-Host $Message
    }
    finally {
        [Console]::ForegroundColor = $original
    }
}

function Test-IsAdministrator {
    try {
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Test-EnvironmentCompatibility {
    if ($PSVersionTable.PSVersion.Major -lt 3) {
        throw 'PowerShell 3.0 or later is required.'
    }
}

function Ensure-Elevation {
    if (Test-IsAdministrator) {
        return $true
    }

    if (-not $PSCommandPath) {
        Write-UiLine 'This script must run as Administrator.' Yellow
        Write-UiLine 'Open PowerShell as Administrator and run the script again from the file path.' Yellow
        return $false
    }

    try {
        $quotedScript = '"' + $PSCommandPath + '"'
        $encodedArgs = '-NoProfile -ExecutionPolicy Bypass -File ' + $quotedScript
        Start-Process -FilePath 'powershell.exe' -ArgumentList $encodedArgs -Verb RunAs | Out-Null
        return $false
    }
    catch {
        Write-UiLine 'Administrator rights are required and self-elevation did not succeed.' Yellow
        Write-UiLine 'Please right-click PowerShell and choose "Run as administrator", then run this script again.' Yellow
        return $false
    }
}

function Pause-ForUser {
    param([string] $Message = 'Press Enter to continue')
    Write-Host
    Read-Host $Message | Out-Null
}

function Get-ScriptRootPath {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }

    if ($PSCommandPath) {
        return (Split-Path -Path $PSCommandPath -Parent)
    }

    return (Get-Location).Path
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        [void] (New-Item -ItemType Directory -Path $Path -Force)
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-InternalRuntimeLogRoot {
    $candidateRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $candidateRoots += (Join-Path -Path $env:ProgramData -ChildPath 'GW-Router-Logger\server-runtime')
    }
    $candidateRoots += (Join-Path -Path (Get-ScriptRootPath) -ChildPath '.gw-router-logger-runtime')

    foreach ($candidate in $candidateRoots) {
        try {
            return (Ensure-Directory -Path $candidate)
        }
        catch {}
    }

    throw 'No writable runtime log folder was found for internal server events.'
}

function Move-DirectoryContents {
    param(
        [string] $SourcePath,
        [string] $DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return
    }

    Ensure-Directory -Path $DestinationPath | Out-Null
    $children = @(Get-ChildItem -LiteralPath $SourcePath -Force -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        Move-Item -LiteralPath $child.FullName -Destination (Join-Path -Path $DestinationPath -ChildPath $child.Name) -Force -ErrorAction SilentlyContinue
    }
}

function Remove-DirectoryIfEmpty {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $remaining = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-LogLayout {
    param([hashtable] $Settings)

    $Settings.LogRoot = Ensure-Directory -Path $Settings.LogRoot
    $Settings.SourceLogRoot = $Settings.LogRoot
    $Settings.ServerLogRoot = Get-InternalRuntimeLogRoot

    $sourceArchiveRoot = Ensure-Directory -Path (Join-Path -Path $Settings.SourceLogRoot -ChildPath 'archive')
    $serverArchiveRoot = Ensure-Directory -Path (Join-Path -Path $Settings.ServerLogRoot -ChildPath 'archive')

    $legacySourceRoot = Join-Path -Path $Settings.LogRoot -ChildPath 'sources'
    $legacySourceArchiveRoot = Join-Path -Path $legacySourceRoot -ChildPath 'archive'
    $legacyServerRoot = Join-Path -Path $Settings.LogRoot -ChildPath 'server'
    $legacyServerArchiveRoot = Join-Path -Path $legacyServerRoot -ChildPath 'archive'

    if (Test-Path -LiteralPath $legacySourceArchiveRoot) {
        Move-DirectoryContents -SourcePath $legacySourceArchiveRoot -DestinationPath $sourceArchiveRoot
    }
    if (Test-Path -LiteralPath $legacySourceRoot) {
        $sourceFiles = @(Get-ChildItem -LiteralPath $legacySourceRoot -Force -File -ErrorAction SilentlyContinue)
        foreach ($file in $sourceFiles) {
            Move-Item -LiteralPath $file.FullName -Destination (Join-Path -Path $Settings.SourceLogRoot -ChildPath $file.Name) -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $legacyServerArchiveRoot) {
        Move-DirectoryContents -SourcePath $legacyServerArchiveRoot -DestinationPath $serverArchiveRoot
    }
    if (Test-Path -LiteralPath $legacyServerRoot) {
        $serverFiles = @(Get-ChildItem -LiteralPath $legacyServerRoot -Force -File -ErrorAction SilentlyContinue)
        foreach ($file in $serverFiles) {
            Move-Item -LiteralPath $file.FullName -Destination (Join-Path -Path $Settings.ServerLogRoot -ChildPath $file.Name) -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-DirectoryIfEmpty -Path $legacySourceArchiveRoot
    Remove-DirectoryIfEmpty -Path $legacySourceRoot
    Remove-DirectoryIfEmpty -Path $legacyServerArchiveRoot
    Remove-DirectoryIfEmpty -Path $legacyServerRoot
}

function Get-TimestampString {
    return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
}

function New-RuntimeState {
    param([hashtable] $Settings)

    return @{
        StartTime = Get-Date
        Status = 'Starting'
        LastError = ''
        LastReceiveTime = $null
        LastSender = ''
        LastProtocol = ''
        MessageCount = 0
        UdpCount = 0
        TcpCount = 0
        SourceCounts = @{}
        RecentEvents = New-Object System.Collections.ArrayList
        Settings = $Settings
        ForceRefresh = $true
        LastScreenRenderTime = $null
        LastScreenSignature = ''
    }
}

function Add-RecentEvent {
    param(
        [hashtable] $State,
        [string] $Message
    )

    $timestamped = '{0}  {1}' -f (Get-Date).ToString('HH:mm:ss'), $Message
    [void] $State.RecentEvents.Add($timestamped)
    while ($State.RecentEvents.Count -gt $script:RecentEventsMax) {
        $State.RecentEvents.RemoveAt(0)
    }

    $State.ForceRefresh = $true
}

function Get-SafeFileName {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'unknown-source'
    }

    $invalidChars = [IO.Path]::GetInvalidFileNameChars()
    $safeValue = $Value
    foreach ($char in $invalidChars) {
        $safeValue = $safeValue.Replace([string] $char, '_')
    }

    $safeValue = $safeValue -replace '\s+', '_'
    $safeValue = $safeValue.Trim(' ._')
    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        return 'unknown-source'
    }

    if (Test-IsReservedFileStem -Value $safeValue) {
        return ('device-{0}' -f $safeValue.ToLowerInvariant())
    }

    return $safeValue
}

function Get-LocalIpv4Addresses {
    $results = New-Object System.Collections.ArrayList
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) {
                continue
            }

            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) {
                continue
            }

            $properties = $nic.GetIPProperties()
            foreach ($unicast in $properties.UnicastAddresses) {
                if ($unicast.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    continue
                }

                $entry = [PSCustomObject] @{
                    Name = $nic.Name
                    Description = $nic.Description
                    Address = $unicast.Address.IPAddressToString
                }
                [void] $results.Add($entry)
            }
        }
    }
    catch {
    }

    return @($results | Sort-Object Address -Unique)
}

function Get-PrimaryGatewayAddressInfo {
    $addresses = Get-LocalIpv4Addresses
    if (-not $addresses -or $addresses.Count -eq 0) {
        return $null
    }

    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) {
                continue
            }

            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) {
                continue
            }

            $properties = $nic.GetIPProperties()
            $hasIpv4Gateway = $false
            foreach ($gateway in $properties.GatewayAddresses) {
                if ($gateway.Address -and $gateway.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    if ($gateway.Address.IPAddressToString -ne '0.0.0.0') {
                        $hasIpv4Gateway = $true
                        $gatewayAddress = $gateway.Address.IPAddressToString
                        break
                    }
                }
            }

            if (-not $hasIpv4Gateway) {
                continue
            }

            foreach ($unicast in $properties.UnicastAddresses) {
                if ($unicast.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    continue
                }

                return [PSCustomObject] @{
                    InterfaceName = $nic.Name
                    LocalAddress = $unicast.Address.IPAddressToString
                    GatewayAddress = $gatewayAddress
                }
            }
        }
    }
    catch {
    }

    return $null
}

function Read-ValidatedPort {
    param(
        [string] $Prompt,
        [int] $Default
    )

    while ($true) {
        $rawValue = Read-Host "$Prompt [$Default] or type 0 to disable"
        if ([string]::IsNullOrWhiteSpace($rawValue)) {
            return $Default
        }

        $port = 0
        if (-not [int]::TryParse($rawValue, [ref] $port)) {
            Write-UiLine 'Please enter a valid whole number between 0 and 65535.' Yellow
            continue
        }

        if ($port -lt 0 -or $port -gt 65535) {
            Write-UiLine 'Port must be between 0 and 65535.' Yellow
            continue
        }

        return $port
    }
}

function Read-ValidatedPositiveInt {
    param(
        [string] $Prompt,
        [int] $Default,
        [int] $Minimum = 1
    )

    while ($true) {
        $rawValue = Read-Host ('{0} [{1}]' -f $Prompt, $Default)
        if ([string]::IsNullOrWhiteSpace($rawValue)) {
            return $Default
        }

        $value = 0
        if (-not [int]::TryParse($rawValue, [ref] $value)) {
            Write-UiLine 'Please enter a valid whole number.' Yellow
            continue
        }

        if ($value -lt $Minimum) {
            Write-UiLine ('Please enter a number greater than or equal to {0}.' -f $Minimum) Yellow
            continue
        }

        return $value
    }
}

function Read-BooleanChoice {
    param(
        [string] $Prompt,
        [bool] $Default
    )

    $defaultText = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $rawValue = Read-Host "$Prompt [$defaultText]"
        if ([string]::IsNullOrWhiteSpace($rawValue)) {
            return $Default
        }

        switch -Regex ($rawValue.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$' { return $false }
            default { Write-UiLine 'Please answer yes or no.' Yellow }
        }
    }
}

function Read-MenuChoice {
    param(
        [string] $Prompt,
        [string[]] $ValidChoices,
        [string] $DefaultChoice
    )

    while ($true) {
        $rawValue = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($rawValue)) {
            if ($DefaultChoice) {
                return $DefaultChoice
            }
        }
        else {
            $normalized = $rawValue.Trim().ToUpperInvariant()
            if ($ValidChoices -contains $normalized) {
                return $normalized
            }
        }

        Write-UiLine ('Please enter one of: {0}' -f ($ValidChoices -join ', ')) Yellow
    }
}

function Select-BindAddress {
    param([string] $DefaultAddress)

    $addresses = Get-LocalIpv4Addresses
    $gatewayInfo = Get-PrimaryGatewayAddressInfo

    if ($gatewayInfo) {
        Write-UiLine 'Detected the adapter currently using the default gateway.' Cyan
        Write-Host ('Suggested local IP: {0}  (gateway {1}, adapter {2})' -f $gatewayInfo.LocalAddress, $gatewayInfo.GatewayAddress, $gatewayInfo.InterfaceName)
        $useSuggested = Read-MenuChoice -Prompt 'Use this local IP for listening? [Y/n]' -ValidChoices @('Y', 'N') -DefaultChoice 'Y'
        if ($useSuggested -eq 'Y') {
            return $gatewayInfo.LocalAddress
        }
    }

    if ($addresses.Count -eq 0) {
        Write-UiLine 'No active IPv4 addresses were detected. Enter the local IP manually.' Yellow
    }
    else {
        Write-UiLine 'Available IPv4 addresses:' Cyan
        for ($index = 0; $index -lt $addresses.Count; $index++) {
            $entry = $addresses[$index]
            Write-Host ('[{0}] {1}  ({2})' -f ($index + 1), $entry.Address, $entry.Name)
        }
        Write-Host '[M] Enter a custom IP address'
        if ($DefaultAddress) {
            Write-Host "[Enter] Use previous choice: $DefaultAddress"
        }
    }

    while ($true) {
        $rawValue = Read-Host 'Select a bind address'
        if ([string]::IsNullOrWhiteSpace($rawValue) -and $DefaultAddress) {
            return $DefaultAddress
        }

        $selectedIndex = 0
        if ($addresses.Count -gt 0 -and [int]::TryParse($rawValue, [ref] $selectedIndex)) {
            if ($selectedIndex -ge 1 -and $selectedIndex -le $addresses.Count) {
                return $addresses[$selectedIndex - 1].Address
            }
        }

        if ($rawValue -match '^(m|manual)$') {
            $manual = Read-Host 'Enter the local IPv4 address to bind'
            try {
                $parsed = [System.Net.IPAddress]::Parse($manual)
                if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    throw 'IPv4 required'
                }
                return $parsed.IPAddressToString
            }
            catch {
                Write-UiLine 'Please enter a valid IPv4 address.' Yellow
                continue
            }
        }

        try {
            $parsed = [System.Net.IPAddress]::Parse($rawValue)
            if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
                throw 'IPv4 required'
            }
            return $parsed.IPAddressToString
        }
        catch {
            Write-UiLine 'Choose a listed number or enter a valid IPv4 address.' Yellow
        }
    }
}

function Get-RunSettings {
    $defaultBind = $null
    $defaultUdp = $script:DefaultUdpPort
    $defaultTcp = $script:DefaultTcpPort
    $defaultLookup = $script:DefaultResolveHostNames
    $defaultLogPath = Join-Path -Path (Get-ScriptRootPath) -ChildPath 'GW-ROUTER-LOGS'

    if ($script:LastSettings) {
        $defaultBind = $script:LastSettings.BindAddress
        $defaultUdp = [int] $script:LastSettings.UdpPort
        $defaultTcp = [int] $script:LastSettings.TcpPort
        $defaultLookup = [bool] $script:LastSettings.ResolveHostNames
        $defaultLogPath = $script:LastSettings.LogRoot
    }

    Clear-Host
    Write-TitleBlock -Title 'GW ROUTER LOGGER' -Subtitle 'Listener configuration'
    Write-Host

    Write-UiLine 'Most residential routers use UDP port 514.' Cyan
    Write-UiLine 'Press Enter to use the common router defaults: UDP 514 and TCP disabled.' DarkGray
    $modeChoice = Read-MenuChoice -Prompt 'Use common router defaults? [Y/n]' -ValidChoices @('Y', 'N') -DefaultChoice 'Y'

    $bindAddress = Select-BindAddress -DefaultAddress $defaultBind
    if ($modeChoice -eq 'Y') {
        $udpPort = 514
        $tcpPort = 0
        Write-UiLine 'Using router defaults: UDP 514, TCP disabled.' DarkGreen
    }
    else {
        $udpPort = Read-ValidatedPort -Prompt 'UDP syslog port' -Default $defaultUdp
        $tcpPort = Read-ValidatedPort -Prompt 'TCP syslog port' -Default $defaultTcp
    }

    if ($udpPort -eq 0 -and $tcpPort -eq 0) {
        throw 'At least one listener must be enabled.'
    }

    $resolveHostNames = Read-BooleanChoice -Prompt 'Resolve source IPs to host names when possible' -Default $defaultLookup
    $useDefaultLogPath = Read-MenuChoice -Prompt ('Use default path for logs? [Y/n] {0}' -f $defaultLogPath) -ValidChoices @('Y', 'N') -DefaultChoice 'Y'
    if ($useDefaultLogPath -eq 'Y') {
        $logRoot = $defaultLogPath
    }
    else {
        while ($true) {
            $logRootInput = Read-Host 'Enter the full folder path for logs'
            if ([string]::IsNullOrWhiteSpace($logRootInput)) {
                Write-UiLine 'Please enter a folder path.' Yellow
                continue
            }

            try {
                $logRoot = Get-NormalizedPath -Path $logRootInput.Trim('"')
                break
            }
            catch {
                Write-UiLine $_.Exception.Message Yellow
            }
        }
    }

    $settings = @{
        BindAddress = $bindAddress
        UdpPort = $udpPort
        TcpPort = $tcpPort
        ResolveHostNames = $resolveHostNames
        LogRoot = $logRoot
        SourceLogRoot = $logRoot
        ServerLogRoot = Get-InternalRuntimeLogRoot
    }

    Resolve-LogLayout -Settings $settings
    $script:LastSettings = $settings.Clone()
    return $settings
}

function Resolve-LogPaths {
    param([hashtable] $Settings)

    Resolve-LogLayout -Settings $Settings
}

function Get-ShortHash {
    param([string] $Value)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($bytes)
    }
    finally {
        $sha1.Dispose()
    }

    return ([BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 10).ToLowerInvariant()
}

function Get-SafeLogPath {
    param(
        [Parameter(Mandatory = $true)] [string] $Directory,
        [Parameter(Mandatory = $true)] [string] $BaseName,
        [Parameter(Mandatory = $true)] [string] $Suffix
    )

    $safeName = Get-SafeFileName -Value $BaseName
    $candidate = Join-Path -Path $Directory -ChildPath ($safeName + $Suffix)
    if ($candidate.Length -le 240) {
        return $candidate
    }

    $hash = Get-ShortHash -Value $BaseName
    $trimmed = $safeName
    if ($trimmed.Length -gt 48) {
        $trimmed = $trimmed.Substring(0, 48)
    }

    return (Join-Path -Path $Directory -ChildPath ('{0}-{1}{2}' -f $trimmed, $hash, $Suffix))
}

function Rotate-And-CompressLog {
    param(
        [Parameter(Mandatory = $true)] [string] $LogFilePath,
        [Parameter(Mandatory = $true)] [string] $ArchiveDirectory,
        [hashtable] $State
    )

    if (-not (Test-Path -LiteralPath $LogFilePath)) {
        return $false
    }

    # Rotate active logs on either size or age so quiet systems still archive regularly
    # and busy systems do not let a single active file grow too large.
    $fileInfo = Get-Item -LiteralPath $LogFilePath
    $ageMinutes = ((Get-Date).ToUniversalTime() - $fileInfo.CreationTimeUtc).TotalMinutes
    $shouldRotateBySize = $fileInfo.Length -ge $script:ActiveLogRotateBytes
    $shouldRotateByAge = $ageMinutes -ge $script:ActiveLogRotateMinutes

    if (-not $shouldRotateBySize -and -not $shouldRotateByAge) {
        return $false
    }

    Ensure-Directory -Path $ArchiveDirectory | Out-Null

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $archiveBaseName = '{0}-{1}' -f $fileInfo.BaseName, $timestamp
    $rotatedPath = Get-SafeLogPath -Directory $ArchiveDirectory -BaseName $archiveBaseName -Suffix '.log'
    $zipPath = Get-SafeLogPath -Directory $ArchiveDirectory -BaseName $archiveBaseName -Suffix '.zip'

    try {
        Move-Item -LiteralPath $LogFilePath -Destination $rotatedPath -Force
        $zipArchive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            [void] [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $rotatedPath, ([IO.Path]::GetFileName($rotatedPath)), [System.IO.Compression.CompressionLevel]::Optimal)
        }
        finally {
            $zipArchive.Dispose()
        }
        Remove-Item -LiteralPath $rotatedPath -Force -ErrorAction SilentlyContinue
        if ($State) {
            Add-RecentEvent -State $State -Message ('Archived {0}' -f [IO.Path]::GetFileName($zipPath))
        }
        return $true
    }
    catch {
        if ($State) {
            $State.LastError = 'Log rotation error: ' + $_.Exception.Message
            Add-RecentEvent -State $State -Message $State.LastError
        }
        return $false
    }
}

function Enforce-CompressedArchiveCap {
    param(
        [Parameter(Mandatory = $true)] [string] $RootPath,
        [hashtable] $State
    )

    try {
        $archives = @(Get-ChildItem -LiteralPath $RootPath -Recurse -File -Filter '*.zip' | Sort-Object LastWriteTimeUtc)
        $totalBytes = 0
        foreach ($archive in $archives) {
            $totalBytes += [int64] $archive.Length
        }

        foreach ($archive in $archives) {
            if ($totalBytes -le $script:MaxCompressedBytes) {
                break
            }

            $length = $archive.Length
            Remove-Item -LiteralPath $archive.FullName -Force -ErrorAction Stop
            $totalBytes -= $length
            if ($State) {
                Add-RecentEvent -State $State -Message ('Pruned archive {0}' -f $archive.Name)
            }
        }
    }
    catch {
        if ($State) {
            $State.LastError = 'Archive pruning error: ' + $_.Exception.Message
            Add-RecentEvent -State $State -Message $State.LastError
        }
    }
}

function Write-LogRecord {
    param(
        [hashtable] $Settings,
        [hashtable] $State,
        [string] $Category,
        [string] $SourceName,
        [string] $Message
    )

    $timestamp = Get-TimestampString
    if ($Category -eq 'server') {
        $targetPath = Get-SafeLogPath -Directory $Settings.ServerLogRoot -BaseName 'server-current' -Suffix '.log'
        $archiveRoot = Join-Path -Path $Settings.ServerLogRoot -ChildPath 'archive'
    }
    else {
        $targetPath = Get-SafeLogPath -Directory $Settings.SourceLogRoot -BaseName ($SourceName + '-current') -Suffix '.log'
        $archiveRoot = Join-Path -Path $Settings.LogRoot -ChildPath 'archive'
    }

    $line = '{0} [{1}] {2}' -f $timestamp, $Category.ToUpperInvariant(), $Message
    try {
        Add-Content -LiteralPath $targetPath -Value $line -Encoding UTF8
        $rotated = Rotate-And-CompressLog -LogFilePath $targetPath -ArchiveDirectory $archiveRoot -State $State
        if ($rotated) {
            Enforce-CompressedArchiveCap -RootPath $Settings.LogRoot -State $State
        }
    }
    catch {
        if ($State) {
            $State.LastError = 'Write log error: ' + $_.Exception.Message
            Add-RecentEvent -State $State -Message $State.LastError
        }
    }
}

function Write-ServerEvent {
    param(
        [hashtable] $Settings,
        [hashtable] $State,
        [string] $Message
    )

    Write-LogRecord -Settings $Settings -State $State -Category 'server' -SourceName 'server' -Message $Message
}

function Resolve-SourceIdentity {
    param(
        [string] $Address,
        [bool] $ResolveHostNames
    )

    $nowUtc = (Get-Date).ToUniversalTime()
    $cacheKey = '{0}|{1}' -f $Address, $ResolveHostNames
    if ($script:SourceNameCache.ContainsKey($cacheKey)) {
        $cached = $script:SourceNameCache[$cacheKey]
        if ($cached.ExpiresUtc -gt $nowUtc) {
            return $cached.Name
        }
    }

    if (-not $ResolveHostNames) {
        $script:SourceNameCache[$cacheKey] = @{
            Name = $Address
            ExpiresUtc = $nowUtc.AddMinutes($script:SourceNameCacheTtlMinutes)
        }
        return $Address
    }

    $resolvedName = $Address
    $asyncResult = $null
    try {
        $asyncResult = [System.Net.Dns]::BeginGetHostEntry($Address, $null, $null)
        $completed = $asyncResult.AsyncWaitHandle.WaitOne($script:DnsLookupTimeoutMilliseconds, $false)
        if ($completed) {
            $entry = [System.Net.Dns]::EndGetHostEntry($asyncResult)
            if ($entry.HostName) {
                $resolvedName = '{0}_{1}' -f $entry.HostName, $Address
            }
        }
    }
    catch {
    }
    finally {
        if ($asyncResult) {
            try {
                $asyncResult.AsyncWaitHandle.Close()
            }
            catch {
            }
        }
    }

    $script:SourceNameCache[$cacheKey] = @{
        Name = $resolvedName
        ExpiresUtc = $nowUtc.AddMinutes($script:SourceNameCacheTtlMinutes)
    }
    return $resolvedName
}

function Test-IsReservedFileStem {
    param([string] $Value)

    $reserved = @(
        'CON', 'PRN', 'AUX', 'NUL',
        'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
    )

    return $reserved -contains $Value.ToUpperInvariant()
}

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)] [string] $Path)

    try {
        return [IO.Path]::GetFullPath($Path)
    }
    catch {
        throw "Invalid path: $Path"
    }
}

function Test-PathWritable {
    param([Parameter(Mandatory = $true)] [string] $DirectoryPath)

    try {
        $resolved = Ensure-Directory -Path $DirectoryPath
        $probeFile = Join-Path -Path $resolved -ChildPath ('write-test-{0}.tmp' -f ([guid]::NewGuid().ToString('N')))
        Set-Content -LiteralPath $probeFile -Value 'ok' -Encoding ASCII
        Remove-Item -LiteralPath $probeFile -Force
        return $true
    }
    catch {
        return $false
    }
}

function Resolve-PreferredLogRoot {
    param([hashtable] $Settings)

    # The script prefers the launch folder, but it should not fail there if permissions or
    # path policies are different on another machine. These fallbacks are ordered by usefulness.
    $candidates = New-Object System.Collections.ArrayList
    [void] $candidates.Add((Get-NormalizedPath -Path $Settings.LogRoot))
    [void] $candidates.Add((Join-Path -Path $env:ProgramData -ChildPath 'GW-ROUTER-LOGS'))
    [void] $candidates.Add((Join-Path -Path $env:TEMP -ChildPath 'GW-ROUTER-LOGS'))

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if (Test-PathWritable -DirectoryPath $candidate) {
            $Settings.LogRoot = Ensure-Directory -Path $candidate
            Resolve-LogLayout -Settings $Settings
            return
        }
    }

    throw 'No writable log folder was found. Try a different location or confirm disk permissions.'
}

function Test-PortAvailable {
    param(
        [string] $Address,
        [int] $Port,
        [ValidateSet('UDP', 'TCP')] [string] $Protocol
    )

    if ($Port -eq 0) {
        return $true
    }

    try {
        $endpoint = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($Address)), $Port
        if ($Protocol -eq 'UDP') {
            $client = New-Object System.Net.Sockets.UdpClient
            try {
                $client.Client.Bind($endpoint)
            }
            finally {
                $client.Dispose()
            }
        }
        else {
            $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Parse($Address)), $Port
            try {
                $listener.Start()
            }
            finally {
                $listener.Stop()
            }
        }

        return $true
    }
    catch {
        return $false
    }
}

function Ensure-FirewallRule {
    param(
        [ValidateSet('UDP', 'TCP')] [string] $Protocol,
        [int] $Port
    )

    if ($Port -eq 0) {
        return
    }

    $ruleName = '{0} {1} {2}' -f $script:AppName, $Protocol, $Port
    try {
        if (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue) {
            $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
            if ($existing) {
                $null = $existing | Remove-NetFirewallRule -ErrorAction SilentlyContinue
            }

            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol $Protocol -LocalPort $Port -Profile Any | Out-Null
            return
        }

        $arguments = @(
            'advfirewall', 'firewall', 'delete', 'rule',
            ('name={0}' -f $ruleName)
        )
        & netsh @arguments | Out-Null

        $arguments = @(
            'advfirewall', 'firewall', 'add', 'rule',
            ('name={0}' -f $ruleName),
            'dir=in',
            'action=allow',
            ('protocol={0}' -f $Protocol),
            ('localport={0}' -f $Port)
        )
        & netsh @arguments | Out-Null
    }
    catch {
        throw "Firewall update failed for $Protocol/$Port. $($_.Exception.Message)"
    }
}

function Get-SyslogSummary {
    param([string] $RawMessage)

    $priority = ''
    $content = $RawMessage.Trim()
    if ($content -match '^<(?<pri>\d{1,3})>(?<rest>.*)$') {
        $priority = $Matches.pri
        $content = $Matches.rest.Trim()
    }

    $preview = $content
    if ($preview.Length -gt 120) {
        $preview = $preview.Substring(0, 120) + '...'
    }

    if ($priority) {
        return "PRI=$priority $preview"
    }

    return $preview
}

function Register-ReceivedMessage {
    param(
        [hashtable] $Settings,
        [hashtable] $State,
        [string] $Protocol,
        [string] $Address,
        [string] $RawMessage
    )

    if ([string]::IsNullOrWhiteSpace($RawMessage)) {
        return
    }

    $sourceIdentity = Resolve-SourceIdentity -Address $Address -ResolveHostNames $Settings.ResolveHostNames
    $summary = Get-SyslogSummary -RawMessage $RawMessage

    $State.Status = 'Running'
    $State.LastReceiveTime = Get-Date
    $State.LastSender = $sourceIdentity
    $State.LastProtocol = $Protocol
    $State.MessageCount++
    if ($Protocol -eq 'UDP') {
        $State.UdpCount++
    }
    else {
        $State.TcpCount++
    }

    if (-not $State.SourceCounts.ContainsKey($sourceIdentity)) {
        $State.SourceCounts[$sourceIdentity] = 0
    }
    $State.SourceCounts[$sourceIdentity]++
    $State.ForceRefresh = $true

    # Every inbound log updates both the console state and the durable log files so that
    # troubleshooting can continue even after the console session ends.
    Add-RecentEvent -State $State -Message ("$Protocol message from $sourceIdentity")
    $messageLine = '{0} [{1}] {2}' -f $Address, $Protocol, $RawMessage.Trim()
    Write-LogRecord -Settings $Settings -State $State -Category 'source' -SourceName $sourceIdentity -Message $messageLine
    Write-ServerEvent -Settings $Settings -State $State -Message ("Received {0} message from {1}: {2}" -f $Protocol, $sourceIdentity, $summary)
}

function Show-NoLogGuidance {
    param([hashtable] $Settings)

    Clear-Host
    Write-UiLine $script:AppName Yellow
    Write-Host 'No logs have been received after 2 minutes.'
    Write-Host
    Write-Host 'Things to verify:'
    Write-Host ('1. The router is sending syslog to this IP: {0}' -f $Settings.BindAddress)
    if ($Settings.UdpPort -gt 0) {
        Write-Host ('2. The router syslog port matches UDP {0}' -f $Settings.UdpPort)
    }
    if ($Settings.TcpPort -gt 0) {
        Write-Host ('3. The router syslog port matches TCP {0}' -f $Settings.TcpPort)
    }
    Write-Host '4. Windows Firewall or security software is not blocking the listener'
    Write-Host '5. The router and this PC are on reachable networks'
    Write-Host '6. If the router supports only UDP, keep TCP disabled unless needed'
    Write-Host
    Pause-ForUser -Message 'Press Enter to return to the listener'
}

function Test-TcpClientClosed {
    param([System.Net.Sockets.TcpClient] $TcpClient)

    try {
        if (-not $TcpClient.Connected) {
            return $true
        }

        $socket = $TcpClient.Client
        if ($socket.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and $socket.Available -eq 0) {
            return $true
        }

        return $false
    }
    catch {
        return $true
    }
}

function Get-CompletedTcpMessages {
    param([string] $Buffer)

    $messages = New-Object System.Collections.ArrayList
    $remaining = $Buffer

    while ($remaining.Length -gt 0) {
        if ($remaining -match '^(?<length>\d{1,10}) (?<rest>[\s\S]*)$') {
            $candidateLength = [int] $Matches.length
            $rest = $Matches.rest
            if ($rest.Length -ge $candidateLength) {
                $message = $rest.Substring(0, $candidateLength)
                [void] $messages.Add($message)
                $remaining = $rest.Substring($candidateLength)
                continue
            }
        }

        $newlineIndex = $remaining.IndexOf("`n")
        if ($newlineIndex -lt 0) {
            break
        }

        $message = $remaining.Substring(0, $newlineIndex).TrimEnd("`r")
        [void] $messages.Add($message)
        $remaining = $remaining.Substring($newlineIndex + 1)
    }

    return [PSCustomObject] @{
        Messages = @($messages)
        Remaining = $remaining
    }
}

function Show-StatusScreen {
    param([hashtable] $State)

    # This screen is redrawn on a timer so the operator always has a single place to confirm
    # whether the server is healthy and whether logs are actively arriving.
    $udpDisplay = 'Disabled'
    $tcpDisplay = 'Disabled'
    $lastReceivedDisplay = 'None yet'
    $lastSenderDisplay = 'None yet'
    $lastProtocolDisplay = 'N/A'

    if ($State.Settings.UdpPort -gt 0) {
        $udpDisplay = [string] $State.Settings.UdpPort
    }
    if ($State.Settings.TcpPort -gt 0) {
        $tcpDisplay = [string] $State.Settings.TcpPort
    }
    if ($State.LastReceiveTime) {
        $lastReceivedDisplay = [string] $State.LastReceiveTime
    }
    if ($State.LastSender) {
        $lastSenderDisplay = $State.LastSender
    }
    if ($State.LastProtocol) {
        $lastProtocolDisplay = $State.LastProtocol
    }

    $recentEventsText = ''
    foreach ($event in $State.RecentEvents) {
        $recentEventsText += $event + "`n"
    }

    $signature = '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f `
        $State.Status, `
        $State.MessageCount, `
        $State.UdpCount, `
        $State.TcpCount, `
        $lastReceivedDisplay, `
        $lastSenderDisplay, `
        $recentEventsText

    $now = Get-Date
    $shouldRender = $State.ForceRefresh
    if (-not $shouldRender) {
        if ($null -eq $State.LastScreenRenderTime) {
            $shouldRender = $true
        }
        else {
            $elapsed = $now - $State.LastScreenRenderTime
            if ($elapsed.TotalMilliseconds -ge $script:StatusRefreshMilliseconds) {
                $shouldRender = $true
            }
        }
    }

    if (-not $shouldRender) {
        return
    }

    if ($signature -eq $State.LastScreenSignature -and -not $State.ForceRefresh) {
        return
    }

    Clear-Host
    Write-TitleBlock -Title 'GW ROUTER LOGGER' -Subtitle 'Residential syslog listener'
    Write-LabelValue -Label 'Started' -Value ([string] $State.StartTime) -ValueColor DarkGray
    Write-LabelValue -Label 'Status' -Value $State.Status -ValueColor (Get-StatusColor -Status $State.Status)
    Write-LabelValue -Label 'Bind IP' -Value $State.Settings.BindAddress -ValueColor Cyan
    Write-LabelValue -Label 'UDP Port' -Value $udpDisplay -ValueColor Gray
    Write-LabelValue -Label 'TCP Port' -Value $tcpDisplay -ValueColor Gray
    Write-LabelValue -Label 'Log folder' -Value $State.Settings.LogRoot -ValueColor DarkGray
    Write-LabelValue -Label 'Messages' -Value ('{0} total | UDP {1} | TCP {2}' -f $State.MessageCount, $State.UdpCount, $State.TcpCount) -ValueColor Green
    Write-LabelValue -Label 'Last recv' -Value $lastReceivedDisplay -ValueColor Gray
    Write-LabelValue -Label 'Last sender' -Value $lastSenderDisplay -ValueColor Gray
    Write-LabelValue -Label 'Last proto' -Value $lastProtocolDisplay -ValueColor Gray
    if ($State.LastError) {
        Write-LabelValue -Label 'Last error' -Value $State.LastError -ValueColor Yellow
    }
    else {
        Write-LabelValue -Label 'Last error' -Value 'None' -ValueColor DarkGreen
    }

    Write-Host
    Write-Rule -Width 72 -Color DarkGray
    Write-UiLine 'Recent Activity' Cyan
    if ($State.RecentEvents.Count -eq 0) {
        Write-UiLine '  Waiting for activity...' DarkGray
    }
    else {
        foreach ($event in $State.RecentEvents) {
            Write-Host '  ' -NoNewline
            Write-UiLine $event Gray
        }
    }

    Write-Host
    Write-Rule -Width 72 -Color DarkGray
    Write-UiLine '[Q] Stop listener   [O] Open log folder   [Ctrl+C] Cancel script' DarkCyan

    $State.LastScreenRenderTime = $now
    $State.LastScreenSignature = $signature
    $State.ForceRefresh = $false
}

function Start-LogServer {
    param([hashtable] $Settings)

    # This is the core runtime wrapper. Everything needed for environment validation happens
    # here before the long-running listener loop begins.
    Resolve-PreferredLogRoot -Settings $Settings
    $state = New-RuntimeState -Settings $Settings

    Enforce-CompressedArchiveCap -RootPath $Settings.LogRoot -State $state
    Write-ServerEvent -Settings $Settings -State $state -Message 'Server startup requested.'

    if ($Settings.UdpPort -gt 0 -and -not (Test-PortAvailable -Address $Settings.BindAddress -Port $Settings.UdpPort -Protocol 'UDP')) {
        throw "UDP port $($Settings.UdpPort) is already in use on $($Settings.BindAddress)."
    }
    if ($Settings.TcpPort -gt 0 -and -not (Test-PortAvailable -Address $Settings.BindAddress -Port $Settings.TcpPort -Protocol 'TCP')) {
        throw "TCP port $($Settings.TcpPort) is already in use on $($Settings.BindAddress)."
    }

    $udpClient = $null
    $tcpListener = $null
    $tcpClients = New-Object System.Collections.ArrayList
    $bindIp = [System.Net.IPAddress]::Parse($Settings.BindAddress)
    $verificationPromptShown = $false

    try {
        if ($Settings.UdpPort -gt 0) {
            Ensure-FirewallRule -Protocol 'UDP' -Port $Settings.UdpPort
            $udpEndpoint = New-Object System.Net.IPEndPoint $bindIp, $Settings.UdpPort
            $udpClient = New-Object System.Net.Sockets.UdpClient
            $udpClient.Client.Bind($udpEndpoint)
            $startupMessage = 'UDP listener started on {0}:{1}.' -f $Settings.BindAddress, $Settings.UdpPort
            Write-ServerEvent -Settings $Settings -State $state -Message $startupMessage
        }

        if ($Settings.TcpPort -gt 0) {
            Ensure-FirewallRule -Protocol 'TCP' -Port $Settings.TcpPort
            $tcpListener = New-Object System.Net.Sockets.TcpListener $bindIp, $Settings.TcpPort
            $tcpListener.Start()
            $startupMessage = 'TCP listener started on {0}:{1}.' -f $Settings.BindAddress, $Settings.TcpPort
            Write-ServerEvent -Settings $Settings -State $state -Message $startupMessage
        }

        $state.Status = 'Running'
        $state.ForceRefresh = $true
        Add-RecentEvent -State $state -Message 'Listener started successfully.'

        while ($true) {
            Show-StatusScreen -State $state

            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    'Q' {
                        Add-RecentEvent -State $state -Message 'Stop requested by user.'
                        return
                    }
                    'O' {
                        Start-Process -FilePath 'explorer.exe' -ArgumentList $Settings.LogRoot | Out-Null
                    }
                }
            }

            if ($udpClient) {
                try {
                    while ($udpClient.Available -gt 0) {
                        $remoteEndpoint = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0
                        $receivedBytes = $udpClient.Receive([ref] $remoteEndpoint)
                        $message = [Text.Encoding]::UTF8.GetString($receivedBytes)
                        Register-ReceivedMessage -Settings $Settings -State $state -Protocol 'UDP' -Address $remoteEndpoint.Address.IPAddressToString -RawMessage $message
                    }
                }
                catch {
                    $state.LastError = 'UDP receive error: ' + $_.Exception.Message
                    Add-RecentEvent -State $state -Message $state.LastError
                    Write-ServerEvent -Settings $Settings -State $state -Message $state.LastError
                }
            }

            if ($tcpListener) {
                try {
                    while ($tcpListener.Pending()) {
                        $accepted = $tcpListener.AcceptTcpClient()
                        $accepted.NoDelay = $true
                        $accepted.ReceiveTimeout = 100
                        $clientState = [PSCustomObject] @{
                            Client = $accepted
                            Stream = $accepted.GetStream()
                            Buffer = ''
                            Address = ([string] $accepted.Client.RemoteEndPoint).Split(':')[0]
                            LastActivity = Get-Date
                        }
                        [void] $tcpClients.Add($clientState)
                        $connectMessage = 'TCP client connected: {0}' -f $clientState.Address
                        Add-RecentEvent -State $state -Message $connectMessage
                    }
                }
                catch {
                    $state.LastError = 'TCP accept error: ' + $_.Exception.Message
                    Add-RecentEvent -State $state -Message $state.LastError
                    Write-ServerEvent -Settings $Settings -State $state -Message $state.LastError
                }
            }

            for ($index = $tcpClients.Count - 1; $index -ge 0; $index--) {
                $clientState = $tcpClients[$index]
                try {
                    $idleMinutes = ((Get-Date) - $clientState.LastActivity).TotalMinutes
                    if ($idleMinutes -ge $script:TcpClientIdleTimeoutMinutes) {
                        if ($clientState.Buffer) {
                            Register-ReceivedMessage -Settings $Settings -State $state -Protocol 'TCP' -Address $clientState.Address -RawMessage $clientState.Buffer
                        }
                        Add-RecentEvent -State $state -Message ('TCP client idle timeout: {0}' -f $clientState.Address)
                        $clientState.Stream.Dispose()
                        $clientState.Client.Dispose()
                        $tcpClients.RemoveAt($index)
                        continue
                    }

                    if (Test-TcpClientClosed -TcpClient $clientState.Client) {
                        if ($clientState.Buffer) {
                            Register-ReceivedMessage -Settings $Settings -State $state -Protocol 'TCP' -Address $clientState.Address -RawMessage $clientState.Buffer
                        }
                        $clientState.Stream.Dispose()
                        $clientState.Client.Dispose()
                        $tcpClients.RemoveAt($index)
                        continue
                    }

                    if ($clientState.Stream.DataAvailable) {
                        $readBuffer = New-Object byte[] 4096
                        $bytesRead = $clientState.Stream.Read($readBuffer, 0, $readBuffer.Length)
                        if ($bytesRead -le 0) {
                            if ($clientState.Buffer) {
                                Register-ReceivedMessage -Settings $Settings -State $state -Protocol 'TCP' -Address $clientState.Address -RawMessage $clientState.Buffer
                            }
                            $clientState.Stream.Dispose()
                            $clientState.Client.Dispose()
                            $tcpClients.RemoveAt($index)
                            continue
                        }

                        $clientState.LastActivity = Get-Date
                        $clientState.Buffer += [Text.Encoding]::UTF8.GetString($readBuffer, 0, $bytesRead)
                        $parsed = Get-CompletedTcpMessages -Buffer $clientState.Buffer
                        foreach ($message in $parsed.Messages) {
                            Register-ReceivedMessage -Settings $Settings -State $state -Protocol 'TCP' -Address $clientState.Address -RawMessage $message
                        }
                        $clientState.Buffer = $parsed.Remaining
                    }
                }
                catch {
                    $state.LastError = 'TCP client error: ' + $_.Exception.Message
                    Add-RecentEvent -State $state -Message $state.LastError
                    Write-ServerEvent -Settings $Settings -State $state -Message $state.LastError
                    try {
                        if ($clientState.Buffer) {
                            Register-ReceivedMessage -Settings $Settings -State $state -Protocol 'TCP' -Address $clientState.Address -RawMessage $clientState.Buffer
                        }
                    }
                    catch {
                    }
                    try { $clientState.Stream.Dispose() } catch {}
                    try { $clientState.Client.Dispose() } catch {}
                    $tcpClients.RemoveAt($index)
                }
            }

            if (-not $verificationPromptShown) {
                $elapsed = (Get-Date) - $state.StartTime
                if (($null -eq $state.LastReceiveTime) -and $elapsed.TotalMinutes -ge 2) {
                    $verificationPromptShown = $true
                    $verifyChoice = Read-MenuChoice -Prompt 'No logs received after 2 minutes. Show verification steps now? [Y/n]' -ValidChoices @('Y', 'N') -DefaultChoice 'Y'
                    if ($verifyChoice -eq 'Y') {
                        Show-NoLogGuidance -Settings $Settings
                    }
                    Add-RecentEvent -State $state -Message 'No-log verification prompt was shown.'
                }
            }

            Start-Sleep -Milliseconds 200
        }
    }
    finally {
        foreach ($clientState in @($tcpClients)) {
            try {
                if ($clientState.Buffer) {
                    Register-ReceivedMessage -Settings $Settings -State $state -Protocol 'TCP' -Address $clientState.Address -RawMessage $clientState.Buffer
                }
            }
            catch {
            }
            try { $clientState.Stream.Dispose() } catch {}
            try { $clientState.Client.Dispose() } catch {}
        }

        if ($udpClient) {
            try { $udpClient.Dispose() } catch {}
        }
        if ($tcpListener) {
            try { $tcpListener.Stop() } catch {}
        }

        $state.Status = 'Stopped'
        $state.ForceRefresh = $true
        Write-ServerEvent -Settings $Settings -State $state -Message 'Listener stopped.'
    }
}

function Show-EnvironmentSummary {
    Clear-Host
    Write-UiLine $script:AppName Cyan
    Write-Host ('PowerShell:     {0}' -f $PSVersionTable.PSVersion)
    Write-Host ('Computer:       {0}' -f $env:COMPUTERNAME)
    Write-Host ('User:           {0}' -f $env:USERNAME)
    Write-Host ('Administrator:  {0}' -f $(if (Test-IsAdministrator) { 'Yes' } else { 'No' }))
    Write-Host ('Working dir:    {0}' -f (Get-Location).Path)
    Write-Host
    Write-UiLine 'Detected IPv4 addresses' Cyan
    $addresses = Get-LocalIpv4Addresses
    if ($addresses.Count -eq 0) {
        Write-Host 'No active IPv4 addresses detected.'
    }
    else {
        foreach ($entry in $addresses) {
            Write-Host ('{0}  ({1})' -f $entry.Address, $entry.Name)
        }
    }
    Pause-ForUser
}

function Show-DefaultSettingsMenu {
    while ($true) {
        $hostnameLookupDisplay = 'Disabled'
        if ($script:DefaultResolveHostNames) {
            $hostnameLookupDisplay = 'Enabled'
        }

        Clear-Host
        Write-TitleBlock -Title 'GW ROUTER LOGGER' -Subtitle 'Change defaults'
        Write-Host
        Write-Host ('1. Default UDP port:            {0}' -f $script:DefaultUdpPort)
        Write-Host ('2. Default TCP port:            {0}' -f $script:DefaultTcpPort)
        Write-Host ('3. Max compressed archive size: {0} MB' -f ([int]($script:MaxCompressedBytes / 1MB)))
        Write-Host ('4. Active log rotate size:      {0} MB' -f ([int]($script:ActiveLogRotateBytes / 1MB)))
        Write-Host ('5. Active log rotate age:       {0} minutes' -f $script:ActiveLogRotateMinutes)
        Write-Host ('6. Recent event lines shown:    {0}' -f $script:RecentEventsMax)
        Write-Host ('7. Hostname lookup default:     {0}' -f $hostnameLookupDisplay)
        Write-Host ('8. DNS lookup timeout:          {0} ms' -f $script:DnsLookupTimeoutMilliseconds)
        Write-Host ('9. TCP idle timeout:            {0} minutes' -f $script:TcpClientIdleTimeoutMinutes)
        Write-Host '10. Return to main menu'
        Write-Host

        $selection = Read-Host 'Choose a setting to change'
        switch ($selection) {
            '1' {
                $script:DefaultUdpPort = Read-ValidatedPort -Prompt 'Default UDP port' -Default $script:DefaultUdpPort
            }
            '2' {
                $script:DefaultTcpPort = Read-ValidatedPort -Prompt 'Default TCP port' -Default $script:DefaultTcpPort
            }
            '3' {
                $value = Read-ValidatedPositiveInt -Prompt 'Maximum compressed archive size in MB' -Default ([int]($script:MaxCompressedBytes / 1MB)) -Minimum 1
                $script:MaxCompressedBytes = $value * 1MB
            }
            '4' {
                $value = Read-ValidatedPositiveInt -Prompt 'Active log rotate size in MB' -Default ([int]($script:ActiveLogRotateBytes / 1MB)) -Minimum 1
                $script:ActiveLogRotateBytes = $value * 1MB
            }
            '5' {
                $script:ActiveLogRotateMinutes = Read-ValidatedPositiveInt -Prompt 'Active log rotate age in minutes' -Default $script:ActiveLogRotateMinutes -Minimum 1
            }
            '6' {
                $script:RecentEventsMax = Read-ValidatedPositiveInt -Prompt 'Recent event lines shown' -Default $script:RecentEventsMax -Minimum 3
            }
            '7' {
                $script:DefaultResolveHostNames = Read-BooleanChoice -Prompt 'Enable hostname lookup by default' -Default $script:DefaultResolveHostNames
            }
            '8' {
                $script:DnsLookupTimeoutMilliseconds = Read-ValidatedPositiveInt -Prompt 'DNS lookup timeout in milliseconds' -Default $script:DnsLookupTimeoutMilliseconds -Minimum 50
            }
            '9' {
                $script:TcpClientIdleTimeoutMinutes = Read-ValidatedPositiveInt -Prompt 'TCP idle timeout in minutes' -Default $script:TcpClientIdleTimeoutMinutes -Minimum 1
            }
            '10' {
                return
            }
            default {
                Write-UiLine 'Please choose a valid menu option.' Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Show-MainMenu {
    # The menu is intentionally simple and self-contained so new features can be added as
    # extra menu entries without changing the listener logic.
    while ($true) {
        Clear-Host
        Write-TitleBlock -Title 'GW ROUTER LOGGER' -Subtitle 'Menu-driven residential syslog server'
        Write-UiLine '  1. Start log listener' White
        Write-UiLine '  2. Change defaults' White
        Write-UiLine '  3. Open default log folder' White
        Write-UiLine '  4. Exit' White
        Write-Host

        $selection = Read-Host 'Choose an option'
        switch ($selection) {
            '1' {
                try {
                    $settings = Get-RunSettings
                    Start-LogServer -Settings $settings
                }
                catch {
                    Write-UiLine $_.Exception.Message Yellow
                    Pause-ForUser
                }
            }
            '2' {
                Show-DefaultSettingsMenu
            }
            '3' {
                $defaultLogRoot = Join-Path -Path (Get-ScriptRootPath) -ChildPath 'GW-ROUTER-LOGS'
                if ($script:LastSettings) {
                    $defaultLogRoot = $script:LastSettings.LogRoot
                }
                $settings = @{
                    LogRoot = $defaultLogRoot
                    SourceLogRoot = ''
                    ServerLogRoot = ''
                }
                Resolve-PreferredLogRoot -Settings $settings
                Start-Process -FilePath 'explorer.exe' -ArgumentList $settings.LogRoot | Out-Null
            }
            '4' {
                return
            }
            default {
                Write-UiLine 'Please choose 1, 2, 3, or 4.' Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

try {
    # Startup remains intentionally small: verify elevation, then hand off to the menu.
    Test-EnvironmentCompatibility

    if (-not (Ensure-Elevation)) {
        return
    }

    Show-StartupSplash
    Show-MainMenu
}
catch {
    Write-UiLine ('Fatal error: {0}' -f $_.Exception.Message) Red
    Pause-ForUser
}
