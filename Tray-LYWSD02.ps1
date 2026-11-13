<#
.SYNOPSIS
    System-tray widget for the Xiaomi LYWSD02 clock and an Aranet4 CO2 monitor.
    Shows the temperature in the taskbar tray, logs both devices to CSV, raises
    alerts, and opens a "Room state" dashboard that reads the room for you.

.DESCRIPTION
    Runs as a hidden PowerShell process with a NotifyIcon. Bluetooth work is done
    by child processes (Sync-LYWSD02.ps1 for the clock, Watch-Aranet4.ps1 for the
    Aranet), so the UI never blocks on a scan. Both histories are held in memory
    by the compiled core (Vulcan.Core.cs), which also does the inference maths and
    the drawing primitives - this script is the UI and the scheduling.

    Launch hidden via Start-Widget.vbs (Install-Widget.ps1 sets that up).
    Settings persist in settings.json; data in logs\sensors.csv and logs\aranet4.csv.

.PARAMETER SelfTest
    Developer check: build the whole UI against the real data, save screenshots
    into the given folder and exit. Touches no device, setting or log.
#>
[CmdletBinding()]
param([string]$SettingsPath, [string]$SelfTest, [string]$SelfTestTheme, [string]$SelfTestSize)

$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$SyncScript   = Join-Path $ScriptDir 'Sync-LYWSD02.ps1'   # clock device (one scan per read)
$WatchScript  = Join-Path $ScriptDir 'Watch-Aranet4.ps1'  # air-quality device (persistent listener)
if (-not $SettingsPath) { $SettingsPath = Join-Path $ScriptDir 'settings.json' }
$LogDir       = Join-Path $ScriptDir 'logs'
$CacheDir     = Join-Path $LogDir 'cache'
$CsvPath      = Join-Path $LogDir 'sensors.csv'           # LYWSD02 history
$AranetCsv    = Join-Path $LogDir 'aranet4.csv'           # Aranet4 history
$LatestJson   = Join-Path $LogDir 'aranet-latest.json'    # latest Aranet reading (written by the watcher)
$WatchPidFile = Join-Path $LogDir 'aranet-watcher.pid'
$WidgetLog    = Join-Path $LogDir 'widget.log'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

function WLog([string]$m) {
    if ($SelfTest) { Write-Host $m; return }
    try { [System.IO.File]::AppendAllText($WidgetLog, ("{0} {1}`r`n" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m)) } catch {}
}

# ---- Single instance, then the assemblies everything below depends on ----
if (-not $SelfTest) {
    $createdNew = $false
    $script:mutex = New-Object System.Threading.Mutex($true, 'LYWSD02_Tray_Widget_Mutex', [ref]$createdNew)
    if (-not $createdNew) {
        # Already running: ask that instance to show its dashboard, then leave.
        try { $ev = [System.Threading.EventWaitHandle]::OpenExisting('LYWSD02_Show_Dashboard'); [void]$ev.Set(); $ev.Dispose() } catch {}
        return
    }
}

$swStart = [System.Diagnostics.Stopwatch]::StartNew()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $ScriptDir 'Compile-Cache.ps1')
$coreHow = Import-CachedAssembly -Name 'vulcan-core' -Source ([System.IO.File]::ReadAllText((Join-Path $ScriptDir 'Vulcan.Core.cs'))) -CacheDir $CacheDir -ProbeType 'Vulcan.Model' -References {
    'System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.Windows.Forms.DataVisualization.dll'
}
[System.Windows.Forms.Application]::EnableVisualStyles()
# Log UI-thread exceptions instead of popping a modal error dialog.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($s,$e) try { WLog "THREADEXC: $($e.Exception.Message)" } catch {} })

# ===========================================================================
#  Settings
# ===========================================================================
$DefaultSettings = [ordered]@{
    Address           = ''
    DeviceName        = 'LYWSD02'
    ScanSeconds       = 90
    IntervalMinutes   = 60
    ConnectionEnabled = $true
    HourlyLogging     = $true
    AranetEnabled     = $true
    RoomName          = 'Living room'
    RoomVolume        = 29        # m3 (~3 x 4 x 2.4); used by the occupancy estimate
    AlertsEnabled     = $true
    QuietNight        = $true     # no pop-up notifications 22:00-07:00
    Theme             = 'dark'
    TrendRange        = '7d'
    TrendFrom         = ''
    TrendTo           = ''
}
function Load-Settings {
    $s = [ordered]@{}
    foreach ($k in $DefaultSettings.Keys) { $s[$k] = $DefaultSettings[$k] }
    if (Test-Path $SettingsPath) {
        try {
            $j = Get-Content $SettingsPath -Raw | ConvertFrom-Json
            foreach ($k in @($DefaultSettings.Keys)) { if ($null -ne $j.$k) { $s[$k] = $j.$k } }
        } catch { WLog "WARN could not parse settings.json: $($_.Exception.Message)" }
    }
    return $s
}
function Save-Settings {
    if ($SelfTest) { return }
    try { ($script:settings | ConvertTo-Json) | Set-Content -Path $SettingsPath -Encoding UTF8 }
    catch { WLog "WARN could not save settings: $($_.Exception.Message)" }
}
function Clock-Interval { $m = [int]$script:settings.IntervalMinutes; if ($m -lt 1) { 60 } else { $m } }
function NVal($v) { if ($null -eq $v) { return $null }; $d = [double]$v; if ([double]::IsNaN($d)) { return $null }; return $d }
function NNum($v) { if ($null -eq $v) { return [double]::NaN }; return [double]$v }

# ===========================================================================
#  Theme, fonts, small drawing helpers
# ===========================================================================
$script:RsDeg=[char]0x00B0; $script:RsMid=[char]0x00B7; $script:RsNd=[char]0x2013; $script:RsEm=[char]0x2014
$script:RsSub2=[char]0x2082; $script:RsSup3=[char]0x00B3; $script:RsApx=[char]0x2248
$script:RsUp=[char]0x2191; $script:RsDn=[char]0x2193; $script:RsRt=[char]0x2192
$script:RsDR=[char]0x2198; $script:RsUR=[char]0x2197
$script:GlRefresh=[string][char]0xE72C; $script:GlGear=[string][char]0xE713; $script:GlEdit=[string][char]0xE70F
$script:GlSync=[string][char]0xE895; $script:GlChart=[string][char]0xE9D2; $script:GlClose=[string][char]0xE8BB
$script:GlFolder=[string][char]0xE8B7
$script:RsFonts = $null

function Build-Theme($mode) {
    $c = { param($r,$g,$b) [System.Drawing.Color]::FromArgb($r,$g,$b) }
    if ($mode -eq 'light') {
        $t = @{ Mode='light'
            Canvas=(& $c 246 246 243); Surface=(& $c 255 255 255); Sunken=(& $c 238 238 234); Hover=(& $c 226 226 221)
            TextP=(& $c 21 22 26); TextS=(& $c 92 94 102); TextT=(& $c 138 140 148)
            Hairline=[System.Drawing.Color]::FromArgb(22,20,22,26); Accent=(& $c 15 158 142); AccentWash=[System.Drawing.Color]::FromArgb(24,15,158,142)
            Caution=(& $c 193 138 46); Alert=(& $c 192 87 59); OnAccent=(& $c 255 255 255) }
    } else {
        $t = @{ Mode='dark'
            Canvas=(& $c 13 14 16); Surface=(& $c 23 24 27); Sunken=(& $c 30 31 35); Hover=(& $c 42 44 50)
            TextP=(& $c 244 244 241); TextS=(& $c 162 164 172); TextT=(& $c 110 112 119)
            Hairline=[System.Drawing.Color]::FromArgb(20,255,255,255); Accent=(& $c 43 182 164); AccentWash=[System.Drawing.Color]::FromArgb(28,43,182,164)
            Caution=(& $c 214 162 74); Alert=(& $c 215 122 92); OnAccent=(& $c 13 14 16) }
    }
    return $t
}
function Apply-Theme($mode) {
    $script:DashTheme = Build-Theme $mode
    foreach ($k in 'Canvas','Surface','Sunken','Hover','TextP','TextS','TextT','Hairline','Accent','AccentWash','Caution','Alert','OnAccent') {
        [Vulcan.Theme].GetField($k).SetValue($null, $script:DashTheme[$k])
    }
}
function Ensure-RsFonts {
    if ($script:RsFonts) { return }
    $sb = 'Segoe UI Semibold'; $ui = 'Segoe UI'
    $script:RsFonts = @{
        Verdict = New-Object System.Drawing.Font($sb, 21)
        Title   = New-Object System.Drawing.Font($sb, 11.5)
        Value   = New-Object System.Drawing.Font($sb, 20)
        Big     = New-Object System.Drawing.Font($sb, 27)
        Unit    = New-Object System.Drawing.Font($ui, 9.5)
        Body    = New-Object System.Drawing.Font($ui, 9.5)
        BodyB   = New-Object System.Drawing.Font($sb, 9.5)
        Caption = New-Object System.Drawing.Font($ui, 8.25)
        Section = New-Object System.Drawing.Font($sb, 7.5)
        Arrow   = New-Object System.Drawing.Font($sb, 17)
        Glyph   = New-Object System.Drawing.Font('Segoe MDL2 Assets', 8)
    }
}
function Rs-Skel { if ($script:DashTheme.Mode -eq 'light') { [System.Drawing.Color]::FromArgb(18,20,22,26) } else { [System.Drawing.Color]::FromArgb(26,255,255,255) } }
function Rs-StateColor($state) { $T = $script:DashTheme; if ($state -eq 'alert') { return $T.Alert }; if ($state -eq 'caution') { return $T.Caution }; return $T.Accent }
function Rs-AgeText([double]$min) { if ($min -lt 1) { 'just now' } elseif ($min -lt 90) { "$([int]$min) min ago" } else { '{0:0.0} h ago' -f ($min/60) } }
function Rs-Person($g, [int]$cx, [int]$top, [int]$size, $color) {
    $pen = New-Object System.Drawing.Pen($color, 1.5); $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $hd = [int]($size*0.34)
    $g.DrawEllipse($pen, [single]($cx-$hd/2), [single]$top, [single]$hd, [single]$hd)
    $bx = $cx-$size/2+$size*0.12; $bw = $size-$size*0.24; $by = $top+$hd+2; $bh = $size-$hd-2
    $g.DrawArc($pen, [single]$bx, [single]$by, [single]$bw, [single]($bh*2), 180, 180); $pen.Dispose()
}
function Rs-Icon($g, $name, [int]$x, [int]$y, [int]$s, $color) {
    $pen = New-Object System.Drawing.Pen($color, 1.5); $pen.StartCap='Round'; $pen.EndCap='Round'; $pen.LineJoin='Round'
    switch ($name) {
        'temp' { $g.DrawArc($pen,[single]($x+$s*0.28),[single]$y,[single]($s*0.44),[single]($s*0.44),0,360); $g.DrawLine($pen,[single]($x+$s*0.5),[single]($y+$s*0.18),[single]($x+$s*0.5),[single]($y+$s*0.62)) }
        'drop' { $g.DrawArc($pen,[single]($x+$s*0.2),[single]($y+$s*0.3),[single]($s*0.6),[single]($s*0.6),30,300); $g.DrawLine($pen,[single]($x+$s*0.5),[single]($y+$s*0.05),[single]($x+$s*0.22),[single]($y+$s*0.45)); $g.DrawLine($pen,[single]($x+$s*0.5),[single]($y+$s*0.05),[single]($x+$s*0.78),[single]($y+$s*0.45)) }
        'air'  { $g.DrawArc($pen,[single]($x+$s*0.1),[single]($y+$s*0.25),[single]($s*0.5),[single]($s*0.3),90,260); $g.DrawLine($pen,[single]($x+$s*0.1),[single]($y+$s*0.4),[single]($x+$s*0.75),[single]($y+$s*0.4)) }
        'gauge'{ $g.DrawArc($pen,[single]($x+$s*0.1),[single]($y+$s*0.2),[single]($s*0.8),[single]($s*0.8),180,180); $g.DrawLine($pen,[single]($x+$s*0.5),[single]($y+$s*0.6),[single]($x+$s*0.7),[single]($y+$s*0.35)) }
    }
    $pen.Dispose()
}

# ===========================================================================
#  Tray icon
# ===========================================================================
$script:iconHandle = [IntPtr]::Zero; $script:iconKey = ''
function Update-Icon {
    param([string]$Text, [bool]$Dim, [string]$Level = 'good')
    $key = "$Text|$Dim|$Level"
    if ($key -eq $script:iconKey -and $script:iconHandle -ne [IntPtr]::Zero) { return }
    $script:iconKey = $key; $script:lastText = $Text
    $bmp = New-Object System.Drawing.Bitmap 32,32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)
    # colour carries the room state: blue = fine, amber = attention, red = act, grey = Bluetooth off
    $bg = [System.Drawing.Color]::FromArgb(235, 28, 90, 160)
    if ($Dim) { $bg = [System.Drawing.Color]::FromArgb(160, 96, 96, 96) }
    elseif ($Level -eq 'alert') { $bg = [System.Drawing.Color]::FromArgb(240, 196, 64, 44) }
    elseif ($Level -eq 'caution') { $bg = [System.Drawing.Color]::FromArgb(240, 186, 122, 22) }
    [Vulcan.Gfx]::Fill($g, $bg, 1, 1, 30, 30, 7)
    $size = if ($Text.Length -ge 3) { 15 } else { 19 }
    $font = New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center; $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString($Text, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0,0,32,32)), $fmt)
    $g.Dispose(); $font.Dispose(); $fmt.Dispose()
    $newHandle = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($newHandle)
    $bmp.Dispose()
    $old = $script:iconHandle
    $script:ni.Icon = $icon
    $script:iconHandle = $newHandle
    if ($old -ne [IntPtr]::Zero) { [void][Vulcan.Native]::DestroyIcon($old) }
}
function Reading-Text {
    $rs = $script:rs
    if (-not $rs -or ($null -eq $rs.Temp -and $null -eq $rs.Co2)) { return 'No reading yet' }
    $parts = @()
    if ($null -ne $rs.Temp) { $parts += ('{0:0.0}{1}C' -f $rs.Temp, $script:RsDeg) }
    if ($null -ne $rs.Hum)  { $parts += ('{0:0}% RH' -f $rs.Hum) }
    if ($null -ne $rs.Co2)  { $parts += ('{0:0} ppm' -f $rs.Co2) }
    return ($parts -join "  $($script:RsMid)  ")
}
function Set-Tooltip {
    # NotifyIcon.Text is limited to 63 characters
    $t = if (-not $script:settings.ConnectionEnabled) { 'Room state - Bluetooth off' } else { Reading-Text }
    if ($t.Length -gt 63) { $t = $t.Substring(0, 60) + '...' }
    try { $script:ni.Text = $t } catch {}
}

# ===========================================================================
#  State: readings -> what they mean  (the heavy lifting is in Vulcan.Model)
# ===========================================================================
$script:lastReading = $null    # @{ TempC; Humidity; Battery; When }
$script:lastAranet  = $null    # @{ Co2; TempC; Hum; Pres; Battery; Status; When (measured); Captured; Interval }
$script:rs = $null
$script:alerts = [ordered]@{}
$script:rsDisp = @{}; $script:rsTarget = @{}
$script:rsVAlpha = 1.0; $script:rsPrevVerdict = ''; $script:rsSettle = @{}; $script:rsScrubFrac = $null
$script:rsReduced = $false

function Seed-Readings {
    # Show the last logged values at once on launch instead of "..." until the first Bluetooth read.
    $now = Get-Date; $C = [Vulcan.Data]::Clock; $A = [Vulcan.Data]::Air
    if ($C.Count -gt 0 -and ($now - $C.LastTime).TotalHours -lt 12) {
        $hu = NVal $C.Last(1); if ($null -eq $hu) { $hu = 0 }
        $script:lastReading = @{ TempC = $C.Last(0); Humidity = [int]$hu; Battery = (NVal $C.Last(2)); When = $C.LastTime }
    }
    if ($A.Count -gt 0 -and ($now - $A.LastTime).TotalHours -lt 12) {
        $script:lastAranet = @{ Co2 = [int]$A.Last(0); TempC = (NVal $A.Last(1)); Hum = (NVal $A.Last(2)); Pres = (NVal $A.Last(3)); Battery = (NVal $A.Last(4))
                                Status = ''; When = $A.LastTime; Captured = $A.LastTime; Interval = 0 }
    }
}
function Rs-ReducedMotion {
    try { return ([string](Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name MinAnimate -ErrorAction Stop).MinAnimate -eq '0') } catch { return $false }
}
function Rs-AchBand($ach) {
    if ($null -eq $ach)   { return @{ Band = 'Estimating'; Level = -1 } }
    if ($ach -lt 0.4)     { return @{ Band = 'Poor';     Level = 0 } }
    if ($ach -lt 1.2)     { return @{ Band = 'Moderate'; Level = 1 } }
    if ($ach -lt 4.0)     { return @{ Band = 'Good';     Level = 2 } }
    return @{ Band = 'Breezy'; Level = 3 }
}
function Rs-Delta1h($tbl, [int]$col, $cur, $now) {
    if ($null -eq $cur) { return $null }
    $p = $tbl.ValueNear($col, $now.AddHours(-1), 15)
    if ([double]::IsNaN($p)) { return $null }
    return ([double]$cur - $p)
}
function Rs-Verdict($co2, $airStale, $temp, $rh, $dew, $occ, $M) {
    if ($null -eq $co2 -and $null -eq $temp) { return @{ Line = 'Waiting for sensors.'; State = 'good' } }
    $airState = 'good'; $airWord = ''
    if ($null -ne $co2 -and -not $airStale) {
        if ($co2 -lt 800) { $airWord = 'Fresh' }
        elseif ($co2 -lt 1200) { $airWord = 'Air is fine' }
        elseif ($co2 -lt 2000) { $airWord = 'Air is getting stuffy'; $airState = 'caution' }
        else { $airWord = 'Air is poor'; $airState = 'alert' }
        if ($M.AchLive -and $co2 -ge 800 -and (NNum (NVal $M.Co2Slope)) -lt -200) { $airWord = 'Air is clearing' }
    }
    $cWord = ''; $cState = 'good'
    if ($null -ne $temp -and $null -ne $rh) {
        $cWord = 'comfortable'
        if ($temp -ge 29) { $cWord = 'hot'; $cState = 'caution' }
        elseif ($temp -gt 26) { $cWord = 'a little warm'; $cState = 'caution' }
        elseif ($temp -lt 16) { $cWord = 'cold'; $cState = 'caution' }
        elseif ($temp -lt 18) { $cWord = 'a little cool'; $cState = 'caution' }
        elseif ($rh -gt 65 -or ($null -ne $dew -and $dew -ge 19)) { $cWord = 'a little humid'; $cState = 'caution' }
        elseif ($rh -lt 30) { $cWord = 'a little dry'; $cState = 'caution' }
    }
    $state = 'good'; if ($airState -eq 'caution' -or $cState -eq 'caution') { $state = 'caution' }; if ($airState -eq 'alert') { $state = 'alert' }
    $line = ''
    if ($airWord -and $cWord) { $line = "$airWord and $cWord." }
    elseif ($airWord) { $line = "$airWord." }
    elseif ($cWord) { $line = $cWord.Substring(0,1).ToUpper() + $cWord.Substring(1) + '.' }
    $op = ''
    if ($occ.Level -eq 0) { if (-not $occ.Low) { $op = 'Nobody in.' } }
    elseif ($occ.Level -eq 1) { $op = 'One or two people.' }
    elseif ($occ.Level -eq 2) { $op = 'Several people.' }
    elseif ($occ.Level -eq 3) { $op = 'A crowd.' }
    if ($op) { $line = ($line + ' ' + $op).Trim() }
    if (-not $line) { $line = 'Waiting for sensors.' }
    return @{ Line = $line; State = $state }
}
function Rs-SetTargets($map, [bool]$animate) {
    foreach ($k in @($map.Keys)) {
        $script:rsTarget[$k] = $map[$k]
        if (-not $animate -or -not $script:rsDisp.ContainsKey($k) -or $null -eq $map[$k] -or $null -eq $script:rsDisp[$k]) { $script:rsDisp[$k] = $map[$k] }
    }
}
function Rs-AnimStep {
    $moving = $false
    foreach ($k in @($script:rsTarget.Keys)) {
        $t = $script:rsTarget[$k]
        if ($null -eq $t) { $script:rsDisp[$k] = $null; continue }
        $d = $script:rsDisp[$k]
        if ($null -eq $d) { $script:rsDisp[$k] = $t; continue }
        $diff = $t - $d
        if ([Math]::Abs($diff) -lt 0.05) { $script:rsDisp[$k] = $t } else { $script:rsDisp[$k] = $d + $diff * 0.25; $moving = $true }
    }
    return $moving
}
function Rs-Fmt($key, $fmt) {
    $v = $script:rsTarget[$key]
    if ($script:rsDisp.ContainsKey($key) -and $null -ne $script:rsDisp[$key]) { $v = $script:rsDisp[$key] }
    if ($null -eq $v) { return [string]$script:RsEm }
    return ($fmt -f [double]$v)
}

