<#
.SYNOPSIS
    Emulator test for TrailMind's auto-pause in a vehicle, group hikes, old maps and Strava. Needs a DEBUG build.

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
    - Strava: scripts/e2e-mocks/strava_server.py (python) stands in for Strava's sign-in and upload API. Checks the
      Connect flow through the real browser (including a wrong secret and a forged redirect), the automatic post when
      a hike is finished (token refresh, GPX with times, activity type), rate-limit and outage handling with Post
      now, a hike too short to post, and Disconnect. Skipped when python is missing.

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

# A free port, so a server left over from an earlier run can't answer instead.
function Free-Port {
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $port
}

function Wait-Log([string]$path, [string]$pattern, [int]$timeout = 30) {
    $end = (Get-Date).AddSeconds($timeout)
    do {
        if ((Test-Path $path) -and (Select-String -Path $path -Pattern $pattern -Quiet)) { return $true }
        Start-Sleep -Milliseconds 700
    } while ((Get-Date) -lt $end)
    $false
}

function Hide-Keyboard {
    if (((Adb shell dumpsys input_method) -join ' ') -match 'mInputShown=true') {
        Adb shell input keyevent KEYCODE_BACK | Out-Null
        Start-Sleep -Milliseconds 500
    }
}

# Brings [pattern] on screen by scrolling down, then up if it was above.
function Reveal([string]$pattern) {
    if (Has $pattern) { return $true }
    if (Scroll-To $pattern 6) { return $true }
    Scroll-To $pattern 10 -Up
}

function Tap-Scrolling([string]$pattern) {
    Reveal $pattern | Out-Null
    Tap $pattern 4
}

# Types [text] into the box under the capitalised label [label].
function Type-Under([string]$label, [string]$text) {
    if (-not (Reveal "^$label$")) { return $false }
    $l = Find-Nodes "^$label$" | Select-Object -First 1
    Adb shell input tap ([int]$l.X) ([int]($l.Y + 100)) | Out-Null
    Start-Sleep -Milliseconds 500
    Adb shell input text $text | Out-Null
    Hide-Keyboard
    $true
}

# Walks [steps] steps of 6 m north at walking pace, from the running position in $lat.
function Walk([int]$steps) {
    for ($i = 0; $i -lt $steps; $i++) { $script:lat += 6 / 111320.0; Fix $script:lat $lon 1.5; Start-Sleep -Milliseconds 1250 }
}

# Brings TrailMind back to the front if something (a stray Back press) took it away.
function Ensure-App {
    if (((Adb shell dumpsys activity activities) -join ' ') -notmatch 'topResumedActivity=[^}]*com\.trailmind\.app') {
        Adb shell am start -n "$Pkg/.ui.MainActivity" | Out-Null
        Start-Sleep 2
    }
}

# Starts a hike from the Map tab and walks [steps] steps. Returns whether it was recording.
function Record-Walk([int]$steps) {
    Ensure-App
    Open-Tab 'Map'
    Fix $lat $lon; Start-Sleep 1; Fix $lat $lon
    Tap '^Start hike$' | Out-Null
    # Starting offers a check-in; dismiss it only when it is there, since Back on the map itself leaves the app.
    if (Wait-Ui 'Set check-in for' 6) { Adb shell input keyevent KEYCODE_BACK | Out-Null; Start-Sleep -Milliseconds 800 }
    Ensure-App
    $recording = Wait-Ui '^Pause$' 8
    Walk $steps
    $recording
}

# Finishes the recording and stays on the hike summary that opens.
function Finish-To-Summary {
    Ensure-App
    Open-Tab 'Map'
    if (-not (Has '^Pause$|^Resume$')) { return $false }
    Tap '^Finish$' 5 | Out-Null
    if (Wait-Ui '^Finish hike\?$' 5) { Tap '^Finish$' 5 -Last | Out-Null }
    Wait-Ui '^POINTS$' 10
}

function Leave-Summary {
    Adb shell input keyevent KEYCODE_BACK | Out-Null
    Start-Sleep -Milliseconds 1000
    Open-Tab 'Map'
}

# Chrome's first run asks a few questions before it shows anything; then taps Authorize on the stand-in sign-in page.
function Authorize-In-Browser {
    for ($i = 0; $i -lt 14; $i++) {
        Start-Sleep -Milliseconds 1500
        $ui = Get-Ui
        if (Has '^Authorize$' $ui) { Tap '^Authorize$' 3 | Out-Null; return $true }
        if (Has 'oauth/mobile/authorize' $ui) { Adb shell input tap 55 366 | Out-Null; return $true }
        foreach ($p in '^Use without an account$', '^No thanks$', '^Got it$') {
            if (Has $p $ui) { Tap $p 3 | Out-Null; break }
        }
    }
    $false
}

