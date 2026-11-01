<#
.SYNOPSIS
  Drive the TrailMind iPhone build in WSL from Windows, then run scripts/ios-xtool.sh there.

.DESCRIPTION
  USB iPhones are reached through Apple's own Windows device service (the Apple Devices app, usbmuxd on
  127.0.0.1:27015) with WSL in mirrored networking mode. Forwarding the raw USB device into WSL with
  usbipd-win is not used: its packet timing makes the iPhone reject installs (dorssel/usbipd-win#867).

.EXAMPLE
  scripts\ios-wsl.ps1 setup
  scripts\ios-wsl.ps1 setup -XcodeXip C:\Users\me\Downloads\Xcode_27.1.xip
  scripts\ios-wsl.ps1 test -Filter ShellGeometryTests
  scripts\ios-wsl.ps1 auth             # one-time Apple ID sign-in for xtool (interactive)
  scripts\ios-wsl.ps1 devices          # list connected iPhones and their UDIDs
  scripts\ios-wsl.ps1 run -Udid 00008101-000455A21189001E
  scripts\ios-wsl.ps1 screenshot -Udid <UDID> -Display inner -Out .\inner.png   # iPhone Duo's open display
  scripts\ios-wsl.ps1 logs -Udid <UDID>
  scripts\ios-wsl.ps1 ship                                # App Store build, validated offline (no account needed)
  scripts\ios-wsl.ps1 ipa                                 # dist\TrailMind-<version>.ipa for testers to sideload (free)
  scripts\ios-wsl.ps1 ship -Upload -AscKeyId ABC123DEFG -AscIssuerId <issuer uuid> -AscKeyPath C:\keys\AuthKey_ABC123DEFG.p8
  scripts\ios-wsl.ps1 run-network -PhoneIp 192.168.68.12
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('setup', 'test', 'build', 'auth', 'devices', 'run', 'pair-network', 'run-network', 'screenshot', 'logs', 'ship', 'ipa')]
    [string]$Command,
    [string]$Distro = 'trailmind-ios',
    [string]$XcodeXip,
    [string]$PhoneIp,
    [string]$Udid,
    # test: only run tests whose name matches (swift test --filter)
    [string]$Filter,
    # screenshot: inner or outer (iPhone Duo), and the PNG to write; ipa: where to write the .ipa
    [string]$Display,
    [string]$Out,
    # ship: upload to App Store Connect for TestFlight, with an App Store Connect API key (or $env:ASC_KEY_ID,
    # $env:ASC_ISSUER_ID and $env:ASC_KEY_PATH)
    [switch]$Upload,
    [string]$AscKeyId = $env:ASC_KEY_ID,
    [string]$AscIssuerId = $env:ASC_ISSUER_ID,
    [string]$AscKeyPath = $env:ASC_KEY_PATH
)
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
$repo = Split-Path -Parent $PSScriptRoot

function ConvertTo-WslPath([string]$path) {
    $full = (Resolve-Path $path).Path
    '/mnt/' + $full.Substring(0, 1).ToLower() + ($full.Substring(2) -replace '\\', '/')
}

function Test-AppleMux {
    $c = New-Object Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', 27015); $true } catch { $false } finally { $c.Dispose() }
}

function Start-AppleMobileDevice {
    $config = Join-Path $env:USERPROFILE '.wslconfig'
    if (-not ((Test-Path $config) -and (Select-String -Path $config -Pattern '^\s*networkingMode\s*=\s*mirrored' -Quiet))) {
        throw "WSL must use mirrored networking to reach Apple's device service. Add 'networkingMode=mirrored' under [wsl2] in $config, then run: wsl --shutdown"
    }
    if (Test-AppleMux) { return }
    $pkg = Get-AppxPackage AppleInc.AppleDevices
    if (-not $pkg) { throw 'Install Apple Devices first: winget install --id 9NP83LWLPZ9K -s msstore' }
    # The package normally starts this at sign-in (a startup task); start it now if it is not running.
    Invoke-CommandInDesktopPackage -PackageFamilyName $pkg.PackageFamilyName -AppId App `
        -Command (Join-Path $pkg.InstallLocation 'AppleMobileDeviceLauncher.exe')
    foreach ($i in 1..30) { if (Test-AppleMux) { Start-Sleep 5; return }; Start-Sleep 1 }
    throw "Apple's device service did not start on 127.0.0.1:27015. Open the Apple Devices app and retry."
}

function Invoke-Script([string[]]$scriptArgs, [string]$prefix = '') {
    $script = (ConvertTo-WslPath (Join-Path $repo 'scripts\ios-xtool.sh'))
    wsl -d $Distro -- bash -lc "$prefix bash '$script' $($scriptArgs -join ' ')"
    if ($LASTEXITCODE) { throw "ios-xtool.sh $($scriptArgs -join ' ') failed ($LASTEXITCODE)" }
}

$udidArgs = if ($Udid) { @('--udid', $Udid) } else { @() }
switch ($Command) {
    'setup' {
        $prefix = if ($XcodeXip) { "XCODE_XIP='$(ConvertTo-WslPath $XcodeXip)'" } else { '' }
        Invoke-Script @('setup') $prefix
    }
    'auth' { Invoke-Script @('auth') }
    'test' { Invoke-Script (@('test') + $(if ($Filter) { @($Filter) } else { @() })) }
    'devices' { Start-AppleMobileDevice; Invoke-Script @('devices') }
    'pair-network' { Start-AppleMobileDevice; Invoke-Script @('pair-network') }
    'run' { Start-AppleMobileDevice; Invoke-Script (@('run') + $udidArgs) }
    'screenshot' {
        if (-not $Out) { throw '-Out <file.png> is required' }
        $full = [IO.Path]::GetFullPath($Out)
        $wslOut = '/mnt/' + $full.Substring(0, 1).ToLower() + ($full.Substring(2) -replace '\\', '/')
        $displayArgs = if ($Display) { @('--display', $Display) } else { @() }
        Start-AppleMobileDevice; Invoke-Script (@('screenshot') + $udidArgs + $displayArgs + @("'$wslOut'"))
    }
    'logs' { Start-AppleMobileDevice; Invoke-Script (@('logs') + $udidArgs) }
    'ship' {
        if (-not $Upload) { Invoke-Script @('ship'); break }
        if (-not ($AscKeyId -and $AscIssuerId -and $AscKeyPath)) {
            throw '-Upload needs -AscKeyId, -AscIssuerId and -AscKeyPath (or $env:ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH)'
        }
        $prefix = "ASC_KEY_ID='$AscKeyId' ASC_ISSUER_ID='$AscIssuerId' ASC_KEY_PATH='$(ConvertTo-WslPath $AscKeyPath)'"
        Invoke-Script @('ship', '--upload') $prefix
    }
    'ipa' {
        if ($Out) {
            $full = [IO.Path]::GetFullPath($Out)
            $wslOut = '/mnt/' + $full.Substring(0, 1).ToLower() + ($full.Substring(2) -replace '\\', '/')
            Invoke-Script @('ipa', "'$wslOut'")
        } else {
            Invoke-Script @('ipa')
        }
    }
    'run-network' {
        if (-not $PhoneIp) { throw '-PhoneIp is required' }
        Invoke-Script @('run-network', $PhoneIp)
    }
    default { Invoke-Script @($Command) }
}