function Update-State {
    $now = Get-Date
    $r = $script:lastReading; $a = $script:lastAranet
    $Clk = [Vulcan.Data]::Clock; $Air = [Vulcan.Data]::Air
    $clockAge = $null; if ($r) { $clockAge = ($now - $r.When).TotalMinutes }
    $airAge = $null;   if ($a) { $airAge = ($now - $a.When).TotalMinutes }
    $airIvl = 2.0;     if ($a -and $a.Interval -gt 0) { $airIvl = $a.Interval / 60.0 }
    $clockStale = ($null -eq $clockAge) -or ($clockAge -gt [Math]::Max(3 * (Clock-Interval), 20))
    $airStale   = ($null -eq $airAge) -or ($airAge -gt [Math]::Max(12, 4 * $airIvl))
    # Temperature and humidity come from the clock; if the clock has gone quiet the
    # Aranet's own sensor fills in, so the dashboard keeps working on one device.
    $src = $null
    if ($r -and -not $clockStale) { $src = 'clock' }
    elseif ($a -and -not $airStale -and $null -ne (NVal $a.TempC)) { $src = 'aranet' }
    elseif ($r) { $src = 'clock' }
    elseif ($a -and $null -ne (NVal $a.TempC)) { $src = 'aranet' }
    $temp = $null; $hum = $null; $envStale = $true; $envAge = $null; $envTbl = $Clk; $tCol = 0; $hCol = 1
    if ($src -eq 'clock') { $temp = [double]$r.TempC; $hum = [double]$r.Humidity; $envStale = $clockStale; $envAge = $clockAge }
    elseif ($src -eq 'aranet') { $temp = NVal $a.TempC; $hum = NVal $a.Hum; $envStale = $airStale; $envAge = $airAge; $envTbl = $Air; $tCol = 1; $hCol = 2 }
    $co2 = $null; $pres = $null
    if ($a) { $co2 = [double]$a.Co2; $pres = NVal $a.Pres }
    $dew = $null; $abs = $null
    if ($null -ne $temp -and $null -ne $hum -and $hum -gt 0) {
        $dew = [Math]::Round([Vulcan.Model]::DewPoint($temp, $hum), 1); $abs = [Math]::Round([Vulcan.Model]::AbsHum($temp, $hum), 1)
    }
    $M = [Vulcan.Model]::Evaluate($now, [double]$script:settings.RoomVolume)

    # occupancy (a band, never a count)
    $lvl = $null; if (-not $airStale -and $M.OccLevel -ge 0) { $lvl = [int]$M.OccLevel }
    $band = 'Waiting for sensor'
    if ($null -ne $lvl) { $band = @('Empty', ('1' + $script:RsNd + '2 people'), 'Several people', 'A crowd')[$lvl] }
    $hr = $now.Hour
    $occ = @{ Level = $lvl; Band = $band; Held = [bool]$M.OccHeld; Low = [bool]$M.OccLowSignal; Night = ($hr -ge 23 -or $hr -lt 6); Volume = [int]$script:settings.RoomVolume }

    # ventilation: a decay in progress is a live measurement; otherwise this room's usual rate
    $achShown = $null; $achKind = 'none'
    if ($M.AchLive) { $achShown = $M.AchLiveK; $achKind = 'live' }
    elseif (-not [double]::IsNaN($M.AchTypical)) { $achShown = $M.AchTypical; $achKind = 'typical' }
    elseif (-not [double]::IsNaN($M.AchLast)) { $achShown = $M.AchLast; $achKind = 'last' }
    $ab = Rs-AchBand $achShown
    $airing = ($M.AchLive -and $M.AchLiveK -gt 1.5 * $M.AchClosed)

    # pressure tendency, in the Met Office's words
    $pRate = NVal $M.PresRate3h; $pTrend = 'Gathering data'; $pDir = 0; $pNote = 'Needs about an hour of readings.'
    if ($null -ne $pRate) {
        $ar = [Math]::Abs($pRate); $w = 'Rising'; $pDir = 1
        if ($pRate -lt 0) { $w = 'Falling'; $pDir = -1 }
        if ($ar -lt 0.5) { $pTrend = 'Steady'; $pDir = 0; $pNote = 'Little change expected.' }
        elseif ($ar -lt 1.6) { $pTrend = "$w slowly"; $pNote = 'Slowly settling.'; if ($pRate -lt 0) { $pNote = 'Conditions may slowly turn.' } }
        elseif ($ar -lt 3.6) { $pTrend = $w; $pNote = 'Clearing and settling.'; if ($pRate -lt 0) { $pNote = 'Unsettled weather is more likely.' } }
        else { $pTrend = "$w quickly"; $pNote = 'Clearing fast; it may turn windy.'; if ($pRate -lt 0) { $pNote = 'A front or storm may be approaching.' } }
    }

    $vd = Rs-Verdict $co2 $airStale $temp $hum $dew $occ $M
    $h6 = $now.AddHours(-6)
    $tD = Rs-Delta1h $envTbl $tCol $temp $now; if ($null -ne $tD) { $tD = [Math]::Round($tD, 1) }
    $hD = Rs-Delta1h $envTbl $hCol $hum $now;  if ($null -ne $hD) { $hD = [Math]::Round($hD, 0) }
    $cD = Rs-Delta1h $Air 0 $co2 $now;           if ($null -ne $cD) { $cD = [Math]::Round($cD, 0) }
    $pD = Rs-Delta1h $Air 3 $pres $now;          if ($null -ne $pD) { $pD = [Math]::Round($pD, 1) }
    $envNote = ''; if ($src -eq 'aranet') { $envNote = 'via Aranet4' }
    $envAgeTxt = ''; if ($null -ne $envAge) { $envAgeTxt = Rs-AgeText $envAge }
    $airAgeTxt = ''; if ($null -ne $airAge) { $airAgeTxt = Rs-AgeText $airAge }

    $oldLine = ''; $oldState = 'good'
    if ($script:rs) { $oldLine = $script:rs.Verdict; $oldState = $script:rs.State }
    $dashOpen = [bool]($script:dash -and $script:dash.Form -and -not $script:dash.Form.IsDisposed)
    $animate = ($dashOpen -and -not $script:rsReduced)
    Rs-SetTargets @{ co2 = $co2; v_temp = $temp; v_hum = $hum; v_co2 = $co2; v_pres = $pres; dew = $dew } $animate

    $script:rs = @{
        Updated = $now; M = $M
        Temp = $temp; Hum = $hum; Co2 = $co2; Pres = $pres; Dew = $dew; Abs = $abs
        EnvSrc = $src; EnvStale = $envStale; Co2Stale = $airStale; Co2Age = $airAgeTxt
        Occ = $occ
        Ach = $achShown; AchKind = $achKind; AchBand = $ab.Band; AchLevel = $ab.Level; Airing = $airing
        PresRate = $pRate; PresTrend = $pTrend; PresDir = $pDir; PresNote = $pNote
        Verdict = $vd.Line; State = $vd.State
        Rebreathed = $(if ($null -ne $co2) { [Math]::Round([Vulcan.Model]::Rebreathed($co2, $M.Baseline), 1) } else { $null })
        AirIntervalMin = $airIvl
        ClockWhen = $(if ($r) { $r.When } else { $null }); AranetWhen = $(if ($a) { $a.When } else { $null })
        ClockBatt = $(if ($r) { NVal $r.Battery } else { $null }); AranetBatt = $(if ($a) { NVal $a.Battery } else { $null })
        Alerts = @(); AlertLevel = 'good'
        V = @{
            temp = @{ Label='Temperature'; Raw=$temp; DispKey='v_temp'; Fmt='{0:0.0}'; Unit=($script:RsDeg+'C'); Icon='temp'; Spark=$envTbl.Spark($tCol,$h6,$now,36); Delta=$tD; DFmt='{0:0.0}'; DUnit=$script:RsDeg; Stale=$envStale; AgeText=$envAgeTxt; Hot=($null -ne $tD -and [Math]::Abs($tD) -ge 1.5); Note=$envNote }
            hum  = @{ Label='Humidity';    Raw=$hum;  DispKey='v_hum';  Fmt='{0:0}';   Unit='%';   Icon='drop';  Spark=$envTbl.Spark($hCol,$h6,$now,36); Delta=$hD; DFmt='{0:0}'; DUnit='%'; Stale=$envStale; AgeText=$envAgeTxt; Hot=($null -ne $hD -and [Math]::Abs($hD) -ge 8); Note=$envNote }
            co2  = @{ Label=('CO'+$script:RsSub2); Raw=$co2; DispKey='v_co2'; Fmt='{0:0}'; Unit='ppm'; Icon='air';   Spark=$Air.Spark(0,$h6,$now,36); Delta=$cD; DFmt='{0:0}'; DUnit=' ppm'; Stale=$airStale; AgeText=$airAgeTxt; Hot=($null -ne $cD -and $cD -ge 200); Note='' }
            pres = @{ Label='Pressure';    Raw=$pres; DispKey='v_pres'; Fmt='{0:0}';   Unit='hPa'; Icon='gauge'; Spark=$Air.Spark(3,$h6,$now,36); Delta=$pD; DFmt='{0:0.0}'; DUnit=' hPa'; Stale=$airStale; AgeText=$airAgeTxt; Hot=($null -ne $pD -and [Math]::Abs($pD) -ge 2.5); Note='' }
        }
    }
    Update-Alerts
    if ($script:rs.AlertLevel -eq 'alert') { $script:rs.State = 'alert' }
    elseif ($script:rs.AlertLevel -eq 'caution' -and $script:rs.State -eq 'good') { $script:rs.State = 'caution' }
    if ($vd.Line -ne $oldLine) { $script:rsPrevVerdict = $oldLine; $script:rsVAlpha = 1.0; if ($animate -and $oldLine) { $script:rsVAlpha = 0.0 } }
    if ($script:rs.State -ne $oldState -and $animate) { $script:rsSettle['aq'] = 1.0 }
}

# ---------------------------------------------------------------------------
#  Alerts: a short list of things worth interrupting for. Each has hysteresis
#  (so it does not flap at the threshold), a hold time (so a blip is ignored)
#  and a re-notify interval (so it does not nag).
# ---------------------------------------------------------------------------
function Update-Alerts {
    $rs = $script:rs; $now = $rs.Updated; $want = [ordered]@{}
    $S = $script:settings
    $def = { param($key, $level, $title, $msg, $hold, $renotify) $want[$key] = @{ Key=$key; Level=$level; Title=$title; Msg=$msg; Hold=$hold; Renotify=$renotify } }
    $co2Name = 'CO' + $script:RsSub2

    if ($null -ne $rs.Co2 -and -not $rs.Co2Stale) {
        $c = $rs.Co2; $prev = $script:alerts['co2']
        if ($c -ge 1400 -or ($prev -and $c -ge 1200)) {
            if ($c -ge 2000 -or ($prev -and $prev.Level -eq 'alert' -and $c -ge 1800)) { & $def 'co2' 'alert' "$co2Name is very high" ('{0:0} ppm. Open a window or door now.' -f $c) 2 30 }
            else { & $def 'co2' 'caution' "$co2Name is high" ('{0:0} ppm. Open a window or door.' -f $c) 3 45 }
        }
    }
    if ($null -ne $rs.Hum -and -not $rs.EnvStale) {
        $h = $rs.Hum
        if ($h -ge 70 -or ($script:alerts['humid'] -and $h -ge 66)) { & $def 'humid' 'caution' 'Humidity is high' ('{0:0}% RH. Mould becomes likely if it stays above 70%.' -f $h) 30 240 }
        if ($h -le 25 -or ($script:alerts['dry'] -and $h -le 28)) { & $def 'dry' 'caution' 'Air is very dry' ('{0:0}% RH.' -f $h) 30 240 }
    }
    if ($null -ne $rs.Temp -and -not $rs.EnvStale) {
        $t = $rs.Temp
        if ($t -ge 30 -or ($script:alerts['hot'] -and $t -ge 29)) { & $def 'hot' 'caution' 'Room is hot' ('{0:0.0}{1}C.' -f $t, $script:RsDeg) 15 240 }
        if ($t -le 12 -or ($script:alerts['cold'] -and $t -le 13)) { & $def 'cold' 'caution' 'Room is cold' ('{0:0.0}{1}C.' -f $t, $script:RsDeg) 15 240 }
    }
    # A device going quiet. Bluetooth reception thins out while the PC is locked, and
    # short silences are routine (this Aranet skips 15+ minutes a few times a day),
    # so: only count time while someone is at the PC, and wait well past the routine.
    if ($S.ConnectionEnabled -and -not $script:sessionLocked) {
        $since0 = $script:startedAt; if ($script:unlockedAt -gt $since0) { $since0 = $script:unlockedAt }
        if ($S.AranetEnabled) {
            $heard = $since0; if ($script:lastAranet -and $script:lastAranet.Captured -gt $heard) { $heard = $script:lastAranet.Captured }
            $quiet = ($now - $heard).TotalMinutes
            if ($quiet -ge [Math]::Max(45, 10 * $rs.AirIntervalMin)) { & $def 'air-off' 'caution' 'Aranet4 is quiet' ('No broadcast for {0}. Check it is in range and Smart Home integration is on.' -f (Rs-AgeText $quiet).Replace(' ago','')) 0 360 }
        }
        $read = $since0; if ($script:lastReading -and $script:lastReading.When -gt $read) { $read = $script:lastReading.When }
        $since = ($now - $read).TotalMinutes
        if ($since -ge [Math]::Max(3 * (Clock-Interval) + 5, 60)) { & $def 'clock-off' 'caution' 'Clock not reached' ('No reading for {0}. It may be out of range or need batteries.' -f (Rs-AgeText $since).Replace(' ago','')) 0 360 }
    }
    if ($null -ne $rs.ClockBatt -and ($rs.ClockBatt -le 10 -or ($script:alerts['batt-clock'] -and $rs.ClockBatt -le 15))) { & $def 'batt-clock' 'caution' 'Clock battery low' ('{0:0}% left.' -f $rs.ClockBatt) 0 1440 }
    if ($null -ne $rs.AranetBatt -and ($rs.AranetBatt -le 15 -or ($script:alerts['batt-air'] -and $rs.AranetBatt -le 20))) { & $def 'batt-air' 'caution' 'Aranet4 battery low' ('{0:0}% left.' -f $rs.AranetBatt) 0 1440 }
    if ($null -ne $rs.PresRate -and ($rs.PresRate -le -3.6 -or ($script:alerts['pressure'] -and $rs.PresRate -le -3.0))) { & $def 'pressure' 'info' 'Pressure dropping fast' ('{0:0.0} hPa in 3 h. Weather is likely turning.' -f [Math]::Abs($rs.PresRate)) 10 720 }

    foreach ($k in @($script:alerts.Keys)) { if (-not $want.Contains($k)) { $script:alerts.Remove($k) } }
    foreach ($k in $want.Keys) {
        $w = $want[$k]; $cur = $script:alerts[$k]
        if (-not $cur) { $w.Since = $now; $w.Notified = $null; $script:alerts[$k] = $w; $cur = $w }
        else {
            if ($w.Level -eq 'alert' -and $cur.Level -ne 'alert') { $cur.Notified = $null }   # escalation: speak up again
            $cur.Level = $w.Level; $cur.Title = $w.Title; $cur.Msg = $w.Msg; $cur.Renotify = $w.Renotify
        }
        $cur.Visible = (($now - $cur.Since).TotalMinutes -ge $cur.Hold)
        if ($cur.Visible -and $cur.Level -ne 'info' -and ($null -eq $cur.Notified -or ($now - $cur.Notified).TotalMinutes -ge $cur.Renotify)) {
            if (Alert-Notify $cur) { $cur.Notified = $now }
        }
    }
    $rank = @{ alert = 0; caution = 1; info = 2 }
    $vis = @($script:alerts.Values | Where-Object { $_.Visible } | Sort-Object { $rank[$_.Level] })
    $rs.Alerts = $vis
    $lv = 'good'
    foreach ($x in $vis) { if ($x.Level -eq 'alert') { $lv = 'alert' } elseif ($x.Level -eq 'caution' -and $lv -eq 'good') { $lv = 'caution' } }
    $rs.AlertLevel = $lv
}
function Alert-Notify($al) {
    if ($SelfTest) { return $true }
    if (-not $script:settings.AlertsEnabled) { return $true }
    if ($script:sessionLocked) { return $false }      # nobody is at the PC: say it when they are back, if it is still true
    $h = (Get-Date).Hour
    if ($script:settings.QuietNight -and ($h -ge 22 -or $h -lt 7)) { return $false }   # hold it until morning if it is still true
    $kind = 'warn'; if ($al.Level -eq 'alert') { $kind = 'alert' }
    Rs-Toast $al.Title $al.Msg $kind $true
    WLog "ALERT [$($al.Level)] $($al.Title): $($al.Msg)"
    return $true
}