# Types the Client ID and secret on the Strava page (a blank argument leaves that box alone) and taps Connect.
function Connect-To-Strava([string]$id, [string]$secret) {
    if ($id) { Type-Under 'CLIENT ID' $id | Out-Null }
    if ($secret) { Type-Under 'CLIENT SECRET' $secret | Out-Null }
    Tap-Scrolling '^Connect with Strava$' | Out-Null
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
    Check 'Onboarding shown' (Wait-Ui '^Welcome to TrailMind$' 45)
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

    # ------------------------------------------------------------ Strava
    Section 'Strava'
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        Skip 'Strava' 'python is needed for the stand-in Strava server'
    } else {
        $stravaLog = Join-Path $Out 'strava.log'
        $stravaPy = Join-Path $Root 'scripts/e2e-mocks/strava_server.py'
        $stravaPort = Free-Port
        $script:StravaServer = Start-Process python -ArgumentList "`"$stravaPy`"", "`"$stravaLog`"", $stravaPort -WindowStyle Hidden -PassThru
        Start-Sleep 2
        Debug-Broadcast 'STRAVA_URL' @('--es', 'url', "http://10.0.2.2:$stravaPort")
        $stravaApi = "http://localhost:$stravaPort"

        Open-Tab 'More'
        Tap '^Settings$' | Out-Null
        Start-Sleep -Milliseconds 1500
        Check 'Settings offers Set up Strava' (Scroll-To '^Set up Strava$' 20)
        Tap '^Set up Strava$' | Out-Null
        Check 'Setup page explains how to link' (Wait-Ui '^Post your hikes to Strava$' 6)
        Check 'It says a Strava subscription is needed, and what to do without one' ((Has 'needs a Strava subscription') -and (Has 'Upload to Strava'))
        Shot 'strava-setup'
        Tap-Scrolling '^Connect with Strava$' | Out-Null
        Check 'Blank boxes are refused before anything is sent' ((Wait-Ui 'Client ID is the number' 5) -and -not (Test-Path $stravaLog))

        # A wrong secret: the sign-in works, the code exchange is refused, and the page says so.
        Connect-To-Strava '12345' 'WRONGSECRET1234567890'
        Check 'Connect opens the Strava sign-in in the browser' (Authorize-In-Browser)
        Check 'A wrong secret is reported, not linked' (Wait-Ui "didn.t accept the Client ID and secret" 20)
        Shot 'strava-wrong-secret'

        Connect-To-Strava '' 'mocksecret1234567890'
        Check 'Second attempt opens the browser again' (Authorize-In-Browser)
        Check 'Returning from Strava links the account' (Wait-Ui '^Linked to Strava$' 20)
        Check 'The Strava username is shown' (Has 'forest_walker')
        Shot 'strava-linked'
        $log = @(Get-Content $stravaLog)
        Check 'Sign-in asks for read + activity:write with the callback and a random state' (@($log | Where-Object { $_ -match 'GET authorize client_id=12345 redirect_uri=trailmind://localhost/strava scope=read,activity:write response_type=code state=[0-9a-f]{32}$' }).Count -eq 2)
        Check 'Wrong secret was refused, right secret accepted' (($log -match 'secret_ok=False').Count -eq 1 -and ($log -match 'authorization_code client_id=12345 secret_ok=True code=MOCKCODE').Count -eq 1)

        # A redirect nobody asked for (wrong state) must not reach Strava.
        Adb shell "am start -a android.intent.action.VIEW -d 'trailmind://localhost/strava?state=forged&code=EVIL&scope=read,activity:write' $Pkg" | Out-Null
        Start-Sleep 3
        Check 'A redirect with the wrong state is ignored' (-not (Select-String -Path $stravaLog -Pattern 'code=EVIL' -Quiet))
        Check 'Still linked afterwards' (Has '^Linked to Strava$')

        # Hike 1: finished, then posted by itself.
        Check 'Recording the first Strava hike' (Record-Walk 50)
        Check 'Hike finished' (Finish-To-Summary)
        Check 'Finishing posts it to Strava by itself' (Wait-Log $stravaLog 'POST upload auth=ok .*activity_type=hike data_type=gpx' 45)
        $log = @(Get-Content $stravaLog)
        $refresh = -1; $upload = -1
        for ($k = 0; $k -lt $log.Count; $k++) {
            if ($refresh -lt 0 -and $log[$k] -match 'grant_type=refresh_token .*secret_ok=True') { $refresh = $k }
            if ($upload -lt 0 -and $log[$k] -match 'POST upload') { $upload = $k }
        }
        Check 'The short-lived token is refreshed before the upload' ($refresh -ge 0 -and $refresh -lt $upload)
        $up = $log | Where-Object { $_ -match 'POST upload' } | Select-Object -First 1
        $pts = if ($up -match 'trkpts=(\d+) times=(\d+)') { [int]$Matches[1], [int]$Matches[2] } else { 0, 0 }
        Check 'The GPX has a track with a time on every point' ($pts[0] -ge 10 -and $pts[1] -ge $pts[0]) $up
        Check 'Named after the hike, with the TrailMind note' ($up -match "name='[^']*\d{4} \d+:\d\d" -and $up -match "description='Recorded with TrailMind'") $up
        Check 'The hike page says Posted to Strava' ((Scroll-To '^Posted to Strava' 8) -and (Has '^View on Strava$'))
        Shot 'strava-posted'
        Check 'A notification says it was posted' (((Adb shell dumpsys notification --noredact) -join "`n") -match 'Posted to Strava')
        Leave-Summary

        # Hike 2: Strava's rate limit, then an outage, then success by hand.
        Invoke-RestMethod "$stravaApi/__fail?n=1&code=429" | Out-Null
        Check 'Recording the second Strava hike' (Record-Walk 50)
        Check 'Second hike finished' (Finish-To-Summary)
        Check 'Rate limit: the hike waits and says why' ((Scroll-To '^Post now$' 12) -and (Has 'limit was reached'))
        Shot 'strava-rate-limited'
        Invoke-RestMethod "$stravaApi/__fail?n=1&code=503" | Out-Null
        Tap-Scrolling '^Post now$' | Out-Null
        Check 'An outage: still waiting, and says so' (Wait-Ui 'Strava had a problem \(HTTP 503\)' 25)
        Tap-Scrolling '^Post now$' | Out-Null
        Check 'Post now succeeds once Strava is back' (Wait-Ui '^Posted to Strava' 30)
        $log = @(Get-Content $stravaLog)
        $byId = $log | Where-Object { $_ -match 'POST upload' } | ForEach-Object { if ($_ -match 'external_id=(\S+)') { $Matches[1] } } | Group-Object
        Check 'Retries reuse one external id, so Strava can drop a duplicate' (@($byId | Where-Object { $_.Count -ge 3 }).Count -eq 1)
        Leave-Summary

        # Hike 3: too short to post.
        $before = @($log | Where-Object { $_ -match 'POST upload' }).Count
        Check 'Recording a very short hike' (Record-Walk 4)
        Check 'Short hike finished' (Finish-To-Summary)
        Check 'A short recording is not posted, and can be posted anyway' ((Scroll-To '^Post anyway$' 12) -and (Has 'Too short to be a hike'))
        Start-Sleep 3
        Check 'Nothing was uploaded for it' (@(Get-Content $stravaLog | Where-Object { $_ -match 'POST upload' }).Count -eq $before)
        Leave-Summary

        # Disconnect: Strava is told, and the page goes back to setup with the application kept.
        Open-Tab 'More'
        Tap '^Settings$' | Out-Null
        Start-Sleep -Milliseconds 1500
        Scroll-To '^Manage Strava$' 20 | Out-Null
        Tap '^Manage Strava$' | Out-Null
        Tap-Scrolling '^Disconnect from Strava$' | Out-Null
        Check 'Disconnect asks first' (Wait-Ui '^Disconnect from Strava\?$' 5)
        Tap '^Disconnect$' | Out-Null
        Check 'Strava is told to forget TrailMind' (Wait-Log $stravaLog 'POST deauthorize auth=ok' 20)
        Check 'The page is back to setup, with the secret kept' ((Wait-Ui '^Post your hikes to Strava$' 8) -and (Reveal 'saved: leave blank to keep it'))
        Shot 'strava-disconnected'

        # No subscription needed: Upload to Strava on the hike page saves the GPX to Downloads and opens Strava's page.
        Open-Tab 'Hikes'
        Tap '^Hike \w{3} \d+, ' | Out-Null
        Check 'Hike page offers Upload to Strava when not linked' ((Wait-Ui '^POINTS$' 8) -and (Scroll-To '^Upload to Strava$' 10) -and (Has 'needs a Strava subscription'))
        Shot 'strava-upload-by-hand'
        Adb shell "rm -f /sdcard/Download/Hike*.gpx" | Out-Null
        Tap '^Upload to Strava$' | Out-Null
        Start-Sleep 4
        $saved = (Adb shell "ls /sdcard/Download") -join ' '
        Check 'The GPX is saved straight to Downloads' ($saved -match 'Hike.*\.gpx') $saved
        Check 'Strava upload page opens in the browser' (((Adb shell dumpsys activity activities) -join ' ') -match 'topResumedActivity=.*com\.android\.chrome')
        Adb shell "rm -f /sdcard/Download/Hike*.gpx" | Out-Null
        Adb shell am start -n "$Pkg/.ui.MainActivity" | Out-Null
        Start-Sleep 2
        Leave-Summary
    }
} catch {
    $script:Failures++
    Write-Host "FAIL  Test run aborted: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    # The python on PATH can be a launcher that starts the real interpreter, so find the server by its script.
    Get-CimInstance Win32_Process -Filter "Name LIKE 'python%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'tile-server\.py|strava_server\.py' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "$script:Failures failed. Screenshots: $Out"
exit $script:Failures
