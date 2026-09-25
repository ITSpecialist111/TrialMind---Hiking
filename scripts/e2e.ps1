<#
.SYNOPSIS
    End-to-end test for TrailMind on emulators: the phone app and, optionally, the Wear OS companion.

.DESCRIPTION
    Drives the real UI with adb and uiautomator while simulating a walk from Glenridding towards Helvellyn
    with GPS fixes, and prints PASS, FAIL or SKIP for each check. Screenshots, UI dumps, the exported GPX,
    logcat and results.csv are saved to the output folder. The exit code is the number of failed checks.

    Needs adb on PATH and a phone emulator. GPS is simulated with 'adb emu geo fix', so real devices are
    not supported. -Watch needs a Wear OS emulator that is already paired with the phone over Bluetooth
    (see README). The run clears TrailMind's data on every device it tests.

    OS maps are tested when an OS Data Hub key is available: -OsKey, else TRAILMIND_OS_KEY, else
    trailmind.osApiKey in local.properties (which git ignores). The key is typed into the app's Settings.

.EXAMPLE
    ./scripts/e2e.ps1

.EXAMPLE
    ./scripts/e2e.ps1 -Phone emulator-5554 -Watch emulator-5556 -SkipBuild
#>
param(
    [string]$Phone = 'emulator-5554',
    [string]$Watch = '',
    [switch]$SkipBuild,
    [string]$Out = '',
    [string]$OsKey = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $PSScriptRoot
$Pkg = 'com.trailmind.app'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Up = [char]0x2191
if (-not $OsKey) { $OsKey = $env:TRAILMIND_OS_KEY }
$localProps = Join-Path $Root 'local.properties'
if (-not $OsKey -and (Test-Path $localProps)) {
    $m = Select-String -Path $localProps -Pattern '^\s*trailmind\.osApiKey\s*=\s*(\S+)' | Select-Object -First 1
    if ($m) { $OsKey = $m.Matches[0].Groups[1].Value }
}
if (-not $Out) { $Out = Join-Path $Root ('out-e2e/' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Results = New-Object System.Collections.Generic.List[object]
$consoleEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

# ---------------------------------------------------------------- reporting

function Section([string]$title) { Write-Host ''; Write-Host "== $title" -ForegroundColor Cyan }

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $result = if ($ok) { 'PASS' } else { 'FAIL' }
    $Results.Add([pscustomobject]@{ Result = $result; Check = $name; Detail = $detail })
    $line = "$result  $name"
    if ($detail) { $line += "  ($detail)" }
    Write-Host $line -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}

function Skip([string]$name, [string]$why) {
    $Results.Add([pscustomobject]@{ Result = 'SKIP'; Check = $name; Detail = $why })
    Write-Host "SKIP  $name  ($why)" -ForegroundColor DarkYellow
}

# ---------------------------------------------------------------- adb and UI helpers

# Adb <serial> <args...>. Parameters are not declared so that arguments such as -r or -d pass straight through.
# The executable is called by path: PowerShell names are case-insensitive, so 'adb' here would mean this function.
$AdbExe = (Get-Command adb -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
function Adb {
    $serial, $rest = $args
    & $AdbExe -s $serial @rest 2>&1 | ForEach-Object { "$_" }
}

function Get-Ui([string]$s) {
    $local = Join-Path $Out ('ui-' + ($s -replace '[^\w]', '_') + '.xml')
    for ($try = 0; $try -lt 6; $try++) {
        $o = (Adb $s shell uiautomator dump /sdcard/tm-ui.xml) -join ' '
        if ($o -match 'dumped to') {
            Adb $s pull /sdcard/tm-ui.xml $local | Out-Null
            try { return [xml](Get-Content -Raw -Encoding UTF8 -Path $local) } catch { }
        }
        Start-Sleep -Milliseconds 700
    }
    $null
}

function Find-Nodes([string]$s, [string]$pattern, [switch]$TextOnly) {
    $ui = Get-Ui $s
    if (-not $ui) { return }
    foreach ($n in $ui.SelectNodes('//node')) {
        $t = $n.GetAttribute('text'); $d = $n.GetAttribute('content-desc')
        if (($t -and $t -match $pattern) -or (-not $TextOnly -and $d -and $d -match $pattern)) { $n }
    }
}

function Get-Center($node) {
    if ($node.GetAttribute('bounds') -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
        [int](([int]$Matches[1] + [int]$Matches[3]) / 2)
        [int](([int]$Matches[2] + [int]$Matches[4]) / 2)
    }
}

function Tap([string]$s, [string]$pattern, [int]$timeout = 8, [switch]$TextOnly) {
    $end = (Get-Date).AddSeconds($timeout)
    do {
        $n = @(Find-Nodes $s $pattern -TextOnly:$TextOnly)
        if ($n.Count) {
            $c = @(Get-Center $n[0])
            Adb $s shell input tap $c[0] $c[1] | Out-Null
            Start-Sleep -Milliseconds 800
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $end)
    Write-Host "      could not find /$pattern/ on $s" -ForegroundColor DarkYellow
    $false
}

function Wait-Ui([string]$s, [string]$pattern, [int]$timeout = 10) {
    $end = (Get-Date).AddSeconds($timeout)
    do {
        if (@(Find-Nodes $s $pattern).Count) { return $true }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $end)
    $false
}

function Wait-Until([scriptblock]$condition, [int]$timeout = 10) {
    $end = (Get-Date).AddSeconds($timeout)
    do {
        if (& $condition) { return $true }
        Start-Sleep -Milliseconds 700
    } while ((Get-Date) -lt $end)
    $false
}

# The value shown under a stat label (labels come first in TrailMind's stat tiles).
function Get-StatValue([string]$s, [string]$label) {
    $ui = Get-Ui $s
    if (-not $ui) { return $null }
    $next = $false
    foreach ($n in $ui.SelectNodes('//node')) {
        $t = $n.GetAttribute('text')
        if ($next -and $t) { return $t }
        if ($t -eq $label) { $next = $true }
    }
    $null
}

# Swipes the widest scrollable view until something matching the pattern is on screen.
function ScrollTo([string]$s, [string]$pattern, [int]$swipes = 10) {
    for ($i = 0; $i -le $swipes; $i++) {
        $ui = Get-Ui $s
        if (-not $ui) { return $false }
        $box = $null; $width = 0
        foreach ($n in $ui.SelectNodes('//node')) {
            $t = $n.GetAttribute('text'); $d = $n.GetAttribute('content-desc')
            if (($t -and $t -match $pattern) -or ($d -and $d -match $pattern)) { return $true }
            if ($n.GetAttribute('scrollable') -eq 'true' -and $n.GetAttribute('bounds') -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
                $w = [int]$Matches[3] - [int]$Matches[1]
                if ($w -gt $width) { $width = $w; $box = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4]) }
            }
        }
        if (-not $box) { return $false }
        $x = [int](($box[0] + $box[2]) / 2); $h = $box[3] - $box[1]
        Adb $s shell input swipe $x ([int]($box[1] + $h * 0.75)) $x ([int]($box[1] + $h * 0.3)) 400 | Out-Null
        Start-Sleep -Milliseconds 700
    }
    $false
}

# Bottom navigation (phone layout) has no Settings or Offline tab; those are under More.
function OpenTab([string]$name) {
    if (@(Find-Nodes $Phone "^$name$").Count) { return (Tap $Phone "^$name$") }
    if (Tap $Phone '^More$' 3) { return (Tap $Phone "^$name$") }
    $false
}

# Captures the display that is switched on (a folded Fold has two, and the inner one is then off).
function Shot([string]$s, [string]$name) {
    $viewports = (Adb $s shell dumpsys display) -join "`n"
    $m = [regex]::Match($viewports, "isActive=true[^}]*?uniqueId='local:(\d+)'")
    $display = if ($m.Success) { @('-d', $m.Groups[1].Value) } else { @() }
    Adb $s shell screencap -p @display /sdcard/tm-shot.png | Out-Null
    Adb $s pull /sdcard/tm-shot.png (Join-Path $Out "$name.png") | Out-Null
}

# Percentage of a 30 x 30 grid over the map area that is not the map's empty background, rgb(238, 241, 234). The map
# fills the right of the screen in both layouts; the band sampled avoids the route card, the buttons and the scale bar.
function Get-MapCoverage([string]$png) {
    if (-not (Test-Path $png)) { return 0 }
    Add-Type -AssemblyName System.Drawing
    $img = [Drawing.Bitmap]::FromFile($png)
    try {
        $drawn = 0
        for ($i = 0; $i -lt 30; $i++) {
            for ($j = 0; $j -lt 30; $j++) {
                $c = $img.GetPixel([int]($img.Width * (0.58 + 0.3 * $i / 29)), [int]($img.Height * (0.36 + 0.38 * $j / 29)))
                if (-not ($c.R -eq 238 -and $c.G -eq 241 -and $c.B -eq 234)) { $drawn++ }
            }
        }
        [int](100 * $drawn / 900)
    } finally { $img.Dispose() }
}

function Get-AppNotifications([string]$s) {
    $lines = @(Adb $s shell dumpsys notification --noredact)
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s+Notification List:') { $start = $i + 1; break } }
    if ($start -lt 0) { return }
    $end = $lines.Count
    for ($i = $start; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^  \S') { $end = $i; break } }
    if ($end -le $start) { return }
    $seen = @{}
    $section = ($lines[$start..($end - 1)] -join "`n") -replace "`r", ''
    foreach ($b in ($section -split 'NotificationRecord\(')) {
        if ($b -notmatch "pkg=$([regex]::Escape($Pkg))\s") { continue }
        $id = if ($b -match '\sid=(-?\d+)') { $Matches[1] } else { '?' }
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        [pscustomobject]@{
            Id      = $id
            Title   = $(if ($b -match 'android\.title=String \((.*?)\)\n') { $Matches[1] } else { '' })
            Text    = $(if ($b -match 'android\.text=String \((.*?)\)\n') { $Matches[1] } else { '' })
            Actions = @([regex]::Matches($b, '\[\d+\] "([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
        }
    }
}

function Get-TrackingNotification {
    Get-AppNotifications $Phone | Where-Object { $_.Title -in 'Recording hike', 'Hike paused' } | Select-Object -First 1
}

function ToMetres([string]$text) {
    if ($text -match '(\d+(?:\.\d+)?) (km|m)\b') {
        $v = [double]::Parse($Matches[1], $Inv)
        if ($Matches[2] -eq 'km') { $v * 1000 } else { $v }
    }
}

# Distance in the tracking notification, which refreshes on a GPS fix at most every 5 s.
function Get-RecordedMetres { $n = Get-TrackingNotification; if ($n) { ToMetres $n.Text } }

function Test-Tracking { ((Adb $Phone shell dumpsys activity services $Pkg) -join "`n") -match 'location\.TrackingService' }

function Get-ResumedActivity {
    foreach ($l in (Adb $Phone shell dumpsys activity activities)) {
        if ($l -match 'topResumedActivity=ActivityRecord\{(\S+) \S+ (\S+)') { return "$($Matches[2])#$($Matches[1])" }
    }
    $null
}

# ---------------------------------------------------------------- simulated GPS

function Dist($a, $b) {
    $r = 6371000.0
    $p1 = $a[0] * [Math]::PI / 180; $p2 = $b[0] * [Math]::PI / 180
    $dp = $p2 - $p1; $dl = ($b[1] - $a[1]) * [Math]::PI / 180
    $h = [Math]::Sin($dp / 2) * [Math]::Sin($dp / 2) + [Math]::Cos($p1) * [Math]::Cos($p2) * [Math]::Sin($dl / 2) * [Math]::Sin($dl / 2)
    2 * $r * [Math]::Asin([Math]::Sqrt($h))
}

function Bearing($a, $b) {
    $p1 = $a[0] * [Math]::PI / 180; $p2 = $b[0] * [Math]::PI / 180; $dl = ($b[1] - $a[1]) * [Math]::PI / 180
    $y = [Math]::Sin($dl) * [Math]::Cos($p2)
    $x = [Math]::Cos($p1) * [Math]::Sin($p2) - [Math]::Sin($p1) * [Math]::Cos($p2) * [Math]::Cos($dl)
    ([Math]::Atan2($y, $x) * 180 / [Math]::PI + 360) % 360
}

function Offset($p, [double]$bearing, [double]$metres) {
    $b = $bearing * [Math]::PI / 180
    , @(($p[0] + $metres * [Math]::Cos($b) / 111320), ($p[1] + $metres * [Math]::Sin($b) / (111320 * [Math]::Cos($p[0] * [Math]::PI / 180))), $p[2])
}

function Length($points) { $m = 0.0; for ($i = 0; $i -lt $points.Count - 1; $i++) { $m += Dist $points[$i] $points[$i + 1] }; $m }

# The emulator takes an ellipsoidal altitude; TrailMind shows height above sea level, about 53 m lower here.
# The barometer reads what that height gives on a 1003 hPa day, so an uncalibrated altimeter would be ~85 m high.
$Qnh = 1003.0
# The emulators' default magnetic field is not the Earth's, which TrailMind rightly reports as interference.
# This is the Lake District's (50 microtesla dipping 69 degrees) for the emulators' default upright pose.
$EarthField = '0:-48.02:13.97'
function Fix($p) {
    $script:LastFix = $p
    Adb $Phone emu geo fix $p[1].ToString('F6', $Inv) $p[0].ToString('F6', $Inv) ($p[2] + 53).ToString('F1', $Inv) | Out-Null
    $hpa = $Qnh * [Math]::Pow(1 - $p[2] / 44330.77, 5.255877)
    Adb $Phone emu sensor set pressure $hpa.ToString('F2', $Inv) | Out-Null
    # The phone emulator does not keep this setting, so it goes with every fix.
    Adb $Phone emu sensor set magnetic-field $EarthField | Out-Null
}

function Walk($points, [double]$interval = 2.1) { foreach ($p in $points) { Fix $p; Start-Sleep -Milliseconds ([int]($interval * 1000)) } }

# Repeats a fix so the tracking notification (5 s refresh) catches up.
function Hold($p, [int]$times = 3) { for ($i = 0; $i -lt $times; $i++) { Fix $p; Start-Sleep -Milliseconds 2100 } }

# Glenridding to Helvellyn via Striding Edge: 73 points, 4.85 km, 800 m of ascent, 3 waypoints.
$legs = @(
    @(54.5436, -2.9506, 150.0), @(54.5418, -2.9636, 200.0), @(54.5373, -2.9684, 260.0), @(54.5311, -2.9868, 700.0),
    @(54.5283, -2.9952, 750.0), @(54.5264, -3.0055, 863.0), @(54.5271, -3.0164, 950.0))
$route = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $legs.Count - 1; $i++) {
    $a = $legs[$i]; $b = $legs[$i + 1]
    for ($k = 0; $k -lt 12; $k++) {
        $f = $k / 12
        $route.Add(@(($a[0] + ($b[0] - $a[0]) * $f), ($a[1] + ($b[1] - $a[1]) * $f), ($a[2] + ($b[2] - $a[2]) * $f)))
    }
}
$route.Add($legs[-1])

# The walk: the route resampled to a fix every 35 m or less.
$Dense = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $route.Count - 1; $i++) {
    $a = $route[$i]; $b = $route[$i + 1]
    $n = [Math]::Max(1, [Math]::Ceiling((Dist $a $b) / 35))
    for ($k = 0; $k -lt $n; $k++) {
        $f = $k / $n
        $Dense.Add(@(($a[0] + ($b[0] - $a[0]) * $f), ($a[1] + ($b[1] - $a[1]) * $f), ($a[2] + ($b[2] - $a[2]) * $f)))
    }
}
$Dense.Add($route[$route.Count - 1])

$trkpts = ($route | ForEach-Object {
        '      <trkpt lat="{0}" lon="{1}"><ele>{2}</ele></trkpt>' -f $_[0].ToString('F6', $Inv), $_[1].ToString('F6', $Inv), $_[2].ToString('F1', $Inv)
    }) -join "`n"
$gpxText = @"
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="TrailMind E2E" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata><name>Helvellyn via Striding Edge</name></metadata>
  <wpt lat="54.528300" lon="-2.995200"><ele>750</ele><name>Hole-in-the-Wall</name></wpt>
  <wpt lat="54.526400" lon="-3.005500"><ele>863</ele><name>Striding Edge</name></wpt>
  <wpt lat="54.527100" lon="-3.016400"><ele>950</ele><name>Helvellyn summit</name></wpt>
  <trk><name>Helvellyn via Striding Edge</name><trkseg>
$trkpts
  </trkseg></trk>
</gpx>
"@

# ---------------------------------------------------------------- the run

try {
    Section 'Setup'
    $attached = (& $AdbExe devices) -join "`n"
    foreach ($d in @($Phone, $Watch) | Where-Object { $_ }) {
        if ($attached -notmatch "(?m)^$([regex]::Escape($d))\s+device\b") { throw "$d is not attached. Start it and check 'adb devices'." }
    }
    if ($Phone -notmatch '^emulator-') { throw "$Phone is not an emulator. GPS is simulated with 'adb emu geo fix', which needs one." }
    if ($Watch) { Adb $Watch emu sensor set magnetic-field $EarthField | Out-Null }

    if (-not $SkipBuild) {
        $gradlew = Join-Path $Root $(if ($env:OS -eq 'Windows_NT') { 'gradlew.bat' } else { 'gradlew' })
        $tasks = @(':app:assembleDebug')
        if ($Watch) { $tasks += ':wear:assembleDebug' }
        Write-Host "Building $($tasks -join ' ')"
        & $gradlew -p $Root @tasks --console=plain -q
        if ($LASTEXITCODE -ne 0) { throw 'Gradle build failed.' }
    }
    $phoneApk = Join-Path $Root 'app/build/outputs/apk/debug/app-debug.apk'
    $watchApk = Join-Path $Root 'wear/build/outputs/apk/debug/wear-debug.apk'

    Adb $Phone shell input keyevent KEYCODE_WAKEUP | Out-Null
    Adb $Phone shell wm dismiss-keyguard | Out-Null
    $foldable = ((Adb $Phone emu unfold) -join ' ') -match '\bOK\b'
    $r = (Adb $Phone install -r $phoneApk) -join ' '
    Check 'Install the phone app' ($r -match 'Success') $(if ($r -notmatch 'Success') { $r })
    Adb $Phone shell am force-stop $Pkg | Out-Null
    Adb $Phone shell pm clear $Pkg | Out-Null
    foreach ($perm in 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION', 'POST_NOTIFICATIONS', 'BLUETOOTH_CONNECT') {
        Adb $Phone shell pm grant $Pkg "android.permission.$perm" | Out-Null
    }
    Adb $Phone logcat -b all -c | Out-Null

    Section 'First launch and GPS'
    Fix $Dense[0]
    Adb $Phone shell am start -W -n "$Pkg/.ui.MainActivity" | Out-Null
    Check 'Safety onboarding on first launch' (Wait-Ui $Phone '^Welcome to TrailMind$' 20)
    Shot $Phone '01-onboarding'
    ScrollTo $Phone '^I understand' | Out-Null
    Tap $Phone '^I understand' | Out-Null
    Check 'Map with Start hike after onboarding' (Wait-Ui $Phone '^Start hike$' 10)
    Hold $Dense[0] 2
    Check 'GPS fix shown as an OS grid reference' (Wait-Ui $Phone 'NY 38\d 1[67]\d' 15)

    Section 'Barometer'
    Tap $Phone 'NY 38\d 1[67]\d' | Out-Null
    Hold $Dense[0] 2
    Check 'Pressure and trend on the Safety page' (Wait-Ui $Phone 'Pressure \d+ hPa' 10)
    Check 'Barometric altitude calibrated to GPS (150 m, not ~235 m)' (Wait-Ui $Phone '\b1[45]\d m \(barometric\)' 10)
    Shot $Phone '01b-safety'
    OpenTab 'Map' | Out-Null

    Section 'Route import'
    $gpxLocal = Join-Path $Out 'trailmind-e2e.gpx'
    [IO.File]::WriteAllText($gpxLocal, $gpxText, (New-Object System.Text.UTF8Encoding $false))
    Adb $Phone push $gpxLocal /sdcard/Download/trailmind-e2e.gpx | Out-Null
    Adb $Phone shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Download/trailmind-e2e.gpx | Out-Null
    OpenTab 'Routes' | Out-Null
    Tap $Phone '^Import$' | Out-Null
    $inPicker = Wait-Ui $Phone '^trailmind-e2e\.gpx$' 10
    if (-not $inPicker -and (Tap $Phone '^Show roots$' 3)) {
        Tap $Phone '^Downloads$' 3 | Out-Null
        $inPicker = Wait-Ui $Phone '^trailmind-e2e\.gpx$' 8
    }
    Check 'GPX offered by the system file picker' $inPicker
    Tap $Phone '^trailmind-e2e\.gpx$' | Out-Null
    Check "Imported route stats (4.85 km, $($Up)800 m)" ((Wait-Ui $Phone '^4\.85 km$' 15) -and (Wait-Ui $Phone "^$($Up)800 m$" 3))
    Shot $Phone '02-route'

    Section 'Route guidance'
    Tap $Phone '^Follow route$' | Out-Null
    OpenTab 'Map' | Out-Null
    Check 'Guidance to the first waypoint' (Wait-Ui $Phone '^Next: Hole-in-the-Wall in ' 10)

    Section 'Recording'
    Tap $Phone '^Start hike$' | Out-Null
    Check 'Pause and Finish controls while recording' ((Wait-Ui $Phone '^Pause$' 10) -and (Wait-Ui $Phone '^Finish$' 2))
    $n = Get-TrackingNotification
    Check 'Tracking notification with Pause and Finish actions' ($n -and $n.Title -eq 'Recording hike' -and $n.Actions -contains 'Pause' -and $n.Actions -contains 'Finish')
    Walk $Dense[1..40]
    Hold $Dense[40] 3
    $walked = Length $Dense[0..40]
    $rec = Get-RecordedMetres
    Check 'Recorded distance matches the walk' ($rec -and $rec -ge 0.8 * $walked -and $rec -le 1.1 * $walked) ('recorded {0:N0} m, walked {1:N0} m' -f $rec, $walked)
    Shot $Phone '03-recording'

    Section 'Off-route alert'
    $base = $Dense[40]
    $side = (Bearing $Dense[39] $Dense[41]) + 90
    Walk (@(40, 80, 120, 150, 150, 150, 150) | ForEach-Object { Offset $base $side $_ })
    $alert = @(Get-AppNotifications $Phone | Where-Object { $_.Title -eq 'Off route' })
    Check 'Off-route notification after 150 m off the line' ($alert.Count -gt 0) $(if ($alert.Count) { $alert[0].Text })
    Check 'Off-route warning on the map' (Wait-Ui $Phone '^Off route by ' 5)
    Shot $Phone '04-off-route'
    Walk (@(100, 50, 10, 0, 0, 0) | ForEach-Object { Offset $base $side $_ })
    $alert = @(Get-AppNotifications $Phone | Where-Object { $_.Title -eq 'Off route' })
    Check 'Off-route notification cleared after rejoining' ($alert.Count -eq 0)

    Section 'Pause and resume'
    Hold $base 3
    $before = Get-RecordedMetres
    Tap $Phone '^Pause$' | Out-Null
    Start-Sleep -Seconds 2
    $n = Get-TrackingNotification
    Check 'Paused: notification offers Resume' ($n -and $n.Title -eq 'Hike paused' -and $n.Actions -contains 'Resume')
    Check 'Paused: Resume control on the map' (Wait-Ui $Phone '^Resume$' 5)
    Walk $Dense[41..45]
    Tap $Phone '^Resume$' | Out-Null
    Hold $Dense[45] 3
    $n = Get-TrackingNotification
    Check 'Resumed: notification offers Pause' ($n -and $n.Title -eq 'Recording hike' -and $n.Actions -contains 'Pause')
    $after = Get-RecordedMetres
    Check 'Distance moved while paused is not counted' ($null -ne $before -and $null -ne $after -and ($after - $before) -lt 25) ('{0:N0} m before, {1:N0} m after' -f $before, $after)
    Walk $Dense[46..55]
    Hold $Dense[55] 3

    Section 'Finish and GPX export'
    Tap $Phone '^Finish$' | Out-Null
    if (Wait-Ui $Phone '^Finish hike\?$' 5) { Tap $Phone '^Finish$' -TextOnly | Out-Null }
    Check 'Hike summary after finishing' (Wait-Ui $Phone '^Points$' 10)
    Check 'Tracking service stopped' (Wait-Until { -not (Test-Tracking) } 10)
    $summary = ToMetres (Get-StatValue $Phone 'Distance')
    Check 'Summary distance' ($summary -gt 1000) ('{0:N0} m' -f $summary)
    Shot $Phone '05-summary'
    Adb $Phone shell touch /sdcard/Download/.tm-marker | Out-Null
    Start-Sleep -Seconds 1
    Tap $Phone '^Save GPX$' | Out-Null
    if (Wait-Ui $Phone '^(SAVE|Save)$' 10) { Tap $Phone '^(SAVE|Save)$' -TextOnly | Out-Null }
    $saved = $null
    Wait-Until {
        $script:saved = @(Adb $Phone shell find /sdcard/Download -name '*.gpx' -newer /sdcard/Download/.tm-marker) | Where-Object { $_ -match '\.gpx$' } | Select-Object -First 1
        [bool]$script:saved
    } 10 | Out-Null
    $gpxOut = Join-Path $Out 'exported-hike.gpx'
    $content = ''
    # The picker creates the file before the app has written it.
    if ($saved) {
        Wait-Until {
            Adb $Phone pull $saved $gpxOut | Out-Null
            $script:content = [string](Get-Content -Raw -Encoding UTF8 -Path $gpxOut -ErrorAction SilentlyContinue)
            $script:content.TrimEnd().EndsWith('</gpx>')
        } 10 | Out-Null
    }
    $pts = ([regex]::Matches($content, '<trkpt ')).Count
    $segs = ([regex]::Matches($content, '<trkseg>')).Count
    $times = ([regex]::Matches($content, '<time>')).Count
    Check 'GPX saved through the system picker' ([bool]$saved) $(if ($saved) { $saved })
    Check 'GPX has timed points and a new segment after the pause' ($pts -ge 30 -and $segs -ge 2 -and $times -ge $pts) "$pts points, $segs segments"

    Section 'Fold and unfold while recording'
    if (-not $foldable) {
        Skip 'Fold and unfold' 'the phone emulator is not foldable'
    } else {
        OpenTab 'Map' | Out-Null
        Tap $Phone '^Start hike$' | Out-Null
        Walk $Dense[56..60]
        Hold $Dense[60] 3
        $d0 = Get-RecordedMetres
        $activity = Get-ResumedActivity
        Adb $Phone emu fold | Out-Null
        Start-Sleep -Seconds 3
        Adb $Phone shell input keyevent KEYCODE_WAKEUP | Out-Null
        Adb $Phone shell wm dismiss-keyguard | Out-Null
        Start-Sleep -Seconds 2
        Check 'Folded: cover screen uses the phone layout' (Wait-Ui $Phone '^More$' 10)
        Check 'Folded: same activity, no restart' ($activity -and (Get-ResumedActivity) -eq $activity) $activity
        Shot $Phone '06-folded'
        Walk $Dense[61..66]
        Hold $Dense[66] 3
        # The notification refreshes every 5 s, and the emulator's fixes can pause briefly after a fold.
        $d1 = $null
        Wait-Until { $script:d1 = Get-RecordedMetres; $null -ne $script:d1 -and $script:d1 -gt $d0 + 100 } 15 | Out-Null
        Check 'Folded: recording continues' ($null -ne $d0 -and $d1 -gt $d0 + 100) ('{0:N0} m -> {1:N0} m' -f $d0, $d1)
        Adb $Phone emu unfold | Out-Null
        Start-Sleep -Seconds 3
        Check 'Unfolded: inner screen uses the tablet layout' (Wait-Ui $Phone '^Settings$' 10)
        Check 'Unfolded: same activity, no restart' ((Get-ResumedActivity) -eq $activity)
        Shot $Phone '07-unfolded'

        Tap $Phone '^Full-screen map$' | Out-Null
        Check 'Full-screen map hides the rail and side pane' ((Wait-Ui $Phone '^Exit full-screen map$' 5) -and @(Find-Nodes $Phone '^Settings$').Count -eq 0)
        Check 'Full-screen map keeps the recording controls' (Wait-Ui $Phone '^Pause$' 2)
        Shot $Phone '07b-full-screen'
        Adb $Phone emu fold | Out-Null
        Start-Sleep -Seconds 3
        Adb $Phone shell input keyevent KEYCODE_WAKEUP | Out-Null
        Adb $Phone shell wm dismiss-keyguard | Out-Null
        Check 'Folded from full-screen: cover screen layout unchanged' (Wait-Ui $Phone '^More$' 10)
        Adb $Phone emu unfold | Out-Null
        Start-Sleep -Seconds 3
        Check 'Unfolded again: full-screen map restored' ((Wait-Ui $Phone '^Exit full-screen map$' 10) -and @(Find-Nodes $Phone '^Settings$').Count -eq 0)
        Adb $Phone shell input keyevent KEYCODE_BACK | Out-Null
        Check 'Back leaves full-screen map' (Wait-Ui $Phone '^Settings$' 5)

        Tap $Phone '^Finish$' | Out-Null
        if (Wait-Ui $Phone '^Finish hike\?$' 5) { Tap $Phone '^Finish$' -TextOnly | Out-Null }
        Check 'Second hike finished' (Wait-Until { -not (Test-Tracking) } 10)
    }

    Section 'OS maps'
    if (-not $OsKey) {
        Skip 'OS maps' 'no OS Data Hub key (trailmind.osApiKey in local.properties, or TRAILMIND_OS_KEY)'
    } elseif ($OsKey -notmatch '^[A-Za-z0-9]{16,64}$') {
        Skip 'OS maps' 'the OS Data Hub key should be 16-64 letters and digits'
    } else {
        OpenTab 'Settings' | Out-Null
        ScrollTo $Phone '^Save & test$' | Out-Null
        # 'input text' can drop characters, so type the key in short pieces and read the field back.
        $entered = $false
        for ($try = 0; $try -lt 3 -and -not $entered; $try++) {
            $ui = Get-Ui $Phone
            $field = if ($ui) { @($ui.SelectNodes("//node[@class='android.widget.EditText']")) | Select-Object -First 1 }
            if (-not $field) { break }
            $c = @(Get-Center $field)
            Adb $Phone shell input tap $c[0] $c[1] | Out-Null
            Adb $Phone shell input keyevent KEYCODE_MOVE_END | Out-Null
            Adb $Phone shell input keyevent @(1..70 | ForEach-Object { 'KEYCODE_DEL' }) | Out-Null
            foreach ($piece in [regex]::Matches($OsKey, '.{1,8}')) { Adb $Phone shell input text $piece.Value | Out-Null }
            $ui = Get-Ui $Phone
            $field = if ($ui) { @($ui.SelectNodes("//node[@class='android.widget.EditText']")) | Select-Object -First 1 }
            $entered = [bool]$field -and $field.GetAttribute('text') -ceq $OsKey
        }
        Tap $Phone '^Save & test$' | Out-Null
        Check 'OS key accepted (Settings, Save & test)' (Wait-Ui $Phone 'Key works' 20) $(if (-not $entered) { 'the key field did not read back as typed' })
        $freePlan = Wait-Ui $Phone 'free OS OpenData plan' 1

        OpenTab 'Map' | Out-Null
        Tap $Phone '^Map layers$' | Out-Null
        Tap $Phone '^OS Maps . Outdoor' -TextOnly | Out-Null
        $cachedZooms = { @(Adb $Phone shell run-as $Pkg find cache/tiles/os_outdoor -name '*.tile') | ForEach-Object { if ($_ -match 'os_outdoor/(\d+)/\d+/\d+\.tile$') { [int]$Matches[1] } } }
        Check 'OS Outdoor OpenData tiles load' (Wait-Until { @(& $cachedZooms | Where-Object { $_ -le 16 }).Count -gt 0 } 20)
        Shot $Phone '08-os-outdoor'

        $premium = $false
        for ($i = 0; $i -lt 4 -and -not $premium; $i++) {
            Tap $Phone '^Zoom in$' 3 | Out-Null
            $premium = Wait-Until { @(& $cachedZooms | Where-Object { $_ -ge 17 }).Count -gt 0 } 8
        }
        if ($freePlan) {
            Check 'Free plan: zoom 17+ enlarges zoom 16 instead of fetching Premium tiles' (-not $premium)
        } else {
            Check 'OS Premium tiles (zoom 17+) load' $premium
        }
        Shot $Phone '09-os-zoom17'

        # Plant a 2-day-old tile at a Premium zoom and at an OpenData zoom, then restart so the purge runs.
        $old = (Get-Date).AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ss')
        $p17 = 'cache/tiles/os_outdoor/17/0/0.tile'; $p16 = 'cache/tiles/os_outdoor/16/0/0.tile'
        Adb $Phone shell run-as $Pkg sh -c "'mkdir -p cache/tiles/os_outdoor/17/0 cache/tiles/os_outdoor/16/0 && echo x > $p17 && echo x > $p16 && touch -d $old $p17 $p16'" | Out-Null
        Adb $Phone shell am force-stop $Pkg | Out-Null
        Adb $Phone shell am start -W -n "$Pkg/.ui.MainActivity" | Out-Null
        Start-Sleep -Seconds 8
        $state = (Adb $Phone shell run-as $Pkg sh -c "'for f in $p17 $p16; do if [ -e `$f ]; then echo KEPT:`$f; else echo GONE:`$f; fi; done'") -join ' '
        Check 'Premium tiles older than 24 h purged, OpenData tiles kept' ($state -match 'GONE:\S*17/0/0' -and $state -match 'KEPT:\S*16/0/0') $state

        # Offline, zooming past everything on the phone should enlarge the closest cached zoom, not show a blank map.
        OpenTab 'Settings' | Out-Null
        ScrollTo $Phone '^Offline only' | Out-Null
        Tap $Phone '^Offline only' | Out-Null
        OpenTab 'Map' | Out-Null
        Adb $Phone logcat -b main -c | Out-Null
        # Eight steps reach the deepest zoom from anywhere a restart leaves the map; only zoom 16-18 are cached.
        for ($i = 0; $i -lt 8; $i++) { Tap $Phone '^Zoom in$' 3 | Out-Null }
        Start-Sleep -Seconds 3
        Shot $Phone '09b-offline-enlarged'
        $coverage = Get-MapCoverage (Join-Path $Out '09b-offline-enlarged.png')
        $enlarged = @(Adb $Phone logcat -d -s TileProvider:D | Where-Object { $_ -match 'showing a lower zoom enlarged' }).Count
        Check 'Offline past the cached zooms: a lower zoom is enlarged, not a blank map' ($enlarged -gt 0 -and $coverage -ge 50) "$enlarged tiles enlarged, $coverage% of the map area drawn"
        OpenTab 'Settings' | Out-Null
        ScrollTo $Phone '^Offline only' | Out-Null
        Tap $Phone '^Offline only' | Out-Null
    }

    Section 'Find routes online'
    OpenTab 'Routes' | Out-Null
    Tap $Phone '^Find$' | Out-Null
    Check 'Waymarked routes listed near the GPS fix' (Wait-Ui $Phone '^Coast to Coast Walk$' 25)
    Shot $Phone '10-find-routes'
    $ui = Get-Ui $Phone
    $field = if ($ui) { @($ui.SelectNodes("//node[@class='android.widget.EditText']")) | Select-Object -First 1 }
    if ($field) {
        $c = @(Get-Center $field)
        Adb $Phone shell input tap $c[0] $c[1] | Out-Null
        Adb $Phone shell input text 'ullswater' | Out-Null
        Adb $Phone shell input keyevent KEYCODE_ENTER | Out-Null
    }
    Check 'Route search by name' (Wait-Ui $Phone '^The Ullswater Way$' 20)
    Tap $Phone '^The Ullswater Way$' | Out-Null
    $added = Wait-Ui $Phone '^Naismith$' 60
    $dist = if ($added) { ToMetres (Get-StatValue $Phone 'Distance') }
    $high = if ($added) { ToMetres (Get-StatValue $Phone 'Highest') }
    Check 'Found route added with its line and heights' ($dist -ge 30000 -and $dist -le 40000 -and $high -ge 400 -and $high -le 520) ('{0:N0} m long, highest {1:N0} m' -f $dist, $high)
    Shot $Phone '11-found-route'

    Section 'Watch companion'
    if (-not $Watch) {
        Skip 'Watch companion' 'no -Watch serial given'
    } else {
        $r = (Adb $Watch install -r $watchApk) -join ' '
        Check 'Install the watch app' ($r -match 'Success') $(if ($r -notmatch 'Success') { $r })
        Adb $Watch shell am force-stop $Pkg | Out-Null
        Adb $Watch shell pm clear $Pkg | Out-Null
        foreach ($perm in 'BLUETOOTH_CONNECT', 'POST_NOTIFICATIONS') { Adb $Watch shell pm grant $Pkg "android.permission.$perm" | Out-Null }
        Adb $Watch logcat -b all -c | Out-Null
        # A sleeping watch swallows the first touch and stops the app; keep it awake for the test.
        Adb $Watch shell svc power stayon true | Out-Null
        Adb $Watch shell input keyevent KEYCODE_WAKEUP | Out-Null
        $watchName = ((Adb $Watch shell settings get secure bluetooth_name) -join '').Trim()
        $nameRx = [regex]::Escape($watchName)

        OpenTab 'Settings' | Out-Null
        Check 'Watch companion setting' (ScrollTo $Phone '^Connect to my watch$')
        Tap $Phone '^Connect to my watch$' | Out-Null
        $listed = ScrollTo $Phone "^$nameRx$"
        Check 'Paired watch listed' $listed "Bluetooth name '$watchName'"
        Tap $Phone "^$nameRx$" | Out-Null
        Check 'Phone ready for the watch' (Wait-Ui $Phone '^Ready . open TrailMind on the watch\.$' 10)

        Adb $Watch shell am start -n "$Pkg/com.trailmind.wear.WatchActivity" | Out-Null
        Check 'Watch connects over Bluetooth' (Wait-Ui $Phone "^Connected to $nameRx\.$" 60)
        Check 'Watch navigation page points to the next waypoint' (Wait-Ui $Watch '^Hole-in-the-Wall$' 20)
        Check 'Watch navigation page shows heading and scale' (Wait-Ui $Watch '^(\d{1,3}\u00B0 [NESW]{1,3}|North up) . [\d.]+ k?m$' 5)
        Start-Sleep -Seconds 2
        Shot $Watch '08-watch-navigate'

        # The link must survive the phone app going to the background and the watch screen going off.
        $linkLost = 'Connecting to your phone|reach TrailMind on your phone'
        Adb $Phone shell input keyevent KEYCODE_HOME | Out-Null
        Start-Sleep -Seconds 5
        $services = (Adb $Phone shell dumpsys activity services $Pkg) -join "`n"
        Check 'Phone app in the background: watch link service keeps running' ($services -match 'watch\.WatchLinkService')
        Check 'Phone app in the background: watch stays connected' ((Wait-Ui $Watch '^Hole-in-the-Wall$' 10) -and @(Find-Nodes $Watch $linkLost).Count -eq 0)
        Adb $Watch shell input keyevent KEYCODE_SLEEP | Out-Null
        Start-Sleep -Seconds 15
        Adb $Watch shell input keyevent KEYCODE_WAKEUP | Out-Null
        Adb $Watch shell am start -n "$Pkg/com.trailmind.wear.WatchActivity" | Out-Null
        $services = (Adb $Watch shell dumpsys activity services $Pkg) -join "`n"
        Check 'Watch screen off and on: link kept, data back at once' (($services -match 'LinkService') -and (Wait-Ui $Watch '^Hole-in-the-Wall$' 4) -and @(Find-Nodes $Watch $linkLost).Count -eq 0)
        Adb $Phone shell am start -n "$Pkg/.ui.MainActivity" | Out-Null
        Start-Sleep -Seconds 2

        $size = (Adb $Watch shell wm size) -join ' '
        $w = 454; $h = 454
        if ($size -match '(\d+)x(\d+)') { $w = [int]$Matches[1]; $h = [int]$Matches[2] }
        $swipeUp = { Adb $Watch shell input swipe ([int]($w / 2)) ([int]($h * 0.8)) ([int]($w / 2)) ([int]($h * 0.2)) 150 | Out-Null }
        $onHikePage = $false
        for ($i = 0; $i -lt 3 -and -not $onHikePage; $i++) {
            & $swipeUp
            $onHikePage = Wait-Ui $Watch '^Start hike$' 4
        }
        Check 'Swipe up to the watch Hike page' $onHikePage
        Tap $Watch '^Start hike$' | Out-Null
        $started = Wait-Until { Test-Tracking } 10
        Check 'Hike started from the watch' $started
        if ($started) {
            # Carry on from the phone's last position. A jump would be dropped as a GPS glitch.
            $from = 0; $best = [double]::MaxValue
            for ($i = 0; $i -lt $Dense.Count; $i++) { $d = Dist $Dense[$i] $LastFix; if ($d -lt $best) { $best = $d; $from = $i } }
            $leg = @($Dense[$from..[Math]::Min($from + 10, $Dense.Count - 1)])
            Walk $leg[1..($leg.Count - 1)]
            Hold $leg[-1] 2
            $walked = Length $leg
            $watchM = $null
            $shown = Wait-Until {
                $n = @(Find-Nodes $Watch "^[\d.]+ k?m . $($Up)\d+ m$") | Select-Object -First 1
                $script:watchM = if ($n) { ToMetres $n.GetAttribute('text') }
                $script:watchM -ge 0.8 * $walked -and $script:watchM -le 1.1 * $walked
            } 15
            Shot $Watch '09-watch-hike'
            Check 'Watch shows the distance walked' $shown ('watch {0:N0} m, walked {1:N0} m' -f $watchM, $walked)

            Tap $Watch '^Retrace$' | Out-Null
            $backM = $null
            $back = Wait-Until {
                $script:backM = ToMetres (Get-StatValue $Watch 'Start of hike')
                $script:backM -ge 0.8 * $walked -and $script:backM -le 1.1 * $walked
            } 15
            Check 'Retrace from the watch leads back along the breadcrumbs' $back ('{0:N0} m back to the start' -f $backM)
            Shot $Watch '10-watch-retrace'

            $finish = @()
            for ($i = 0; $i -lt 3 -and $finish.Count -eq 0; $i++) {
                & $swipeUp
                Start-Sleep -Milliseconds 600
                $finish = @(Find-Nodes $Watch '^Finish$')
            }
            if ($finish.Count) {
                $c = @(Get-Center $finish[0])
                Adb $Watch shell input tap $c[0] $c[1] | Out-Null
                Start-Sleep -Milliseconds 900
                Adb $Watch shell input tap $c[0] $c[1] | Out-Null
            }
            Check 'Hike finished from the watch (Finish, then Confirm)' (Wait-Until { -not (Test-Tracking) } 10)
        }
        Adb $Watch shell svc power stayon false | Out-Null
    }

    Section 'Stability'
    foreach ($d in @($Phone, $Watch) | Where-Object { $_ }) {
        $crashes = @(Adb $d logcat -d -b crash | Where-Object { $_ -match [regex]::Escape($Pkg) })
        Check "No TrailMind crashes on $d" ($crashes.Count -eq 0) $(if ($crashes.Count) { $crashes[0] })
        $anrs = @(Adb $d logcat -d -b events | Where-Object { $_ -match 'am_anr' -and $_ -match [regex]::Escape($Pkg) })
        Check "No TrailMind ANRs on $d" ($anrs.Count -eq 0)
    }
} catch {
    Check 'Test run completed' $false $_.Exception.Message
} finally {
    foreach ($d in @($Phone, $Watch) | Where-Object { $_ }) {
        Adb $d logcat -d -v threadtime | Set-Content -Encoding UTF8 -Path (Join-Path $Out "logcat-$($d -replace '[^\w]', '_').txt")
    }
    [Console]::OutputEncoding = $consoleEncoding
}

$Results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $Out 'results.csv')
$failed = @($Results | Where-Object { $_.Result -eq 'FAIL' }).Count
$passed = @($Results | Where-Object { $_.Result -eq 'PASS' }).Count
$skipped = @($Results | Where-Object { $_.Result -eq 'SKIP' }).Count
Write-Host ''
Write-Host ("{0} passed, {1} failed, {2} skipped. Artifacts: {3}" -f $passed, $failed, $skipped, $Out) -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
exit $failed