# Read feedback and alerts: inside the dashboard when it is the window in front,
# otherwise a normal Windows notification from the tray icon.
function Rs-Toast($title, $msg, $kind, [bool]$preferBalloon = $false) {
    $dashOpen = [bool]($script:dash -and $script:dash.Form -and -not $script:dash.Form.IsDisposed)
    $inWindow = $dashOpen
    if ($dashOpen -and $preferBalloon) { $inWindow = ([System.Windows.Forms.Form]::ActiveForm -eq $script:dash.Form) }
    if ($inWindow) {
        $script:toast = @{ Title = [string]$title; Msg = [string]$msg; Kind = [string]$kind }
        try { $script:dash.Status.Invalidate() } catch {}
        if ($script:toastTimer) { $script:toastTimer.Stop(); $script:toastTimer.Start() }
    } elseif ($script:ni -and -not $SelfTest) {
        $icon = [System.Windows.Forms.ToolTipIcon]::Info
        if ($kind -ne 'info') { $icon = [System.Windows.Forms.ToolTipIcon]::Warning }
        try { $script:ni.ShowBalloonTip(5000, [string]$title, [string]$msg, $icon) } catch {}
    }
}

function Refresh-Views {
    $rs = $script:rs; if (-not $rs) { return }
    $txt = '..'; if ($null -ne $rs.Temp) { $txt = [string][Math]::Round($rs.Temp) }
    try { Update-Icon $txt (-not $script:settings.ConnectionEnabled) $rs.AlertLevel } catch {}
    Set-Tooltip
    try { $miReading.Text = Reading-Text } catch {}
    if ($script:popupShown) { try { $script:popupPanel.Invalidate() } catch {} }
    if ($script:dash -and $script:dash.Form -and -not $script:dash.Form.IsDisposed) {
        $d = $script:dash
        try { $d.Orb.SetTone((Rs-StateColor $rs.State)); $d.Verdict.AccessibleDescription = $rs.Verdict } catch {}
        $want = 0; if ($rs.Alerts.Count -gt 0) { $want = 46 }
        if ($d.Layout.RowStyles[1].Height -ne $want) { $d.Layout.RowStyles[1].Height = $want }
        foreach ($pnl in $d.Panels) { if ($pnl -and -not $pnl.IsDisposed) { $pnl.Invalidate() } }
        if ($script:RsAnimTimer -and -not $script:rsReduced) { $script:RsAnimTimer.Start() }
    }
}
function Refresh-All { try { Update-State; Refresh-Views } catch { WLog "ERROR refresh: $($_.Exception.Message) :: $($_.ScriptStackTrace)" } }

# ===========================================================================
#  Devices
# ===========================================================================
$script:jobs = New-Object System.Collections.ArrayList
function Job-Active([string]$device) { foreach ($j in $script:jobs) { if ($j.Device -eq $device) { return $true } }; return $false }

# ---- Clock (LYWSD02): one short child process per read / time-sync ----
function Start-Bg {
    param([ValidateSet('read','sync')] [string]$Kind, [bool]$LogCsv, [bool]$Notify)
    if (-not $script:settings.ConnectionEnabled) { if ($Notify) { Rs-Toast 'LYWSD02' 'Bluetooth is off. Turn the connection on in Settings to reach the clock.' 'warn' }; return }
    if (Job-Active 'clock') { if ($Notify) { Rs-Toast 'LYWSD02' 'Already talking to the clock...' 'info' }; return }
    $tmp = [System.IO.Path]::GetTempFileName()
    $common = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SyncScript`" -Json -NoToggle -DeviceName `"$($script:settings.DeviceName)`" -ScanSeconds $([int]$script:settings.ScanSeconds)"
    if ($script:settings.Address) { $common += " -Address `"$($script:settings.Address)`"" }
    if ($Kind -eq 'read') { $common += ' -ReadSensors' }
    try { [void]$script:pauseEvt.Set() } catch {}     # the Aranet listener yields the radio (it keeps running)
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $common -WindowStyle Hidden -PassThru -RedirectStandardOutput $tmp
        [void]$script:jobs.Add(@{ Proc=$p; Out=$tmp; Device='clock'; Kind=$Kind; LogCsv=$LogCsv; Notify=$Notify; Started=(Get-Date) })
        if (-not $script:lastReading) { Update-Icon '..' $false 'good' }
        $script:poll.Start(); Refresh-Menu
        if ($script:dash -and $script:dash.Status) { try { $script:dash.Status.Invalidate() } catch {} }
    } catch {
        WLog "ERROR launching clock $Kind : $($_.Exception.Message)"
        try { [void]$script:pauseEvt.Reset() } catch {}
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}
function Read-JobJson($j) {
    $raw = ''
    try { $raw = Get-Content $j.Out -Raw -ErrorAction SilentlyContinue } catch {}
    Remove-Item $j.Out -ErrorAction SilentlyContinue
    $line = ($raw -split "`r?`n" | Where-Object { $_ -match '^\s*\{' } | Select-Object -First 1)
    if ($line) { try { return ($line | ConvertFrom-Json) } catch {} }
    return $null
}
function Complete-Clock($j, $data) {
    if (-not ($data -and $data.ok)) {
        if ($j.Notify) {
            $msg = 'Could not reach the clock (not seen, or out of range).'
            if ($j.Kind -eq 'sync') { $msg = 'Time sync failed: the clock was not seen. Press a button on it and try again.' }
            Rs-Toast 'LYWSD02' $msg 'warn'
        }
        WLog "WARN clock $($j.Kind) failed"
        return
    }
    if ($data.addr -and $data.addr -ne $script:settings.Address) {
        WLog "INFO learned/updated address: $($data.addr)"
        $script:settings.Address = $data.addr; Save-Settings
    }
    # A time sync returns no sensor values - only a read does.
    if ($null -ne $data.tempC) {
        $tc = [double]$data.tempC; $hu = [int]$data.humidity; $bat = $data.battery; $when = Get-Date
        $script:lastReading = @{ TempC = $tc; Humidity = $hu; Battery = $bat; When = $when }
        [Vulcan.Data]::AddClock($when, $tc, $hu, (NNum $bat), [bool]$j.LogCsv)
        if ($j.Notify) {
            $batTxt = '?'; if ($null -ne $bat) { $batTxt = "$bat%" }
            Rs-Toast 'LYWSD02' ("{0:0.0}{1}C   {2}% RH   battery {3}" -f $tc, $script:RsDeg, $hu, $batTxt) 'info'
        }
    }
    if ($j.Kind -eq 'sync') { WLog 'INFO clock synced'; if ($j.Notify) { Rs-Toast 'LYWSD02' 'Clock time synchronised.' 'info' } }
}
function Poll-Jobs {
    if ($script:jobs.Count -eq 0) { $script:poll.Stop(); return }
    foreach ($j in @($script:jobs)) {      # a hung scan must not hold the radio for ever
        if (-not $j.Proc.HasExited -and ((Get-Date) - $j.Started).TotalSeconds -gt 300) { try { $j.Proc.Kill() } catch {}; WLog 'WARN clock job timed out; killed' }
    }
    $done = @($script:jobs | Where-Object { $_.Proc.HasExited })
    foreach ($j in $done) {
        $script:jobs.Remove($j)
        try { Complete-Clock $j (Read-JobJson $j) } catch { WLog "ERROR clock result: $($_.Exception.Message)" }
    }
    if ($done.Count -gt 0) {
        if (-not (Job-Active 'clock')) { try { [void]$script:pauseEvt.Reset() } catch {} }   # radio is free: the listener resumes
        Refresh-All; Refresh-Menu
    }
    if ($script:jobs.Count -eq 0) { $script:poll.Stop() }
}

# ---- Aranet4: one persistent listener process; the widget just reads its file ----
$script:watchProc = $null; $script:watchStartedAt = [datetime]::MinValue; $script:latestStamp = [datetime]::MinValue
function Test-WatcherAlive {
    $m = $null
    try { if ([System.Threading.Mutex]::TryOpenExisting('LYWSD02_Aranet_Watcher_Mutex', [ref]$m)) { $m.Dispose(); return $true } } catch {}
    return $false
}
function Stop-AranetWatcher {
    try { if ($script:watchProc -and -not $script:watchProc.HasExited) { $script:watchProc.Kill() } } catch {}
    $script:watchProc = $null
    try {
        if (Test-Path $WatchPidFile) {
            $wp = [int](([System.IO.File]::ReadAllText($WatchPidFile)).Trim())
            $p = Get-Process -Id $wp -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -eq 'powershell') { $p.Kill() }
            Remove-Item $WatchPidFile -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}
# A listener left behind by an older version of the widget has no pid file and does
# not understand the pause signal. Find it the slow way - once, at startup only.
function Stop-LegacyWatchers {
    if (-not (Test-WatcherAlive) -or (Test-Path $WatchPidFile)) { return }
    try {
        $pat = '*-File*' + 'Watch-' + 'Aranet4.ps1*'
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like $pat -and $_.ProcessId -ne $PID } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
        WLog 'INFO replaced an older Aranet listener'
    } catch {}
}
function Ensure-AranetWatcher {
    if (-not $script:settings.ConnectionEnabled -or -not $script:settings.AranetEnabled) { return }
    if (Test-WatcherAlive) { return }
    if (((Get-Date) - $script:watchStartedAt).TotalSeconds -lt 20) { return }   # one is on its way up
    try {
        $script:watchProc = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatchScript`" -ParentPid $PID" -WindowStyle Hidden -PassThru
        $script:watchStartedAt = Get-Date
        WLog "INFO aranet listener started (pid $($script:watchProc.Id))"
    } catch { WLog "ERROR launching aranet listener: $($_.Exception.Message)" }
}
function Read-AranetLatest {
    try {
        if (-not (Test-Path $LatestJson)) { return $null }
        $d = [System.IO.File]::ReadAllText($LatestJson) | ConvertFrom-Json
        if (-not ($d -and $d.ok)) { return $null }
        $cap = [datetime]::ParseExact([string]$d.ts, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        $age = -1; $ivl = 0
        if ($null -ne $d.age) { $age = [int]$d.age }
        if ($null -ne $d.interval -and [int]$d.interval -gt 0) { $ivl = [int]$d.interval }
        $meas = $cap; if ($age -ge 0) { $meas = $cap.AddSeconds(-$age) }     # when the Aranet actually measured
        return @{ Co2 = [int]$d.co2; TempC = [double]$d.tempC; Hum = [double]$d.humidity; Pres = [double]$d.pressure; Battery = $d.battery
                  Status = [string]$d.status; When = $meas; Captured = $cap; Interval = $ivl; HasAge = ($age -ge 0) }
    } catch { return $null }
}
# Pick up a new broadcast if there is one. Returns $true when the reading changed.
function Sample-Aranet {
    try { $stamp = [System.IO.File]::GetLastWriteTimeUtc($LatestJson) } catch { return $false }
    if ($stamp -eq $script:latestStamp) { return $false }
    $d = Read-AranetLatest
    if (-not $d) { return $false }         # mid-write or unreadable: try again next tick
    $script:latestStamp = $stamp
    if (((Get-Date) - $d.Captured).TotalHours -gt 12) { return $false }
    $script:lastAranet = $d
    # One row per measurement: the Aranet repeats each measurement in several
    # broadcasts, and its age field says when it was really taken.
    $last = [Vulcan.Data]::Air.LastTime
    $minGap = 55; if ($d.HasAge) { $minGap = 20 }
    if (($d.When - $last).TotalSeconds -ge $minGap) {
        [Vulcan.Data]::AddAir($d.When, $d.Co2, $d.TempC, $d.Hum, $d.Pres, (NNum $d.Battery), $d.Status, [bool]$script:settings.HourlyLogging)
    }
    return $true
}
function Aranet-Summary {
    $a = $script:lastAranet; if (-not $a) { return 'No reading captured yet.' }
    $age = [int]((Get-Date) - $a.When).TotalSeconds
    $ageTxt = "measured $age s ago"; if ($age -ge 120) { $ageTxt = 'measured ' + (Rs-AgeText ($age/60.0)) }
    $every = ''; if ($a.Interval -gt 0) { $every = "  $($script:RsMid)  measures every $([int]($a.Interval/60)) min" }
    return ("{0} ppm   {1:0.0} hPa   {2}{3}" -f $a.Co2, $a.Pres, $ageTxt, $every)
}
# "Read now" for the Aranet. It measures on its own timer and cannot be commanded,
# so the honest answer is the latest measurement and how old it is. Only if nothing
# has been heard for a while do we wait for the next broadcast.
function Force-Aranet {
    if (-not $script:settings.ConnectionEnabled) { return }
    if (-not $script:settings.AranetEnabled) { Rs-Toast 'Aranet4' 'Aranet tracking is off. Turn it on in Settings.' 'warn'; return }
    Ensure-AranetWatcher
    [void](Sample-Aranet)
    $a = $script:lastAranet
    $heard = 99999.0; if ($a) { $heard = ((Get-Date) - $a.Captured).TotalSeconds }
    if ($heard -lt 150) { Refresh-All; Rs-Toast 'Aranet4' (Aranet-Summary) 'info'; return }
    $script:aranetForce = @{ Stamp = $script:latestStamp; Deadline = (Get-Date).AddSeconds(90) }
    Rs-Toast 'Aranet4' 'Listening for the next broadcast...' 'info'
    $script:aranetForceTimer.Start()
}
function Aranet-ForceTick {
    if (-not $script:aranetForce) { $script:aranetForceTimer.Stop(); return }
    if (Sample-Aranet) {
        $script:aranetForce = $null; $script:aranetForceTimer.Stop()
        Refresh-All; Rs-Toast 'Aranet4' (Aranet-Summary) 'info'
    } elseif ((Get-Date) -ge $script:aranetForce.Deadline) {
        $script:aranetForce = $null; $script:aranetForceTimer.Stop()
        Rs-Toast 'Aranet4' 'Nothing heard. Check it is in range and that Smart Home integration is on in the Aranet app.' 'warn'
    }
}
function Read-Now { Start-Bg -Kind 'read' -LogCsv ([bool]$script:settings.HourlyLogging) -Notify $true; if ($script:settings.AranetEnabled) { Force-Aranet } }

# ---- Scheduler: clock reads on their interval; Aranet broadcasts as they arrive ----
function Scheduler-Tick {
    $now = Get-Date; $changed = $false
    $locked = [Vulcan.Native]::SessionLocked()
    if ($script:sessionLocked -and -not $locked) { $script:unlockedAt = $now; $script:nextStateAt = $now }
    $script:sessionLocked = $locked
    if ($script:settings.ConnectionEnabled) {
        if (-not (Job-Active 'clock') -and $now -ge $script:clockDue) {
            $script:clockDue = $now.AddMinutes((Clock-Interval))
            Start-Bg -Kind 'read' -LogCsv ([bool]$script:settings.HourlyLogging) -Notify $false
        }
        if ($script:settings.AranetEnabled) {
            Ensure-AranetWatcher
            if (-not $script:aranetForce -and (Sample-Aranet)) { $changed = $true }
        }
    }
    if ($changed -or $now -ge $script:nextStateAt) { $script:nextStateAt = $now.AddSeconds(60); Refresh-All }
    if ($now -ge $script:nextTrimAt) { $script:nextTrimAt = $now.AddHours(24); Trim-Logs }
}
function Trim-Logs {
    foreach ($n in 'widget.log','sync.log','aranet.log') { try { [void][Vulcan.Files]::TrimLog((Join-Path $LogDir $n), 1MB, 256KB) } catch {} }
}
function Toggle-Connection {
    $script:settings.ConnectionEnabled = -not $script:settings.ConnectionEnabled
    Save-Settings
    if ($script:settings.ConnectionEnabled) { $script:clockDue = Get-Date; Ensure-AranetWatcher; Scheduler-Tick }
    else { Stop-AranetWatcher }
    Refresh-Menu; Sync-DrawerControls; Refresh-All
}
function Toggle-Aranet {
    $script:settings.AranetEnabled = -not $script:settings.AranetEnabled
    Save-Settings
    if ($script:settings.AranetEnabled) { Ensure-AranetWatcher } else { Stop-AranetWatcher }
    Refresh-Menu; Sync-DrawerControls; Refresh-All
}
function Set-ClockInterval([int]$mins) {
    $script:settings.IntervalMinutes = $mins
    $next = (Get-Date).AddMinutes($mins)
    if ($script:lastReading) { $next = $script:lastReading.When.AddMinutes($mins) }
    $script:clockDue = $next
    Save-Settings; Refresh-Menu; Sync-DrawerControls; Refresh-All
}

# ---- Startup shortcut ----
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'LYWSD02 Widget.lnk'
function Test-Startup { Test-Path $StartupLnk }
function Set-Startup {
    param([bool]$On)
    if ($SelfTest) { return }
    try {
        if ($On) {
            $wsh = New-Object -ComObject WScript.Shell
            $sc = $wsh.CreateShortcut($StartupLnk)
            $sc.TargetPath = Join-Path $ScriptDir 'Start-Widget.vbs'
            $sc.WorkingDirectory = $ScriptDir
            $sc.Description = 'LYWSD02 tray widget'
            $sc.Save()
        } elseif (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
    } catch { WLog "WARN startup toggle failed: $($_.Exception.Message)" }
}
function Refresh-Menu {
    $S = $script:settings
    $miConn.Checked = [bool]$S.ConnectionEnabled
    $miConn.Text = if ($S.ConnectionEnabled) { 'Bluetooth connection' } else { 'Bluetooth connection (off - battery saver)' }
    $miLog.Checked = [bool]$S.HourlyLogging
    $miAranet.Checked = [bool]$S.AranetEnabled
    $miAlerts.Checked = [bool]$S.AlertsEnabled
    $miStartup.Checked = (Test-Startup)
    $busy = Job-Active 'clock'
    $miRead.Enabled = (-not $busy) -and $S.ConnectionEnabled
    $miSync.Enabled = (-not $busy) -and $S.ConnectionEnabled
    $civl = Clock-Interval
    $miClockIvl.Text = "Clock read interval ($civl min)"
    foreach ($k in $script:miClockIvlItems.Keys) { $script:miClockIvlItems[$k].Checked = ($k -eq $civl) }
}

# ===========================================================================
#  Hover popup: the room at a glance
# ===========================================================================
$script:popupShown = $false; $script:popupAnchor = New-Object System.Drawing.Point(0,0); $script:suppressUntil = 0
function Rs-PaintPopup($g, $p) {
    $T = $script:DashTheme; $F = $script:RsFonts; $Gx = [Vulcan.Gfx]
    $Gx::Setup($g); $g.Clear($T.Canvas)
    $Gx::Fill($g, $T.Surface, 0, 0, ($p.Width-1), ($p.Height-1), 14); $Gx::Stroke($g, $T.Hairline, 0, 0, ($p.Width-1), ($p.Height-1), 14)
    $d = $script:rs
    if (-not $d) { $Gx::Text($g, 'Waiting for sensors', $F.Body, $T.TextT, 18, 18); return }
    $Gx::Dot($g, (Rs-StateColor $d.State), 16, 18, 11)
    $Gx::TextBox($g, $d.Verdict, $F.Title, $T.TextP, 34, 11, ($p.Width-48), 24, $false)
    $items = @(
        @{ L = 'Temp';  V = $(if ($null -ne $d.Temp) { ('{0:0.0}' -f $d.Temp) + $script:RsDeg } else { [string]$script:RsEm }) },
        @{ L = 'Humidity'; V = $(if ($null -ne $d.Hum) { "$([int]$d.Hum)%" } else { [string]$script:RsEm }) },
        @{ L = ('CO' + $script:RsSub2 + ' ppm'); V = $(if ($null -ne $d.Co2) { "$([int]$d.Co2)" } else { [string]$script:RsEm }) },
        @{ L = 'hPa'; V = $(if ($null -ne $d.Pres) { '{0:0}' -f $d.Pres } else { [string]$script:RsEm }) })
    $cw = ($p.Width-32)/4.0; $x = 16; $y = 46
    foreach ($it in $items) {
        $Gx::Text($g, $it.L, $F.Caption, $T.TextT, $x, $y)
        [void]$Gx::Num($g, $it.V, $F.Title, $T.TextP, $x, ($y+15))
        $x += $cw
    }
    $sp = $d.V.co2.Spark
    if ($sp -and $sp.Length -ge 2) { $Gx::Spark($g, $sp, 16, ($p.Height-52), ($p.Width-32), 26, $T.Accent, $T.AccentWash) }
    if ($d.Alerts.Count -gt 0) {
        $al = $d.Alerts[0]; $col = $T.Caution; if ($al.Level -eq 'alert') { $col = $T.Alert } elseif ($al.Level -eq 'info') { $col = $T.TextS }
        $more = ''; if ($d.Alerts.Count -gt 1) { $more = "  (+$($d.Alerts.Count-1))" }
        $Gx::TextBox($g, ($al.Title + $more), $F.Caption, $col, 16, ($p.Height-20), ($p.Width-32), 16, $false)
    } else {
        $Gx::Text($g, ('CO' + $script:RsSub2 + ', last 6 hours'), $F.Caption, $T.TextT, 16, ($p.Height-20))
        $Gx::TextRight($g, 'click to open', $F.Caption, $T.TextT, 16, ($p.Height-20), ($p.Width-32))
    }
}
function Show-Popup {
    param([int]$cx,[int]$cy)
    try {
        Ensure-RsFonts
        $script:popup.BackColor = $script:DashTheme.Canvas; $script:popupPanel.BackColor = $script:DashTheme.Canvas
        $script:popupPanel.Invalidate()
        $scr = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point($cx,$cy))).WorkingArea
        $w = $script:popup.Width; $h = $script:popup.Height
        $x = [math]::Min([math]::Max([int]($cx - $w/2), $scr.Left), $scr.Right - $w)
        $y = $cy - $h - 12; if ($y -lt $scr.Top) { $y = $cy + 24 }
        $script:popup.Location = New-Object System.Drawing.Point([int]$x, [int]$y)
        $script:popup.Show(); $script:popup.TopMost = $true
        $script:popupShown = $true; $script:popupAnchor = New-Object System.Drawing.Point($cx, $cy)
        $script:hide.Start()
    } catch { WLog "WARN show-popup: $($_.Exception.Message)" }
}
function Hide-Popup {
    if ($script:popupShown) { try { $script:popup.Hide() } catch {}; $script:popupShown = $false; $script:hide.Stop() }
}

