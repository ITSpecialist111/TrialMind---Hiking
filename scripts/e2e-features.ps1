<#
.SYNOPSIS
    Emulator test for TrailMind's auto-pause in a vehicle, group hikes and old maps. Needs a DEBUG build.

.DESCRIPTION
    Drives the real UI with adb and uiautomator on a phone emulator and prints PASS, FAIL or SKIP per check.
    The exit code is the number of failed checks. Screenshots go to the output folder.

    - Auto-pause: simulates a walk, then a drive, with 'adb emu geo fix' (speed included), and checks the hike
      pauses itself, leaves the drive out of the distance, and carries on after Resume.
    - Group hikes: the debug build's DebugReceiver stands in for the Bluetooth radio and plays a second member,
      Alex, whose sealed adverts go through the same code as real ones. Checks that this phone records when Alex
      starts a group hike, doesn't take it back after finishing, takes a new one, and asks first when told to.
    - Old maps: a small local tile server (python with Pillow) stands in for MapTiler, so the key flow, a rejected
      key, the fade overlay and the credit can be checked without a real key. Skipped when python or Pillow is
      missing.

    The run clears TrailMind's data on the emulator.

.EXAMPLE
    ./scripts/e2e-features.ps1 -SkipBuild
#>
param(
    [string]$Phone = 'emulator-5554',
    [switch]$SkipBuild,
    [string]$Out = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $PSScriptRoot
$Pkg = 'com.trailmind.app'
$Receiver = "$Pkg/.debug.DebugReceiver"
$Inv = [Globalization.CultureInfo]::InvariantCulture
if (-not $Out) { $Out = Join-Path $Root ('out-e2e/features-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
# The executable's full path: the bare name "adb" would find this script's own Adb function and call itself forever.
$onPath = Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$AdbExe = if ($onPath) { $onPath.Source } else { Join-Path $sdk 'platform-tools/adb' }
$script:Failures = 0
$script:Server = $null

function Section([string]$title) { Write-Host ''; Write-Host "== $title" -ForegroundColor Cyan }
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green }
    else { $script:Failures++; Write-Host "FAIL  $name $detail" -ForegroundColor Red }
}
function Skip([string]$name, [string]$why) { Write-Host "SKIP  $name ($why)" -ForegroundColor Yellow }

function Adb { & $AdbExe -s $Phone @args }

function Shot([string]$name) { & $AdbExe -s $Phone exec-out screencap -p > (Join-Path $Out "$name.png") }

function Get-Ui {
    Adb shell uiautomator dump /sdcard/ui.xml | Out-Null
    (Adb exec-out cat /sdcard/ui.xml) -join "`n"
}

# Nodes whose text or content-description matches [pattern], with the centre of their bounds. XML entities are decoded.
function Find-Nodes([string]$pattern, [string]$ui = $null) {
    if (-not $ui) { $ui = Get-Ui }
    foreach ($m in [regex]::Matches($ui, '<node [^>]*>')) {
        $n = $m.Value
        $t = [System.Net.WebUtility]::HtmlDecode([regex]::Match($n, ' text="([^"]*)"').Groups[1].Value)
        $d = [System.Net.WebUtility]::HtmlDecode([regex]::Match($n, ' content-desc="([^"]*)"').Groups[1].Value)
        if (($t -match $pattern) -or ($d -match $pattern)) {
            $b = [regex]::Match($n, 'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
            if ($b.Success) {
                [pscustomobject]@{
                    Text = if ($t) { $t } else { $d }
                    X = ([int]$b.Groups[1].Value + [int]$b.Groups[3].Value) / 2
                    Y = ([int]$b.Groups[2].Value + [int]$b.Groups[4].Value) / 2
                }
            }
        }
    }
}

function Has([string]$pattern, [string]$ui = $null) { [bool](Find-Nodes $pattern $ui) }

function Wait-Ui([string]$pattern, [int]$timeout = 10) {
    $end = (Get-Date).AddSeconds($timeout)
    do { if (Has $pattern) { return $true }; Start-Sleep -Milliseconds 600 } while ((Get-Date) -lt $end)
    $false
}

# Taps the first node matching [pattern], or the last one with -Last (a dialog button over a button of the same name).
function Tap([string]$pattern, [int]$timeout = 8, [switch]$Last) {
    $end = (Get-Date).AddSeconds($timeout)
    do {
        $nodes = @(Find-Nodes $pattern)
        if ($nodes.Count -gt 0) {
            $n = if ($Last) { $nodes[-1] } else { $nodes[0] }
            Adb shell input tap ([int]$n.X) ([int]$n.Y) | Out-Null
            return $true
        }
        Start-Sleep -Milliseconds 600
    } while ((Get-Date) -lt $end)
    $false
}

function Scroll-To([string]$pattern, [int]$swipes = 12, [switch]$Up) {
    for ($i = 0; $i -lt $swipes -and -not (Has $pattern); $i++) {
        if ($Up) { Adb shell input swipe 540 700 540 1800 250 } else { Adb shell input swipe 540 1700 540 800 300 }
        Start-Sleep -Milliseconds 700
    }
    Has $pattern
}

# The emulator console: lon lat alt satellites speed(m/s).
function Fix([double]$lat, [double]$lon, [double]$speed = -1) {
    $args2 = @('emu', 'geo', 'fix', $lon.ToString('F6', $Inv), $lat.ToString('F6', $Inv), '100')
    if ($speed -ge 0) { $args2 += @('12', $speed.ToString('F2', $Inv)) }
    Adb @args2 | Out-Null
}

function Debug-Broadcast([string]$action, [string[]]$extras = @()) { Adb shell am broadcast -n $Receiver -a "com.trailmind.app.debug.$action" @extras | Out-Null }

function Group-State {
    Adb logcat -c | Out-Null
    Debug-Broadcast 'GROUP_STATE'
    Start-Sleep -Milliseconds 800
    $line = (Adb logcat -d -s TrailMindDebug) | Select-String 'ownFlags' | Select-Object -Last 1
    if ($line) { $line.Line } else { '' }
}

function Open-Tab([string]$label) { Tap "^$label$" | Out-Null; Start-Sleep -Milliseconds 1200 }

# Finishes the recording through the confirmation, then leaves the hike summary that opens, and returns to the Map tab
# (finishing a hike opens the Hikes tab).
function Finish-Hike {
    Open-Tab 'Map'
    if (-not (Has '^Pause$|^Resume$')) { return }
    Tap '^Finish$' 5 | Out-Null
    if (Wait-Ui '^Finish hike\?$' 5) { Tap '^Finish$' 5 -Last | Out-Null }
    if (Wait-Ui '^POINTS$' 8) { Adb shell input keyevent KEYCODE_BACK | Out-Null; Start-Sleep -Milliseconds 1000 }
    Open-Tab 'Map'
}

function Recording-Distance {
    $n = Find-Nodes '^\d+(\.\d+)? (m|km)$' | Where-Object { $_.Y -gt 1500 } | Select-Object -First 1
    if ($n) { $n.Text }
}

function To-Metres([string]$text) {
    if ($text -match '^([\d.]+) km$') { return [double]::Parse($Matches[1], $Inv) * 1000 }
    if ($text -match '^([\d.]+) m$') { return [double]::Parse($Matches[1], $Inv) }
    $null
}

# ---------------------------------------------------------------- run

try {
    Section 'Setup'
    if (((& $AdbExe devices) -join "`n") -notmatch "(?m)^$([regex]::Escape($Phone))\s+device\b") { throw "$Phone is not attached." }
    if ($Phone -notmatch '^emulator-') { throw 'These tests need an emulator: GPS is simulated with adb emu geo fix.' }
    if (-not $SkipBuild) {
        $gradlew = Join-Path $Root $(if ($env:OS -eq 'Windows_NT') { 'gradlew.bat' } else { 'gradlew' })
        & $gradlew -p $Root ':app:assembleDebug' --console=plain -q
        if ($LASTEXITCODE -ne 0) { throw 'Gradle build failed.' }
    }
    $apk = Join-Path $Root 'app/build/outputs/apk/debug/app-debug.apk'
    foreach ($scale in 'window_animation_scale', 'transition_animation_scale', 'animator_duration_scale') { Adb shell settings put global $scale 0 | Out-Null }
    Adb shell input keyevent KEYCODE_WAKEUP | Out-Null
    Adb shell wm dismiss-keyguard | Out-Null
    $r = (Adb install -r $apk) -join ' '
    Check 'Install the debug build' ($r -match 'Success') $r
    Adb shell am force-stop $Pkg | Out-Null
    Adb shell pm clear $Pkg | Out-Null
    foreach ($perm in 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION', 'POST_NOTIFICATIONS', 'BLUETOOTH_SCAN', 'BLUETOOTH_ADVERTISE', 'BLUETOOTH_CONNECT') {
        Adb shell pm grant $Pkg "android.permission.$perm" | Out-Null
    }
    # Forest of Dean, near Parkend.
    $lat = 51.7890; $lon = -2.5500
    Fix $lat $lon
    Adb shell am start -W -n "$Pkg/.ui.MainActivity" | Out-Null
    Check 'Onboarding shown' (Wait-Ui '^Welcome to TrailMind$' 20)
    Scroll-To '^I understand' | Out-Null
    Tap '^I understand' | Out-Null
    Check 'Map with Start hike' (Wait-Ui '^Start hike$' 10)
    Fix $lat $lon; Start-Sleep 2; Fix $lat $lon

    # ------------------------------------------------------------ auto-pause
    Section 'Auto-pause in a vehicle'
    $m = 1 / 111320.0
    Tap '^Start hike$' | Out-Null
    Start-Sleep 2
    Adb shell input keyevent KEYCODE_BACK | Out-Null   # the check-in sheet
    Check 'Recording after Start hike' (Wait-Ui '^Pause$' 8)
    for ($i = 0; $i -lt 15; $i++) { $lat += 6 * $m; Fix $lat $lon 1.5; Start-Sleep -Milliseconds 1900 }
    $walked = To-Metres (Recording-Distance)
    Check 'Walking 90 m is recorded' ($walked -ge 80 -and $walked -le 100) "recorded $walked m"
    $paused = $false
    for ($i = 0; $i -lt 28 -and -not $paused; $i++) {
        $lat += 28 * $m; Fix $lat $lon 14; Start-Sleep -Milliseconds 1700
        if ($i -ge 12 -and $i % 3 -eq 0) { $paused = [bool]((Adb shell dumpsys notification --noredact) | Select-String 'Hike paused: looks like') }
    }
    Check 'Drive pauses the hike and notifies' $paused
    Start-Sleep 2
    $ui = Get-Ui
    Shot 'auto-pause'
    Check 'Recording card shows Paused and Resume' ((Has '^PAUSED$' $ui) -and (Has '^Resume$' $ui))
    $afterDrive = To-Metres (Recording-Distance)
    Check 'The drive is left out of the distance' ($afterDrive -le $walked + 15) "distance $afterDrive m after the drive, $walked m before"
    Check 'Notification offers Resume and Finish' ((((Adb shell dumpsys notification --noredact) -join "`n") -match 'Resume') -and (((Adb shell dumpsys notification --noredact) -join "`n") -match 'Finish'))
    Tap '^Resume$' | Out-Null
    Start-Sleep 2
    for ($i = 0; $i -lt 10; $i++) { $lat += 6 * $m; Fix $lat $lon 1.5; Start-Sleep -Milliseconds 1900 }
    $resumed = To-Metres (Recording-Distance)
    Check 'Resume records again, without a line across the drive' ($resumed -ge $walked + 45 -and $resumed -le $walked + 75) "distance $resumed m"
    Check 'Pause notification is cleared' (-not (((Adb shell dumpsys notification --noredact) -join "`n") -match 'looks like you'))
    Finish-Hike
    Shot 'hike-finished'
    Check 'Hike finished' (-not (Has '^Pause$|^Resume$') -and (Has '^Start hike$'))

    # ------------------------------------------------------------ group hikes
    Section 'Group hikes'
    Adb logcat -c | Out-Null
    Debug-Broadcast 'GROUP_CREATE' @('--es', 'name', 'Forest')
    Start-Sleep 2
    $state = Group-State
    Check 'Trip group created' ($state -match 'group=Forest') $state
    Debug-Broadcast 'GROUP_PEER' @('--ei', 'id', '20481', '--es', 'name', 'Alex', '--ei', 'flags', '5')
    Start-Sleep 3
    Fix $lat $lon; Start-Sleep 2; Fix ($lat + 4 * $m) $lon; Start-Sleep 2
    $state = Group-State
    Check 'Alex starts a group hike: this phone records too' ($state -match 'recording=true') $state
    Check 'This phone says it is recording a group hike (flags 5)' ($state -match 'ownFlags=5') $state
    Shot 'group-auto'
    Finish-Hike
    Start-Sleep 1
    Debug-Broadcast 'GROUP_PEER' @('--ei', 'id', '20481', '--es', 'name', 'Alex', '--ei', 'flags', '5')
    Start-Sleep 5
    $state = Group-State
    Check 'After finishing, Alex still hiking is not offered back' ($state -match 'recording=false') $state
    Debug-Broadcast 'GROUP_PEER' @('--ei', 'id', '20481', '--es', 'name', 'Alex', '--ei', 'flags', '0')
    Start-Sleep 2.2
    Debug-Broadcast 'GROUP_PEER' @('--ei', 'id', '20481', '--es', 'name', 'Alex', '--ei', 'flags', '5')
    Start-Sleep 3
    Fix $lat $lon; Start-Sleep 2
    $state = Group-State
    Check 'A new hike by Alex is taken' ($state -match 'recording=true') $state
    Finish-Hike

    # Ask first: Safety > Open trip group > Ask me before recording a group hike.
    Open-Tab 'More'
    Tap '^Safety' | Out-Null
    Start-Sleep -Milliseconds 1500
    Scroll-To '^Open trip group$' 20 | Out-Null
    Tap '^Open trip group$' | Out-Null
    Check 'Trip group page has Group hikes' (Scroll-To '^Group hikes$' 12)
    Check 'Ask-before-recording switch' (Tap 'Ask me before recording')
    Shot 'group-hikes-card'
    Adb shell input keyevent KEYCODE_BACK | Out-Null
    Open-Tab 'Map'
    Debug-Broadcast 'GROUP_PEER' @('--ei', 'id', '20481', '--es', 'name', 'Alex', '--ei', 'flags', '0')
    Start-Sleep 2.2
    Debug-Broadcast 'GROUP_PEER' @('--ei', 'id', '20481', '--es', 'name', 'Alex', '--ei', 'flags', '5')
    Check 'Asked first: "Alex started a group hike"' (Wait-Ui '^Alex started a group hike$' 6)
    Shot 'group-ask'
    Tap '^Not now$' | Out-Null
    Start-Sleep 1
    Debug-Broadcast 'GROUP_PEER' @('--ei', 'id', '20481', '--es', 'name', 'Alex', '--ei', 'flags', '5')
    Start-Sleep 6
    Check 'Not now is not asked again for the same hike' (-not (Has '^Alex started a group hike$'))
    Debug-Broadcast 'GROUP_PEER' @('--ei', 'id', '20481', '--es', 'name', 'Alex', '--ei', 'flags', '0')
    Start-Sleep 2.2
    Debug-Broadcast 'GROUP_PEER' @('--ei', 'id', '20481', '--es', 'name', 'Alex', '--ei', 'flags', '5')
    Check 'A later hike is asked about again' (Wait-Ui '^Alex started a group hike$' 6)
    Tap '^Start my hike$' | Out-Null
    Start-Sleep 3
    Fix $lat $lon; Start-Sleep 2
    $state = Group-State
    Check 'Start my hike records' ($state -match 'recording=true') $state
    Finish-Hike

    # ------------------------------------------------------------ old maps
    Section 'Old maps'
    $python = Get-Command python -ErrorAction SilentlyContinue
    $pillow = $false
    if ($python) { & python -c 'import PIL' 2>$null; $pillow = ($LASTEXITCODE -eq 0) }
    if (-not $pillow) {
        Skip 'Old maps' 'python with Pillow is needed for the stand-in tile server'
    } else {
        $serverLog = Join-Path $Out 'tiles.log'
        $serverPy = Join-Path $Out 'tile-server.py'
        # A free port, so a server left over from an earlier run can't answer instead.
        $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, 0)
        $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
        @'
import io, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from PIL import Image, ImageDraw
LOG = sys.argv[1]
def tile(name, z, x, y):
    img = Image.new("RGB", (256, 256), (214, 190, 140))
    d = ImageDraw.Draw(img)
    for i in range(0, 256, 32):
        d.line([(i, 0), (i, 255)], fill=(150, 120, 80)); d.line([(0, i), (255, i)], fill=(150, 120, 80))
    d.rectangle([0, 0, 255, 255], outline=(110, 70, 40), width=3)
    d.ellipse([100, 100, 156, 156], outline=(90, 40, 30), width=4)
    d.text((8, 8), f"OLD MAP {name} z{z}/{x}/{y}", fill=(70, 30, 20))
    out = io.BytesIO(); img.save(out, "JPEG"); return out.getvalue()
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path); m = re.fullmatch(r"/tiles/([\w-]+)/(\d+)/(\d+)/(\d+)\.jpg", u.path)
        key = parse_qs(u.query).get("key", [""])[0]
        status = 404 if not m else (403 if key != "TESTKEY" else 200)
        open(LOG, "a").write(f"{status} {u.path} key={key}\n")
        if status != 200:
            self.send_response(status); self.end_headers(); return
        body = tile(m.group(1), *map(int, m.groups()[1:]))
        self.send_response(200); self.send_header("Content-Type", "image/jpeg"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
ThreadingHTTPServer(("0.0.0.0", int(sys.argv[2])), H).serve_forever()
'@ | Set-Content -Path $serverPy -Encoding utf8
        $script:Server = Start-Process python -ArgumentList $serverPy, $serverLog, $port -WindowStyle Hidden -PassThru
        Start-Sleep 2
        Debug-Broadcast 'OLD_MAPS_URL' @('--es', 'url', "http://10.0.2.2:$port/tiles")

        Tap 'Map layers' | Out-Null
        Start-Sleep -Milliseconds 1200
        Tap '^Old maps$' | Out-Null
        Check 'Old maps lists the six-inch first, for the Forest of Dean' ((Wait-Ui '^OS six-inch 1888' 6) -and (Has '^Forest of Dean$'))
        Check 'No key: asks for a MapTiler key' (Has 'No MapTiler key yet')
        Shot 'old-maps-dialog'
        Tap '^OS six-inch 1888' | Out-Null
        Check 'Choosing a map without a key explains the key' (Wait-Ui '^MapTiler key needed$' 5)
        Tap '^Add key$' | Out-Null
        Start-Sleep 2
        $field = Find-Nodes '^MapTiler key$' | Select-Object -First 1
        Scroll-To '^MapTiler key$' 8 | Out-Null
        $field = Find-Nodes '^MapTiler key$' | Select-Object -First 1
        Adb shell input tap ([int]$field.X) ([int]$field.Y) | Out-Null
        Adb shell input text BADKEY | Out-Null
        Adb shell input keyevent KEYCODE_BACK | Out-Null
        Scroll-To 'Save & test' 4 | Out-Null
        $save = @(Find-Nodes '^Save & test$') | Sort-Object Y | Select-Object -Last 1
        Adb shell input tap ([int]$save.X) ([int]$save.Y) | Out-Null
        Check 'A rejected key is reported' (Wait-Ui 'Key rejected \(HTTP 403\)' 10)
        $field = Find-Nodes '^BADKEY$' | Select-Object -First 1
        Adb shell input tap ([int]$field.X) ([int]$field.Y) | Out-Null
        Adb shell input keyevent KEYCODE_MOVE_END | Out-Null
        1..10 | ForEach-Object { Adb shell input keyevent KEYCODE_DEL | Out-Null }
        Adb shell input text TESTKEY | Out-Null
        Adb shell input keyevent KEYCODE_BACK | Out-Null
        $save = @(Find-Nodes '^Save & test$') | Sort-Object Y | Select-Object -Last 1
        Adb shell input tap ([int]$save.X) ([int]$save.Y) | Out-Null
        Check 'A working key is accepted' (Wait-Ui 'Key works' 10)
        Adb shell input keyevent KEYCODE_BACK | Out-Null
        Start-Sleep 1
        Adb shell am start -n "$Pkg/.ui.MainActivity" | Out-Null
        Start-Sleep 2
        Fix $lat $lon
        Open-Tab 'Map'
        Tap 'Map layers' | Out-Null
        Start-Sleep -Milliseconds 1200
        Tap '^Old maps$' | Out-Null
        Check 'With a key the banner is gone' ((Wait-Ui '^Forest of Dean$' 5) -and -not (Has 'No MapTiler key yet'))
        Tap '^Forest of Dean$' | Out-Null
        Check 'Forest of Dean button shows the six-inch over the map' (Wait-Ui 'OS six-inch 1888.* 55%' 10)
        Start-Sleep 6
        Shot 'old-map-55'
        $log = if (Test-Path $serverLog) { Get-Content $serverLog } else { @() }
        Check 'Tiles come from the Forest of Dean (zoom 14, x 8074-8077)' (@($log | Where-Object { $_ -match '^200 /tiles/uk-osgb10k1888/14/80(7\d)/54\d\d\.jpg key=TESTKEY' }).Count -ge 4) "$($log.Count) requests"
        Check 'The key is sent to the tile service only as key=' (@($log | Where-Object { $_ -match '^200 ' }).Count -gt 0)
        # The credit is drawn on the map, so read it from the dialog the credit opens.
        Adb shell input tap 300 1850 | Out-Null
        Check 'Credit to the National Library of Scotland and MapTiler on the map' (Wait-Ui 'Old map: Ordnance Survey via National Library of Scotland' 5)
        Tap '^Close$' 3 | Out-Null
        Tap '^OS six-inch 1888.* 55%$' | Out-Null
        Check 'The chip reopens Old maps' (Wait-Ui '^Done$' 5)
        $ui = Get-Ui
        $bar = [regex]::Match($ui, 'class="android.widget.SeekBar"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
        if ($bar.Success) {
            Adb shell input tap ([int]$bar.Groups[3].Value - 40) ([int](([int]$bar.Groups[2].Value + [int]$bar.Groups[4].Value) / 2)) | Out-Null
            Check 'Slider sets the fade to 100 %' (Wait-Ui 'showing: 100%' 4)
        } else { Check 'Slider present' $false }
        Tap '^Done$' | Out-Null
        Start-Sleep 2
        Shot 'old-map-100'
        Check 'Chip shows 100 %' (Has 'OS six-inch 1888.* 100%')
    }
} catch {
    $script:Failures++
    Write-Host "FAIL  Test run aborted: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    # The python on PATH can be a launcher that starts the real interpreter, so find the server by its script.
    Get-CimInstance Win32_Process -Filter "Name LIKE 'python%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'tile-server\.py' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "$script:Failures failed. Screenshots: $Out"
exit $script:Failures