# ===========================================================================
#  Trends window (zoomable history)
# ===========================================================================
$script:RangeMap = [ordered]@{ 'Last hour'='1h'; 'Last 6 hours'='6h'; 'Last 24 hours'='24h'; 'Last 7 days'='7d'; 'Last 30 days'='30d'; 'All'='all'; 'Custom range...'='custom' }
$script:trendForm = $null; $script:trendChart = $null; $script:trendCo2Chart = $null; $script:zoomBusy = $false
function Get-RangeBounds {
    $code = $script:settings.TrendRange; if (-not $code) { $code = '7d' }
    $now = Get-Date
    switch ($code) {
        '1h'  { return @{ From=$now.AddHours(-1);  To=$now } }
        '6h'  { return @{ From=$now.AddHours(-6);  To=$now } }
        '24h' { return @{ From=$now.AddDays(-1);   To=$now } }
        '30d' { return @{ From=$now.AddDays(-30);  To=$now } }
        'all' {
            $f = $now.AddDays(-1)
            foreach ($tb in @([Vulcan.Data]::Clock, [Vulcan.Data]::Air)) { if ($tb.Count -gt 0 -and $tb.Time(0) -lt $f) { $f = $tb.Time(0) } }
            return @{ From=$f; To=$now }
        }
        'custom' {
            $f = $now.AddDays(-7); $t = $now
            try { if ($script:settings.TrendFrom) { $f = [datetime]$script:settings.TrendFrom } } catch {}
            try { if ($script:settings.TrendTo)   { $t = [datetime]$script:settings.TrendTo } } catch {}
            return @{ From=$f; To=$t }
        }
        default { return @{ From=$now.AddDays(-7); To=$now } }
    }
}
function Style-ChartArea($chart, $area, $bg, $grid, $fg) {
    $chart.BackColor = $bg
    $chart.AntiAliasing = [System.Windows.Forms.DataVisualization.Charting.AntiAliasingStyles]::All
    $chart.BorderlineWidth = 0
    $area.BackColor = [System.Drawing.Color]::Transparent
    $area.BorderColor = [System.Drawing.Color]::Transparent
    foreach ($ax in @($area.AxisX, $area.AxisY, $area.AxisY2)) {
        $ax.LineColor = $grid
        $ax.MajorTickMark.Enabled = $false
        $ax.LabelStyle.ForeColor = $fg
        $ax.MajorGrid.LineColor = $grid
        $ax.MajorGrid.LineDashStyle = [System.Windows.Forms.DataVisualization.Charting.ChartDashStyle]::Dot
    }
    $area.AxisX.MajorGrid.Enabled = $false
    $area.AxisX.ScrollBar.BackColor = $bg; $area.AxisX.ScrollBar.ButtonColor = $grid; $area.AxisX.ScrollBar.LineColor = $grid
    $area.AxisX.ScrollBar.Size = 10
}
function New-TrendSeries($chart, $name, $legend, $axis, $color, [bool]$dash, $tip) {
    $s = New-Object System.Windows.Forms.DataVisualization.Charting.Series($name)
    # Line, not Spline: a spline overshoots between unevenly spaced samples.
    $s.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
    $s.XValueType = [System.Windows.Forms.DataVisualization.Charting.ChartValueType]::DateTime
    $s.BorderWidth = 2; $s.Color = $color; $s.YAxisType = $axis; $s.LegendText = $legend; $s.ToolTip = $tip
    $s.MarkerColor = $color
    if ($dash) { $s.BorderDashStyle = [System.Windows.Forms.DataVisualization.Charting.ChartDashStyle]::Dash }
    $chart.Series.Add($s)
}
function New-TrendBase($leftColor, $rightColor) {
    $T = $script:DashTheme
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $area  = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea('main')
    Style-ChartArea $chart $area $T.Surface ([System.Drawing.Color]::FromArgb(60, $T.TextT.R, $T.TextT.G, $T.TextT.B)) $T.TextS
    $area.AxisX.IntervalType = [System.Windows.Forms.DataVisualization.Charting.DateTimeIntervalType]::Hours
    $area.AxisY.LabelStyle.ForeColor = $leftColor; $area.AxisY.IsStartedFromZero = $false
    $area.AxisY2.Enabled = [System.Windows.Forms.DataVisualization.Charting.AxisEnabled]::True
    $area.AxisY2.IsStartedFromZero = $false; $area.AxisY2.LabelStyle.ForeColor = $rightColor; $area.AxisY2.MajorGrid.Enabled = $false
    $chart.ChartAreas.Add($area)
    $lg = New-Object System.Windows.Forms.DataVisualization.Charting.Legend('L')
    $lg.BackColor = [System.Drawing.Color]::Transparent; $lg.ForeColor = $T.TextS
    $lg.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Top
    $lg.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $chart.Legends.Add($lg)
    $tt = New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $tt.ForeColor = $T.TextP; $tt.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $tt.Alignment = [System.Drawing.ContentAlignment]::TopLeft
    $chart.Titles.Add($tt)
    return $chart
}
function New-TrendChart {
    $cTemp = [System.Drawing.Color]::FromArgb(255,122,89); $cDew = [System.Drawing.Color]::FromArgb(86,180,239); $cHum = [System.Drawing.Color]::FromArgb(72,199,142)
    $chart = New-TrendBase $cTemp $cHum
    $P = [System.Windows.Forms.DataVisualization.Charting.AxisType]::Primary; $S = [System.Windows.Forms.DataVisualization.Charting.AxisType]::Secondary
    $deg = $script:RsDeg
    New-TrendSeries $chart 'Humidity'    'Humidity (%)'           $S $cHum  $false "Humidity  #VALY{0}%  @ #VALX{ddd d MMM HH:mm}"
    New-TrendSeries $chart 'Temperature' "Temperature ($($deg)C)" $P $cTemp $false "Temperature  #VALY{0.0}$($deg)C  @ #VALX{ddd d MMM HH:mm}"
    New-TrendSeries $chart 'Dew point'   "Dew point ($($deg)C)"   $P $cDew  $true  "Dew point  #VALY{0.0}$($deg)C  @ #VALX{ddd d MMM HH:mm}"
    return $chart
}
function New-Co2Chart {
    $cCo2 = [System.Drawing.Color]::FromArgb(232,176,64); $cPres = [System.Drawing.Color]::FromArgb(167,139,238)
    $chart = New-TrendBase $cCo2 $cPres
    $P = [System.Windows.Forms.DataVisualization.Charting.AxisType]::Primary; $S = [System.Windows.Forms.DataVisualization.Charting.AxisType]::Secondary
    New-TrendSeries $chart 'CO2'      'CO2 (ppm)'      $P $cCo2  $false "CO2  #VALY{0} ppm  @ #VALX{ddd d MMM HH:mm}"
    New-TrendSeries $chart 'Pressure' 'Pressure (hPa)' $S $cPres $false "Pressure  #VALY{0.0} hPa  @ #VALX{ddd d MMM HH:mm}"
    return $chart
}
# Fill one series from the in-memory history, thinned to what a chart can show.
# A zoomed view (focus) is re-sampled at full detail.
function Fill-Series($chart, [string]$name, $tbl, [int]$col, $b, $focus) {
    $ff = [datetime]::MinValue; $ft = [datetime]::MinValue
    if ($focus) { $ff = $focus.From; $ft = $focus.To }
    $xy = $tbl.Sample($col, $b.From, $b.To, 2000, $ff, $ft, (2.0/24))
    $s = $chart.Series[$name]
    [Vulcan.ChartUtil]::Fill($s, $xy)
    # markers keep lone points visible on sparse data; on dense data they only cost time
    if ($xy.Count -le 400) { $s.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle; $s.MarkerSize = 4 }
    else { $s.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::None }
}
function Rebuild-Both($focus = $null) {
    $b = Get-RangeBounds
    if ($script:trendChart) {
        $C = [Vulcan.Data]::Clock
        Fill-Series $script:trendChart 'Humidity' $C 1 $b $focus
        Fill-Series $script:trendChart 'Temperature' $C 0 $b $focus
        Fill-Series $script:trendChart 'Dew point' $C 3 $b $focus
        $script:trendChart.Titles[0].Text = 'LYWSD02 clock'
        Update-Granularity $script:trendChart
    }
    if ($script:trendCo2Chart) {
        $A = [Vulcan.Data]::Air
        Fill-Series $script:trendCo2Chart 'CO2' $A 0 $b $focus
        Fill-Series $script:trendCo2Chart 'Pressure' $A 3 $b $focus
        $script:trendCo2Chart.Titles[0].Text = 'Aranet4 air quality'
        Update-Granularity $script:trendCo2Chart
    }
}
function Set-XGranularity($ax, [double]$spanH) {
    $IT = [System.Windows.Forms.DataVisualization.Charting.DateTimeIntervalType]
    if     ($spanH -gt 17520) { $ax.IntervalType = $IT::Years;   $ax.Interval = 1; $ax.LabelStyle.Format = 'yyyy' }
    elseif ($spanH -gt 2880)  { $ax.IntervalType = $IT::Months;  $ax.Interval = 1; $ax.LabelStyle.Format = 'MMM yyyy' }
    elseif ($spanH -gt 720)   { $ax.IntervalType = $IT::Weeks;   $ax.Interval = 1; $ax.LabelStyle.Format = 'MMM d' }
    elseif ($spanH -gt 96)    { $ax.IntervalType = $IT::Days;    $ax.Interval = 1; $ax.LabelStyle.Format = 'ddd d' }
    elseif ($spanH -gt 12)    { $ax.IntervalType = $IT::Hours;   $ax.Interval = 3; $ax.LabelStyle.Format = 'ddd HH:mm' }
    elseif ($spanH -gt 2)     { $ax.IntervalType = $IT::Hours;   $ax.Interval = 1; $ax.LabelStyle.Format = 'HH:mm' }
    elseif ($spanH -gt 0.5)   { $ax.IntervalType = $IT::Minutes; $ax.Interval = 10; $ax.LabelStyle.Format = 'HH:mm' }
    else                      { $ax.IntervalType = $IT::Minutes; $ax.Interval = 2; $ax.LabelStyle.Format = 'HH:mm' }
}
function Get-ChartXRange($chart) {
    $mn = [double]::PositiveInfinity; $mx = [double]::NegativeInfinity; $pc = 0
    foreach ($s in $chart.Series) {
        $n = $s.Points.Count
        if ($n -gt 0) {
            if ($s.Points[0].XValue -lt $mn) { $mn = $s.Points[0].XValue }
            if ($s.Points[$n-1].XValue -gt $mx) { $mx = $s.Points[$n-1].XValue }
            if ($n -gt $pc) { $pc = $n }
        }
    }
    return @{ Min=$mn; Max=$mx; Count=$pc }
}
function Update-Granularity($chart) {
    if (-not $chart -or $chart.ChartAreas.Count -eq 0) { return }
    try {
        $ax = $chart.ChartAreas['main'].AxisX; $sv = $ax.ScaleView
        $r = Get-ChartXRange $chart
        if ($r.Count -lt 2) { return }
        if ($sv.IsZoomed) { $spanH = ($sv.ViewMaximum - $sv.ViewMinimum) * 24 } else { $spanH = ($r.Max - $r.Min) * 24 }
        if ($spanH -le 0) { $spanH = 1 }
        Set-XGranularity $ax $spanH
    } catch {}
}
function Zoom-Reset {
    $script:zoomBusy = $true
    try {
        Rebuild-Both
        foreach ($c in @($script:trendChart, $script:trendCo2Chart)) { if ($c) { try { $c.ChartAreas['main'].AxisX.ScaleView.ZoomReset(0); Update-Granularity $c } catch {} } }
    } finally { $script:zoomBusy = $false }
}
# Show the same time window [vmin,vmax] (OADate) on both charts, re-sampled at full detail.
function Zoom-Apply($vmin, $vmax) {
    if ($script:zoomBusy) { return }
    $script:zoomBusy = $true
    try {
        $span = $vmax - $vmin
        Rebuild-Both @{ From = [datetime]::FromOADate($vmin - $span); To = [datetime]::FromOADate($vmax + $span) }
        foreach ($c in @($script:trendChart, $script:trendCo2Chart)) {
            if (-not $c) { continue }
            try {
                $r = Get-ChartXRange $c
                if ($r.Count -lt 2 -or $r.Max -le $r.Min) { continue }
                $mn = [math]::Max($vmin, $r.Min); $mx = [math]::Min($vmax, $r.Max)
                if ($mx -gt $mn) { $c.ChartAreas['main'].AxisX.ScaleView.Zoom($mn, $mx) } else { $c.ChartAreas['main'].AxisX.ScaleView.ZoomReset(0) }
                Update-Granularity $c
            } catch {}
        }
    } finally { $script:zoomBusy = $false }
}
$script:OnChartWheel = {
    param($sender, $e)
    try {
        $chart = $sender
        $ax = $chart.ChartAreas['main'].AxisX
        $r = Get-ChartXRange $chart
        if ($r.Count -lt 2 -or $r.Max -le $r.Min) { return }
        $fullRange = $r.Max - $r.Min
        $sv = $ax.ScaleView
        if ($sv.IsZoomed) { $curMin = $sv.ViewMinimum; $curMax = $sv.ViewMaximum } else { $curMin = $r.Min; $curMax = $r.Max }
        if ([double]::IsNaN($curMin) -or [double]::IsNaN($curMax) -or $curMax -le $curMin) { $curMin = $r.Min; $curMax = $r.Max }
        $curRange = $curMax - $curMin
        $anchor = $null
        try { $anchor = $ax.PixelPositionToValue([double]$e.Location.X) } catch {}
        if ($null -eq $anchor -or [double]::IsNaN($anchor) -or $anchor -lt $curMin -or $anchor -gt $curMax) { $anchor = ($curMin + $curMax) / 2 }
        $minRange = 10.0 / 1440.0                             # ten minutes is as far in as it goes
        $factor = if ($e.Delta -gt 0) { 0.75 } else { 1.333 } # wheel up = zoom in
        $newRange = $curRange * $factor
        if ($newRange -ge $fullRange) { Zoom-Reset; return }
        if ($newRange -lt $minRange) { $newRange = $minRange }
        $leftFrac = ($anchor - $curMin) / $curRange
        $newMin = $anchor - $leftFrac * $newRange; $newMax = $newMin + $newRange
        if ($newMin -lt $r.Min) { $newMin = $r.Min; $newMax = $r.Min + $newRange }
        if ($newMax -gt $r.Max) { $newMax = $r.Max; $newMin = $r.Max - $newRange }
        Zoom-Apply $newMin $newMax
    } catch {}
}
function Show-TrendsWindow {
    try {
        if ($script:trendForm -and -not $script:trendForm.IsDisposed) {
            Rebuild-Both
            $script:trendForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $script:trendForm.Activate(); return
        }
        Add-Type -AssemblyName System.Windows.Forms.DataVisualization
        $T = $script:DashTheme
        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'Trends  -  scroll to zoom, drag the scrollbar to pan'
        $f.Size = New-Object System.Drawing.Size(980,680); $f.MinimumSize = New-Object System.Drawing.Size(600,440)
        $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $f.BackColor = $T.Canvas; $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        try { $f.Icon = [System.Drawing.Icon]::FromHandle($script:iconHandle) } catch {}
        $envChart = New-TrendChart; $envChart.Dock = [System.Windows.Forms.DockStyle]::Fill
        $co2Chart = New-Co2Chart;   $co2Chart.Dock = [System.Windows.Forms.DockStyle]::Fill
        foreach ($c in @($envChart, $co2Chart)) {
            $c.Add_MouseEnter({ try { $this.Focus() } catch {} })
            $c.Add_MouseWheel($script:OnChartWheel)
            # panning with the scrollbar: keep the detail under the view
            $c.Add_AxisViewChanged({ param($s,$e); try { if (-not $script:zoomBusy -and -not [double]::IsNaN($e.NewPosition) -and $e.NewSize -gt 0) { Zoom-Apply $e.NewPosition ($e.NewPosition + $e.NewSize) } } catch {} })
        }
        $split = New-Object System.Windows.Forms.SplitContainer
        $split.Dock = [System.Windows.Forms.DockStyle]::Fill
        $split.Orientation = [System.Windows.Forms.Orientation]::Horizontal
        $split.BackColor = $T.Canvas; $split.Panel1MinSize = 90; $split.Panel2MinSize = 90; $split.SplitterWidth = 8
        $split.Panel1.Controls.Add($envChart); $split.Panel2.Controls.Add($co2Chart)
        $bar = New-Object System.Windows.Forms.Panel
        $bar.Size = New-Object System.Drawing.Size($f.ClientSize.Width, 52)
        $bar.Dock = [System.Windows.Forms.DockStyle]::Bottom; $bar.BackColor = $T.Canvas

        $lblRange = New-Object System.Windows.Forms.Label
        $lblRange.Text = 'Range'; $lblRange.ForeColor = $T.TextS; $lblRange.AutoSize = $true; $lblRange.Location = New-Object System.Drawing.Point(14,18)
        # These are used by event handlers that fire after this function returns, so
        # they live in script scope (handler scriptblocks do not capture locals).
        $script:cbRange = New-Object System.Windows.Forms.ComboBox
        $script:cbRange.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
        $script:cbRange.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $script:cbRange.BackColor = $T.Sunken; $script:cbRange.ForeColor = $T.TextP
        $script:cbRange.Width = 140; $script:cbRange.Location = New-Object System.Drawing.Point(62,14)
        foreach ($k in $script:RangeMap.Keys) { [void]$script:cbRange.Items.Add($k) }
        $curCode = $script:settings.TrendRange; if (-not $curCode) { $curCode = '7d' }
        $curLabel = ($script:RangeMap.GetEnumerator() | Where-Object { $_.Value -eq $curCode } | Select-Object -First 1).Key
        if (-not $curLabel) { $curLabel = 'Last 7 days' }
        $script:cbRange.SelectedItem = $curLabel
        $script:dtFrom = New-Object System.Windows.Forms.DateTimePicker
        $script:dtFrom.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
        $script:dtFrom.Width = 110; $script:dtFrom.Location = New-Object System.Drawing.Point(214,14)
        $script:dtTo = New-Object System.Windows.Forms.DateTimePicker
        $script:dtTo.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
        $script:dtTo.Width = 110; $script:dtTo.Location = New-Object System.Drawing.Point(350,14)
        $script:lblTo = New-Object System.Windows.Forms.Label
        $script:lblTo.Text = 'to'; $script:lblTo.ForeColor = $T.TextS; $script:lblTo.AutoSize = $true; $script:lblTo.Location = New-Object System.Drawing.Point(329,18)
        try { if ($script:settings.TrendFrom) { $script:dtFrom.Value = [datetime]$script:settings.TrendFrom } else { $script:dtFrom.Value = (Get-Date).AddDays(-7) } } catch {}
        try { if ($script:settings.TrendTo) { $script:dtTo.Value = ([datetime]$script:settings.TrendTo).Date } } catch {}
        $showCustom = ($curCode -eq 'custom')
        $script:dtFrom.Visible = $showCustom; $script:dtTo.Visible = $showCustom; $script:lblTo.Visible = $showCustom
        $applyRange = {
            try {
                $sel = $script:cbRange.SelectedItem; if (-not $sel) { return }
                $code = $script:RangeMap[[string]$sel]; if (-not $code) { return }
                $script:settings.TrendRange = $code
                $isCustom = ($code -eq 'custom')
                $script:dtFrom.Visible = $isCustom; $script:dtTo.Visible = $isCustom; $script:lblTo.Visible = $isCustom
                if ($isCustom) {
                    $script:settings.TrendFrom = $script:dtFrom.Value.Date.ToString('yyyy-MM-dd')
                    $script:settings.TrendTo   = $script:dtTo.Value.Date.AddDays(1).AddSeconds(-1).ToString('yyyy-MM-dd HH:mm:ss')
                }
                Save-Settings
                Zoom-Reset
            } catch { WLog "WARN range change: $($_.Exception.Message)" }
        }
        $script:cbRange.Add_SelectedIndexChanged($applyRange)
        $script:dtFrom.Add_ValueChanged($applyRange)
        $script:dtTo.Add_ValueChanged($applyRange)
        $bReset = New-Object Vulcan.PillButton; $bReset.Text = 'Reset zoom'; $bReset.BackColor = $T.Canvas; [void]$bReset.Fit()
        $bFolder = New-Object Vulcan.PillButton; $bFolder.Text = 'Open data folder'; $bFolder.Glyph = $script:GlFolder; $bFolder.BackColor = $T.Canvas; [void]$bFolder.Fit()
        $bFolder.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
        $bReset.Anchor = $bFolder.Anchor
        $cw = $f.ClientSize.Width
        $bFolder.Location = New-Object System.Drawing.Point(($cw - $bFolder.Width - 14), 8)
        $bReset.Location = New-Object System.Drawing.Point(($bFolder.Left - $bReset.Width - 8), 8)
        $bReset.Add_Click({ Zoom-Reset })
        $bFolder.Add_Click({ Start-Process explorer.exe $LogDir })
        $bar.Controls.AddRange(@($lblRange, $script:cbRange, $script:dtFrom, $script:lblTo, $script:dtTo, $bReset, $bFolder))
        $f.Controls.Add($split)   # Fill first
        $f.Controls.Add($bar)     # Bottom last
        $script:trendForm = $f; $script:trendChart = $envChart; $script:trendCo2Chart = $co2Chart
        $script:trendSplit = $split
        Rebuild-Both
        $f.Add_Shown({ try { $script:trendSplit.SplitterDistance = [int]($script:trendSplit.Height * 0.52) } catch {} })
        $f.Add_FormClosed({ $script:trendForm = $null; $script:trendChart = $null; $script:trendCo2Chart = $null })
        $f.Show(); $f.Activate()
    } catch { WLog "ERROR trends window: $($_.Exception.Message) :: $($_.ScriptStackTrace)" }
}

# ===========================================================================
#  Room state dashboard
#  A verdict-led view: one plain-language read of the room, then quiet cards
#  that each answer a human question. One accent; colour only where it means
#  something. Painters read $script:rs and never compute.
# ===========================================================================
function Rs-PaintVerdict($g, $p) {
    $T = $script:DashTheme; $F = $script:RsFonts; $Gx = [Vulcan.Gfx]
    $Gx::Setup($g); $g.Clear($T.Canvas)
    if (-not $script:rs) { $Gx::Fill($g, (Rs-Skel), 30, 12, 380, 26, 6); return }
    $fa = $script:rsVAlpha; if ($fa -lt 0) { $fa = 0 }; if ($fa -gt 1) { $fa = 1 }
    $tw = $p.Width - 34
    if ($fa -lt 1 -and $script:rsPrevVerdict) {
        $Gx::TextBox($g, $script:rsPrevVerdict, $F.Verdict, [System.Drawing.Color]::FromArgb([int](255*(1-$fa)), $T.TextP.R, $T.TextP.G, $T.TextP.B), 28, 0, $tw, 44, $false)
    }
    $Gx::TextBox($g, $script:rs.Verdict, $F.Verdict, [System.Drawing.Color]::FromArgb([int](255*$fa), $T.TextP.R, $T.TextP.G, $T.TextP.B), 28, 0, $tw, 44, $false)
    # room name (click to rename) and when this was last worked out
    $name = [string]$script:settings.RoomName; if (-not $name) { $name = 'Room' }
    $x = 32; $y = 47
    $nw = $Gx::Width($g, $name, $F.BodyB)
    if (-not ($script:dash -and $script:dash.NameBox -and $script:dash.NameBox.Visible)) {
        $Gx::Text($g, $name, $F.BodyB, $T.TextS, $x, $y)
        $Gx::Text($g, $script:GlEdit, $F.Glyph, $T.TextT, ($x + $nw + 1), ($y + 4))
    }
    if ($script:dash) { $script:dash.NameRect = New-Object System.Drawing.Rectangle(($x - 4), ($y - 3), [int]($nw + 26), 26) }
    $Gx::Text($g, ("$($script:RsMid)   updated " + $script:rs.Updated.ToString('HH:mm')), $F.Body, $T.TextT, ($x + $nw + 24), $y)
}
function Rs-PaintAlerts($g, $p) {
    $T = $script:DashTheme; $F = $script:RsFonts; $Gx = [Vulcan.Gfx]
    $Gx::Setup($g); $g.Clear($T.Canvas)
    if (-not $script:rs -or $script:rs.Alerts.Count -eq 0) { return }
    $x = 0; $y = 2; $h = 32; $n = $script:rs.Alerts.Count; $i = 0
    foreach ($al in $script:rs.Alerts) {
        $col = $T.Caution; if ($al.Level -eq 'alert') { $col = $T.Alert } elseif ($al.Level -eq 'info') { $col = $T.TextS }
        $tw = $Gx::Width($g, $al.Title, $F.BodyB); $mw = $Gx::Width($g, $al.Msg, $F.Body)
        $avail = $p.Width - $x
        if ($avail -lt (30 + $tw + 16)) { $Gx::Text($g, "+$($n - $i) more", $F.Body, $T.TextT, ($x + 2), ($y + 7)); break }
        $w = [Math]::Min((30 + $tw + 6 + $mw + 16), $avail)
        $Gx::Fill($g, [System.Drawing.Color]::FromArgb(30, $col.R, $col.G, $col.B), $x, $y, $w, $h, 16)
        $Gx::Stroke($g, [System.Drawing.Color]::FromArgb(90, $col.R, $col.G, $col.B), $x, $y, $w, $h, 16)
        $Gx::Dot($g, $col, ($x + 12), ($y + 12), 8)
        $Gx::Text($g, $al.Title, $F.BodyB, $T.TextP, ($x + 26), ($y + 7))
        $Gx::TextBox($g, $al.Msg, $F.Body, $T.TextS, ($x + 26 + $tw + 4), ($y + 7), ($w - (26 + $tw + 4) - 10), 20, $false)
        $x += $w + 10; $i++
    }
}
function Rs-PaintVital($g, $p) {
    $T = $script:DashTheme; $F = $script:RsFonts; $Gx = [Vulcan.Gfx]
    $Gx::Card($g, $p.Width, $p.Height, 16)
    $pad = 16
    if (-not $script:rs) { $Gx::Fill($g, (Rs-Skel), $pad, ($pad+28), 84, 26, 6); return }
    $d = $script:rs.V[$p.Tag.Key]; if (-not $d) { return }
    Rs-Icon $g $d.Icon $pad ($pad+1) 18 $T.TextT
    $Gx::Text($g, $d.Label, $F.Body, $T.TextS, ($pad+24), $pad)
    if ($d.Note) { $Gx::TextRight($g, $d.Note, $F.Caption, $T.TextT, $pad, ($pad+2), ($p.Width-2*$pad)) }
    if ($null -eq $d.Raw) {
        $Gx::Text($g, [string]$script:RsEm, $F.Value, $T.TextT, $pad, ($pad+24))
        $Gx::Text($g, 'waiting for sensor', $F.Caption, $T.TextT, $pad, ($p.Height-$pad-14))
        return
    }
    $vcol = $T.TextP; if ($d.Stale) { $vcol = $T.TextT }
    $vw = $Gx::Num($g, (Rs-Fmt $d.DispKey $d.Fmt), $F.Value, $vcol, $pad, ($pad+24))
    $Gx::Text($g, $d.Unit, $F.Unit, $T.TextT, ($pad+$vw+3), ($pad+41))
    $cy = $p.Height - $pad - 14
    if ($d.Stale) { $Gx::Text($g, ('last read ' + $d.AgeText), $F.Caption, $T.Caution, $pad, $cy) }
    elseif ($null -ne $d.Delta) {
        $dcol = $T.TextT; if ($d.Hot) { $dcol = $T.Caution }
        if ($d.Delta -eq 0) { $Gx::Text($g, 'steady this hour', $F.Caption, $T.TextT, $pad, $cy) }
        else {
            $chev = $script:RsUp; if ($d.Delta -lt 0) { $chev = $script:RsDn }
            $Gx::Text($g, ("$chev " + ($d.DFmt -f [Math]::Abs($d.Delta)) + $d.DUnit + ' in 1 h'), $F.Caption, $dcol, $pad, $cy)
        }
    }
    $sw = [int]($p.Width*0.38); if ($sw -lt 40) { $sw = 40 }
    if ($d.Spark -and $d.Spark.Length -ge 2 -and -not $d.Stale -and $p.Width -gt 190) { $Gx::Spark($g, $d.Spark, ($p.Width-$pad-$sw), ($pad+26), $sw, 28, $T.Accent, $T.AccentWash) }
}
function Rs-PaintAirQuality($g, $p) {
    $T = $script:DashTheme; $F = $script:RsFonts; $Gx = [Vulcan.Gfx]
    $Gx::Card($g, $p.Width, $p.Height, 18)
    if (-not $script:rs) { $Gx::Fill($g, (Rs-Skel), 22, 46, 150, 34, 6); return }
    $sp = 0.0; if ($script:rsSettle.ContainsKey('aq')) { $sp = $script:rsSettle['aq'] }
    $gs = $g.Save()
    if ($sp -gt 0.01) { $sc = 1 + 0.03*[Math]::Sin($sp*[Math]::PI); $cx = $p.Width/2.0; $cy = $p.Height/2.0; $g.TranslateTransform($cx,$cy); $g.ScaleTransform($sc,$sc); $g.TranslateTransform(-$cx,-$cy) }
    $pad = 22; $rs = $script:rs
    $Gx::Text($g, 'Air quality', $F.Title, $T.TextP, $pad, ($pad-4))
    $co2 = $rs.Co2
    if ($null -eq $co2) {
        $Gx::Text($g, [string]$script:RsEm, $F.Big, $T.TextT, $pad, ($pad+18))
        $Gx::Text($g, 'Waiting for the Aranet4 to broadcast.', $F.Body, $T.TextT, $pad, ($p.Height-$pad-18))
        $g.Restore($gs); return
    }
    $vcol = $T.TextP; if ($rs.Co2Stale) { $vcol = $T.TextT }
    $vw = $Gx::Num($g, (Rs-Fmt 'co2' '{0:0}'), $F.Big, $vcol, $pad, ($pad+18))
    $Gx::Text($g, ('ppm CO' + $script:RsSub2), $F.Unit, $T.TextT, ($pad+$vw+4), ($pad+43))
    # how fast it is moving, on the right
    $sl = NVal $rs.M.Co2Slope
    if ($null -ne $sl -and -not $rs.Co2Stale -and [Math]::Abs($sl) -ge 60) {
        $ch = $script:RsUp; $w = 'rising'; if ($sl -lt 0) { $ch = $script:RsDn; $w = 'falling' }
        $scol = $T.TextS; if ($sl -gt 0 -and $co2 -ge 1000) { $scol = $T.Caution }
        $Gx::TextRight($g, ("$ch $w {0:0} ppm an hour" -f [Math]::Abs($sl)), $F.Body, $scol, $pad, ($pad+42), ($p.Width-2*$pad))
    }
    $by = $pad + 70; $bw = $p.Width - $pad*2
    $Gx::Band($g, $pad, $by, $bw, 12, 400, 2200, [double[]]@(400,800,1200,2000), [double[]]@(800,1200,2000,2200), [System.Drawing.Color[]]@($T.Accent,$T.TextT,$T.Caution,$T.Alert), [double]$co2)
    $Gx::Text($g, 'fresh', $F.Caption, $T.TextT, $pad, ($by+17))
    $Gx::TextRight($g, 'poor', $F.Caption, $T.TextT, $pad, ($by+17), $bw)
    $ny = $p.Height - $pad - 16
    if ($rs.Co2Stale) { $Gx::TextBox($g, ("Last measured $($rs.Co2Age). This may be out of date."), $F.Body, $T.Caution, $pad, $ny, $bw, 20, $false) }
    else {
        $note = 'Good for thinking.'
        if ($co2 -ge 2000) { $note = 'Headaches and drowsiness are likely. Air the room.' }
        elseif ($co2 -ge 1400) { $note = 'Concentration suffers at this level. Open a window.' }
        elseif ($co2 -ge 1000) { $note = 'Focus may start to dip.' }
        $Gx::TextBox($g, ("About {0:0.0}% of each breath is air someone has already breathed. {1}" -f $rs.Rebreathed, $note), $F.Body, $T.TextS, $pad, $ny, $bw, 20, $false)
    }
    $g.Restore($gs)
}
function Rs-PaintOccupancy($g, $p) {
    $T = $script:DashTheme; $F = $script:RsFonts; $Gx = [Vulcan.Gfx]
    $Gx::Card($g, $p.Width, $p.Height, 18)
    if (-not $script:rs) { $Gx::Fill($g, (Rs-Skel), 20, 46, 120, 26, 6); return }
    $pad = 20; $occ = $script:rs.Occ; $w = $p.Width - 2*$pad
    $Gx::Text($g, 'Occupancy', $F.Title, $T.TextP, $pad, ($pad-4))
    if ($null -eq $occ.Level) { $Gx::Text($g, 'Waiting for the Aranet4.', $F.Body, $T.TextT, $pad, ($pad+28)); return }
    $Gx::Text($g, $occ.Band, $F.Value, $T.TextP, $pad, ($pad+20))
    $ng = @(0, 2, 3, 4)[$occ.Level]
    for ($i = 0; $i -lt $ng; $i++) { Rs-Person $g ($pad+10+$i*22) ($pad+60) 22 $T.TextS }
    $sub = ''
    if ($occ.Held) { $sub = 'Airing now, so this is the count from just before.' }
    elseif ($occ.Level -eq 0 -and $occ.Low) { $sub = 'At outdoor level: empty, or very well aired.' }
    elseif ($occ.Night -and $occ.Level -ge 1) { $sub = 'Probably asleep.' }
    if ($sub) { $sy = $pad + 88; if ($ng -eq 0) { $sy = $pad + 62 }; $Gx::TextBox($g, $sub, $F.Body, $T.TextS, $pad, $sy, $w, 20, $false) }
    $Gx::TextBox($g, ("inferred from CO$($script:RsSub2)  $($script:RsMid)  $($occ.Volume) m$($script:RsSup3) room  $($script:RsMid)  no camera"), $F.Caption, $T.TextT, $pad, ($p.Height-$pad-14), $w, 16, $false)
}
function Rs-PaintVentilation($g, $p) {
    $T = $script:DashTheme; $F = $script:RsFonts; $Gx = [Vulcan.Gfx]
    $Gx::Card($g, $p.Width, $p.Height, 18)
    if (-not $script:rs) { return }
    $pad = 20; $rs = $script:rs; $M = $rs.M; $w = $p.Width - 2*$pad; $lvl = [int]$rs.AchLevel
    $Gx::Text($g, 'Ventilation', $F.Title, $T.TextP, $pad, ($pad-4))
    if ($rs.AchKind -eq 'live') { $tag = 'measuring now'; if ($rs.Airing) { $tag = 'airing now' }; $Gx::TextRight($g, $tag, $F.Caption, $T.Accent, $pad, ($pad-1), $w) }
    elseif ($rs.AchKind -eq 'typical') { $Gx::TextRight($g, 'usual for this room', $F.Caption, $T.TextT, $pad, ($pad-1), $w) }
    $bcol = $T.TextP; if ($lvl -lt 0) { $bcol = $T.TextT }
    $Gx::Text($g, $rs.AchBand, $F.Value, $bcol, $pad, ($pad+20))
    $by = $pad + 62; $seg = ($w - 3*6)/4.0
    for ($i = 0; $i -lt 4; $i++) {
        $col = $T.Sunken; if ($lvl -ge 0 -and $i -le $lvl) { $col = $T.Accent }
        $Gx::Fill($g, $col, ($pad+$i*($seg+6)), $by, $seg, 6, 3)
    }
    $line = ''; $cap = ''
    if ($rs.AchKind -eq 'live') {
        $line = "$($script:RsApx){0:0.0} air changes an hour" -f $rs.Ach
        $fm = NVal $M.FreshenMin
        if ($null -ne $fm -and $fm -ge 1) { if ($fm -gt 180) { $line += "  $($script:RsMid)  slow to clear" } else { $line += ("  $($script:RsMid)  fresh in ~{0:0} min" -f $fm) } }
        $cap = "from the CO$($script:RsSub2) fall in progress"
        if ($M.AchLiveOccupied) { $cap += ', with people still in the room' }
    } elseif ($rs.AchKind -eq 'typical') {
        $line = "$($script:RsApx){0:0.0} air changes an hour" -f $rs.Ach
        $la = NVal $M.AchLast
        if ($null -ne $la) { $line += ("  $($script:RsMid)  last measured {0:0.0}, {1}" -f $la, (Rs-AgeText $M.AchLastAgeMin)) }
        $cap = "median of $($M.AchHistory) CO$($script:RsSub2) falls over 30 days"
    } elseif ($rs.AchKind -eq 'last') {
        $line = ("$($script:RsApx){0:0.0} air changes an hour, measured {1}" -f $rs.Ach, (Rs-AgeText $M.AchLastAgeMin))
        $cap = "from one CO$($script:RsSub2) fall so far"
    } else {
        $line = "Needs CO$($script:RsSub2) to build up and then fall."
        $cap = 'measured each time the room airs out or empties'
    }
    $Gx::TextBox($g, $line, $F.Body, $T.TextS, $pad, ($by+16), $w, 20, $false)
    $Gx::TextBox($g, $cap, $F.Caption, $T.TextT, $pad, ($p.Height-$pad-14), $w, 16, $false)
}
function Rs-PaintComfort($g, $p) {
    $T = $script:DashTheme; $F = $script:RsFonts; $Gx = [Vulcan.Gfx]
    $Gx::Card($g, $p.Width, $p.Height, 18)
    if (-not $script:rs) { return }
    $pad = 20; $rs = $script:rs; $w = $p.Width - 2*$pad
    $Gx::Text($g, 'Comfort', $F.Title, $T.TextP, $pad, ($pad-4))
    if ($null -ne $rs.Dew) {
        $feel = 'dry air'; if ($rs.Dew -ge 21) { $feel = 'oppressive' } elseif ($rs.Dew -ge 18) { $feel = 'muggy' } elseif ($rs.Dew -ge 13) { $feel = 'comfortable' } elseif ($rs.Dew -ge 8) { $feel = 'crisp' }
        $Gx::TextRight($g, $feel, $F.Caption, $T.TextT, $pad, ($pad-1), $w)
        $dw = $Gx::Num($g, (Rs-Fmt 'dew' '{0:0.0}'), $F.Value, $T.TextP, $pad, ($pad+20))
    } else { $dw = $Gx::Num($g, [string]$script:RsEm, $F.Value, $T.TextT, $pad, ($pad+20)) }
    $Gx::Text($g, ($script:RsDeg + 'C dew point'), $F.Unit, $T.TextT, ($pad+$dw+4), ($pad+37))
    $by = $pad + 62
    $Gx::Band($g, $pad, ($by-3), $w, 12, 0, 100, [double[]]@(40), [double[]]@(60), [System.Drawing.Color[]]@($T.Accent), (NNum $rs.Hum))
    if ($null -ne $rs.Hum -and $null -ne $rs.Abs) {
        $Gx::TextBox($g, ("{0:0}% RH  $($script:RsMid)  {1:0.0} g of water per m$($script:RsSup3)" -f $rs.Hum, $rs.Abs), $F.Body, $T.TextS, $pad, ($by+16), $w, 20, $false)
    }
    $Gx::Text($g, ('comfort band 40' + $script:RsNd + '60% RH'), $F.Caption, $T.TextT, $pad, ($p.Height-$pad-14))
}
function Rs-PaintOutside($g, $p) {
    $T = $script:DashTheme; $F = $script:RsFonts; $Gx = [Vulcan.Gfx]
    $Gx::Card($g, $p.Width, $p.Height, 18)
    if (-not $script:rs) { return }
    $pad = 20; $rs = $script:rs; $w = $p.Width - 2*$pad
    $Gx::Text($g, 'Outside', $F.Title, $T.TextP, $pad, ($pad-4))
    $arrow = $script:RsRt; if ($rs.PresDir -lt 0) { $arrow = $script:RsDR } elseif ($rs.PresDir -gt 0) { $arrow = $script:RsUR }
    $acol = $T.TextP; if ($null -eq $rs.PresRate) { $acol = $T.TextT }
    $Gx::Text($g, [string]$arrow, $F.Arrow, $acol, ($pad-2), ($pad+20))
    $Gx::Text($g, $rs.PresTrend, $F.Value, $acol, ($pad+30), ($pad+20))
    if ($null -ne $rs.PresRate) { $Gx::TextRight($g, ("{0:+0.0;-0.0} hPa in 3 h" -f $rs.PresRate), $F.Caption, $T.TextT, $pad, ($pad-1), $w) }
    $Gx::TextBox($g, $rs.PresNote, $F.Body, $T.TextS, $pad, ($pad+78), $w, 20, $false)
    $Gx::TextBox($g, ("pressure tendency  $($script:RsMid)  no outdoor sensor"), $F.Caption, $T.TextT, $pad, ($p.Height-$pad-14), $w, 16, $false)
}
function Rs-PaintTimeline($g, $p) {
    $T = $script:DashTheme; $F = $script:RsFonts; $Gx = [Vulcan.Gfx]
    $Gx::Card($g, $p.Width, $p.Height, 18)
    if (-not $script:rs) { $Gx::Fill($g, (Rs-Skel), 20, 42, 220, 16, 6); return }
    $pad = 20; $M = $script:rs.M
    $Gx::Text($g, 'Today', $F.Title, $T.TextP, $pad, ($pad-4))
    $lx = $p.Width - 232
    if ($lx -gt $pad + 70) {
        $Gx::Line($g, $T.Accent, 2.5, $lx, ($pad+6), ($lx+16), ($pad+6), $false); $Gx::Text($g, ('CO' + $script:RsSub2), $F.Caption, $T.TextT, ($lx+21), ($pad-2))
        $Gx::Line($g, $T.TextT, 1.5, ($lx+62), ($pad+6), ($lx+78), ($pad+6), $false); $Gx::Text($g, 'people (inferred)', $F.Caption, $T.TextT, ($lx+83), ($pad-2))
    }
    $x = $pad; $y = $pad + 26; $w = $p.Width - $pad*2; $h = $p.Height - $y - $pad - 12
    if ($h -lt 16 -or $w -lt 60) { return }
    # night shading by the clock (00:00-06:30 and 20:30-24:00)
    $nb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(16,120,130,160))
    $g.FillRectangle($nb, [single]$x, [single]$y, [single]($w*0.271), [single]$h)
    $g.FillRectangle($nb, [single]($x+$w*0.854), [single]$y, [single]($w*0.146), [single]$h); $nb.Dispose()
    foreach ($hh in 6, 12, 18) { $Gx::Line($g, $T.Hairline, 1, ($x+$w*$hh/24.0), $y, ($x+$w*$hh/24.0), ($y+$h), $false) }
    if ($M.TlX.Length -ge 2) {
        $scale = $Gx::Timeline($g, $M, $x, $y, $w, $h, $T.Accent, $T.AccentWash, $T.TextT)
        $Gx::Text($g, ('{0:0} ppm' -f $scale[1]), $F.Caption, $T.TextT, ($x+3), ($y+1))
        $nx = $x + (((Get-Date) - (Get-Date).Date).TotalHours/24.0)*$w
        $Gx::Line($g, $T.TextS, 1, $nx, $y, $nx, ($y+$h), $true)
        if ($null -ne $script:rsScrubFrac) {
            $i = $Gx::Nearest($M.TlX, [double]$script:rsScrubFrac)
            if ($i -ge 0 -and [Math]::Abs($M.TlX[$i] - $script:rsScrubFrac) -lt 0.03) {
                $sx = $x + $M.TlX[$i]*$w
                $Gx::Line($g, $T.TextP, 1, $sx, $y, $sx, ($y+$h), $false)
                $who = @('empty', ('1' + $script:RsNd + '2 people'), 'several people', 'a crowd')[$M.TlOcc[$i]]
                $lbl = ((Get-Date).Date.AddDays($M.TlX[$i])).ToString('HH:mm') + ("   {0:0} ppm   " -f $M.TlCo2[$i]) + $who
                $lw = $Gx::Width($g, $lbl, $F.Caption); $lxp = $sx + 6; if ($lxp + $lw -gt $x + $w) { $lxp = $sx - 6 - $lw }
                $Gx::Fill($g, $T.Surface, ($lxp-3), ($y+14), ($lw+6), 16, 4)
                $Gx::Text($g, $lbl, $F.Caption, $T.TextP, $lxp, ($y+15))
            }
        }
    } else { $Gx::Text($g, 'Gathering today''s readings.', $F.Body, $T.TextT, ($x+8), ($y+$h/2-8)) }
    $ly = $y + $h + 2
    $Gx::Text($g, '00:00', $F.Caption, $T.TextT, $x, $ly)
    foreach ($hh in 6, 12, 18) { $Gx::Text($g, ('{0:00}:00' -f $hh), $F.Caption, $T.TextT, ($x+$w*$hh/24.0-14), $ly) }
    $Gx::TextRight($g, '24:00', $F.Caption, $T.TextT, $x, $ly, $w)
}
# Bottom-right of the action bar: quiet device status, replaced for a few seconds
# by a message when a read finishes or something needs saying.
function Rs-PaintStatus($g, $p) {
    $T = $script:DashTheme; $F = $script:RsFonts; $Gx = [Vulcan.Gfx]
    $Gx::Setup($g); $g.Clear($T.Canvas)
    $w = $p.Width; $h = $p.Height
    $note = $script:toast
    if ($note) {
        $acc = $T.Accent; if ($note.Kind -eq 'warn') { $acc = $T.Caution } elseif ($note.Kind -eq 'alert') { $acc = $T.Alert }
        $bw = [Math]::Min($w - 8, 500); $bx = $w - $bw
        $Gx::Fill($g, $T.Sunken, $bx, 4, ($bw-1), ($h-9), 12); $Gx::Stroke($g, $T.Hairline, $bx, 4, ($bw-1), ($h-9), 12)
        $Gx::Dot($g, $acc, ($bx+14), 13, 8)
        $Gx::Text($g, $note.Title, $F.Caption, $acc, ($bx+30), 8)
        $Gx::TextBox($g, $note.Msg, $F.Body, $T.TextP, ($bx+30), 22, ($bw-42), ($h-28), $true)
        return
    }
    if (-not $script:rs) { return }
    $rs = $script:rs; $S = $script:settings; $mid = "   $($script:RsMid)   "
    $busy = Job-Active 'clock'
    $l1 = 'Bluetooth off'; $dot = $T.TextT
    if ($S.ConnectionEnabled) {
        $dot = $T.Accent; if ($rs.AlertLevel -eq 'alert') { $dot = $T.Alert } elseif ($rs.AlertLevel -eq 'caution' -or $rs.Co2Stale -or $rs.EnvStale) { $dot = $T.Caution }
        $ct = '--'; if ($rs.ClockWhen) { $ct = $rs.ClockWhen.ToString('HH:mm') }
        $at = '--'; if ($rs.AranetWhen) { $at = $rs.AranetWhen.ToString('HH:mm') }
        $l1 = "clock read $ct"; if ($busy) { $l1 = 'reading the clock...' }
        if ($S.AranetEnabled) { $l1 += $mid + "CO$($script:RsSub2) measured $at" }
    }
    $cb = '--'; if ($null -ne $rs.ClockBatt) { $cb = '{0:0}%' -f $rs.ClockBatt }
    $abt = '--'; if ($null -ne $rs.AranetBatt) { $abt = '{0:0}%' -f $rs.AranetBatt }
    $l2 = "battery: clock $cb, Aranet $abt"
    if ($script:lastAranet -and $script:lastAranet.Interval -gt 0) { $l2 += $mid + "Aranet measures every $([int]($script:lastAranet.Interval/60)) min" }
    $l1w = $Gx::Width($g, $l1, $F.Body)
    $Gx::TextRight($g, $l1, $F.Body, $T.TextS, 0, 10, $w)
    if ($w - $l1w - 18 -gt 0) { $Gx::Dot($g, $dot, ($w - $l1w - 14), 16, 7) }
    $Gx::TextRight($g, $l2, $F.Caption, $T.TextT, 0, 31, $w)
}
function Rs-PaintDrawer($g, $p) {
    $T = $script:DashTheme; $F = $script:RsFonts; $Gx = [Vulcan.Gfx]
    $Gx::Setup($g); $g.Clear($T.Surface)
    $Gx::Line($g, $T.Hairline, 1, 0, 0, 0, $p.Height, $false)
    $Gx::Text($g, 'Settings', $F.Title, $T.TextP, 24, 20)
    foreach ($l in $script:dash.DrawerLabels) {
        if ($l.Kind -eq 'section') { $Gx::Text($g, $l.Text, $F.Section, $T.TextT, 24, $l.Y) }
        elseif ($l.Kind -eq 'note') { $Gx::TextBox($g, $l.Text, $F.Caption, $T.TextT, 24, $l.Y, ($p.Width-48), 30, $true) }
        else { $Gx::Text($g, $l.Text, $F.Body, $T.TextP, 24, $l.Y) }
    }
}

function Sync-DrawerControls {
    if (-not ($script:dash -and $script:dash.Ctl)) { return }
    $c = $script:dash.Ctl; $S = $script:settings
    try {
        $c.Conn.Checked = [bool]$S.ConnectionEnabled; $c.Aranet.Checked = [bool]$S.AranetEnabled; $c.Log.Checked = [bool]$S.HourlyLogging
        $c.Alerts.Checked = [bool]$S.AlertsEnabled; $c.Quiet.Checked = [bool]$S.QuietNight
        $c.Theme.Checked = ($script:DashTheme.Mode -eq 'light'); $c.Startup.Checked = [bool](Test-Startup)
        $c.Seg.SelectedIndex = [Array]::IndexOf($script:ClockIvlOptions, (Clock-Interval))
        if ($script:dash.Status) { $script:dash.Status.Invalidate() }
    } catch {}
}
function Toggle-Drawer {
    if (-not ($script:dash -and $script:dash.Drawer)) { return }
    $d = $script:dash.Drawer; $f = $script:dash.Form
    if ($d.Visible) { $d.Visible = $false; return }
    Sync-DrawerControls
    $d.Bounds = New-Object System.Drawing.Rectangle(($f.ClientSize.Width - $d.Width), 0, $d.Width, $f.ClientSize.Height)
    $d.Visible = $true; $d.BringToFront()
}
function Set-RoomName([string]$name) {
    $name = $name.Trim(); if (-not $name) { $name = 'Room' }
    if ($name.Length -gt 40) { $name = $name.Substring(0, 40) }
    $script:settings.RoomName = $name
    if ($script:dash) {
        try { $script:dash.Verdict.Invalidate(); $script:dash.Form.Text = "Room state  -  $name" } catch {}
        try { if ($script:dash.Ctl.Name.Text -ne $name -and -not $script:dash.Ctl.Name.Focused) { $script:dash.Ctl.Name.Text = $name } } catch {}
    }
}
function Begin-NameEdit {
    $d = $script:dash; if (-not $d -or -not $d.NameRect) { return }
    $b = $d.NameBox
    $b.Text = [string]$script:settings.RoomName
    $b.Location = New-Object System.Drawing.Point(($d.NameRect.X + 2), ($d.NameRect.Y + 1))
    $b.Width = [Math]::Max(180, $d.NameRect.Width + 40)
    $b.Visible = $true; $b.BringToFront(); [void]$b.Focus(); $b.SelectAll()
    $d.Verdict.Invalidate()
}
function End-NameEdit([bool]$commit) {
    $d = $script:dash; if (-not $d -or -not $d.NameBox.Visible) { return }
    $d.NameBox.Visible = $false
    if ($commit) { Set-RoomName $d.NameBox.Text; Save-Settings }
    $d.Verdict.Invalidate()
}
function Toggle-Theme {
    $new = 'dark'; if ($script:DashTheme.Mode -eq 'dark') { $new = 'light' }
    $script:settings.Theme = $new; Save-Settings
    $reopen = [bool]($script:dash -and $script:dash.Drawer -and $script:dash.Drawer.Visible)
    $bounds = $null; if ($script:dash -and $script:dash.Form) { $bounds = $script:dash.Form.Bounds }
    $f = $script:dash.Form; $script:dash = $null
    if ($f -and -not $f.IsDisposed) { $f.Close() }
    if ($script:trendForm -and -not $script:trendForm.IsDisposed) { $script:trendForm.Close() }
    Show-Dashboard
    if ($bounds -and $script:dash) { $script:dash.Form.Bounds = $bounds }
    if ($reopen) { Toggle-Drawer }
}
function Rs-Card($painter, [int]$right = 14) {
    $p = New-Object Vulcan.CardPanel
    $p.BackColor = $script:DashTheme.Canvas; $p.Dock = [System.Windows.Forms.DockStyle]::Fill
    $p.Margin = New-Object System.Windows.Forms.Padding(0, 0, $right, 14); $p.Tag = @{}
    $p.Add_Paint($painter)
    return $p
}
function New-RsTable([int]$cols, $percents) {
    $t = New-Object Vulcan.BufferedTable; $t.Dock = [System.Windows.Forms.DockStyle]::Fill; $t.BackColor = $script:DashTheme.Canvas
    $t.Margin = New-Object System.Windows.Forms.Padding(0)
    $t.ColumnCount = $cols; $t.RowCount = 1
    foreach ($pc in $percents) { [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, $pc))) }
    [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    return $t
}

function Show-Dashboard {
    try {
        if ($script:dash -and $script:dash.Form -and -not $script:dash.Form.IsDisposed) {
            $script:dash.Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $script:dash.Form.Activate(); Refresh-All; return
        }
        $mode = 'dark'; if ($script:settings.Theme -eq 'light') { $mode = 'light' }
        Apply-Theme $mode; Ensure-RsFonts
        $T = $script:DashTheme
        $script:rsReduced = Rs-ReducedMotion
        $script:dash = @{ Panels = @(); AnimPanels = @(); DrawerLabels = @(); Ctl = @{} }
        $AS = [System.Windows.Forms.AnchorStyles]; $ST = [System.Windows.Forms.SizeType]

        $f = New-Object System.Windows.Forms.Form
        $f.Text = "Room state  -  $($script:settings.RoomName)"
        $f.BackColor = $T.Canvas; $f.Font = New-Object System.Drawing.Font('Segoe UI', 9); $f.KeyPreview = $true
        try { $f.Icon = [System.Drawing.Icon]::FromHandle($script:iconHandle) } catch {}
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $f.Size = New-Object System.Drawing.Size([Math]::Min(1180, $wa.Width - 60), [Math]::Min(880, $wa.Height - 40))
        $f.MinimumSize = New-Object System.Drawing.Size(940, 820)
        $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $f.AccessibleName = 'Room state dashboard'

        # outer layout: verdict / alerts (only when there are any) / cards / action bar
        $tl = New-Object Vulcan.BufferedTable
        $tl.Dock = [System.Windows.Forms.DockStyle]::Fill; $tl.BackColor = $T.Canvas
        $tl.Padding = New-Object System.Windows.Forms.Padding(28, 20, 28, 8)
        $tl.ColumnCount = 1; $tl.RowCount = 4
        [void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle($ST::Percent, 100)))
        [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($ST::Absolute, 84)))
        [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($ST::Absolute, 0)))
        [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($ST::Percent, 100)))
        [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($ST::Absolute, 58)))
        $script:dash.Layout = $tl

        # ---- verdict ----
        $verdict = New-Object Vulcan.CardPanel; $verdict.BackColor = $T.Canvas; $verdict.Dock = [System.Windows.Forms.DockStyle]::Fill
        $verdict.Margin = New-Object System.Windows.Forms.Padding(0)
        $verdict.AccessibleName = 'Room verdict'
        $verdict.Add_Paint({ param($s,$e); try { Rs-PaintVerdict $e.Graphics $this } catch { WLog "rs verdict: $($_.Exception.Message)" } })
        $orb = New-Object Vulcan.Orb; $orb.Location = New-Object System.Drawing.Point(0, 12); $orb.BackColor = $T.Canvas
        $orb.Animate = (-not $script:rsReduced)
        $nameBox = New-Object System.Windows.Forms.TextBox
        $nameBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle; $nameBox.BackColor = $T.Sunken; $nameBox.ForeColor = $T.TextP
        $nameBox.Font = $script:RsFonts.BodyB; $nameBox.MaxLength = 40; $nameBox.Visible = $false
        $nameBox.AccessibleName = 'Room name'
        $nameBox.Add_KeyDown({ param($s,$e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $e.SuppressKeyPress = $true; End-NameEdit $true }
            elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $e.SuppressKeyPress = $true; End-NameEdit $false } })
        $nameBox.Add_Leave({ End-NameEdit $true })
        $verdict.Controls.Add($orb); $verdict.Controls.Add($nameBox)
        $verdict.Add_MouseMove({ param($s,$e); try { $over = ($script:dash.NameRect -and $script:dash.NameRect.Contains($e.Location)); $this.Cursor = if ($over) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default } } catch {} })
        $verdict.Add_MouseClick({ param($s,$e); try { if ($script:dash.NameRect -and $script:dash.NameRect.Contains($e.Location)) { Begin-NameEdit } } catch {} })
        $script:dash.Verdict = $verdict; $script:dash.Orb = $orb; $script:dash.NameBox = $nameBox

        # ---- alerts strip ----
        $alertStrip = New-Object Vulcan.CardPanel; $alertStrip.BackColor = $T.Canvas; $alertStrip.Dock = [System.Windows.Forms.DockStyle]::Fill
        $alertStrip.Margin = New-Object System.Windows.Forms.Padding(0); $alertStrip.AccessibleName = 'Alerts'
        $alertStrip.Add_Paint({ param($s,$e); try { Rs-PaintAlerts $e.Graphics $this } catch { WLog "rs alerts: $($_.Exception.Message)" } })

        # ---- cards ----
        $body = New-Object Vulcan.BufferedTable; $body.Dock = [System.Windows.Forms.DockStyle]::Fill; $body.BackColor = $T.Canvas
        $body.Margin = New-Object System.Windows.Forms.Padding(0)
        $body.ColumnCount = 1; $body.RowCount = 4
        [void]$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle($ST::Percent, 100)))
        [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($ST::Absolute, 180)))
        [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($ST::Absolute, 118)))
        [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($ST::Absolute, 162)))
        [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($ST::Percent, 100)))

        $r1 = New-RsTable 2 @(62, 38)
        $aq  = Rs-Card { param($s,$e); try { Rs-PaintAirQuality $e.Graphics $this } catch { WLog "rs aq: $($_.Exception.Message)" } }
        $occ = Rs-Card { param($s,$e); try { Rs-PaintOccupancy $e.Graphics $this } catch { WLog "rs occ: $($_.Exception.Message)" } } 0
        $r1.Controls.Add($aq, 0, 0); $r1.Controls.Add($occ, 1, 0)

        $r2 = New-RsTable 4 @(25, 25, 25, 25)
        $vCards = @{}; $vi = 0
        foreach ($key in @('temp','hum','co2','pres')) {
            $right = 14; if ($vi -eq 3) { $right = 0 }
            $c = Rs-Card { param($s,$e); try { Rs-PaintVital $e.Graphics $this } catch { WLog "rs vital: $($_.Exception.Message)" } } $right
            $c.Tag = @{ Key = $key }
            $r2.Controls.Add($c, $vi, 0); $vCards[$key] = $c; $vi++
        }

        $r3 = New-RsTable 3 @(36, 32, 32)
        $vent = Rs-Card { param($s,$e); try { Rs-PaintVentilation $e.Graphics $this } catch { WLog "rs vent: $($_.Exception.Message)" } }
        $comf = Rs-Card { param($s,$e); try { Rs-PaintComfort $e.Graphics $this } catch { WLog "rs comf: $($_.Exception.Message)" } }
        $outs = Rs-Card { param($s,$e); try { Rs-PaintOutside $e.Graphics $this } catch { WLog "rs out: $($_.Exception.Message)" } } 0
        $r3.Controls.Add($vent, 0, 0); $r3.Controls.Add($comf, 1, 0); $r3.Controls.Add($outs, 2, 0)

        $timeline = Rs-Card { param($s,$e); try { Rs-PaintTimeline $e.Graphics $this } catch { WLog "rs timeline: $($_.Exception.Message)" } } 0
        $timeline.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
        $timeline.Cursor = [System.Windows.Forms.Cursors]::Hand
        $timeline.Add_MouseMove({ param($s,$e); try { $w = $this.Width-40; if ($w -gt 0) { $fr = ($e.X-20)/[double]$w; if ($fr -lt 0) { $fr = 0 }; if ($fr -gt 1) { $fr = 1 }; $script:rsScrubFrac = $fr; $this.Invalidate() } } catch {} })
        $timeline.Add_MouseLeave({ param($s,$e); $script:rsScrubFrac = $null; try { $this.Invalidate() } catch {} })
        $timeline.Add_Click({ try { Show-TrendsWindow } catch {} })
        $body.Controls.Add($r1, 0, 0); $body.Controls.Add($r2, 0, 1); $body.Controls.Add($r3, 0, 2); $body.Controls.Add($timeline, 0, 3)

        # ---- action bar: the few things you do, then status / messages on the right ----
        $bar = New-Object System.Windows.Forms.Panel; $bar.Dock = [System.Windows.Forms.DockStyle]::Fill; $bar.BackColor = $T.Canvas
        $bar.Margin = New-Object System.Windows.Forms.Padding(0)
        $status = New-Object Vulcan.CardPanel; $status.BackColor = $T.Canvas; $status.Dock = [System.Windows.Forms.DockStyle]::Fill
        $status.AccessibleName = 'Status'
        $status.Add_Paint({ param($s,$e); try { Rs-PaintStatus $e.Graphics $this } catch { WLog "rs status: $($_.Exception.Message)" } })
        $flow = New-Object System.Windows.Forms.FlowLayoutPanel
        $flow.Dock = [System.Windows.Forms.DockStyle]::Left; $flow.AutoSize = $true; $flow.WrapContents = $false; $flow.BackColor = $T.Canvas
        $flow.Padding = New-Object System.Windows.Forms.Padding(0, 9, 12, 0); $flow.Margin = New-Object System.Windows.Forms.Padding(0)
        $mk = { param($text, $glyph, [bool]$primary, $name)
            $b = New-Object Vulcan.PillButton; $b.Text = $text; $b.Glyph = $glyph; $b.Primary = $primary; $b.BackColor = $script:DashTheme.Canvas
            $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0); $b.AccessibleName = $name; [void]$b.Fit(); $b }
        $bRead = & $mk 'Read now' $script:GlRefresh $true 'Read both devices now'
        $bSync = & $mk 'Sync clock time' $script:GlSync $false 'Set the clock time'
        $bTrend = & $mk 'Trends' $script:GlChart $false 'Open the trends graphs'
        $bSet = & $mk 'Settings' $script:GlGear $false 'Open settings'
        $bRead.Add_Click({ Read-Now })
        $bSync.Add_Click({ Start-Bg -Kind 'sync' -LogCsv $false -Notify $true })
        $bTrend.Add_Click({ Show-TrendsWindow })
        $bSet.Add_Click({ Toggle-Drawer })
        $flow.Controls.AddRange(@($bRead, $bSync, $bTrend, $bSet))
        $bar.Controls.Add($status)   # Fill first
        $bar.Controls.Add($flow)     # Left last
        $script:dash.Status = $status

        $tl.Controls.Add($verdict, 0, 0); $tl.Controls.Add($alertStrip, 0, 1); $tl.Controls.Add($body, 0, 2); $tl.Controls.Add($bar, 0, 3)
        $f.Controls.Add($tl)

        # ---- settings drawer (slides over the right edge) ----
        $dw = 348
        $drawer = New-Object Vulcan.CardPanel; $drawer.BackColor = $T.Surface; $drawer.Visible = $false
        $drawer.Size = New-Object System.Drawing.Size($dw, $f.ClientSize.Height)
        $drawer.Anchor = ($AS::Top -bor $AS::Bottom -bor $AS::Right)
        $drawer.AccessibleName = 'Settings'
        $drawer.Add_Paint({ param($s,$e); try { Rs-PaintDrawer $e.Graphics $this } catch { WLog "rs drawer: $($_.Exception.Message)" } })
        $labels = New-Object System.Collections.ArrayList
        $ctl = $script:dash.Ctl
        $tgl = { param($text, [int]$y, $key, $name)
            [void]$labels.Add(@{ Kind = 'row'; Text = $text; Y = $y })
            $t = New-Object Vulcan.Toggle; $t.BackColor = $script:DashTheme.Surface; $t.Location = New-Object System.Drawing.Point(($dw - 24 - 44), ($y - 3)); $t.AccessibleName = $name
            $drawer.Controls.Add($t); $ctl[$key] = $t; $t }
        $closeB = New-Object Vulcan.PillButton; $closeB.Glyph = $script:GlClose; $closeB.Text = ''; $closeB.Quiet = $true; $closeB.BackColor = $T.Surface
        $closeB.Size = New-Object System.Drawing.Size(34, 34); $closeB.Location = New-Object System.Drawing.Point(($dw - 24 - 34), 14); $closeB.AccessibleName = 'Close settings'
        $closeB.Add_Click({ Toggle-Drawer }); $drawer.Controls.Add($closeB)

        $y = 66
        [void]$labels.Add(@{ Kind = 'section'; Text = 'ROOM'; Y = $y }); $y += 24
        [void]$labels.Add(@{ Kind = 'row'; Text = 'Name'; Y = $y })
        $tbName = New-Object System.Windows.Forms.TextBox
        $tbName.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle; $tbName.BackColor = $T.Sunken; $tbName.ForeColor = $T.TextP
        $tbName.Font = $script:RsFonts.Body; $tbName.MaxLength = 40; $tbName.Text = [string]$script:settings.RoomName
        $tbName.Location = New-Object System.Drawing.Point(124, ($y - 3)); $tbName.Width = $dw - 124 - 24; $tbName.AccessibleName = 'Room name'
        $tbName.Add_TextChanged({ if ($this.Focused) { Set-RoomName $this.Text } })
        $tbName.Add_Leave({ Set-RoomName $this.Text; $this.Text = [string]$script:settings.RoomName; Save-Settings })
        $tbName.Add_KeyDown({ param($s,$e); if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $e.SuppressKeyPress = $true; Save-Settings } })
        $drawer.Controls.Add($tbName); $ctl.Name = $tbName; $y += 36
        [void]$labels.Add(@{ Kind = 'row'; Text = ('Volume, m' + $script:RsSup3); Y = $y })
        $numVol = New-Object System.Windows.Forms.NumericUpDown
        $numVol.Minimum = 5; $numVol.Maximum = 2000; $numVol.Increment = 1; $numVol.Font = $script:RsFonts.Body
        $numVol.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle; $numVol.BackColor = $T.Sunken; $numVol.ForeColor = $T.TextP
        $numVol.Location = New-Object System.Drawing.Point(($dw - 24 - 84), ($y - 3)); $numVol.Width = 84; $numVol.AccessibleName = 'Room volume in cubic metres'
        $numVol.Value = [decimal][Math]::Min(2000, [Math]::Max(5, [int]$script:settings.RoomVolume))
        $numVol.Add_ValueChanged({ $script:settings.RoomVolume = [int]$this.Value; Save-Settings; Refresh-All })
        $drawer.Controls.Add($numVol); $ctl.Vol = $numVol; $y += 28
        [void]$labels.Add(@{ Kind = 'note'; Text = 'Length x width x height. Used to turn CO2 into a headcount.'; Y = $y }); $y += 44

        [void]$labels.Add(@{ Kind = 'section'; Text = 'DEVICES'; Y = $y }); $y += 24
        $tg = & $tgl 'Bluetooth connection' $y 'Conn' 'Bluetooth connection'; $tg.Add_CheckedChanged({ if ([bool]$this.Checked -ne [bool]$script:settings.ConnectionEnabled) { Toggle-Connection } }); $y += 34
        $tg = & $tgl ('Aranet4 CO' + $script:RsSub2 + ' monitor') $y 'Aranet' 'Aranet4 monitor'; $tg.Add_CheckedChanged({ if ([bool]$this.Checked -ne [bool]$script:settings.AranetEnabled) { Toggle-Aranet } }); $y += 34
        $tg = & $tgl 'Log readings to CSV' $y 'Log' 'Log readings to CSV'; $tg.Add_CheckedChanged({ $script:settings.HourlyLogging = [bool]$this.Checked; Save-Settings; Refresh-Menu }); $y += 36
        [void]$labels.Add(@{ Kind = 'row'; Text = 'Read the clock every (minutes)'; Y = $y }); $y += 26
        $seg = New-Object Vulcan.Segmented; $seg.BackColor = $T.Surface
        $seg.Items = [string[]]@($script:ClockIvlOptions | ForEach-Object { "$_" })
        $seg.Location = New-Object System.Drawing.Point(24, $y); $seg.Width = $dw - 48; $seg.AccessibleName = 'Clock read interval'
        $seg.Add_SelectedChanged({ $i = $this.SelectedIndex; if ($i -ge 0) { Set-ClockInterval ([int]$script:ClockIvlOptions[$i]) } })
        $drawer.Controls.Add($seg); $ctl.Seg = $seg; $y += 36
        [void]$labels.Add(@{ Kind = 'note'; Text = 'Each read wakes the clock over Bluetooth, so shorter intervals use more of its battery.'; Y = $y }); $y += 46

        [void]$labels.Add(@{ Kind = 'section'; Text = 'ALERTS'; Y = $y }); $y += 24
        $tg = & $tgl 'Notify me when something needs attention' $y 'Alerts' 'Notifications'; $tg.Add_CheckedChanged({ $script:settings.AlertsEnabled = [bool]$this.Checked; Save-Settings; Refresh-Menu }); $y += 34
        $tg = & $tgl 'Stay quiet at night (22:00 to 07:00)' $y 'Quiet' 'Quiet at night'; $tg.Add_CheckedChanged({ $script:settings.QuietNight = [bool]$this.Checked; Save-Settings }); $y += 46

        [void]$labels.Add(@{ Kind = 'section'; Text = 'APP'; Y = $y }); $y += 24
        $tg = & $tgl 'Light theme' $y 'Theme' 'Light theme'; $tg.Add_CheckedChanged({ if ([bool]$this.Checked -ne ($script:DashTheme.Mode -eq 'light')) { [void]$script:dash.Form.BeginInvoke([System.Action]{ Toggle-Theme }) } }); $y += 34
        $tg = & $tgl 'Start when I sign in' $y 'Startup' 'Start at sign-in'; $tg.Add_CheckedChanged({ Set-Startup ([bool]$this.Checked); Refresh-Menu }); $y += 44
        $bData = New-Object Vulcan.PillButton; $bData.Text = 'Open data folder'; $bData.Glyph = $script:GlFolder; $bData.BackColor = $T.Surface; [void]$bData.Fit()
        $bData.Location = New-Object System.Drawing.Point(24, $y); $bData.Add_Click({ Start-Process explorer.exe $LogDir })
        $drawer.Controls.Add($bData)
        $script:dash.DrawerLabels = @($labels); $script:dash.Drawer = $drawer
        $f.Controls.Add($drawer); $drawer.BringToFront()

        $script:dash.Panels = @($verdict, $alertStrip, $aq, $occ, $vCards['temp'], $vCards['hum'], $vCards['co2'], $vCards['pres'], $vent, $comf, $outs, $timeline, $status)
        $script:dash.AnimPanels = @($aq, $vCards['temp'], $vCards['hum'], $vCards['co2'], $vCards['pres'], $comf)
        $script:dash.Form = $f
        $aq.AccessibleName = 'Air quality'; $occ.AccessibleName = 'Occupancy'
        $vCards['temp'].AccessibleName = 'Temperature'; $vCards['hum'].AccessibleName = 'Humidity'
        $vCards['co2'].AccessibleName = 'CO2'; $vCards['pres'].AccessibleName = 'Pressure'
        $vent.AccessibleName = 'Ventilation'; $comf.AccessibleName = 'Comfort'; $outs.AccessibleName = 'Outside'; $timeline.AccessibleName = 'Today timeline'

        $f.Add_KeyDown({ param($s,$e)
            try {
                if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and $script:dash.Drawer.Visible -and -not $script:dash.NameBox.Visible) { Toggle-Drawer; $e.Handled = $true }
                elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) { Read-Now; $e.Handled = $true }
            } catch {} })

        # Tweens run only while something is actually moving, then the timer stops.
        if ($script:RsAnimTimer) { try { $script:RsAnimTimer.Stop(); $script:RsAnimTimer.Dispose() } catch {} }
        $script:RsAnimTimer = New-Object System.Windows.Forms.Timer; $script:RsAnimTimer.Interval = 33
        $script:RsAnimTimer.Add_Tick({
            try {
                if (-not ($script:dash -and $script:dash.Form -and -not $script:dash.Form.IsDisposed)) { $script:RsAnimTimer.Stop(); return }
                $moving = Rs-AnimStep
                $fading = $false
                if ($script:rsVAlpha -lt 1) { $script:rsVAlpha = [Math]::Min(1.0, $script:rsVAlpha + 0.12); $fading = $true }
                $settling = $false
                foreach ($k in @($script:rsSettle.Keys)) { $v = $script:rsSettle[$k]*0.86; if ($v -lt 0.02) { [void]$script:rsSettle.Remove($k) } else { $script:rsSettle[$k] = $v; $settling = $true } }
                if ($fading) { $script:dash.Verdict.Invalidate() }
                if ($moving -or $settling) { foreach ($pnl in $script:dash.AnimPanels) { if ($pnl -and -not $pnl.IsDisposed) { $pnl.Invalidate() } } }
                if (-not ($moving -or $fading -or $settling)) { $script:RsAnimTimer.Stop() }
            } catch { $script:RsAnimTimer.Stop() }
        })
        $f.Add_FormClosed({
            $script:dash = $null; $script:rsScrubFrac = $null; $script:toast = $null
            try { if ($script:RsAnimTimer) { $script:RsAnimTimer.Stop(); $script:RsAnimTimer.Dispose(); $script:RsAnimTimer = $null } } catch {}
        })
        $script:rsVAlpha = 1.0
        Sync-DrawerControls
        Refresh-All
        $f.Show(); $f.Activate()
    } catch { WLog "ERROR dashboard: $($_.Exception.Message) :: $($_.ScriptStackTrace)" }
}

# ===========================================================================
#  Main
# ===========================================================================
$script:settings = Load-Settings
if ($SelfTestTheme) { $script:settings.Theme = $SelfTestTheme }

if (-not $SelfTest) { Trim-Logs }
$rowsLoaded = [Vulcan.Data]::Load($CsvPath, $AranetCsv)
if ([Vulcan.Data]::LastError) { WLog "WARN history: $([Vulcan.Data]::LastError)" }
Apply-Theme $(if ($script:settings.Theme -eq 'light') { 'light' } else { 'dark' })
Ensure-RsFonts
$script:startedAt = Get-Date
$script:clockDue = Get-Date; $script:nextStateAt = Get-Date; $script:nextTrimAt = (Get-Date).AddHours(24)
$script:toast = $null; $script:aranetForce = $null; $script:dash = $null
$script:sessionLocked = $false; $script:unlockedAt = [datetime]::MinValue
$script:pauseEvt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'LYWSD02_Aranet_Pause')

# ---- tray icon + menu ----
$script:ni = New-Object System.Windows.Forms.NotifyIcon
$script:ni.Text = 'Room state'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
function New-MenuItem([string]$text) { New-Object System.Windows.Forms.ToolStripMenuItem($text) }
$miTitle   = New-MenuItem 'Room state'; $miTitle.Enabled = $false; $mf = $miTitle.Font; $miTitle.Font = New-Object System.Drawing.Font($mf.FontFamily, $mf.Size, [System.Drawing.FontStyle]::Bold)
$miReading = New-MenuItem 'No reading yet'; $miReading.Enabled = $false
$miDash    = New-MenuItem 'Open dashboard'
$miTrends  = New-MenuItem 'Trends...'
$miRead    = New-MenuItem 'Read now'
$miSync    = New-MenuItem 'Sync clock time'
$miConn    = New-MenuItem 'Bluetooth connection'
$miAranet  = New-MenuItem 'Aranet4 CO2 monitor'
$miLog     = New-MenuItem 'Log readings to CSV'
$miAlerts  = New-MenuItem 'Notifications'
$miClockIvl = New-MenuItem 'Clock read interval'
$miOpen    = New-MenuItem 'Open data folder'
$miStartup = New-MenuItem 'Start when I sign in'
$miExit    = New-MenuItem 'Exit'
# The clock connects over Bluetooth for each read, which costs its battery.
$script:ClockIvlOptions = @(5, 10, 15, 30, 60)
$script:miClockIvlItems = @{}
foreach ($mins in $script:ClockIvlOptions) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem("Every $mins minutes")
    $item.Tag = $mins
    $item.Add_Click({ param($s,$e) Set-ClockInterval ([int]$s.Tag) })
    [void]$miClockIvl.DropDownItems.Add($item)
    $script:miClockIvlItems[$mins] = $item
}
$menu.Items.AddRange(@(
    $miTitle, $miReading, (New-Object System.Windows.Forms.ToolStripSeparator),
    $miDash, $miTrends, $miRead, $miSync, (New-Object System.Windows.Forms.ToolStripSeparator),
    $miConn, $miAranet, $miLog, $miAlerts, $miClockIvl, (New-Object System.Windows.Forms.ToolStripSeparator),
    $miOpen, $miStartup, (New-Object System.Windows.Forms.ToolStripSeparator), $miExit))
$script:ni.ContextMenuStrip = $menu

# ---- timers ----
$script:poll = New-Object System.Windows.Forms.Timer; $script:poll.Interval = 1000
$script:poll.Add_Tick({ try { Poll-Jobs } catch { WLog "ERROR poll: $($_.Exception.Message)" } })
$script:aranetForceTimer = New-Object System.Windows.Forms.Timer; $script:aranetForceTimer.Interval = 1000
$script:aranetForceTimer.Add_Tick({ try { Aranet-ForceTick } catch {} })
$script:sched = New-Object System.Windows.Forms.Timer; $script:sched.Interval = 5000
$script:sched.Add_Tick({ try { Scheduler-Tick } catch { WLog "ERROR scheduler: $($_.Exception.Message)" } })
$script:toastTimer = New-Object System.Windows.Forms.Timer; $script:toastTimer.Interval = 6000
$script:toastTimer.Add_Tick({ $script:toastTimer.Stop(); $script:toast = $null; try { if ($script:dash -and $script:dash.Status) { $script:dash.Status.Invalidate() } } catch {} })
# launching the widget a second time opens the dashboard of the one already running
$script:showEvt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'LYWSD02_Show_Dashboard')
$script:showTimer = New-Object System.Windows.Forms.Timer; $script:showTimer.Interval = 1000
$script:showTimer.Add_Tick({ try { if ($script:showEvt.WaitOne(0)) { Show-Dashboard } } catch {} })
$script:kick = New-Object System.Windows.Forms.Timer; $script:kick.Interval = 1500
$script:kick.Add_Tick({ $script:kick.Stop(); try { Scheduler-Tick } catch { WLog "ERROR first tick: $($_.Exception.Message)" } })
$script:hide = New-Object System.Windows.Forms.Timer; $script:hide.Interval = 150
$script:hide.Add_Tick({
    try {
        if (-not $script:popupShown) { $script:hide.Stop(); return }
        $p = [System.Windows.Forms.Cursor]::Position
        $b = $script:popup.Bounds; $b.Inflate(8,8)
        $overPopup = $b.Contains($p)
        if (-not $overPopup -and [System.Windows.Forms.Control]::MouseButtons -ne [System.Windows.Forms.MouseButtons]::None) { Hide-Popup; return }
        $a = $script:popupAnchor
        $nearAnchor = ([math]::Abs($p.X-$a.X) -le 40 -and [math]::Abs($p.Y-$a.Y) -le 40)
        if (-not $overPopup -and -not $nearAnchor) { Hide-Popup }
    } catch {}
})

# ---- hover popup window ----
$script:popup = New-Object Vulcan.NoActivatePopup
$script:popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$script:popup.ControlBox = $false; $script:popup.ShowInTaskbar = $false; $script:popup.TopMost = $true
$script:popup.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$script:popup.Size = New-Object System.Drawing.Size(384, 172)
$script:popup.BackColor = $script:DashTheme.Canvas
$script:popupPanel = New-Object Vulcan.CardPanel
$script:popupPanel.Dock = [System.Windows.Forms.DockStyle]::Fill; $script:popupPanel.BackColor = $script:DashTheme.Canvas
$script:popupPanel.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:popupPanel.Add_Paint({ param($s,$e); try { Rs-PaintPopup $e.Graphics $this } catch { WLog "rs popup: $($_.Exception.Message)" } })
$script:popup.Controls.Add($script:popupPanel)
$script:popupPanel.Add_Click({ Hide-Popup; Show-Dashboard })

# ---- menu + tray handlers ----
$miDash.Add_Click({ Show-Dashboard })
$miTrends.Add_Click({ Show-TrendsWindow })
$miRead.Add_Click({ Read-Now })
$miSync.Add_Click({ Start-Bg -Kind 'sync' -LogCsv $false -Notify $true })
$miConn.Add_Click({ Toggle-Connection })
$miAranet.Add_Click({ Toggle-Aranet })
$miLog.Add_Click({ $script:settings.HourlyLogging = -not $script:settings.HourlyLogging; Save-Settings; Refresh-Menu; Sync-DrawerControls })
$miAlerts.Add_Click({ $script:settings.AlertsEnabled = -not $script:settings.AlertsEnabled; Save-Settings; Refresh-Menu; Sync-DrawerControls })
$miOpen.Add_Click({ Start-Process explorer.exe $LogDir })
$miStartup.Add_Click({ Set-Startup (-not (Test-Startup)); Refresh-Menu; Sync-DrawerControls })
$miExit.Add_Click({ try { $script:ni.Visible = $false } catch {}; [System.Windows.Forms.Application]::Exit() })
# Hover shows the summary; double-click opens the dashboard.
$script:ni.Add_MouseMove({
    $cp = [System.Windows.Forms.Cursor]::Position
    if ($script:popupShown) { $script:popupAnchor = $cp }
    elseif ([Environment]::TickCount -ge $script:suppressUntil) { Show-Popup $cp.X $cp.Y }
})
$script:ni.Add_MouseDown({ $script:suppressUntil = [Environment]::TickCount + 900; Hide-Popup })
$script:ni.Add_MouseDoubleClick({ Show-Dashboard })
$menu.Add_Opening({ Hide-Popup })

# ---- first paint: the last logged values, at once ----
Seed-Readings
# a restart should not trigger a clock read (and a battery hit) if one was logged moments ago
if ($script:lastReading) { $due = $script:lastReading.When.AddMinutes((Clock-Interval)); if ($due -gt $script:clockDue) { $script:clockDue = $due } }
Update-Icon '..' (-not $script:settings.ConnectionEnabled) 'good'
Refresh-Menu
Refresh-All

if ($SelfTest) {
    # Developer check: exercise every window against the real data and save screenshots.
    $code = 0
    try {
        if (-not (Test-Path $SelfTest)) { New-Item -ItemType Directory -Force -Path $SelfTest | Out-Null }
        $tag = $script:DashTheme.Mode
        $shot = { param($ctl, $name, [bool]$screen)
            [System.Windows.Forms.Application]::DoEvents()
            if ($screen) {
                Start-Sleep -Milliseconds 400; [System.Windows.Forms.Application]::DoEvents()
                $b = $ctl.Bounds; $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
                $gg = [System.Drawing.Graphics]::FromImage($bmp); $gg.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size); $gg.Dispose()
            } else {
                $bmp = New-Object System.Drawing.Bitmap $ctl.Width, $ctl.Height
                $ctl.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $ctl.Width, $ctl.Height)))
            }
            $bmp.Save((Join-Path $SelfTest "$name-$tag.png"), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose() }
        $t0 = [System.Diagnostics.Stopwatch]::StartNew()
        Show-Dashboard
        if (-not $script:dash) { throw 'dashboard did not open' }
        $f = $script:dash.Form
        if ($SelfTestSize -match '^(\d+)x(\d+)$') { $f.Size = New-Object System.Drawing.Size([int]$Matches[1], [int]$Matches[2]) }
        $f.TopMost = $true; [System.Windows.Forms.Application]::DoEvents()
        Write-Host ("SELFTEST core={0} rows={1} startup={2}ms dashboard-open={3}ms" -f $coreHow, $rowsLoaded, $swStart.ElapsedMilliseconds, $t0.ElapsedMilliseconds)
        $t1 = [System.Diagnostics.Stopwatch]::StartNew(); Refresh-All; [System.Windows.Forms.Application]::DoEvents()
        Write-Host ("SELFTEST refresh={0}ms verdict='{1}' alerts={2}" -f $t1.ElapsedMilliseconds, $script:rs.Verdict, $script:rs.Alerts.Count)
        & $shot $f 'dashboard' $false
        # a message in the status area, an alert strip, the settings drawer
        Rs-Toast 'LYWSD02' ("25.4{0}C   58% RH   battery 56%" -f $script:RsDeg) 'info'
        $script:rs.Alerts = @(@{ Level='caution'; Title=('CO' + $script:RsSub2 + ' is high'); Msg='1,460 ppm. Open a window or door.' }, @{ Level='info'; Title='Pressure dropping fast'; Msg='3.8 hPa in 3 h. Weather is likely turning.' })
        $script:dash.Layout.RowStyles[1].Height = 46; foreach ($pnl in $script:dash.Panels) { $pnl.Invalidate() }
        & $shot $f 'alerts' $false
        Toggle-Drawer
        & $shot $script:dash.Drawer 'drawer' $false
        # drive the controls the way a click would (settings are not saved in a self-test)
        $flags = [System.Reflection.BindingFlags]'Instance,NonPublic'
        foreach ($k in 'Log', 'Alerts', 'Quiet') {
            $c = $script:dash.Ctl[$k]; $before = [bool]$c.Checked
            [void]$c.GetType().GetMethod('OnClick', $flags).Invoke($c, @([System.EventArgs]::Empty))
            if ([bool]$c.Checked -eq $before) { throw "toggle $k did not flip" }
            [void]$c.GetType().GetMethod('OnClick', $flags).Invoke($c, @([System.EventArgs]::Empty))
        }
        if (-not $script:settings.HourlyLogging -or -not $script:settings.AlertsEnabled) { throw 'toggles did not write back to settings' }
        $seg = $script:dash.Ctl.Seg; $keepIvl = Clock-Interval
        $me = New-Object System.Windows.Forms.MouseEventArgs([System.Windows.Forms.MouseButtons]::Left, 1, ($seg.Width - 10), 10, 0)
        [void]$seg.GetType().GetMethod('OnMouseDown', $flags).Invoke($seg, [object[]]@($me.PSObject.BaseObject))
        if ((Clock-Interval) -ne 60) { throw "interval selector gave $(Clock-Interval), expected 60" }
        Set-ClockInterval $keepIvl
        $keepName = [string]$script:settings.RoomName; $keepVol = [int]$script:settings.RoomVolume
        $script:dash.Ctl.Vol.Value = 40; if ([int]$script:settings.RoomVolume -ne 40) { throw 'room volume did not apply' }
        $script:dash.Ctl.Vol.Value = $keepVol
        Toggle-Drawer
        Begin-NameEdit; $script:dash.NameBox.Text = 'Study'; End-NameEdit $true
        if ($script:settings.RoomName -ne 'Study' -or $script:dash.Form.Text -notlike '*Study*') { throw 'room rename did not apply' }
        Set-RoomName $keepName
        $modeBefore = $script:DashTheme.Mode; Toggle-Theme; [System.Windows.Forms.Application]::DoEvents()
        if ($script:DashTheme.Mode -eq $modeBefore -or -not $script:dash) { throw 'theme toggle failed' }
        Toggle-Theme; [System.Windows.Forms.Application]::DoEvents(); $f = $script:dash.Form
        Write-Host 'SELFTEST interactions ok (toggles, interval, volume, rename, theme)'
        $script:popup.Location = New-Object System.Drawing.Point(40, 40); $script:popup.Show()
        & $shot $script:popupPanel 'popup' $false
        $script:popup.Hide()
        $t2 = [System.Diagnostics.Stopwatch]::StartNew(); Show-TrendsWindow; [System.Windows.Forms.Application]::DoEvents()
        if (-not $script:trendForm) { throw 'trends window did not open' }
        Write-Host ("SELFTEST trends-open={0}ms points={1}" -f $t2.ElapsedMilliseconds, $script:trendCo2Chart.Series['CO2'].Points.Count)
        $script:trendForm.TopMost = $true
        & $shot $script:trendForm 'trends' $false
        $r = Get-ChartXRange $script:trendCo2Chart
        $t3 = [System.Diagnostics.Stopwatch]::StartNew(); Zoom-Apply ($r.Max - 0.25) $r.Max; [System.Windows.Forms.Application]::DoEvents()
        Write-Host ("SELFTEST zoom={0}ms points={1}" -f $t3.ElapsedMilliseconds, $script:trendCo2Chart.Series['CO2'].Points.Count)
        & $shot $script:trendForm 'trends-zoom' $false
        $script:trendForm.Close(); $f.Close()
        Write-Host 'SELFTEST OK'
    } catch { Write-Host "SELFTEST ERROR: $($_.Exception.Message) :: $($_.ScriptStackTrace)"; $code = 1 }
    try { $script:ni.Dispose() } catch {}
    exit $code
}

$script:ni.Visible = $true
Stop-LegacyWatchers
$script:sched.Start(); $script:kick.Start(); $script:showTimer.Start()
WLog ("Widget started in {0} ms (core {1}, {2} rows of history, clock every {3} min, bluetooth {4})." -f $swStart.ElapsedMilliseconds, $coreHow, $rowsLoaded, (Clock-Interval), $script:settings.ConnectionEnabled)

# ---- Run ----
$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)

# ---- Cleanup ----
try { [void]$script:pauseEvt.Reset() } catch {}
try { Stop-AranetWatcher } catch {}
try { $script:ni.Visible = $false; $script:ni.Dispose() } catch {}
try { if ($script:iconHandle -ne [IntPtr]::Zero) { [void][Vulcan.Native]::DestroyIcon($script:iconHandle) } } catch {}
try { $script:mutex.ReleaseMutex() } catch {}
WLog 'Widget stopped.'
