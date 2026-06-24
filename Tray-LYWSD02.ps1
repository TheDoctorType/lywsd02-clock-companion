<#
.SYNOPSIS
    System-tray widget for the Xiaomi LYWSD02 clock. Shows the current
    temperature in the taskbar tray, logs temperature/humidity hourly to CSV,
    lets you toggle the Bluetooth connection on/off to save battery, and can
    trigger a clock time-sync on demand.

.DESCRIPTION
    Runs as a hidden PowerShell process with a NotifyIcon. All Bluetooth work is
    delegated to Sync-LYWSD02.ps1 (-ReadSensors / time-sync, -Json) run as short
    child processes, so the UI never blocks during a BLE scan.

    Launch hidden via Start-Widget.vbs (Install-Widget.ps1 sets that up and adds
    a Startup shortcut). Settings persist in settings.json; data in logs\sensors.csv.
#>
[CmdletBinding()]
param([string]$SettingsPath)

$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$SyncScript   = Join-Path $ScriptDir 'Sync-LYWSD02.ps1'   # clock device (per-read scan)
$WatchScript  = Join-Path $ScriptDir 'Watch-Aranet4.ps1'  # air-quality device (persistent listener)
if (-not $SettingsPath) { $SettingsPath = Join-Path $ScriptDir 'settings.json' }
$LogDir     = Join-Path $ScriptDir 'logs'
$CsvPath    = Join-Path $LogDir 'sensors.csv'        # LYWSD02 history
$AranetCsv  = Join-Path $LogDir 'aranet4.csv'        # Aranet4 history
$LatestJson = Join-Path $LogDir 'aranet-latest.json' # latest Aranet reading (written by the watcher)
$WidgetLog  = Join-Path $LogDir 'widget.log'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

function WLog([string]$m) {
    try { Add-Content -Path $WidgetLog -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch {}
}

# ---- Settings -------------------------------------------------------------
$DefaultSettings = [ordered]@{
    Address         = ''
    DeviceName      = 'LYWSD02'
    ScanSeconds     = 90
    IntervalMinutes = 60
    ConnectionEnabled = $true
    HourlyLogging   = $true
    AranetEnabled   = $true
    AranetIntervalMinutes = 5
    AranetScanSeconds = 150
    RoomVolume      = 29        # m3 (~3 x 4 x 2.4); used by the occupancy estimate
    TrendRange      = '7d'
    TrendFrom       = ''
    TrendTo         = ''
}
function Load-Settings {
    $s = [ordered]@{}
    foreach ($k in $DefaultSettings.Keys) { $s[$k] = $DefaultSettings[$k] }
    if (Test-Path $SettingsPath) {
        try {
            $j = Get-Content $SettingsPath -Raw | ConvertFrom-Json
            foreach ($k in @($DefaultSettings.Keys)) {
                if ($null -ne $j.$k) { $s[$k] = $j.$k }
            }
        } catch { WLog "WARN could not parse settings.json: $($_.Exception.Message)" }
    }
    return $s
}
function Save-Settings {
    try { ($script:settings | ConvertTo-Json) | Set-Content -Path $SettingsPath -Encoding UTF8 }
    catch { WLog "WARN could not save settings: $($_.Exception.Message)" }
}
$script:settings = Load-Settings

# ---- Single instance ------------------------------------------------------
$createdNew = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'LYWSD02_Tray_Widget_Mutex', [ref]$createdNew)
if (-not $createdNew) { WLog "Another instance is already running; exiting."; return }

# ---- WinForms / GDI -------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms.DataVisualization
Add-Type -Namespace LywsdNative -Name U32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern bool DestroyIcon(System.IntPtr handle);
'@
# A borderless top-level window that shows WITHOUT stealing keyboard focus and
# stays out of Alt-Tab - used for the hover popup.
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Windows.Forms;
public class NoActivatePopup : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 /*WS_EX_NOACTIVATE*/ | 0x00000080 /*WS_EX_TOOLWINDOW*/; return cp; }
    }
}
'@ -WarningAction SilentlyContinue
[System.Windows.Forms.Application]::EnableVisualStyles()
# Log UI-thread exceptions to widget.log instead of popping a modal error dialog.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($s,$e) try { WLog "THREADEXC: $($e.Exception.Message)" } catch {} })

$script:iconHandle = [IntPtr]::Zero
$script:job = $null           # @{ Proc; Out; Kind; LogCsv; Notify }
$script:lastText = '...'

# ---- Tray icon rendering --------------------------------------------------
function Update-Icon {
    param([string]$Text, [bool]$Dim)
    $script:lastText = $Text
    $bmp = New-Object System.Drawing.Bitmap 32,32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear([System.Drawing.Color]::Transparent)
    $bg = if ($Dim) { [System.Drawing.Color]::FromArgb(150, 96,96,96) } else { [System.Drawing.Color]::FromArgb(230, 28,90,160) }
    $bgBrush = New-Object System.Drawing.SolidBrush $bg
    $g.FillRectangle($bgBrush, 1,1,30,30)
    $size = if ($Text.Length -ge 3) { 15 } else { 19 }
    $font = New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = New-Object System.Drawing.RectangleF(0,0,32,32)
    $g.DrawString($Text, $font, [System.Drawing.Brushes]::White, $rect, $fmt)
    $g.Dispose(); $font.Dispose(); $bgBrush.Dispose()
    $newHandle = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($newHandle)
    $bmp.Dispose()
    $old = $script:iconHandle
    $script:ni.Icon = $icon
    $script:iconHandle = $newHandle
    if ($old -ne [IntPtr]::Zero) { [void][LywsdNative.U32]::DestroyIcon($old) }
}

# ---- CSV ------------------------------------------------------------------
function Append-Csv {
    param([double]$TempC,[int]$Humidity,$Battery)
    try {
        if (-not (Test-Path $CsvPath)) {
            Set-Content -Path $CsvPath -Value 'timestamp,tempC,tempF,humidity,battery' -Encoding UTF8
        }
        $tf = [math]::Round($TempC * 9/5 + 32, 1)
        $bat = if ($null -eq $Battery) { '' } else { $Battery }
        $row = '{0},{1},{2},{3},{4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $TempC, $tf, $Humidity, $bat
        Add-Content -Path $CsvPath -Value $row -Encoding UTF8
    } catch { WLog "WARN csv append failed: $($_.Exception.Message)" }
}
function Append-AranetCsv {
    param([int]$Co2,[double]$TempC,[int]$Humidity,[double]$Pressure,$Battery,[string]$Status)
    try {
        if (-not (Test-Path $AranetCsv)) {
            Set-Content -Path $AranetCsv -Value 'timestamp,co2,tempC,humidity,pressure,battery,status' -Encoding UTF8
        }
        $bat = if ($null -eq $Battery) { '' } else { $Battery }
        $row = '{0},{1},{2},{3},{4},{5},{6}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Co2, $TempC, $Humidity, $Pressure, $bat, $Status
        Add-Content -Path $AranetCsv -Value $row -Encoding UTF8
    } catch { WLog "WARN aranet csv append failed: $($_.Exception.Message)" }
}

# ---- Trends chart (temperature + humidity + dewpoint) ---------------------
function Get-Dewpoint {
    param([double]$T, [double]$RH)
    if ($RH -le 0) { return [double]::NaN }
    $a = 17.62; $b = 243.12
    $g = [math]::Log($RH/100.0) + ($a*$T)/($b+$T)
    return ($b*$g)/($a-$g)
}
function Get-SensorSeries {
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $CsvPath)) { return $list }
    try {
        foreach ($r in (Import-Csv $CsvPath)) {
            $t = [datetime]::MinValue
            if (-not [datetime]::TryParse($r.timestamp, [ref]$t)) { continue }
            $tc = 0.0; if (-not [double]::TryParse($r.tempC, [ref]$tc)) { continue }
            $hu = 0.0; [void][double]::TryParse($r.humidity, [ref]$hu)
            $list.Add([pscustomobject]@{ T=$t; TempC=$tc; Hum=$hu; Dew=[math]::Round((Get-Dewpoint $tc $hu),1) })
        }
    } catch { WLog "WARN csv read failed: $($_.Exception.Message)" }
    return $list
}
function Get-AranetSeries {
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $AranetCsv)) { return $list }
    try {
        foreach ($r in (Import-Csv $AranetCsv)) {
            $t = [datetime]::MinValue
            if (-not [datetime]::TryParse($r.timestamp, [ref]$t)) { continue }
            $co2 = 0.0; if (-not [double]::TryParse($r.co2, [ref]$co2)) { continue }
            $pr = 0.0; [void][double]::TryParse($r.pressure, [ref]$pr)
            $list.Add([pscustomobject]@{ T=$t; Co2=[int]$co2; Pres=$pr })
        }
    } catch { WLog "WARN aranet csv read failed: $($_.Exception.Message)" }
    return $list
}
# Display labels <-> internal codes for the time-range filter.
$script:RangeMap = [ordered]@{
    'Last hour'      = '1h'
    'Last 6 hours'   = '6h'
    'Last 24 hours'  = '24h'
    'Last 7 days'    = '7d'
    'Last 30 days'   = '30d'
    'All'            = 'all'
    'Custom range...'= 'custom'
}
function Get-RangeBounds {
    $code = $script:settings.TrendRange; if (-not $code) { $code = '7d' }
    $now = Get-Date
    switch ($code) {
        '1h'  { @{ From=$now.AddHours(-1);  To=$now } }
        '6h'  { @{ From=$now.AddHours(-6);  To=$now } }
        '24h' { @{ From=$now.AddDays(-1);   To=$now } }
        '7d'  { @{ From=$now.AddDays(-7);   To=$now } }
        '30d' { @{ From=$now.AddDays(-30);  To=$now } }
        'all' { @{ From=[datetime]'1900-01-01'; To=[datetime]'2999-01-01' } }
        'custom' {
            $f = if ($script:settings.TrendFrom) { [datetime]$script:settings.TrendFrom } else { $now.AddDays(-7) }
            $t = if ($script:settings.TrendTo)   { [datetime]$script:settings.TrendTo }   else { $now }
            @{ From=$f; To=$t }
        }
        default { @{ From=$now.AddDays(-7); To=$now } }
    }
}
function Reading-Text {
    $clock = 'LYWSD02: no reading yet'
    if ($script:lastReading) {
        $tc=[double]$script:lastReading.TempC; $hu=[int]$script:lastReading.Humidity; $bat=$script:lastReading.Battery
        $dew=Get-Dewpoint $tc $hu
        $batTxt = if ($null -eq $bat) {'?'} else {"$bat%"}
        $clock = ("LYWSD02: {0:0.0}C  {1}% RH  dew {2:0.0}C  batt {3}" -f $tc,$hu,$dew,$batTxt)
    }
    $aranet = ''
    if ($script:lastAranet) {
        $aranet = ("   |   Aranet4: {0} ppm CO2 ({1})  {2:0.0}hPa" -f [int]$script:lastAranet.Co2, $script:lastAranet.Status, [double]$script:lastAranet.Pres)
    }
    return ($clock + $aranet)
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
    $area.AxisX.MajorGrid.Enabled = $false   # no vertical grid - cleaner
}
function New-TrendChart {
    param([bool]$Compact)
    $deg   = [char]0x00B0
    $bg    = [System.Drawing.Color]::FromArgb(18,19,24)
    $grid  = [System.Drawing.Color]::FromArgb(42,44,52)
    $fg    = [System.Drawing.Color]::FromArgb(165,172,188)
    $cTemp = [System.Drawing.Color]::FromArgb(255,122,89)
    $cDew  = [System.Drawing.Color]::FromArgb(86,180,239)
    $cHum  = [System.Drawing.Color]::FromArgb(72,199,142)
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $area  = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea('main')
    Style-ChartArea $chart $area $bg $grid $fg
    $area.AxisX.IntervalType = [System.Windows.Forms.DataVisualization.Charting.DateTimeIntervalType]::Hours
    $area.AxisY.LabelStyle.ForeColor = $cTemp; $area.AxisY.IsStartedFromZero = $false
    $area.AxisY2.Enabled = [System.Windows.Forms.DataVisualization.Charting.AxisEnabled]::True
    $area.AxisY2.IsStartedFromZero = $false; $area.AxisY2.LabelStyle.ForeColor = $cHum; $area.AxisY2.MajorGrid.Enabled = $false
    $chart.ChartAreas.Add($area)
    $P=[System.Windows.Forms.DataVisualization.Charting.AxisType]::Primary
    $S=[System.Windows.Forms.DataVisualization.Charting.AxisType]::Secondary
    $mk = {
        param($name,$legend,$axis,$color,$dash,$tip)
        $s = New-Object System.Windows.Forms.DataVisualization.Charting.Series($name)
        # Line, not Spline: spline interpolation overshoots between unevenly-spaced
        # samples, inventing curves and spikes that aren't in the data.
        $s.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
        $s.XValueType = [System.Windows.Forms.DataVisualization.Charting.ChartValueType]::DateTime
        $s.BorderWidth = if ($Compact) {2} else {3}; $s.Color = $color; $s.YAxisType = $axis; $s.LegendText = $legend
        $s.ToolTip = $tip
        # small markers so isolated/sparse points stay visible even where the
        # line breaks across a gap (a bare Line draws nothing for a lone point).
        $s.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle
        $s.MarkerSize = if ($Compact) {2} else {3}; $s.MarkerColor = $color
        if ($dash) { $s.BorderDashStyle = [System.Windows.Forms.DataVisualization.Charting.ChartDashStyle]::Dash }
        $chart.Series.Add($s)
    }
    & $mk 'Humidity'    'Humidity (%)'              $S $cHum  $false "Humidity  #VALY{0}%  @ #VALX"
    & $mk 'Temperature' "Temperature ($($deg)C)"    $P $cTemp $false "Temperature  #VALY{0.0}$($deg)C  @ #VALX"
    & $mk 'Dew point'   "Dew point ($($deg)C)"      $P $cDew  $true  "Dew point  #VALY{0.0}$($deg)C  @ #VALX"
    $lg = New-Object System.Windows.Forms.DataVisualization.Charting.Legend('L')
    $lg.BackColor = [System.Drawing.Color]::Transparent; $lg.ForeColor = $fg
    $lg.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Top
    $lg.Font = New-Object System.Drawing.Font('Segoe UI', $(if ($Compact) {7} else {8.5}))
    $chart.Legends.Add($lg)
    return $chart
}
# Add points to a series, inserting an empty point across gaps larger than
# $gapMin so the line/area BREAKS instead of drawing a misleading connector
# across hours/days when the widget wasn't logging.
function Add-GapAware($series, $rows, [string]$vprop, [double]$gapMin) {
    $prev = $null
    foreach ($r in $rows) {
        $t = $r.T
        if ($null -ne $prev -and ($t - $prev).TotalMinutes -gt $gapMin) {
            $i = $series.Points.AddXY($prev.AddSeconds(30), 0); $series.Points[$i].IsEmpty = $true
        }
        [void]$series.Points.AddXY($t, $r.$vprop)
        $prev = $t
    }
}
function Rebuild-ChartData {
    param($chart, [string]$TitleText)
    $b = Get-RangeBounds
    $data = @(Get-SensorSeries | Where-Object { $_.T -ge $b.From -and $_.T -le $b.To })
    $sT = $chart.Series['Temperature']; $sD = $chart.Series['Dew point']; $sH = $chart.Series['Humidity']
    $sT.Points.Clear(); $sD.Points.Clear(); $sH.Points.Clear()
    $gap = [Math]::Max(4 * (Clock-Interval), 120)   # only break across real outages (~2h+)
    Add-GapAware $sH $data 'Hum'   $gap
    Add-GapAware $sT $data 'TempC' $gap
    Add-GapAware $sD $data 'Dew'   $gap
    Update-Granularity $chart
    if ($chart.Titles.Count -gt 0 -and $TitleText) { $chart.Titles[0].Text = $TitleText }
}

# ---- Air-quality chart (Aranet4: CO2 + pressure) --------------------------
function New-Co2Chart {
    param([bool]$Compact)
    $bg    = [System.Drawing.Color]::FromArgb(18,19,24)
    $grid  = [System.Drawing.Color]::FromArgb(42,44,52)
    $fg    = [System.Drawing.Color]::FromArgb(165,172,188)
    $cCo2  = [System.Drawing.Color]::FromArgb(232,176,64)
    $cPres = [System.Drawing.Color]::FromArgb(167,139,238)
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $area  = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea('main')
    Style-ChartArea $chart $area $bg $grid $fg
    $area.AxisX.IntervalType = [System.Windows.Forms.DataVisualization.Charting.DateTimeIntervalType]::Hours
    $area.AxisY.LabelStyle.ForeColor = $cCo2; $area.AxisY.IsStartedFromZero = $false
    $area.AxisY2.Enabled = [System.Windows.Forms.DataVisualization.Charting.AxisEnabled]::True
    $area.AxisY2.IsStartedFromZero = $false; $area.AxisY2.LabelStyle.ForeColor = $cPres; $area.AxisY2.MajorGrid.Enabled = $false
    $chart.ChartAreas.Add($area)
    $P=[System.Windows.Forms.DataVisualization.Charting.AxisType]::Primary
    $S=[System.Windows.Forms.DataVisualization.Charting.AxisType]::Secondary
    # Both as Line (not Spline/Area): Line never overshoots and breaks cleanly at
    # gaps, whereas an Area wedges down to the axis floor across a gap and leaves a
    # misleading faint fill where there is no data.
    $sCo2 = New-Object System.Windows.Forms.DataVisualization.Charting.Series('CO2')
    $sCo2.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
    $sCo2.XValueType = [System.Windows.Forms.DataVisualization.Charting.ChartValueType]::DateTime
    $sCo2.YAxisType = $P; $sCo2.LegendText = 'CO2 (ppm)'
    $sCo2.Color = $cCo2; $sCo2.BorderWidth = if ($Compact) {2} else {3}
    $sCo2.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle
    $sCo2.MarkerSize = if ($Compact) {2} else {3}; $sCo2.MarkerColor = $cCo2
    $sCo2.ToolTip = "CO2  #VALY{0} ppm  @ #VALX"
    $chart.Series.Add($sCo2)
    $sPres = New-Object System.Windows.Forms.DataVisualization.Charting.Series('Pressure')
    $sPres.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
    $sPres.XValueType = [System.Windows.Forms.DataVisualization.Charting.ChartValueType]::DateTime
    $sPres.YAxisType = $S; $sPres.LegendText = 'Pressure (hPa)'
    $sPres.Color = $cPres; $sPres.BorderWidth = if ($Compact) {2} else {3}
    $sPres.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle
    $sPres.MarkerSize = if ($Compact) {2} else {3}; $sPres.MarkerColor = $cPres
    $sPres.ToolTip = "Pressure  #VALY{0.0} hPa  @ #VALX"
    $chart.Series.Add($sPres)
    $lg = New-Object System.Windows.Forms.DataVisualization.Charting.Legend('L')
    $lg.BackColor = [System.Drawing.Color]::Transparent; $lg.ForeColor = $fg
    $lg.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Top
    $lg.Font = New-Object System.Drawing.Font('Segoe UI', $(if ($Compact) {7} else {8.5}))
    $chart.Legends.Add($lg)
    return $chart
}
function Rebuild-Co2Data {
    param($chart, [string]$TitleText)
    $b = Get-RangeBounds
    $data = @(Get-AranetSeries | Where-Object { $_.T -ge $b.From -and $_.T -le $b.To })
    $sC = $chart.Series['CO2']; $sP = $chart.Series['Pressure']
    $sC.Points.Clear(); $sP.Points.Clear()
    $gap = [Math]::Max(8 * (Aranet-Interval), 120)  # only break across real outages (~2h+)
    Add-GapAware $sC $data 'Co2'  $gap
    Add-GapAware $sP $data 'Pres' $gap
    Update-Granularity $chart
    if ($chart.Titles.Count -gt 0 -and $TitleText) { $chart.Titles[0].Text = $TitleText }
}

# ---- NotifyIcon + menu ----------------------------------------------------
$script:ni = New-Object System.Windows.Forms.NotifyIcon
Update-Icon '...' (-not $script:settings.ConnectionEnabled)
$script:ni.Text = 'LYWSD02 clock widget'
$script:ni.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
function New-Item([string]$text) { New-Object System.Windows.Forms.ToolStripMenuItem($text) }

$miTitle      = New-Item 'LYWSD02 Clock + Aranet4'; $miTitle.Enabled = $false; $f=$miTitle.Font; $miTitle.Font = New-Object System.Drawing.Font($f.FontFamily,$f.Size,[System.Drawing.FontStyle]::Bold)
$miReading    = New-Item 'No reading yet'; $miReading.Enabled = $false
$miRead       = New-Item 'Read clock now'
$miReadAranet = New-Item 'Read Aranet4 now'
$miSync       = New-Item 'Sync clock now'
$miTrends     = New-Item 'Open dashboard...'
$miConn       = New-Item 'Connection enabled'
$miLog        = New-Item 'Log hourly to CSV'
$miClockIvl   = New-Item 'LYWSD02 read interval'
$miAranet     = New-Item 'Track Aranet4 (CO2)'
$miAranetIvl  = New-Item 'Aranet4 read interval'
$miOpen       = New-Item 'Open data folder'
$miStartup    = New-Item 'Run at login'
$miExit       = New-Item 'Exit'

# Sub-menu of selectable Aranet read intervals (minutes).
$script:AranetIvlOptions = @(1,2,3,5,10,15,30)
$script:miAranetIvlItems = @{}
foreach ($mins in $script:AranetIvlOptions) {
    $label = if ($mins -eq 1) { 'Every 1 minute' } else { "Every $mins minutes" }
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($label)
    $item.Tag = $mins
    $item.Add_Click({
        param($s,$e)
        $script:settings.AranetIntervalMinutes = [int]$s.Tag
        $script:aranetDue = Get-Date            # apply immediately
        Save-Settings; Refresh-Menu
        Scheduler-Tick
    })
    [void]$miAranetIvl.DropDownItems.Add($item)
    $script:miAranetIvlItems[$mins] = $item
}

# Sub-menu of selectable LYWSD02 read intervals (minutes). The clock connects
# over BLE for each read, which uses its coin-cell battery, so the options are
# more conservative than the (passive) Aranet's.
$script:ClockIvlOptions = @(5,10,15,30,60)
$script:miClockIvlItems = @{}
foreach ($mins in $script:ClockIvlOptions) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem("Every $mins minutes")
    $item.Tag = $mins
    $item.Add_Click({
        param($s,$e)
        $script:settings.IntervalMinutes = [int]$s.Tag
        $script:clockDue = Get-Date              # apply immediately
        Save-Settings; Refresh-Menu
        Scheduler-Tick
    })
    [void]$miClockIvl.DropDownItems.Add($item)
    $script:miClockIvlItems[$mins] = $item
}

$menu.Items.AddRange(@(
    $miTitle, $miReading,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $miRead, $miReadAranet, $miSync, $miTrends,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $miConn, $miLog, $miClockIvl, $miAranet, $miAranetIvl, $miOpen, $miStartup,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $miExit
))
$script:ni.ContextMenuStrip = $menu

# ---- Startup shortcut -----------------------------------------------------
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'LYWSD02 Widget.lnk'
function Test-Startup { Test-Path $StartupLnk }
function Set-Startup {
    param([bool]$On)
    try {
        if ($On) {
            $wsh = New-Object -ComObject WScript.Shell
            $sc = $wsh.CreateShortcut($StartupLnk)
            $sc.TargetPath = Join-Path $ScriptDir 'Start-Widget.vbs'
            $sc.WorkingDirectory = $ScriptDir
            $sc.Description = 'LYWSD02 tray widget'
            $sc.Save()
        } elseif (Test-Path $StartupLnk) {
            Remove-Item $StartupLnk -Force
        }
    } catch { WLog "WARN startup toggle failed: $($_.Exception.Message)" }
}

# ---- Menu state refresh ---------------------------------------------------
function Job-Active([string]$device) {
    foreach ($j in $script:jobs) { if ($j.Device -eq $device) { return $true } }
    return $false
}
function Refresh-Menu {
    $miConn.Checked    = [bool]$script:settings.ConnectionEnabled
    $miConn.Text       = if ($script:settings.ConnectionEnabled) { 'Connection enabled (saving: off)' } else { 'Connection disabled (battery saver)' }
    $miLog.Checked     = [bool]$script:settings.HourlyLogging
    $miAranet.Checked  = [bool]$script:settings.AranetEnabled
    $miStartup.Checked = (Test-Startup)
    $clockBusy = Job-Active 'clock'
    $miRead.Enabled = (-not $clockBusy) -and $script:settings.ConnectionEnabled
    $miSync.Enabled = (-not $clockBusy) -and $script:settings.ConnectionEnabled
    $miReadAranet.Enabled = $script:settings.ConnectionEnabled -and $script:settings.AranetEnabled
    $ivl = [int]$script:settings.AranetIntervalMinutes; if ($ivl -lt 1) { $ivl = 5 }
    $miAranetIvl.Enabled = [bool]$script:settings.AranetEnabled
    $miAranetIvl.Text = "Aranet4 read interval ($ivl min)"
    foreach ($k in $script:miAranetIvlItems.Keys) { $script:miAranetIvlItems[$k].Checked = ($k -eq $ivl) }
    $civl = [int]$script:settings.IntervalMinutes; if ($civl -lt 1) { $civl = 60 }
    $miClockIvl.Text = "LYWSD02 read interval ($civl min)"
    foreach ($k in $script:miClockIvlItems.Keys) { $script:miClockIvlItems[$k].Checked = ($k -eq $civl) }
}

# ---- Tooltip --------------------------------------------------------------
function Set-Tooltip {
    $t = Reading-Text
    if ($t.Length -gt 127) { $t = $t.Substring(0,124) + '...' }
    try { $script:ni.Text = $t } catch {}
}

# ---- Async BLE jobs (one per device; delegated to the device scripts) -----
$script:jobs = New-Object System.Collections.ArrayList

function Start-Bg {
    param([ValidateSet('read','sync')] [string]$Kind, [bool]$LogCsv, [bool]$Notify)
    if (-not $script:settings.ConnectionEnabled) { return }
    if (Job-Active 'clock') { return }
    $addr = $script:settings.Address
    $scan = [int]$script:settings.ScanSeconds
    $tmp  = [System.IO.Path]::GetTempFileName()
    $common = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SyncScript`" -Json -NoToggle -DeviceName `"$($script:settings.DeviceName)`" -ScanSeconds $scan"
    if ($addr) { $common += " -Address `"$addr`"" }
    if ($Kind -eq 'read') { $common += " -ReadSensors" }
    Stop-AranetWatcher   # free the radio for the clock scan; resumed when it completes
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $common -WindowStyle Hidden -PassThru -RedirectStandardOutput $tmp
        [void]$script:jobs.Add(@{ Proc=$p; Out=$tmp; Device='clock'; Kind=$Kind; LogCsv=$LogCsv; Notify=$Notify })
        if ($Kind -eq 'read') { Update-Icon '..' (-not $script:settings.ConnectionEnabled) }
        $script:poll.Start(); Refresh-Menu
    } catch {
        WLog "ERROR launching clock $Kind : $($_.Exception.Message)"
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

# ---- Aranet: persistent watcher daemon + instant file sampling ------------
# The Aranet broadcasts only in bursts (with multi-minute gaps), so instead of
# repeated short scans we keep ONE long-lived watcher (Watch-Aranet4.ps1) that
# writes the latest reading to aranet-latest.json. The widget samples that file
# on its own schedule - instant, no radio. The watcher is paused during the
# (rare) clock scan so the two don't compete for the radio.
function Stop-AranetWatcher {
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*-File*Watch-Aranet4.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {}
    $script:aranetWatcherPid = $null
}
function Ensure-AranetWatcher {
    if (-not $script:settings.ConnectionEnabled) { return }
    if (-not $script:settings.AranetEnabled) { return }
    if (Job-Active 'clock') { return }   # never scan while the clock read is using the radio
    # Reconcile to EXACTLY one watcher: duplicate advertisement watchers fight for
    # the radio and drop broadcasts, so keep the newest and kill any extras.
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -like '*-File*Watch-Aranet4.ps1*' })
    if ($procs.Count -ge 1) {
        $keep = $procs | Sort-Object CreationDate -Descending | Select-Object -First 1
        if ($procs.Count -gt 1) {
            $procs | Where-Object { $_.ProcessId -ne $keep.ProcessId } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
            WLog "INFO killed $($procs.Count - 1) duplicate aranet watcher(s)"
        }
        $script:aranetWatcherPid = $keep.ProcessId
        return
    }
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatchScript`"" -WindowStyle Hidden -PassThru
        $script:aranetWatcherPid = $p.Id
        WLog "INFO aranet watcher started (pid $($p.Id))"
    } catch { WLog "ERROR launching aranet watcher: $($_.Exception.Message)" }
}
function Sample-Aranet {
    param([bool]$LogCsv, [bool]$Notify)
    $data = $null
    if (Test-Path $LatestJson) {
        try { $data = Get-Content $LatestJson -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json } catch {}
    }
    if (-not ($data -and $data.ok)) {
        if ($Notify) { $script:ni.ShowBalloonTip(4000,'Aranet4','No reading captured yet (waiting for a broadcast).',[System.Windows.Forms.ToolTipIcon]::Warning) }
        return
    }
    $ts = [string]$data.ts
    $isNew = ($ts -ne $script:lastAranetTs)
    # Stamp the reading with the broadcast capture time (data.ts), NOT the moment
    # we read the file - otherwise a stale latest.json always looks "fresh".
    $when = Get-Date
    try { if ($ts) { $when = [datetime]::Parse($ts) } } catch {}
    $script:lastAranet = @{
        Co2=[int]$data.co2; TempC=[double]$data.tempC; Hum=[int]$data.humidity;
        Pres=[double]$data.pressure; Battery=$data.battery; Status=[string]$data.status; When=$when
    }
    if ($isNew) {
        $script:lastAranetTs = $ts
        if ($LogCsv) { Append-AranetCsv -Co2 $script:lastAranet.Co2 -TempC $script:lastAranet.TempC -Humidity $script:lastAranet.Hum -Pressure $script:lastAranet.Pres -Battery $script:lastAranet.Battery -Status $script:lastAranet.Status }
        WLog "INFO aranet co2=$($script:lastAranet.Co2) status=$($script:lastAranet.Status) (captured $ts)"
    }
    if ($Notify) { $script:ni.ShowBalloonTip(4000,'Aranet4', ("{0} ppm CO2 ({1})   {2:0.0} hPa   (as of {3})" -f $script:lastAranet.Co2,$script:lastAranet.Status,$script:lastAranet.Pres,$ts), [System.Windows.Forms.ToolTipIcon]::Info) }
    Set-Tooltip
    $miReading.Text = Reading-Text
    if ($script:popupShown) { try { Update-PopupData; $script:popupPanel.Invalidate() } catch {} }
    Refresh-Dashboard
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
    if ($data -and $data.ok) {
        $tc = [double]$data.tempC; $hu = [int]$data.humidity; $bat = $data.battery
        $script:lastReading = @{ TempC=$tc; Humidity=$hu; Battery=$bat; When=(Get-Date) }
        Update-Icon ([string][math]::Round($tc)) (-not $script:settings.ConnectionEnabled)
        if ($data.addr -and $data.addr -ne $script:settings.Address) {
            WLog "INFO learned/updated address: $($data.addr)"
            $script:settings.Address = $data.addr; Save-Settings
        }
        if ($j.LogCsv) { Append-Csv -TempC $tc -Humidity $hu -Battery $bat }
        if ($j.Notify) {
            $batTxt = if ($null -eq $bat) { '?' } else { "$bat%" }
            $script:ni.ShowBalloonTip(4000,'LYWSD02', ("{0:0.0} C   {1}% RH   battery {2}" -f $tc,$hu,$batTxt), [System.Windows.Forms.ToolTipIcon]::Info)
        }
    } else {
        if ($j.Kind -eq 'read') { Update-Icon '--' (-not $script:settings.ConnectionEnabled) }
        if ($j.Notify) {
            $msg = if ($j.Kind -eq 'sync') { 'Clock sync failed (not seen / out of range).' } else { 'Could not read the clock (not seen / out of range).' }
            $script:ni.ShowBalloonTip(4000,'LYWSD02',$msg,[System.Windows.Forms.ToolTipIcon]::Warning)
        }
        WLog "WARN clock $($j.Kind) failed"
        return
    }
    if ($j.Kind -eq 'sync' -and $j.Notify) { $script:ni.ShowBalloonTip(4000,'LYWSD02','Clock time synchronised.',[System.Windows.Forms.ToolTipIcon]::Info) }
    if ($j.Kind -eq 'sync') { WLog 'INFO clock synced' }
}

function Poll-Jobs {
    if ($script:jobs.Count -eq 0) { $script:poll.Stop(); return }
    $done = @($script:jobs | Where-Object { $_.Proc.HasExited })
    $clockCompleted = $false
    foreach ($j in $done) {
        $script:jobs.Remove($j)
        $data = Read-JobJson $j
        Complete-Clock $j $data
        $clockCompleted = $true
    }
    # Clock scan finished -> the radio is free again, so resume the Aranet watcher.
    if ($clockCompleted) { Ensure-AranetWatcher }
    if ($done.Count -gt 0) {
        Set-Tooltip
        $miReading.Text = Reading-Text
        if ($script:popupShown) { try { Update-PopupData; $script:popupPanel.Invalidate() } catch {} }
        Refresh-Dashboard
        Refresh-Menu
    }
    if ($script:jobs.Count -eq 0) { $script:poll.Stop() }
}

# ---- Timers ---------------------------------------------------------------
$script:poll = New-Object System.Windows.Forms.Timer
$script:poll.Interval = 1500
$script:poll.Add_Tick({ Poll-Jobs })

# ---- Scheduler: one BLE scan at a time, independent per-device intervals ---
# Each device has its own "due" time. A single ticking scheduler runs whichever
# device is due, but only when the radio is free - so frequent Aranet reads can
# never starve the hourly clock read (the clock just runs the moment the radio
# frees after its hour is up).
$script:clockDue  = Get-Date   # due immediately on launch
$script:aranetDue = Get-Date
function Aranet-Interval { $m = [int]$script:settings.AranetIntervalMinutes; if ($m -lt 1) { 5 } else { $m } }
function Clock-Interval  { $m = [int]$script:settings.IntervalMinutes; if ($m -lt 1) { 60 } else { $m } }
function Scheduler-Tick {
    if (-not $script:settings.ConnectionEnabled) { return }
    $now = Get-Date
    $log = [bool]$script:settings.HourlyLogging
    # Clock read uses the radio (and pauses the watcher). Do it first; if we start
    # one, return so we don't immediately re-start the watcher we just paused.
    if (-not (Job-Active 'clock') -and $now -ge $script:clockDue) {
        $script:clockDue = $now.AddMinutes((Clock-Interval))
        Start-Bg -Kind 'read' -LogCsv $log -Notify $false
        return
    }
    Ensure-AranetWatcher   # keep the persistent listener alive (no-op if already running)
    # Aranet "read" is just sampling the watcher's latest file - no radio, safe anytime.
    if ($script:settings.AranetEnabled -and $now -ge $script:aranetDue) {
        $script:aranetDue = $now.AddMinutes((Aranet-Interval))
        Sample-Aranet -LogCsv $log -Notify $false
    }
}
$script:sched = New-Object System.Windows.Forms.Timer
$script:sched.Interval = 10000   # poll every 10s; real cadence is set by the due times
$script:sched.Add_Tick({ Scheduler-Tick })
$script:sched.Start()

# Fast first read shortly after launch so the icon/values populate.
$script:kick = New-Object System.Windows.Forms.Timer
$script:kick.Interval = 2500
$script:kick.Add_Tick({ $script:kick.Stop(); Scheduler-Tick })
$script:kick.Start()

# ---- Hover popup + trends window ------------------------------------------
$script:popupShown   = $false
$script:popupAnchor  = New-Object System.Drawing.Point(0,0)
$script:suppressUntil = 0
$script:trendForm    = $null
$script:trendChart   = $null
$script:trendCo2Chart = $null
$script:lastAranet   = $null
$script:lastAranetTs = ''
$script:aranetWatcherPid = $null

# Hover popup: a compact Room State summary that matches the dashboard.
$script:popupData = $null
$script:popup = New-Object NoActivatePopup
$script:popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$script:popup.ControlBox      = $false
$script:popup.ShowInTaskbar   = $false
$script:popup.TopMost         = $true
$script:popup.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
$script:popup.Size            = New-Object System.Drawing.Size(384,160)
$script:popup.BackColor       = [System.Drawing.Color]::FromArgb(13,14,16)   # themed at show time
$script:popupPanel = New-Object System.Windows.Forms.Panel
$script:popupPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:popupPanel.BackColor = [System.Drawing.Color]::FromArgb(13,14,16)
try { ([System.Windows.Forms.Control].GetProperty('DoubleBuffered',[System.Reflection.BindingFlags]'Instance,NonPublic')).SetValue($script:popupPanel,$true,$null) } catch {}
$script:popupPanel.Add_Paint({ param($s,$e); try { Rs-PaintPopup $e.Graphics $this } catch { WLog "rs popup: $($_.Exception.Message)" } })
$script:popup.Controls.Add($script:popupPanel)
# Force handle + layout once, offscreen, so the first hover paints correctly.
$script:popup.Location = New-Object System.Drawing.Point(-4000,-4000)
$script:popup.Show(); $script:popup.Hide()
# Clicking the hover popup opens the full Room State dashboard.
$popupClick = { Hide-Popup; Show-Dashboard }
$script:popup.Add_Click($popupClick)
$script:popupPanel.Add_Click($popupClick)

function Show-Popup {
    param([int]$cx,[int]$cy)
    try {
        Update-PopupData
        $script:popup.BackColor = $script:DashTheme.Canvas; $script:popupPanel.BackColor = $script:DashTheme.Canvas
        $script:popupPanel.Invalidate()
        $scr = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point($cx,$cy))).WorkingArea
        $w = $script:popup.Width; $h = $script:popup.Height
        $x = [math]::Min([math]::Max([int]($cx - $w/2), $scr.Left), $scr.Right - $w)
        $y = $cy - $h - 12; if ($y -lt $scr.Top) { $y = $cy + 24 }
        $script:popup.Location = New-Object System.Drawing.Point([int]$x, [int]$y)
        $script:popup.Show()
        $script:popup.TopMost = $true
        $script:popupShown  = $true
        $script:popupAnchor = New-Object System.Drawing.Point($cx, $cy)
        $script:hide.Start()
    } catch { WLog "WARN show-popup: $($_.Exception.Message)" }
}
function Hide-Popup {
    if ($script:popupShown) {
        try { $script:popup.Hide() } catch {}
        $script:popupShown = $false
        $script:hide.Stop()
    }
}

$script:hide = New-Object System.Windows.Forms.Timer
$script:hide.Interval = 150
$script:hide.Add_Tick({
    try {
        if (-not $script:popupShown) { $script:hide.Stop(); return }
        $p = [System.Windows.Forms.Cursor]::Position
        $b = $script:popup.Bounds; $b.Inflate(8,8)
        $overPopup = $b.Contains($p)
        # Any mouse click outside the popup (tray icon, desktop, another window) dismisses it.
        if (-not $overPopup -and [System.Windows.Forms.Control]::MouseButtons -ne [System.Windows.Forms.MouseButtons]::None) { Hide-Popup; return }
        # Hover away: cursor has left both the popup and the tray-icon area.
        $a = $script:popupAnchor
        $nearAnchor = ([math]::Abs($p.X-$a.X) -le 40 -and [math]::Abs($p.Y-$a.Y) -le 40)
        if (-not $overPopup -and -not $nearAnchor) { Hide-Popup }
    } catch {}
})

# ---- Scroll-wheel zoom on the trends window -------------------------------
# Returns the X data range (OADate doubles) and largest point count of a chart.
function Get-ChartXRange($chart) {
    $mn = [double]::PositiveInfinity; $mx = [double]::NegativeInfinity; $pc = 0
    foreach ($s in $chart.Series) {
        $n = $s.Points.Count
        if ($n -gt 0) {
            if ($s.Points[0].XValue   -lt $mn) { $mn = $s.Points[0].XValue }
            if ($s.Points[$n-1].XValue -gt $mx) { $mx = $s.Points[$n-1].XValue }
            if ($n -gt $pc) { $pc = $n }
        }
    }
    return @{ Min=$mn; Max=$mx; Count=$pc }
}
function Zoom-Reset {
    foreach ($c in @($script:trendChart, $script:trendCo2Chart)) {
        if ($c) { try { $c.ChartAreas['main'].AxisX.ScaleView.ZoomReset(0); Update-Granularity $c } catch {} }
    }
}
# Apply the same absolute time window [vmin,vmax] (OADate) to both charts, each
# clamped to its own data range, so the two devices stay time-aligned.
function Zoom-Apply($vmin, $vmax) {
    foreach ($c in @($script:trendChart, $script:trendCo2Chart)) {
        if (-not $c) { continue }
        try {
            $r = Get-ChartXRange $c
            if ($r.Count -lt 2 -or $r.Max -le $r.Min) { continue }
            $mn = [math]::Max($vmin, $r.Min); $mx = [math]::Min($vmax, $r.Max)
            if ($mx -gt $mn) { $c.ChartAreas['main'].AxisX.ScaleView.Zoom($mn, $mx) }
            else { $c.ChartAreas['main'].AxisX.ScaleView.ZoomReset(0) }
            Update-Granularity $c   # step ticks through years/months/.../minutes
        } catch {}
    }
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
        # Anchor the zoom on the time value under the cursor.
        $anchor = $null
        try { $anchor = $ax.PixelPositionToValue([double]$e.Location.X) } catch {}
        if ($null -eq $anchor -or [double]::IsNaN($anchor) -or $anchor -lt $curMin -or $anchor -gt $curMax) { $anchor = ($curMin + $curMax) / 2 }
        $minRange = 3.0 * $fullRange / $r.Count            # ~3 samples = max zoom-in
        $factor = if ($e.Delta -gt 0) { 0.8 } else { 1.25 } # wheel up = zoom in
        $newRange = $curRange * $factor
        if ($newRange -ge $fullRange) { Zoom-Reset; return } # zoomed all the way out
        if ($newRange -lt $minRange) { $newRange = $minRange }
        $leftFrac = ($anchor - $curMin) / $curRange
        $newMin = $anchor - $leftFrac * $newRange
        $newMax = $newMin + $newRange
        if ($newMin -lt $r.Min) { $newMin = $r.Min; $newMax = $r.Min + $newRange }
        if ($newMax -gt $r.Max) { $newMax = $r.Max; $newMin = $r.Max - $newRange }
        Zoom-Apply $newMin $newMax
    } catch {}
}

function Show-TrendsWindow {
    try {
        if ($script:trendForm -and -not $script:trendForm.IsDisposed) {
            Rebuild-ChartData $script:trendChart ("LYWSD02 (clock)   -   " + (Reading-Text))
            if ($script:trendCo2Chart) { Rebuild-Co2Data $script:trendCo2Chart 'Aranet4 (air quality)' }
            $script:trendForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $script:trendForm.Activate(); return
        }
        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'Environment trends  -  LYWSD02 + Aranet4   (scroll to zoom, scrollbar to pan)'
        $f.Size = New-Object System.Drawing.Size(920,640)
        $f.MinimumSize = New-Object System.Drawing.Size(580,420)
        $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $f.BackColor = [System.Drawing.Color]::FromArgb(24,24,28)
        $fg = [System.Drawing.Color]::FromArgb(225,225,225)
        # Two devices, two stacked charts: LYWSD02 (top) and Aranet4 (bottom).
        $envChart = New-TrendChart $false; $envChart.Dock = [System.Windows.Forms.DockStyle]::Fill
        $co2Chart = New-Co2Chart  $false; $co2Chart.Dock = [System.Windows.Forms.DockStyle]::Fill
        # Mouse-wheel zoom (time axis). Focus the chart on hover so it gets the wheel.
        foreach ($c in @($envChart, $co2Chart)) {
            $c.Add_MouseEnter({ try { $this.Focus() } catch {} })
            $c.Add_MouseWheel($script:OnChartWheel)
        }
        $split = New-Object System.Windows.Forms.SplitContainer
        $split.Dock = [System.Windows.Forms.DockStyle]::Fill
        $split.Orientation = [System.Windows.Forms.Orientation]::Horizontal
        $split.BackColor = [System.Drawing.Color]::FromArgb(24,24,28)
        $split.Panel1MinSize = 90; $split.Panel2MinSize = 90
        $split.Panel1.Controls.Add($envChart)
        $split.Panel2.Controls.Add($co2Chart)
        $bar = New-Object System.Windows.Forms.Panel
        $bar.Dock = [System.Windows.Forms.DockStyle]::Bottom; $bar.Height = 40
        $bar.BackColor = [System.Drawing.Color]::FromArgb(24,24,28)

        $lblRange = New-Object System.Windows.Forms.Label
        $lblRange.Text = 'Range:'; $lblRange.ForeColor = $fg; $lblRange.AutoSize = $true
        $lblRange.Location = New-Object System.Drawing.Point(8,11)
        # These controls are referenced from event handlers that fire AFTER this
        # function returns, so they must live in script scope (PowerShell handler
        # scriptblocks don't capture function locals).
        $script:cbRange = New-Object System.Windows.Forms.ComboBox
        $script:cbRange.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
        $script:cbRange.Width = 130; $script:cbRange.Location = New-Object System.Drawing.Point(54,7)
        foreach ($k in $script:RangeMap.Keys) { [void]$script:cbRange.Items.Add($k) }
        # Select the saved range (default 7 days).
        $curCode = $script:settings.TrendRange; if (-not $curCode) { $curCode = '7d' }
        $curLabel = ($script:RangeMap.GetEnumerator() | Where-Object { $_.Value -eq $curCode } | Select-Object -First 1).Key
        if (-not $curLabel) { $curLabel = 'Last 7 days' }
        $script:cbRange.SelectedItem = $curLabel

        $script:dtFrom = New-Object System.Windows.Forms.DateTimePicker
        $script:dtFrom.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
        $script:dtFrom.Width = 110; $script:dtFrom.Location = New-Object System.Drawing.Point(192,8)
        $script:dtTo = New-Object System.Windows.Forms.DateTimePicker
        $script:dtTo.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
        $script:dtTo.Width = 110; $script:dtTo.Location = New-Object System.Drawing.Point(312,8)
        $lblTo = New-Object System.Windows.Forms.Label
        $lblTo.Text='to'; $lblTo.ForeColor=$fg; $lblTo.AutoSize=$true; $lblTo.Location=New-Object System.Drawing.Point(304,11)
        $script:lblTo = $lblTo
        if ($script:settings.TrendFrom) { try { $script:dtFrom.Value = [datetime]$script:settings.TrendFrom } catch {} } else { $script:dtFrom.Value = (Get-Date).AddDays(-7) }
        if ($script:settings.TrendTo)   { try { $script:dtTo.Value   = [datetime]$script:settings.TrendTo }   catch {} }
        $showCustom = ($curCode -eq 'custom')
        $script:dtFrom.Visible = $showCustom; $script:dtTo.Visible = $showCustom; $lblTo.Visible = $showCustom

        $applyRange = {
            try {
                $sel = $script:cbRange.SelectedItem
                if (-not $sel) { return }
                $code = $script:RangeMap[[string]$sel]
                if (-not $code) { return }
                $script:settings.TrendRange = $code
                $isCustom = ($code -eq 'custom')
                $script:dtFrom.Visible = $isCustom; $script:dtTo.Visible = $isCustom; $script:lblTo.Visible = $isCustom
                if ($isCustom) {
                    $script:settings.TrendFrom = $script:dtFrom.Value.Date.ToString('yyyy-MM-dd')
                    $script:settings.TrendTo   = $script:dtTo.Value.Date.AddDays(1).AddSeconds(-1).ToString('yyyy-MM-dd HH:mm:ss')
                }
                Save-Settings
                Rebuild-Both
                Zoom-Reset   # new time scope -> start unzoomed
            } catch { WLog "WARN range change: $($_.Exception.Message)" }
        }
        $script:cbRange.Add_SelectedIndexChanged($applyRange)
        $script:dtFrom.Add_ValueChanged($applyRange)
        $script:dtTo.Add_ValueChanged($applyRange)

        $cw = $f.ClientSize.Width
        $btnRefresh = New-Object System.Windows.Forms.Button
        $btnRefresh.Text='Refresh'; $btnRefresh.Width=80; $btnRefresh.ForeColor=$fg; $btnRefresh.FlatStyle=[System.Windows.Forms.FlatStyle]::Flat
        $btnRefresh.Anchor=([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
        $btnRefresh.Location=New-Object System.Drawing.Point(($cw-186),6)
        $btnData = New-Object System.Windows.Forms.Button
        $btnData.Text='Open data'; $btnData.Width=92; $btnData.ForeColor=$fg; $btnData.FlatStyle=[System.Windows.Forms.FlatStyle]::Flat
        $btnData.Anchor=([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
        $btnData.Location=New-Object System.Drawing.Point(($cw-98),6)
        $btnRefresh.Add_Click({ Rebuild-Both })
        $btnData.Add_Click({ Start-Process explorer.exe $LogDir })

        $bar.Controls.AddRange(@($lblRange,$script:cbRange,$script:dtFrom,$lblTo,$script:dtTo,$btnRefresh,$btnData))
        $f.Controls.Add($split)   # Fill added first
        $f.Controls.Add($bar)     # Bottom added last
        $script:trendForm = $f; $script:trendChart = $envChart; $script:trendCo2Chart = $co2Chart
        Rebuild-Both
        $f.Add_Shown({ try { $split.SplitterDistance = [int]($split.Height * 0.55) } catch {} })
        $f.Add_FormClosed({ $script:trendForm = $null; $script:trendChart = $null; $script:trendCo2Chart = $null })
        $f.Show(); $f.Activate()
    } catch { WLog "ERROR trends window: $($_.Exception.Message)" }
}
function Rebuild-Both {
    if ($script:trendChart) { Rebuild-ChartData $script:trendChart ("LYWSD02 (clock)   -   " + (Reading-Text)) }
    if ($script:trendCo2Chart) { Rebuild-Co2Data $script:trendCo2Chart 'Aranet4 (air quality)' }
}

# ===========================================================================
#  Dashboard - the main, shippable UI
# ===========================================================================
# Default Room State theme (dark). Build-Theme is defined later in the module;
# this inline copy is the fallback used by the hover popup before the dashboard
# is first opened. Apply-Theme overrides it from the saved setting at startup.
$script:DashTheme = @{
    Mode='dark'
    Canvas=[System.Drawing.Color]::FromArgb(13,14,16); Surface=[System.Drawing.Color]::FromArgb(23,24,27); Sunken=[System.Drawing.Color]::FromArgb(30,31,35)
    TextP=[System.Drawing.Color]::FromArgb(244,244,241); TextS=[System.Drawing.Color]::FromArgb(162,164,172); TextT=[System.Drawing.Color]::FromArgb(110,112,119)
    Hairline=[System.Drawing.Color]::FromArgb(20,255,255,255); Accent=[System.Drawing.Color]::FromArgb(43,182,164); AccentWash=[System.Drawing.Color]::FromArgb(26,43,182,164)
    Caution=[System.Drawing.Color]::FromArgb(214,162,74); Alert=[System.Drawing.Color]::FromArgb(215,122,92)
}
$script:DashTheme.Bg=$script:DashTheme.Canvas; $script:DashTheme.Card=$script:DashTheme.Surface; $script:DashTheme.Card2=$script:DashTheme.Sunken; $script:DashTheme.Border=$script:DashTheme.Hairline
$script:DashTheme.Text=$script:DashTheme.TextP; $script:DashTheme.Muted=$script:DashTheme.TextS; $script:DashTheme.Good=$script:DashTheme.Accent; $script:DashTheme.Warn=$script:DashTheme.Caution; $script:DashTheme.Bad=$script:DashTheme.Alert
$script:DashTheme.Temp=$script:DashTheme.Accent; $script:DashTheme.Hum=$script:DashTheme.Accent; $script:DashTheme.Co2=$script:DashTheme.Accent; $script:DashTheme.Pres=$script:DashTheme.Accent; $script:DashTheme.Batt=$script:DashTheme.Accent
function DashFont([single]$size, [string]$style='Regular', [string]$family='Segoe UI') {
    New-Object System.Drawing.Font($family, $size, [System.Drawing.FontStyle]$style)
}
function Fill-Round($g, $brush, $rect, $r) {
    $x = [int]$rect.X; $y = [int]$rect.Y; $w = [int]$rect.Width; $h = [int]$rect.Height
    $d = [int]$r * 2
    if ($d -gt $w) { $d = $w }; if ($d -gt $h) { $d = $h }
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddArc($x, $y, $d, $d, 180, 90)
    $gp.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
    $gp.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90)
    $gp.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
    $gp.CloseFigure()
    $g.FillPath($brush, $gp)
    $gp.Dispose()
}
# Custom double-buffered controls. Plain WinForms panels don't double-buffer and
# don't redraw on resize, so our owner-drawn cards smear/ghost when the window is
# resized (each layout pass paints over the last). These types fix that.
function Ensure-DashTypes {
    if ('Vulcan.CardPanel' -as [type]) { return }
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System.Windows.Forms;
namespace Vulcan {
  public class CardPanel : Panel {
    public CardPanel() {
      this.DoubleBuffered = true;
      this.SetStyle(ControlStyles.ResizeRedraw, true);
    }
  }
  public class BufferedTable : TableLayoutPanel {
    public BufferedTable() {
      this.DoubleBuffered = true;
      this.SetStyle(ControlStyles.ResizeRedraw, true);
    }
  }
}
"@
}
function New-CardPanel { Ensure-DashTypes; return New-Object Vulcan.CardPanel }
function New-BufferedTable { Ensure-DashTypes; return New-Object Vulcan.BufferedTable }
# A rounded card: a panel that paints a rounded filled rect (anti-aliased).
function New-Card([int]$w, [int]$h, $color) {
    $p = New-CardPanel
    $p.Size = New-Object System.Drawing.Size($w, $h)
    $p.BackColor = $script:DashTheme.Bg
    $p.Tag = @{ Color = $color; Radius = 14 }
    $p.Add_Paint({
        param($s, $e)
        try {
            $c = $this
            $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $br = New-Object System.Drawing.SolidBrush $c.Tag.Color
            $w = [int]$c.Width; $h = [int]$c.Height
            Fill-Round $e.Graphics $br (New-Object System.Drawing.Rectangle(0, 0, ($w - 1), ($h - 1))) $c.Tag.Radius
            $br.Dispose()
        } catch { WLog "paint card: $($_.Exception.Message)" }
    })
    return $p
}
function New-Lbl($text, $font, $fore, $back, [int]$x, [int]$y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = $fore; $l.BackColor = $back
    $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point($x, $y)
    return $l
}
# Draw a pill toggle into a panel given an on/off state.
function Draw-Toggle($g, $panel, [bool]$on) {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($panel.BackColor)
    $pw = [int]$panel.Width; $ph = [int]$panel.Height
    $track = [System.Drawing.Color]::FromArgb(74,78,90)
    if ($on) { $track = $script:DashTheme.Good }
    $br = New-Object System.Drawing.SolidBrush $track
    Fill-Round $g $br (New-Object System.Drawing.Rectangle(0, 0, ($pw - 1), ($ph - 1))) ([int]($ph/2))
    $br.Dispose()
    $kd = $ph - 8
    $kx = 4
    if ($on) { $kx = $pw - $kd - 4 }
    $g.FillEllipse([System.Drawing.Brushes]::White, $kx, 4, $kd, $kd)
}
function Restyle-Seg($btns, $current, $accent) {
    foreach ($b in $btns) {
        if ([int]$b.Tag -eq [int]$current) { $b.BackColor = $accent; $b.ForeColor = [System.Drawing.Color]::White }
        else { $b.BackColor = $script:DashTheme.Card2; $b.ForeColor = $script:DashTheme.Muted }
    }
}
function New-DashButton($text, $accent, $fore=$null) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Font = DashFont 9.5 'Bold'; $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0; $b.BackColor = $accent
    $b.ForeColor = if ($fore) { $fore } else { [System.Drawing.Color]::White }
    $b.Size = New-Object System.Drawing.Size(150, 38); $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}
function New-DashSwitch([int]$x, [int]$y) {
    $t = New-CardPanel
    $t.Size = New-Object System.Drawing.Size(46, 24); $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.BackColor = $script:DashTheme.Bg; $t.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $t
}
# Build a segmented selector into $panel; returns its buttons. $setBlock is the
# (script-scope) click handler attached to each option button.
function New-DashSeg($panel, $label, [int]$x, $options, $accent, $current, $setBlock) {
    $T = $script:DashTheme
    $panel.Controls.Add((New-Lbl $label (DashFont 9) $T.Muted $T.Bg $x 66))
    $bx = $x + 116; $btns = @()
    foreach ($o in $options) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = "$o"; $b.Tag = $o; $b.Font = DashFont 8.5 'Bold'
        $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat; $b.FlatAppearance.BorderSize = 0
        $b.Size = New-Object System.Drawing.Size(40, 28); $b.Location = New-Object System.Drawing.Point($bx, 62)
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand; $b.Add_Click($setBlock)
        $panel.Controls.Add($b); $btns += $b; $bx += 44
    }
    Restyle-Seg $btns $current $accent
    return $btns
}
# Choose X-axis tick spacing + label format from the visible span (in hours), so
# ticks step through years / months / weeks / days / hours / minutes as you zoom.
function Set-XGranularity($ax, [double]$spanH) {
    $IT = [System.Windows.Forms.DataVisualization.Charting.DateTimeIntervalType]
    if     ($spanH -gt 17520) { $ax.IntervalType = $IT::Years;   $ax.Interval = 1; $ax.LabelStyle.Format = 'yyyy' }      # > 2 years
    elseif ($spanH -gt 2880)  { $ax.IntervalType = $IT::Months;  $ax.Interval = 1; $ax.LabelStyle.Format = 'MMM yyyy' }  # > 4 months
    elseif ($spanH -gt 720)   { $ax.IntervalType = $IT::Weeks;   $ax.Interval = 1; $ax.LabelStyle.Format = 'MMM d' }     # > 30 days
    elseif ($spanH -gt 96)    { $ax.IntervalType = $IT::Days;    $ax.Interval = 1; $ax.LabelStyle.Format = 'ddd d' }     # > 4 days
    elseif ($spanH -gt 12)    { $ax.IntervalType = $IT::Hours;   $ax.Interval = 3; $ax.LabelStyle.Format = 'ddd HH:mm' }
    elseif ($spanH -gt 2)     { $ax.IntervalType = $IT::Hours;   $ax.Interval = 1; $ax.LabelStyle.Format = 'HH:mm' }
    elseif ($spanH -gt 0.5)   { $ax.IntervalType = $IT::Minutes; $ax.Interval = 10; $ax.LabelStyle.Format = 'HH:mm' }
    else                      { $ax.IntervalType = $IT::Minutes; $ax.Interval = 1; $ax.LabelStyle.Format = 'HH:mm:ss' }
}
function Update-Granularity($chart) {
    if (-not $chart -or $chart.ChartAreas.Count -eq 0) { return }
    try {
        $ax = $chart.ChartAreas['main'].AxisX
        $sv = $ax.ScaleView
        $r = Get-ChartXRange $chart
        if ($r.Count -lt 2) { return }
        if ($sv.IsZoomed) { $spanH = ($sv.ViewMaximum - $sv.ViewMinimum) * 24 }
        else { $spanH = ($r.Max - $r.Min) * 24 }
        if ($spanH -le 0) { $spanH = 1 }
        Set-XGranularity $ax $spanH
    } catch {}
}

function Update-Dash-Controls {
    if (-not ($script:dash -and $script:dash.Form -and -not $script:dash.Form.IsDisposed)) { return }
    foreach ($t in @($script:dash.ConnTog, $script:dash.AranetTog, $script:dash.LogTog, $script:dash.StartupTog)) { if ($t) { $t.Invalidate() } }
    Restyle-Seg $script:dash.ClockBtns ([int]$script:settings.IntervalMinutes) $script:DashTheme.Temp
    Restyle-Seg $script:dash.AranetBtns ([int]$script:settings.AranetIntervalMinutes) $script:DashTheme.Co2
}

# ======================= ROOM STATE DASHBOARD =======================
# A verdict-led "inference layer": the screen leads with one plain-language
# read of the room, then quiet cards that each answer a human question. Calm
# by default - one accent, semantic colour only as small dots / bands / words.
$script:RsDeg=[char]0x00B0; $script:RsMid=[char]0x00B7; $script:RsNd=[char]0x2013; $script:RsEm=[char]0x2014
$script:RsSub2=[char]0x2082; $script:RsSup3=[char]0x00B3
$script:RsUp=[char]0x2191; $script:RsDn=[char]0x2193; $script:RsRt=[char]0x2192
$script:RsDR=[char]0x2198; $script:RsUR=[char]0x2197; $script:RsBul=[char]0x25CF
$script:RsFonts = $null

function Build-Theme($mode) {
    if ($mode -eq 'light') {
        $t = @{ Mode='light'
          Canvas=[Drawing.Color]::FromArgb(246,246,243); Surface=[Drawing.Color]::FromArgb(255,255,255); Sunken=[Drawing.Color]::FromArgb(240,240,236)
          TextP=[Drawing.Color]::FromArgb(21,22,26); TextS=[Drawing.Color]::FromArgb(92,94,102); TextT=[Drawing.Color]::FromArgb(138,140,148)
          Hairline=[Drawing.Color]::FromArgb(18,20,22,26); Accent=[Drawing.Color]::FromArgb(15,158,142); AccentWash=[Drawing.Color]::FromArgb(20,15,158,142)
          Caution=[Drawing.Color]::FromArgb(193,138,46); Alert=[Drawing.Color]::FromArgb(192,87,59) }
    } else {
        $t = @{ Mode='dark'
          Canvas=[Drawing.Color]::FromArgb(13,14,16); Surface=[Drawing.Color]::FromArgb(23,24,27); Sunken=[Drawing.Color]::FromArgb(30,31,35)
          TextP=[Drawing.Color]::FromArgb(244,244,241); TextS=[Drawing.Color]::FromArgb(162,164,172); TextT=[Drawing.Color]::FromArgb(110,112,119)
          Hairline=[Drawing.Color]::FromArgb(20,255,255,255); Accent=[Drawing.Color]::FromArgb(43,182,164); AccentWash=[Drawing.Color]::FromArgb(26,43,182,164)
          Caution=[Drawing.Color]::FromArgb(214,162,74); Alert=[Drawing.Color]::FromArgb(215,122,92) }
    }
    # legacy aliases so the existing control widgets keep working unchanged
    $t.Bg=$t.Canvas; $t.Card=$t.Surface; $t.Card2=$t.Sunken; $t.Border=$t.Hairline
    $t.Text=$t.TextP; $t.Muted=$t.TextS; $t.Good=$t.Accent; $t.Warn=$t.Caution; $t.Bad=$t.Alert
    $t.Temp=$t.Accent; $t.Hum=$t.Accent; $t.Co2=$t.Accent; $t.Pres=$t.Accent; $t.Batt=$t.Accent
    return $t
}
function Apply-Theme($mode) { $script:DashTheme = Build-Theme $mode }
function Ensure-RsFonts {
    if ($script:RsFonts) { return }
    $script:RsFonts = @{
        Verdict = New-Object Drawing.Font('Segoe UI Semibold', 24)
        Title   = New-Object Drawing.Font('Segoe UI Semibold', 12)
        Value   = New-Object Drawing.Font('Segoe UI Semibold', 21)
        Big     = New-Object Drawing.Font('Segoe UI Semibold', 27)
        Unit    = New-Object Drawing.Font('Segoe UI', 9.5)
        Body    = New-Object Drawing.Font('Segoe UI', 9.5)
        Caption = New-Object Drawing.Font('Segoe UI', 8)
        Arrow   = New-Object Drawing.Font('Segoe UI Semibold', 17)
    }
}
# ---- draw primitives ----
function Rs-Fill($g, $color, [int]$x, [int]$y, [int]$w, [int]$h, [int]$r) {
    if ($w -le 0 -or $h -le 0) { return }
    $gp = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $r * 2; if ($d -gt $w) { $d = $w }; if ($d -gt $h) { $d = $h }; if ($d -lt 1) { $d = 1 }
    $gp.AddArc($x, $y, $d, $d, 180, 90); $gp.AddArc($x+$w-$d, $y, $d, $d, 270, 90)
    $gp.AddArc($x+$w-$d, $y+$h-$d, $d, $d, 0, 90); $gp.AddArc($x, $y+$h-$d, $d, $d, 90, 90); $gp.CloseFigure()
    $b = New-Object Drawing.SolidBrush $color; $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
}
function Rs-Stroke($g, $color, [int]$x, [int]$y, [int]$w, [int]$h, [int]$r) {
    if ($w -le 0 -or $h -le 0) { return }
    $gp = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $r * 2; if ($d -lt 1) { $d = 1 }
    $gp.AddArc($x, $y, $d, $d, 180, 90); $gp.AddArc($x+$w-$d, $y, $d, $d, 270, 90)
    $gp.AddArc($x+$w-$d, $y+$h-$d, $d, $d, 0, 90); $gp.AddArc($x, $y+$h-$d, $d, $d, 90, 90); $gp.CloseFigure()
    $pen = New-Object Drawing.Pen($color, 1); $g.DrawPath($pen, $gp); $pen.Dispose(); $gp.Dispose()
}
function Rs-Txt($g, $text, $font, $color, $x, $y) {
    $b = New-Object Drawing.SolidBrush $color; $g.DrawString([string]$text, $font, $b, [single]$x, [single]$y); $b.Dispose()
}
function Rs-TxtR($g, $text, $font, $color, $x, $y, $w) {
    $sf = New-Object Drawing.StringFormat; $sf.Alignment = [Drawing.StringAlignment]::Far
    $b = New-Object Drawing.SolidBrush $color
    $g.DrawString([string]$text, $font, $b, (New-Object Drawing.RectangleF($x, $y, $w, 40)), $sf); $b.Dispose()
}
function Rs-Meas($g, $text, $font) { $g.MeasureString([string]$text, $font) }
function Rs-CardBg($g, $p, $T) {
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear($T.Canvas)
    Rs-Fill $g $T.Surface 0 0 ($p.Width-1) ($p.Height-1) 18
    Rs-Stroke $g $T.Hairline 0 0 ($p.Width-1) ($p.Height-1) 18
}
function Rs-Spark($g, $pts, [int]$x, [int]$y, [int]$w, [int]$h, $T) {
    if (-not $pts -or @($pts).Count -lt 2) { return }
    $pts = @($pts); $mn = ($pts | Measure-Object -Minimum).Minimum; $mx = ($pts | Measure-Object -Maximum).Maximum
    $rng = $mx - $mn; if ($rng -le 0) { $rng = 1 }
    $n = $pts.Count; $dx = $w / [double]($n-1)
    $poly = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    for ($i=0; $i -lt $n; $i++) { $poly.Add((New-Object Drawing.PointF([single]($x+$i*$dx), [single]($y+$h-(([double]$pts[$i]-$mn)/$rng)*$h)))) }
    $fp = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'; $fp.AddRange($poly)
    $fp.Add((New-Object Drawing.PointF([single]($x+$w), [single]($y+$h)))); $fp.Add((New-Object Drawing.PointF([single]$x, [single]($y+$h))))
    $fb = New-Object Drawing.SolidBrush $T.AccentWash; $g.FillPolygon($fb, $fp.ToArray()); $fb.Dispose()
    $pen = New-Object Drawing.Pen($T.Accent, 1.5); $pen.LineJoin=[Drawing.Drawing2D.LineJoin]::Round; $g.DrawLines($pen, $poly.ToArray()); $pen.Dispose()
}
function Rs-Band($g, [int]$x, [int]$y, [int]$w, [int]$h, $min, $max, $zones, $value, $T) {
    Rs-Fill $g $T.Sunken $x $y $w $h ([int]($h/2))
    $span = $max - $min; if ($span -le 0) { $span = 1 }
    foreach ($z in $zones) {
        $zx = $x + (([double]$z.Lo-$min)/$span)*$w; $zw = (([double]$z.Hi-[double]$z.Lo)/$span)*$w
        if ($zw -lt 1) { continue }
        $tint = [Drawing.Color]::FromArgb(40, $z.Col.R, $z.Col.G, $z.Col.B)
        Rs-Fill $g $tint ([int]$zx) $y ([int]$zw) $h ([int]($h/2))
    }
    if ($null -ne $value) {
        $v = [double]$value; if ($v -lt $min) { $v = $min }; if ($v -gt $max) { $v = $max }
        $mx = $x + (($v-$min)/$span)*$w
        $mb = New-Object Drawing.SolidBrush $T.TextP
        $g.FillRectangle($mb, [single]($mx-1.5), [single]($y-3), [single]3, [single]($h+6)); $mb.Dispose()
    }
}
function Rs-Person($g, [int]$cx, [int]$top, [int]$size, $color) {
    $pen = New-Object Drawing.Pen($color, 1.5); $pen.LineJoin=[Drawing.Drawing2D.LineJoin]::Round
    $hd = [int]($size*0.34)
    $g.DrawEllipse($pen, ($cx-$hd/2), $top, $hd, $hd)
    $bx = $cx-$size/2+$size*0.12; $bw = $size-$size*0.24; $by = $top+$hd+2; $bh = $size-$hd-2
    $g.DrawArc($pen, [single]$bx, [single]$by, [single]$bw, [single]($bh*2), 180, 180); $pen.Dispose()
}
function Rs-Icon($g, $name, [int]$x, [int]$y, [int]$s, $color) {
    $pen = New-Object Drawing.Pen($color, 1.5); $pen.StartCap='Round'; $pen.EndCap='Round'; $pen.LineJoin='Round'
    switch ($name) {
        'temp' { $g.DrawArc($pen,($x+$s*0.28),$y,($s*0.44),($s*0.44),0,360); $g.DrawLine($pen,($x+$s*0.5),($y+$s*0.18),($x+$s*0.5),($y+$s*0.62)) }
        'drop' { $g.DrawArc($pen,($x+$s*0.2),($y+$s*0.3),($s*0.6),($s*0.6),30,300); $g.DrawLine($pen,($x+$s*0.5),($y+$s*0.05),($x+$s*0.22),($y+$s*0.45)); $g.DrawLine($pen,($x+$s*0.5),($y+$s*0.05),($x+$s*0.78),($y+$s*0.45)) }
        'air'  { $g.DrawArc($pen,($x+$s*0.1),($y+$s*0.25),($s*0.5),($s*0.3),90,260); $g.DrawLine($pen,($x+$s*0.1),($y+$s*0.4),($x+$s*0.75),($y+$s*0.4)) }
        'gauge'{ $g.DrawArc($pen,($x+$s*0.1),($y+$s*0.2),($s*0.8),($s*0.8),180,180); $g.DrawLine($pen,($x+$s*0.5),($y+$s*0.6),($x+$s*0.7),($y+$s*0.35)) }
    }
    $pen.Dispose()
}
# ---- inference helpers ----
function Rs-AbsHum([double]$t, [double]$rh) { [Math]::Round((6.112*[Math]::Exp((17.67*$t)/($t+243.5))*$rh*2.1674)/(273.15+$t), 1) }
function Rs-Rebreathed([double]$co2) { $r = ($co2-420)/(40000-420)*100; if ($r -lt 0) { $r = 0 }; [Math]::Round($r,1) }
function Rs-Recent($series, [double]$hours) {
    $cut = (Get-Date).AddHours(-$hours); $out = New-Object System.Collections.Generic.List[object]
    foreach ($x in $series) { if ($x.T -ge $cut) { $out.Add($x) } }
    return $out
}
function Rs-Down($arr, [int]$n) {
    $arr = @($arr); if ($arr.Count -le $n) { return $arr }
    $out = @(); $step = $arr.Count/[double]$n
    for ($i=0; $i -lt $n; $i++) { $out += $arr[[int]($i*$step)] }
    $out += $arr[$arr.Count-1]; return $out
}
function Rs-Delta($series, $prop, $cur, [double]$hours) {
    if ($null -eq $cur) { return 0 }
    $s = Rs-Recent $series $hours; if ($s.Count -lt 1) { return 0 }
    return ($cur - [double]$s[0].$prop)
}
# Headcount from a CO2 mass balance:  generation (n people) = ventilation removal
#   n = ACH * V * (C - C_outdoor) / (1e6 * G)
# where V = room volume (m3), ACH = air changes/hour (estimated from CO2 decay,
# falling back to a typical value), G = per-person CO2 output (~0.0186 m3/h at
# rest), C_outdoor ~ 420 ppm. Room volume comes from the RoomVolume setting -
# without it people and volume can't be separated from a single CO2 reading.
# The raw count multiplies three uncertain inputs (estimated ACH, your room
# volume, an assumed per-person CO2 output that varies ~2-3x), so we never claim
# an exact integer - we report a qualitative band (empty / 1-2 / several / crowd).
function Rs-Occupancy($a, $ach=$null) {
    if (-not $a) { return @{ Band='waiting for sensor'; Level=$null; Night=$false; Volume=$null } }
    $co2 = [double]$a.Co2
    $cout = 420.0
    $s = Rs-Recent (Get-AranetSeries) 0.5; $slope = 0.0
    if ($s.Count -ge 2) { $dt = ($s[$s.Count-1].T - $s[0].T).TotalHours; if ($dt -gt 0) { $slope = ([double]$s[$s.Count-1].Co2 - [double]$s[0].Co2)/$dt } }
    $V = [double]$script:settings.RoomVolume; if ($V -le 0) { $V = 29 }
    if ($null -eq $ach -or $ach -le 0) { $ach = 2.0 }   # assume a typical room when no decay seen
    $G = 18600.0   # ppm-m3 per person-hour  (0.0186 m3/h CO2 * 1e6)
    if ($co2 -lt ($cout + 60) -and $slope -lt 40) {
        $n = 0
    } else {
        $nSteady = ($ach * $V * ($co2 - $cout)) / $G          # plateau case
        $nRise   = ($slope * $V) / $G                          # freshly occupied, before ventilation catches up
        $n = [Math]::Max($nSteady, $nRise * 0.6)
        if ($n -lt 0.5 -and $co2 -gt ($cout + 80)) { $n = 1 }
    }
    if     ($n -lt 0.5) { $band = 'Empty';                          $lvl = 0 }
    elseif ($n -lt 2.5) { $band = '1' + $script:RsNd + '2 people';  $lvl = 1 }
    elseif ($n -lt 5.0) { $band = 'several people';                 $lvl = 2 }
    else                { $band = 'a crowd';                        $lvl = 3 }
    $h = (Get-Date).Hour
    return @{ Band=$band; Level=$lvl; Night=($h -ge 23 -or $h -lt 6); Volume=[int]$V }
}
# Coarse ventilation band from the (uncertain) ACH estimate, home-appropriate.
function Rs-AchBand($ach) {
    if ($null -eq $ach)   { return @{ Band='estimating'; Level=-1 } }
    if ($ach -lt 0.4)     { return @{ Band='Poor';     Level=0 } }
    if ($ach -lt 1.2)     { return @{ Band='Moderate'; Level=1 } }
    if ($ach -lt 4.0)     { return @{ Band='Good';     Level=2 } }
    return @{ Band='Breezy'; Level=3 }
}
# Air changes/hour from the CO2 mass balance, generalised:
#   dC/dt = G' - ACH*(C - C_out)
# A least-squares line of dC/dt against (C - C_out) over a recent window gives
# ACH = -slope (and the generation term G' = intercept) - so we measure airflow
# from ANY varying CO2 (decaying, building toward a plateau, or mixed), not only
# from a room emptying. Flat CO2 has no spread to fit (under-determined), so we
# persist the last good value and keep showing it. A new fit that diverges from
# the persisted one means ventilation changed (a window opened/closed).
function Rs-ACH($a) {
    $cout = 420.0
    $s = Rs-Recent (Get-AranetSeries) 2.0
    $measured = $null
    if ($s.Count -ge 6) {
        # light 3-point smoothing to blunt sensor noise before differencing
        $c = New-Object 'System.Collections.Generic.List[double]'
        for ($i=0; $i -lt $s.Count; $i++) {
            $lo=[Math]::Max(0,$i-1); $hi=[Math]::Min($s.Count-1,$i+1); $sum=0.0; $cnt=0
            for ($j=$lo; $j -le $hi; $j++) { $sum += [double]$s[$j].Co2; $cnt++ }
            $c.Add($sum/$cnt)
        }
        $xs=New-Object 'System.Collections.Generic.List[double]'; $ys=New-Object 'System.Collections.Generic.List[double]'
        for ($i=0; $i -lt $s.Count-1; $i++) {
            $dtH = ($s[$i+1].T - $s[$i].T).TotalHours
            if ($dtH -lt 0.04 -or $dtH -gt 0.34) { continue }   # skip dup samples and data gaps
            $xs.Add(((($c[$i]+$c[$i+1])/2.0) - $cout)); $ys.Add((($c[$i+1]-$c[$i])/$dtH))
        }
        $nn = $xs.Count
        if ($nn -ge 5) {
            $xmin=($xs|Measure-Object -Minimum).Minimum; $xmax=($xs|Measure-Object -Maximum).Maximum
            if (($xmax-$xmin) -ge 70) {   # need CO2 to vary to separate ACH from generation
                $mx=($xs|Measure-Object -Average).Average; $my=($ys|Measure-Object -Average).Average
                $sxx=0.0; $sxy=0.0
                for ($k=0;$k -lt $nn;$k++){ $dx=$xs[$k]-$mx; $sxx+=$dx*$dx; $sxy+=$dx*($ys[$k]-$my) }
                if ($sxx -gt 0) {
                    $b=$sxy/$sxx; $aint=$my-$b*$mx; $sse=0.0; $sst=0.0
                    for ($k=0;$k -lt $nn;$k++){ $p=$aint+$b*$xs[$k]; $sse+=[Math]::Pow($ys[$k]-$p,2); $sst+=[Math]::Pow($ys[$k]-$my,2) }
                    $r2 = if ($sst -gt 0) { 1-$sse/$sst } else { 0 }
                    $ach = -$b
                    if ($ach -gt 0.1 -and $ach -lt 15 -and $r2 -ge 0.45) { $measured = $ach }
                }
            }
        }
    }
    if ($null -ne $measured) {
        $m = [Math]::Max(0.1, [Math]::Min(15, $measured))
        if ($null -ne $script:rsLastAch -and ([Math]::Abs($m-$script:rsLastAch)/[Math]::Max(0.4,$script:rsLastAch)) -gt 0.6) { $script:rsAchChangedAt = (Get-Date) }
        $script:rsLastAch = $m; $script:rsLastAchAt = (Get-Date)
    }
    $ach = $script:rsLastAch
    if ($null -ne $script:rsLastAchAt -and ((Get-Date)-$script:rsLastAchAt).TotalHours -gt 6) { $ach = $null }   # too old to trust
    $changed = ($null -ne $script:rsAchChangedAt -and ((Get-Date)-$script:rsAchChangedAt).TotalMinutes -le 20)
    $ageMin = if ($null -ne $script:rsLastAchAt) { ((Get-Date)-$script:rsLastAchAt).TotalMinutes } else { $null }
    $clear = 0
    if ($a -and $null -ne $ach) { $cnow=[double]$a.Co2; if ($cnow -gt $cout+50) { $clear = [int]([Math]::Log(($cnow-$cout)/50.0)/$ach*60) } }
    return @{ Ach=$(if ($null -ne $ach) { [Math]::Round($ach,1) } else { $null }); ClearMin=$clear; Fresh=($null -ne $measured); Changed=$changed; AgeMin=$ageMin }
}
function Rs-Pressure($a) {
    if (-not $a) { return @{ Trend='steady'; Rate=0 } }
    $s = Rs-Recent (Get-AranetSeries) 3.0; if ($s.Count -lt 2) { return @{ Trend='steady'; Rate=0 } }
    $rate = [double]$a.Pres - [double]$s[0].Pres; $trend = 'steady'
    if ($rate -le -0.6) { $trend = 'falling' } elseif ($rate -ge 0.6) { $trend = 'rising' }
    return @{ Trend=$trend; Rate=[Math]::Round([Math]::Abs($rate),1) }
}
function Rs-Verdict($co2, $temp, $rh, $occ) {
    if ($null -eq $co2 -and $null -eq $temp) { return @{ Line='Waiting for sensors.'; State='good' } }
    $airState='good'; $airWord='Fresh'
    if ($null -ne $co2) {
        if ($co2 -lt 800) { $airWord='Fresh'; $airState='good' }
        elseif ($co2 -lt 1200) { $airWord='Air is fine'; $airState='good' }
        elseif ($co2 -lt 2000) { $airWord='Air getting stuffy'; $airState='caution' }
        else { $airWord='Air is poor'; $airState='alert' }
    }
    $cWord='comfortable'; $cState='good'
    if ($null -ne $temp -and $null -ne $rh) {
        if ($temp -gt 26) { $cWord='a little warm'; $cState='caution' }
        elseif ($temp -lt 17) { $cWord='a little cool'; $cState='caution' }
        elseif ($rh -gt 65) { $cWord='a little humid'; $cState='caution' }
        elseif ($rh -lt 30) { $cWord='a little dry'; $cState='caution' }
    }
    $state='good'; if ($airState -eq 'caution' -or $cState -eq 'caution') { $state='caution' }; if ($airState -eq 'alert') { $state='alert' }
    $op=''
    if ($occ.Level -eq 0) { $op='Empty' } elseif ($occ.Level -eq 1) { $op='Likely one or two people' }
    elseif ($occ.Level -eq 2) { $op='Several people' } elseif ($occ.Level -eq 3) { $op='A crowd' }
    $line = "$airWord and $cWord."; if ($op) { $line += " $op." }
    return @{ Line=$line; State=$state }
}
function Rs-StateColor($state, $T) { if ($state -eq 'alert') { return $T.Alert }; if ($state -eq 'caution') { return $T.Caution }; return $T.Accent }

# ---- motion + state infrastructure ----
# Honour the OS "show animations" setting (and an explicit override). When true,
# tweens and the breathing orb are disabled and changes apply instantly.
function Rs-ReducedMotion {
    if ($null -ne $script:settings.ReducedMotion) { return [bool]$script:settings.ReducedMotion }
    try { return ([string](Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name MinAnimate -ErrorAction Stop).MinAnimate -eq '0') } catch { return $false }
}
$script:RsTypo = $null
function Rs-Typo {
    if (-not $script:RsTypo) { $script:RsTypo = [Drawing.StringFormat]::GenericTypographic.Clone(); $script:RsTypo.FormatFlags = $script:RsTypo.FormatFlags -bor [Drawing.StringFormatFlags]::MeasureTrailingSpaces }
    return $script:RsTypo
}
# Draw a number with a fixed per-digit cell so figures are tabular (no jitter as
# values tween, clean vertical scanning). Returns the drawn width.
function Rs-Num($g, $text, $font, $color, [single]$x, [single]$y) {
    $fmt = Rs-Typo; $text = [string]$text; $o = New-Object Drawing.PointF(0,0)
    $cell = $g.MeasureString('0', $font, $o, $fmt).Width
    $b = New-Object Drawing.SolidBrush $color; $cx = $x
    foreach ($ch in $text.ToCharArray()) {
        $s = [string]$ch; $w = $g.MeasureString($s, $font, $o, $fmt).Width
        if ($ch -ge '0' -and $ch -le '9') { $g.DrawString($s, $font, $b, [single]($cx + ($cell-$w)/2), [single]$y, $fmt); $cx += $cell }
        else { $g.DrawString($s, $font, $b, [single]$cx, [single]$y, $fmt); $cx += $w }
    }
    $b.Dispose(); return ($cx - $x)
}
# low-contrast skeleton block for the Loading state
function Rs-Skeleton($g, $T, [int]$x, [int]$y, [int]$w, [int]$h) {
    $c = if ($T.Mode -eq 'light') { [Drawing.Color]::FromArgb(18,20,22,26) } else { [Drawing.Color]::FromArgb(26,255,255,255) }
    Rs-Fill $g $c $x $y $w $h 6
}
# tween state: target values + currently-displayed (eased) values
$script:rsDisp = @{}; $script:rsTarget = @{}
$script:rsVAlpha = 1.0; $script:rsPrevVerdict = ''; $script:rsSettle = @{}
$script:rsLastAch = $null; $script:rsLastAchAt = $null; $script:rsAchChangedAt = $null   # persisted ventilation estimate
function Rs-SetTargets($map) {
    $reduced = Rs-ReducedMotion
    foreach ($k in @($map.Keys)) {
        $script:rsTarget[$k] = $map[$k]
        if ($reduced -or -not $script:rsDisp.ContainsKey($k) -or $null -eq $map[$k] -or $null -eq $script:rsDisp[$k]) { $script:rsDisp[$k] = $map[$k] }
    }
}
function Rs-Disp($k) { if ($script:rsDisp.ContainsKey($k) -and $null -ne $script:rsDisp[$k]) { return $script:rsDisp[$k] }; return $script:rsTarget[$k] }
function Rs-AnimStep {
    $moving = $false
    foreach ($k in @($script:rsTarget.Keys)) {
        $t = $script:rsTarget[$k]
        if ($null -eq $t) { $script:rsDisp[$k] = $null; continue }
        $d = $script:rsDisp[$k]
        if ($null -eq $d) { $script:rsDisp[$k] = $t; continue }
        $diff = $t - $d
        if ([Math]::Abs($diff) -lt 0.05) { $script:rsDisp[$k] = $t } else { $script:rsDisp[$k] = $d + $diff * 0.22; $moving = $true }
    }
    return $moving
}
# Format a tweened metric for display from its eased value.
function Rs-Fmt($key, $fmt) {
    $v = Rs-Disp $key; if ($null -eq $v) { return $script:RsEm }
    return ($fmt -f [double]$v)
}

# ---- component painters (read $script:rs) ----
function Rs-PaintVerdict($g, $p) {
    $T = $script:DashTheme; Ensure-RsFonts
    $g.SmoothingMode='AntiAlias'; $g.TextRenderingHint='ClearTypeGridFit'; $g.Clear($T.Canvas)
    if (-not $script:rs) { Rs-Skeleton $g $T 26 14 380 26; return }
    $oc = Rs-StateColor $script:rs.State $T
    $ph = $script:OrbPhase; $alpha = [int](115+140*$ph); $od = 13+1.0*$ph
    $ob = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb($alpha,$oc.R,$oc.G,$oc.B))
    $g.FillEllipse($ob, [single]2, [single]15, [single]$od, [single]$od); $ob.Dispose()
    # verdict word cross-fade: previous line fades out as the new one fades in
    $fa = $script:rsVAlpha; if ($fa -lt 0) { $fa = 0 }; if ($fa -gt 1) { $fa = 1 }
    if ($fa -lt 1 -and $script:rsPrevVerdict) {
        $pc = [Drawing.Color]::FromArgb([int](255*(1-$fa)), $T.TextP.R, $T.TextP.G, $T.TextP.B)
        Rs-Txt $g $script:rsPrevVerdict $script:RsFonts.Verdict $pc 26 7
    }
    $ncol = [Drawing.Color]::FromArgb([int](255*$fa), $T.TextP.R, $T.TextP.G, $T.TextP.B)
    Rs-Txt $g $script:rs.Verdict $script:RsFonts.Verdict $ncol 26 7
    $u = $script:rs.Updated.ToString('HH:mm'); Rs-Txt $g "updated $u  $($script:RsMid)  living room" $script:RsFonts.Caption $T.TextT 28 52
}
function Rs-PaintVital($g, $p) {
    $T = $script:DashTheme; Ensure-RsFonts; Rs-CardBg $g $p $T
    $pad = 16
    if (-not $script:rs) { Rs-Skeleton $g $T $pad ($pad+28) 84 26; return }
    $d = $script:rs.V[$p.Tag.Key]; if (-not $d) { return }
    Rs-Icon $g $d.Icon $pad ($pad+1) 18 $T.TextT
    Rs-Txt $g $d.Label $script:RsFonts.Body $T.TextS ($pad+26) ($pad+1)
    if ($null -eq $d.Raw) {
        Rs-Txt $g $script:RsEm $script:RsFonts.Value $T.TextT $pad ($pad+26)
        Rs-Txt $g 'waiting for sensor' $script:RsFonts.Caption $T.TextT $pad ($pad+70)
        return
    }
    $vcol = if ($d.Stale) { $T.TextT } else { $T.TextP }
    $vtxt = Rs-Fmt $d.DispKey $d.Fmt
    $vw = Rs-Num $g $vtxt $script:RsFonts.Value $vcol $pad ($pad+26)
    Rs-Txt $g $d.Unit $script:RsFonts.Unit $T.TextT ($pad+$vw+3) ($pad+44)
    if ($d.Stale) {
        Rs-Txt $g $d.AgeText $script:RsFonts.Caption $T.TextT $pad ($pad+70)
    } elseif ($null -ne $d.Delta) {
        $chev = $script:RsRt; if ($d.Delta -gt 0) { $chev = $script:RsUp } elseif ($d.Delta -lt 0) { $chev = $script:RsDn }
        $dcol = if ($d.DeltaHot) { $T.Caution } else { $T.TextT }
        Rs-Txt $g ("$chev " + [Math]::Abs($d.Delta) + $d.DUnit) $script:RsFonts.Caption $dcol $pad ($pad+70)
    }
    $sw = [int]($p.Width-$pad*2-58); if ($sw -lt 36) { $sw = 36 }
    if ($d.Spark -and -not $d.Stale) { Rs-Spark $g $d.Spark ($p.Width-$pad-$sw) ($p.Height-$pad-22) $sw 22 $T }
}
function Rs-PaintAirQuality($g, $p) {
    $T = $script:DashTheme; Ensure-RsFonts; Rs-CardBg $g $p $T
    if (-not $script:rs) { Rs-Skeleton $g $T 22 46 150 34; return }
    # settle bump: ripple this card briefly when the air state changes
    $sp = 0.0; if ($script:rsSettle.ContainsKey('aq')) { $sp = $script:rsSettle['aq'] }
    $gs = $g.Save()
    if ($sp -gt 0.01) { $sc = 1 + 0.035*[Math]::Sin($sp*[Math]::PI); $cx = $p.Width/2.0; $cy = $p.Height/2.0; $g.TranslateTransform($cx,$cy); $g.ScaleTransform($sc,$sc); $g.TranslateTransform(-$cx,-$cy) }
    $pad = 22
    Rs-Txt $g 'Air quality' $script:RsFonts.Title $T.TextP $pad ($pad-2)
    $co2 = $script:rs.Co2
    if ($null -eq $co2) {
        Rs-Txt $g $script:RsEm $script:RsFonts.Big $T.TextT $pad ($pad+22)
        Rs-Txt $g 'waiting for sensor' $script:RsFonts.Body $T.TextT $pad ($pad+96)
        $g.Restore($gs); return
    }
    $vcol = if ($script:rs.Co2Stale) { $T.TextT } else { $T.TextP }
    $vtxt = Rs-Fmt 'co2' '{0:0}'
    $vw = Rs-Num $g $vtxt $script:RsFonts.Big $vcol $pad ($pad+22)
    Rs-Txt $g ('ppm CO'+$script:RsSub2) $script:RsFonts.Unit $T.TextT ($pad+$vw+4) ($pad+48)
    $zones = @(@{Lo=400;Hi=800;Col=$T.Accent}, @{Lo=800;Hi=1200;Col=$T.TextT}, @{Lo=1200;Hi=2000;Col=$T.Caution}, @{Lo=2000;Hi=2200;Col=$T.Alert})
    $by = $pad+80
    Rs-Band $g $pad $by ($p.Width-$pad*2) 14 400 2200 $zones $co2 $T
    Rs-Txt $g 'fresh' $script:RsFonts.Caption $T.TextT $pad ($by+20)
    Rs-TxtR $g 'poor' $script:RsFonts.Caption $T.TextT $pad ($by+20) ($p.Width-$pad*2)
    if ($script:rs.Co2Stale) {
        Rs-Txt $g "last reading $($script:rs.Co2Age) $($script:RsMid) may be stale" $script:RsFonts.Body $T.TextT $pad ($by+42)
    } else {
        $rb = $script:rs.Rebreathed
        $note = if ($co2 -lt 1000) { 'Decision-making likely sharp.' } elseif ($co2 -lt 1500) { 'Focus may start to dip.' } else { 'Open a window - focus suffers here.' }
        Rs-Txt $g "~$rb% rebreathed air. $note" $script:RsFonts.Body $T.TextS $pad ($by+42)
    }
    $g.Restore($gs)
}
function Rs-PaintOccupancy($g, $p) {
    $T = $script:DashTheme; Ensure-RsFonts; Rs-CardBg $g $p $T
    if (-not $script:rs) { Rs-Skeleton $g $T 20 46 120 26; return }
    $pad = 20; $occ = $script:rs.Occ
    Rs-Txt $g 'Occupancy' $script:RsFonts.Title $T.TextP $pad ($pad-2)
    if ($null -eq $occ.Level) {
        Rs-Txt $g 'waiting for sensor' $script:RsFonts.Body $T.TextT $pad ($pad+30)
        return
    }
    # qualitative band as the headline (no exact integer is claimed)
    Rs-Txt $g $occ.Band $script:RsFonts.Value $T.TextP $pad ($pad+24)
    # a few representative person glyphs (faint, supportive of the band)
    $ng = @(0, 2, 3, 4)[$occ.Level]
    for ($i=0; $i -lt $ng; $i++) { Rs-Person $g ($pad+10+$i*22) ($pad+62) 24 $T.TextS }
    if ($occ.Night -and $occ.Level -ge 1) { Rs-Txt $g 'probably asleep' $script:RsFonts.Body $T.TextS $pad ($pad+96) }
    $cap = "inferred from CO$($script:RsSub2) $($script:RsMid) $($occ.Volume) m$($script:RsSup3) room $($script:RsMid) no camera"
    Rs-Txt $g $cap $script:RsFonts.Caption $T.TextT $pad ($p.Height-$pad-14)
}
function Rs-PaintVentilation($g, $p) {
    $T = $script:DashTheme; Ensure-RsFonts; Rs-CardBg $g $p $T
    if (-not $script:rs) { return }
    $pad = 20; $ach = $script:rs.Ach; $band = $script:rs.AchBand; $lvl = [int]$script:rs.AchLevel
    Rs-Txt $g 'Ventilation' $script:RsFonts.Title $T.TextP $pad ($pad-2)
    $bcol = if ($lvl -lt 0) { $T.TextT } else { $T.TextP }
    Rs-Txt $g $band $script:RsFonts.Value $bcol $pad ($pad+24)
    if ($lvl -ge 0) {
        $bw = (Rs-Meas $g $band $script:RsFonts.Value).Width
        Rs-Txt $g 'airflow' $script:RsFonts.Unit $T.TextT ($pad+$bw+6) ($pad+42)
    }
    # 4-segment scale (poor -> breezy), filled up to the current band
    $by = $pad+60; $tw = $p.Width-$pad*2; $seg = ($tw-3*6)/4.0
    for ($i=0; $i -lt 4; $i++) {
        $col = if ($lvl -ge 0 -and $i -le $lvl) { $T.Accent } else { $T.Sunken }
        Rs-Fill $g $col ([int]($pad+$i*($seg+6))) $by ([int]$seg) 6 3
    }
    if ($null -ne $ach) {
        # fresh fit -> show time-to-clear; remembered value -> show its age, honestly
        if ($script:rs.AchFresh) {
            $clr = if ($null -ne $script:rs.ClearMin -and $script:rs.ClearMin -gt 0) { "  $($script:RsMid)  ~$($script:rs.ClearMin) min to clear" } else { '' }
            $sec = "$([char]0x2248)$('{0:0.0}' -f $ach) air changes/hour$clr"
        } else {
            $ageTxt = if ($null -ne $script:rs.AchAge) { Rs-AgeText ([double]$script:rs.AchAge) } else { 'earlier' }
            $sec = "$([char]0x2248)$('{0:0.0}' -f $ach) ACH  $($script:RsMid)  measured $ageTxt"
        }
        Rs-Txt $g $sec $script:RsFonts.Body $T.TextS $pad ($by+16)
    } else {
        Rs-Txt $g 'needs CO2 to vary (in or out) to estimate' $script:RsFonts.Body $T.TextT $pad ($by+16)
    }
    $cap = 'estimated from CO2 dynamics'; $ccol = $T.TextT
    if ($script:rs.AchChanged) { $cap = 'ventilation just changed'; $ccol = $T.Caution }
    Rs-Txt $g $cap $script:RsFonts.Caption $ccol $pad ($p.Height-$pad-14)
}
function Rs-PaintComfort($g, $p) {
    $T = $script:DashTheme; Ensure-RsFonts; Rs-CardBg $g $p $T
    if (-not $script:rs) { return }
    $pad = 20
    Rs-Txt $g 'Comfort' $script:RsFonts.Title $T.TextP $pad ($pad-2)
    if ($null -ne $script:rs.Dew) { $dw = Rs-Num $g (Rs-Fmt 'dew' '{0:0.0}') $script:RsFonts.Value $T.TextP $pad ($pad+24) }
    else { $dw = Rs-Num $g $script:RsEm $script:RsFonts.Value $T.TextT $pad ($pad+24) }
    Rs-Txt $g ($script:RsDeg+'C dew point') $script:RsFonts.Unit $T.TextT ($pad+$dw+4) ($pad+42)
    $by = $pad+62; $zones = @(@{Lo=40;Hi=60;Col=$T.Accent})
    Rs-Band $g $pad $by ($p.Width-$pad*2) 12 0 100 $zones $script:rs.Hum $T
    if ($null -ne $script:rs.Hum -and $null -ne $script:rs.Abs) {
        Rs-Txt $g ("$([int]$script:rs.Hum)% RH  $($script:RsMid)  $($script:rs.Abs) g/m"+$script:RsSup3+' absolute') $script:RsFonts.Body $T.TextS $pad ($by+18)
    }
    Rs-Txt $g ('comfort band 40'+$script:RsNd+'60% RH') $script:RsFonts.Caption $T.TextT $pad ($p.Height-$pad-14)
}
function Rs-PaintOutside($g, $p) {
    $T = $script:DashTheme; Ensure-RsFonts; Rs-CardBg $g $p $T
    if (-not $script:rs) { return }
    $pad = 20
    Rs-Txt $g 'Outside' $script:RsFonts.Title $T.TextP $pad ($pad-2)
    $tr = $script:rs.PresTrend; $arrow = $script:RsRt; if ($tr -eq 'falling') { $arrow = $script:RsDR } elseif ($tr -eq 'rising') { $arrow = $script:RsUR }
    Rs-Txt $g $arrow $script:RsFonts.Arrow $T.TextP $pad ($pad+22)
    Rs-Txt $g "$tr, $($script:rs.PresRate) hPa / 3h" $script:RsFonts.Body $T.TextS ($pad+34) ($pad+30)
    $nc = if ($tr -eq 'falling') { 'Weather likely turning unsettled.' } elseif ($tr -eq 'rising') { 'Clearing and settling.' } else { 'Steady, little change expected.' }
    Rs-Txt $g $nc $script:RsFonts.Body $T.TextS $pad ($pad+62)
    Rs-Txt $g ("inferred from pressure  $($script:RsMid)  no outdoor sensor") $script:RsFonts.Caption $T.TextT $pad ($p.Height-$pad-14)
}
function Rs-PaintTimeline($g, $p) {
    $T = $script:DashTheme; Ensure-RsFonts; Rs-CardBg $g $p $T
    if (-not $script:rs) { Rs-Skeleton $g $T 20 42 220 16; return }
    $pad = 20
    Rs-Txt $g 'Today' $script:RsFonts.Title $T.TextP $pad ($pad-2)
    Rs-Txt $g ('CO'+$script:RsSub2+' and occupancy across the day') $script:RsFonts.Caption $T.TextT ($pad+58) ($pad+3)
    # legend (top-right): accent = CO2 area, muted = occupancy
    $lx = $p.Width - 196
    if ($lx -gt $pad+220) {
        $pa = New-Object Drawing.Pen($T.Accent,2.5); $g.DrawLine($pa, $lx, ($pad+7), ($lx+16), ($pad+7)); $pa.Dispose()
        Rs-Txt $g ('CO'+$script:RsSub2) $script:RsFonts.Caption $T.TextT ($lx+21) ($pad-1)
        $po = New-Object Drawing.Pen($T.TextT,1.5); $g.DrawLine($po, ($lx+74), ($pad+7), ($lx+90), ($pad+7)); $po.Dispose()
        Rs-Txt $g 'people' $script:RsFonts.Caption $T.TextT ($lx+95) ($pad-1)
    }
    $x = $pad; $y = $pad+32; $w = $p.Width-$pad*2; $h = $p.Height-$y-$pad-2
    if ($h -lt 16 -or $w -lt 60) { return }
    $dayStart = (Get-Date).Date
    # day/night shading driven by the clock (midnight-06:30 and 20:30-24h)
    $nightB = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(16,120,130,160))
    $g.FillRectangle($nightB, [single]$x, [single]$y, [single]($w*0.27), [single]$h)
    $g.FillRectangle($nightB, [single]($x+$w*0.855), [single]$y, [single]($w*0.145), [single]$h); $nightB.Dispose()
    $series = Rs-Recent ($script:rs.Timeline) 24.0
    if ($series.Count -ge 2) {
        $mn = 400.0; $mx = 900.0
        foreach ($s in $series) { $c = [double]$s.Co2; if ($c -gt $mx) { $mx = $c }; if ($c -lt $mn) { $mn = $c } }
        $rng = $mx-$mn; if ($rng -le 0) { $rng = 1 }
        $co2poly = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        $occpoly = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        $prevOcc = $null
        foreach ($s in $series) {
            $frac = ($s.T - $dayStart).TotalHours/24.0; if ($frac -lt 0) { $frac = 0 }; if ($frac -gt 1) { $frac = 1 }
            $px = $x+$frac*$w
            $co2poly.Add((New-Object Drawing.PointF([single]$px, [single]($y+$h-(([double]$s.Co2-$mn)/$rng)*$h))))
            $c = [double]$s.Co2; $oc = if ($c -lt 500) {0} elseif ($c -lt 700) {1} elseif ($c -lt 1000) {2} else {3}
            $oy = $y+$h-($oc/3.0)*($h*0.5)
            if ($null -ne $prevOcc) { $occpoly.Add((New-Object Drawing.PointF([single]$px, [single]$prevOcc))) }
            $occpoly.Add((New-Object Drawing.PointF([single]$px, [single]$oy))); $prevOcc = $oy
        }
        $fp = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'; $fp.AddRange($co2poly)
        $fp.Add((New-Object Drawing.PointF([single]$co2poly[$co2poly.Count-1].X, [single]($y+$h)))); $fp.Add((New-Object Drawing.PointF([single]$co2poly[0].X, [single]($y+$h))))
        $fb = New-Object Drawing.SolidBrush $T.AccentWash; $g.FillPolygon($fb, $fp.ToArray()); $fb.Dispose()
        if ($occpoly.Count -ge 2) { $po = New-Object Drawing.Pen($T.TextT,1.5); $g.DrawLines($po, $occpoly.ToArray()); $po.Dispose() }
        $pen = New-Object Drawing.Pen($T.Accent,1.5); $pen.LineJoin='Round'; $g.DrawLines($pen, $co2poly.ToArray()); $pen.Dispose()
        # "now" marker
        $nx = $x + ((((Get-Date)-$dayStart).TotalHours)/24.0)*$w
        $np = New-Object Drawing.Pen($T.TextS,1); $np.DashStyle='Dot'; $g.DrawLine($np, [single]$nx, [single]$y, [single]$nx, [single]($y+$h)); $np.Dispose()
        # scrub guide + readout
        if ($null -ne $script:rsScrubFrac) {
            $sf = [double]$script:rsScrubFrac; if ($sf -lt 0) { $sf = 0 }; if ($sf -gt 1) { $sf = 1 }
            $sx = $x+$sf*$w
            $spn = New-Object Drawing.Pen($T.TextP,1); $g.DrawLine($spn, [single]$sx, [single]$y, [single]$sx, [single]($y+$h)); $spn.Dispose()
            $best = $null; $bd = [double]::MaxValue
            foreach ($s in $series) { $fr = ($s.T-$dayStart).TotalHours/24.0; $dd = [Math]::Abs($fr-$sf); if ($dd -lt $bd) { $bd = $dd; $best = $s } }
            if ($best) { $lbl = "$($best.T.ToString('HH:mm'))   $([int]$best.Co2) ppm"; $tw = (Rs-Meas $g $lbl $script:RsFonts.Caption).Width; $lxp = $sx+6; if ($lxp+$tw -gt $x+$w) { $lxp = $sx-6-$tw }; Rs-Txt $g $lbl $script:RsFonts.Caption $T.TextP $lxp ($y+1) }
        }
    } else {
        Rs-Txt $g 'gathering today''s data' $script:RsFonts.Caption $T.TextT $x ($y+$h/2-6)
    }
    Rs-Txt $g '00:00' $script:RsFonts.Caption $T.TextT $x ($y+$h+1)
    Rs-TxtR $g '24:00' $script:RsFonts.Caption $T.TextT $x ($y+$h+1) $w
}
function Rs-PaintFooter($g, $p) {
    $T = $script:DashTheme; Ensure-RsFonts
    $g.SmoothingMode='AntiAlias'; $g.TextRenderingHint='ClearTypeGridFit'; $g.Clear($T.Canvas)
    $pen = New-Object Drawing.Pen($T.Hairline,1); $g.DrawLine($pen, 2, 0, ($p.Width-2), 0); $pen.Dispose()
    if (-not $script:rs) { return }
    $cb = $script:rs.ClockBatt; $ab = $script:rs.AranetBatt
    $cbt = if ($null -ne $cb) { "clock $cb%" } else { 'clock --' }
    $abt = if ($null -ne $ab) { "Aranet $ab%" } else { 'Aranet --' }
    $conn = if ($script:settings.ConnectionEnabled) { 'live' } else { 'paused' }
    $air = if ($script:rs.AranetWhen) { "CO$($script:RsSub2) as of $($script:rs.AranetWhen.ToString('HH:mm'))" } else { "CO$($script:RsSub2) --" }
    $tx = 4
    # a single caution dot only if a sensor has gone stale / offline
    if ($script:rs.AnyStale -or -not $script:settings.ConnectionEnabled) {
        $db = New-Object Drawing.SolidBrush $T.Caution; $g.FillEllipse($db, [single]4, [single]11, [single]7, [single]7); $db.Dispose(); $tx = 16
    }
    $txt = "updated $($script:rs.Updated.ToString('HH:mm:ss'))   $($script:RsMid)   $conn   $($script:RsMid)   $air   $($script:RsMid)   $cbt   $($script:RsMid)   $abt"
    Rs-Txt $g $txt $script:RsFonts.Caption $T.TextT $tx 8
}

# Hover popup: compact Room State summary (verdict + 4 readings + CO2 sparkline).
function Update-PopupData {
    $r = $script:lastReading; $a = $script:lastAranet
    $temp = if ($r) { [double]$r.TempC } else { $null }
    $hum  = if ($r) { [double]$r.Humidity } else { $null }
    $co2  = if ($a) { [double]$a.Co2 } else { $null }
    $pres = if ($a) { [double]$a.Pres } else { $null }
    $occ = Rs-Occupancy $a; $vd = Rs-Verdict $co2 $temp $hum $occ
    $spark = Rs-Down (@(Rs-Recent (Get-AranetSeries) 6.0 | ForEach-Object { [double]$_.Co2 })) 26
    $script:popupData = @{ Verdict=$vd.Line; State=$vd.State; Temp=$temp; Hum=$hum; Co2=$co2; Pres=$pres; Spark=$spark }
}
function Rs-PaintPopup($g, $p) {
    $T = $script:DashTheme; Ensure-RsFonts
    $g.SmoothingMode='AntiAlias'; $g.TextRenderingHint='ClearTypeGridFit'; $g.Clear($T.Canvas)
    Rs-Fill $g $T.Surface 0 0 ($p.Width-1) ($p.Height-1) 16
    Rs-Stroke $g $T.Hairline 0 0 ($p.Width-1) ($p.Height-1) 16
    $d = $script:popupData
    if (-not $d) { Rs-Txt $g 'waiting for sensors' $script:RsFonts.Body $T.TextT 18 18; return }
    $oc = Rs-StateColor $d.State $T
    $ob = New-Object Drawing.SolidBrush $oc; $g.FillEllipse($ob, [single]16, [single]18, [single]11, [single]11); $ob.Dispose()
    $sf = New-Object Drawing.StringFormat; $sf.Trimming = [Drawing.StringTrimming]::EllipsisCharacter; $sf.FormatFlags = [Drawing.StringFormatFlags]::NoWrap
    $vb = New-Object Drawing.SolidBrush $T.TextP; $g.DrawString($d.Verdict, $script:RsFonts.Title, $vb, (New-Object Drawing.RectangleF(34, 12, ($p.Width-48), 22)), $sf); $vb.Dispose()
    $items = @(
        @{ L='temp'; V=$(if ($null -ne $d.Temp) { ('{0:0.0}' -f $d.Temp)+$script:RsDeg } else { $script:RsEm }) },
        @{ L='RH';   V=$(if ($null -ne $d.Hum)  { "$([int]$d.Hum)%" } else { $script:RsEm }) },
        @{ L=('CO'+$script:RsSub2); V=$(if ($null -ne $d.Co2) { "$([int]$d.Co2)" } else { $script:RsEm }) },
        @{ L='hPa';  V=$(if ($null -ne $d.Pres) { '{0:0}' -f $d.Pres } else { $script:RsEm }) })
    $cw = ($p.Width-32)/4.0; $x = 16; $y = 46
    foreach ($it in $items) {
        Rs-Txt $g $it.L $script:RsFonts.Caption $T.TextT $x $y
        Rs-Num $g $it.V $script:RsFonts.Body $T.TextP $x ($y+14) | Out-Null
        $x += $cw
    }
    if ($d.Spark) { Rs-Spark $g $d.Spark 16 ($p.Height-42) ($p.Width-32) 22 $T }
    Rs-Txt $g 'click to open dashboard' $script:RsFonts.Caption $T.TextT 16 ($p.Height-16)
}
function Rs-AgeText([double]$min) { if ($min -lt 1) { 'just now' } elseif ($min -lt 90) { "$([int]$min)m ago" } else { '{0:0.0}h ago' -f ($min/60) } }
function Refresh-Dashboard {
    if (-not ($script:dash -and $script:dash.Form -and -not $script:dash.Form.IsDisposed)) { return }
    $now = Get-Date
    $r = $script:lastReading; $a = $script:lastAranet
    $sensor = Get-SensorSeries; $aranet = Get-AranetSeries
    $temp = if ($r) { [double]$r.TempC } else { $null }
    $hum  = if ($r) { [double]$r.Humidity } else { $null }
    $co2  = if ($a) { [double]$a.Co2 } else { $null }
    $pres = if ($a) { [double]$a.Pres } else { $null }
    $dew  = if ($null -ne $temp -and $null -ne $hum -and $hum -gt 0) { [Math]::Round((Get-Dewpoint $temp $hum),1) } else { $null }
    $abs  = if ($null -ne $temp -and $null -ne $hum -and $hum -gt 0) { Rs-AbsHum $temp $hum } else { $null }
    # freshness / stale detection (a reading older than ~3x its interval is stale)
    $clockAge  = if ($r) { ($now - $r.When).TotalMinutes } else { $null }
    $aranetAge = if ($a) { ($now - $a.When).TotalMinutes } else { $null }
    $clockStaleMax  = [Math]::Max(3*(Clock-Interval), 20)
    $aranetStaleMax = [Math]::Max(3*(Aranet-Interval), 12)
    $clockStale  = ($null -ne $clockAge  -and $clockAge  -gt $clockStaleMax)
    $aranetStale = ($null -ne $aranetAge -and $aranetAge -gt $aranetStaleMax)
    $clockAgeTxt  = if ($null -ne $clockAge)  { Rs-AgeText $clockAge }  else { '' }
    $aranetAgeTxt = if ($null -ne $aranetAge) { Rs-AgeText $aranetAge } else { '' }
    $achR = Rs-ACH $a; $occ = Rs-Occupancy $a $achR.Ach; $achBand = Rs-AchBand $achR.Ach; $pt = Rs-Pressure $a; $vd = Rs-Verdict $co2 $temp $hum $occ
    $tD = [Math]::Round((Rs-Delta $sensor 'TempC' $temp 1.0),1)
    $hD = [Math]::Round((Rs-Delta $sensor 'Hum' $hum 1.0),0)
    $cD = [Math]::Round((Rs-Delta $aranet 'Co2' $co2 1.0),0)
    $pD = [Math]::Round((Rs-Delta $aranet 'Pres' $pres 1.0),1)
    # verdict cross-fade + card settle on change
    $reduced = Rs-ReducedMotion
    $oldLine = if ($script:rs) { $script:rs.Verdict } else { '' }
    if ($vd.Line -ne $oldLine) { $script:rsPrevVerdict = $oldLine; $script:rsVAlpha = if ($reduced) { 1.0 } else { 0.0 } }
    $oldState = if ($script:rs) { $script:rs.State } else { 'good' }
    if ($vd.State -ne $oldState -and -not $reduced) { $script:rsSettle['aq'] = 1.0 }
    Rs-SetTargets @{ co2=$co2; v_temp=$temp; v_hum=$hum; v_co2=$co2; v_pres=$pres; dew=$dew; ach=$achR.Ach }
    $script:rs = @{
        Temp=$temp; Hum=$hum; Co2=$co2; Pres=$pres; Dew=$dew; Abs=$abs
        Occ=$occ; Ach=$achR.Ach; ClearMin=$achR.ClearMin; AchBand=$achBand.Band; AchLevel=$achBand.Level
        AchFresh=$achR.Fresh; AchChanged=$achR.Changed; AchAge=$achR.AgeMin; PresTrend=$pt.Trend; PresRate=$pt.Rate
        Verdict=$vd.Line; State=$vd.State; Rebreathed=$(if ($null -ne $co2) { Rs-Rebreathed $co2 } else { $null })
        Updated=$now; Timeline=$aranet
        Co2Stale=$aranetStale; Co2Age=$aranetAgeTxt; AnyStale=($clockStale -or $aranetStale)
        AranetWhen=$(if ($a) { $a.When } else { $null }); ClockWhen=$(if ($r) { $r.When } else { $null })
        ClockBatt=$(if ($r -and $null -ne $r.Battery) { [int]$r.Battery } else { $null })
        AranetBatt=$(if ($a -and $null -ne $a.Battery) { [int]$a.Battery } else { $null })
        V=@{
            temp=@{ Label='Temperature'; Raw=$temp; DispKey='v_temp'; Fmt='{0:0.0}'; Unit=($script:RsDeg+'C'); Icon='temp'; Spark=(Rs-Down (@(Rs-Recent $sensor 6.0 | ForEach-Object { $_.TempC })) 30); Delta=$tD; DUnit=$script:RsDeg; Stale=$clockStale; AgeText=$clockAgeTxt; DeltaHot=([Math]::Abs($tD) -ge 1.5) }
            hum =@{ Label='Humidity'; Raw=$hum; DispKey='v_hum'; Fmt='{0:0}'; Unit='%'; Icon='drop'; Spark=(Rs-Down (@(Rs-Recent $sensor 6.0 | ForEach-Object { $_.Hum })) 30); Delta=$hD; DUnit='%'; Stale=$clockStale; AgeText=$clockAgeTxt; DeltaHot=([Math]::Abs($hD) -ge 8) }
            co2 =@{ Label=('CO'+$script:RsSub2); Raw=$co2; DispKey='v_co2'; Fmt='{0:0}'; Unit='ppm'; Icon='air'; Spark=(Rs-Down (@(Rs-Recent $aranet 6.0 | ForEach-Object { [double]$_.Co2 })) 30); Delta=$cD; DUnit=''; Stale=$aranetStale; AgeText=$aranetAgeTxt; DeltaHot=([Math]::Abs($cD) -ge 200) }
            pres=@{ Label='Pressure'; Raw=$pres; DispKey='v_pres'; Fmt='{0:0}'; Unit='hPa'; Icon='gauge'; Spark=(Rs-Down (@(Rs-Recent $aranet 6.0 | ForEach-Object { $_.Pres })) 30); Delta=$pD; DUnit=''; Stale=$aranetStale; AgeText=$aranetAgeTxt; DeltaHot=([Math]::Abs($pD) -ge 2.5) }
        }
    }
    # announce the verdict to assistive tech (throttled to real changes)
    if ($vd.Line -ne $oldLine -and $script:dash.Orb) { try { $script:dash.Orb.AccessibleName = $vd.Line; $script:dash.Orb.AccessibleDescription = $vd.Line } catch {} }
    foreach ($pnl in $script:dash.Panels) { if ($pnl -and -not $pnl.IsDisposed) { $pnl.Invalidate() } }
    if ($script:RsAnimTimer -and -not $reduced) { $script:RsAnimTimer.Start() }
    Update-Dash-Controls
}

function Toggle-Theme {
    $new = if ($script:DashTheme.Mode -eq 'dark') { 'light' } else { 'dark' }
    $script:settings.Theme = $new; Save-Settings
    $f = $script:dash.Form; $script:dash = $null
    if ($f -and -not $f.IsDisposed) { $f.Close() }
    Show-Dashboard
}
# Create a Room State card panel wired to its painter scriptblock.
function Rs-Card($painter) {
    Ensure-DashTypes
    $p = New-Object Vulcan.CardPanel
    $p.BackColor = $script:DashTheme.Canvas; $p.Dock = [System.Windows.Forms.DockStyle]::Fill
    $p.Margin = New-Object System.Windows.Forms.Padding(0, 0, 16, 16); $p.Tag = @{}
    $p.Add_Paint($painter)
    return $p
}
function New-RsTable([int]$cols) {
    $t = New-BufferedTable; $t.Dock = [System.Windows.Forms.DockStyle]::Fill; $t.BackColor = $script:DashTheme.Canvas
    $t.ColumnCount = $cols; $t.RowCount = 1
    return $t
}

function Show-Dashboard {
    try {
        if ($script:dash -and $script:dash.Form -and -not $script:dash.Form.IsDisposed) {
            $script:dash.Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $script:dash.Form.Activate(); Refresh-Dashboard; return
        }
        $mode = if ($script:settings.Theme) { [string]$script:settings.Theme } else { 'dark' }
        Apply-Theme $mode; Ensure-RsFonts; Ensure-DashTypes
        $T = $script:DashTheme
        $script:dash = @{ Gauges = @{}; ClockBtns = @(); AranetBtns = @(); Panels = @() }

        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'Room state'
        $f.BackColor = $T.Canvas
        $f.Font = DashFont 9
        try { $f.Icon = [System.Drawing.Icon]::FromHandle($script:iconHandle) } catch {}
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $f.Size = New-Object System.Drawing.Size([Math]::Min(1280, $wa.Width - 60), [Math]::Min(960, $wa.Height - 50))
        $f.MinimumSize = New-Object System.Drawing.Size(1040, 820)
        $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen

        # Outer layout: verdict (flush) / body (fill) / controls (slim) / footer
        $tl = New-Object System.Windows.Forms.TableLayoutPanel
        $tl.Dock = [System.Windows.Forms.DockStyle]::Fill; $tl.BackColor = $T.Canvas
        $tl.Padding = New-Object System.Windows.Forms.Padding(32, 22, 32, 10)
        $tl.ColumnCount = 1; $tl.RowCount = 4
        [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 78)))
        [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
        [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
        [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 26)))

        # ---- Verdict (flush on canvas, no card) ----
        $verdict = New-Object Vulcan.CardPanel; $verdict.BackColor = $T.Canvas; $verdict.Dock = [System.Windows.Forms.DockStyle]::Fill
        $verdict.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
        $verdict.Add_Paint({ param($s,$e); try { Rs-PaintVerdict $e.Graphics $this } catch { WLog "rs verdict: $($_.Exception.Message)" } })
        $script:dash.Orb = $verdict

        # ---- Body ----
        $body = New-BufferedTable; $body.Dock = [System.Windows.Forms.DockStyle]::Fill; $body.BackColor = $T.Canvas
        $body.ColumnCount = 1; $body.RowCount = 4
        [void]$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
        [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 186)))
        [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 126)))
        [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 172)))
        [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

        # row 1: air quality (span 2) + occupancy
        $r1 = New-RsTable 3
        [void]$r1.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 40)))
        [void]$r1.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 27)))
        [void]$r1.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33)))
        $aq  = Rs-Card { param($s,$e); try { Rs-PaintAirQuality $e.Graphics $this } catch { WLog "rs aq: $($_.Exception.Message)" } }
        $occ = Rs-Card { param($s,$e); try { Rs-PaintOccupancy $e.Graphics $this } catch { WLog "rs occ: $($_.Exception.Message)" } }
        $occ.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 16)
        $r1.Controls.Add($aq, 0, 0); $r1.SetColumnSpan($aq, 2); $r1.Controls.Add($occ, 2, 0)

        # row 2: vitals 4-up
        $r2 = New-RsTable 4
        1..4 | ForEach-Object { [void]$r2.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 25))) }
        $vCards = @{}
        $vi = 0
        foreach ($key in @('temp','hum','co2','pres')) {
            $c = Rs-Card { param($s,$e); try { Rs-PaintVital $e.Graphics $this } catch { WLog "rs vital: $($_.Exception.Message)" } }
            $c.Tag = @{ Key = $key }
            if ($vi -eq 3) { $c.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 16) }
            $r2.Controls.Add($c, $vi, 0); $vCards[$key] = $c; $vi++
        }

        # row 3: ventilation / comfort / outside
        $r3 = New-RsTable 3
        1..3 | ForEach-Object { [void]$r3.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.33))) }
        $vent = Rs-Card { param($s,$e); try { Rs-PaintVentilation $e.Graphics $this } catch { WLog "rs vent: $($_.Exception.Message)" } }
        $comf = Rs-Card { param($s,$e); try { Rs-PaintComfort $e.Graphics $this } catch { WLog "rs comf: $($_.Exception.Message)" } }
        $outs = Rs-Card { param($s,$e); try { Rs-PaintOutside $e.Graphics $this } catch { WLog "rs out: $($_.Exception.Message)" } }
        $outs.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 16)
        $r3.Controls.Add($vent, 0, 0); $r3.Controls.Add($comf, 1, 0); $r3.Controls.Add($outs, 2, 0)

        # row 4: timeline
        $timeline = Rs-Card { param($s,$e); try { Rs-PaintTimeline $e.Graphics $this } catch { WLog "rs timeline: $($_.Exception.Message)" } }
        $timeline.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)

        $body.Controls.Add($r1, 0, 0); $body.Controls.Add($r2, 0, 1); $body.Controls.Add($r3, 0, 2); $body.Controls.Add($timeline, 0, 3)

        # ---- Controls (slim strip, restyled to tokens) ----
        $ctl = New-Object System.Windows.Forms.Panel; $ctl.Dock = [System.Windows.Forms.DockStyle]::Fill; $ctl.BackColor = $T.Canvas
        $sep = New-Object System.Windows.Forms.Panel; $sep.BackColor = $T.Hairline; $sep.Height = 1; $sep.Dock = [System.Windows.Forms.DockStyle]::Top
        $ctl.Controls.Add($sep)
        $script:dash.ConnTog = New-DashSwitch 4 16
        $script:dash.ConnTog.Add_Paint({ param($s,$e); try { Draw-Toggle $e.Graphics $this ([bool]$script:settings.ConnectionEnabled) } catch { WLog "paint tog: $($_.Exception.Message)" } })
        $script:dash.ConnTog.Add_Click({ Toggle-Connection })
        $script:dash.AranetTog = New-DashSwitch 196 16
        $script:dash.AranetTog.Add_Paint({ param($s,$e); try { Draw-Toggle $e.Graphics $this ([bool]$script:settings.AranetEnabled) } catch { WLog "paint tog: $($_.Exception.Message)" } })
        $script:dash.AranetTog.Add_Click({ Toggle-Aranet })
        $script:dash.LogTog = New-DashSwitch 388 16
        $script:dash.LogTog.Add_Paint({ param($s,$e); try { Draw-Toggle $e.Graphics $this ([bool]$script:settings.HourlyLogging) } catch { WLog "paint tog: $($_.Exception.Message)" } })
        $script:dash.LogTog.Add_Click({ $script:settings.HourlyLogging = -not $script:settings.HourlyLogging; Save-Settings; $script:dash.LogTog.Invalidate(); Refresh-Menu })
        $script:dash.StartupTog = New-DashSwitch 560 16
        $script:dash.StartupTog.Add_Paint({ param($s,$e); try { Draw-Toggle $e.Graphics $this ([bool](Test-Startup)) } catch { WLog "paint tog: $($_.Exception.Message)" } })
        $script:dash.StartupTog.Add_Click({ Set-Startup (-not (Test-Startup)); $script:dash.StartupTog.Invalidate(); Refresh-Menu })
        $script:dash.ThemeTog = New-DashSwitch 736 16
        $script:dash.ThemeTog.Add_Paint({ param($s,$e); try { Draw-Toggle $e.Graphics $this ($script:DashTheme.Mode -eq 'light') } catch { WLog "paint tog: $($_.Exception.Message)" } })
        $script:dash.ThemeTog.Add_Click({ Toggle-Theme })
        $ctl.Controls.AddRange(@(
            $script:dash.ConnTog,   (New-Lbl 'Connection'     (DashFont 9.5) $T.TextS $T.Canvas 58 19),
            $script:dash.AranetTog, (New-Lbl 'Aranet CO2'     (DashFont 9.5) $T.TextS $T.Canvas 250 19),
            $script:dash.LogTog,    (New-Lbl 'Log to CSV'     (DashFont 9.5) $T.TextS $T.Canvas 442 19),
            $script:dash.StartupTog,(New-Lbl 'Start at login' (DashFont 9.5) $T.TextS $T.Canvas 614 19),
            $script:dash.ThemeTog,  (New-Lbl 'Light theme'    (DashFont 9.5) $T.TextS $T.Canvas 790 19)
        ))
        $script:dash.ClockBtns = New-DashSeg $ctl 'Clock read (min)' 4 @(5,10,15,30,60) $T.Accent ([int]$script:settings.IntervalMinutes) `
            ({ param($s,$e); $script:settings.IntervalMinutes = [int]$s.Tag; $script:clockDue = Get-Date; Save-Settings; Update-Dash-Controls; Refresh-Menu })
        $script:dash.AranetBtns = New-DashSeg $ctl 'Aranet read (min)' 412 @(1,2,3,5,10,15,30) $T.Accent ([int]$script:settings.AranetIntervalMinutes) `
            ({ param($s,$e); $script:settings.AranetIntervalMinutes = [int]$s.Tag; $script:aranetDue = Get-Date; Save-Settings; Update-Dash-Controls; Refresh-Menu })
        $bSync = New-DashButton 'Sync clock' $T.Accent; $bSync.Location = New-Object System.Drawing.Point(4, 104); $bSync.Add_Click({ Start-Bg -Kind 'sync' -LogCsv $false -Notify $true })
        $bReadC = New-DashButton 'Read clock' $T.Sunken $T.TextP; $bReadC.Location = New-Object System.Drawing.Point(162, 104); $bReadC.Add_Click({ Start-Bg -Kind 'read' -LogCsv $true -Notify $true })
        $bReadA = New-DashButton 'Read Aranet4' $T.Sunken $T.TextP; $bReadA.Location = New-Object System.Drawing.Point(320, 104); $bReadA.Add_Click({ Ensure-AranetWatcher; Sample-Aranet -LogCsv $true -Notify $true; Refresh-Dashboard })
        $bData = New-DashButton 'Open data folder' $T.Sunken $T.TextP; $bData.Location = New-Object System.Drawing.Point(478, 104); $bData.Add_Click({ Start-Process explorer.exe $LogDir })
        $ctl.Controls.AddRange(@($bSync, $bReadC, $bReadA, $bData))
        # room volume (m3) - feeds the occupancy mass-balance estimate
        $lblVol = New-Lbl ('Room volume (m'+$script:RsSup3+')') (DashFont 9.5) $T.TextS $T.Canvas 648 114
        $numVol = New-Object System.Windows.Forms.NumericUpDown
        $numVol.Minimum = 5; $numVol.Maximum = 1000; $numVol.Increment = 1; $numVol.Font = DashFont 10
        $numVol.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $numVol.BackColor = $T.Sunken; $numVol.ForeColor = $T.TextP
        $numVol.Location = New-Object System.Drawing.Point(772, 110); $numVol.Width = 66
        $numVol.Value = [decimal][Math]::Min(1000, [Math]::Max(5, [int]$script:settings.RoomVolume))
        $numVol.Add_ValueChanged({ $script:settings.RoomVolume = [int]$this.Value; Save-Settings; if ($script:dash) { Refresh-Dashboard } })
        $ctl.Controls.AddRange(@($lblVol, $numVol))

        # ---- Footer ----
        $footer = New-Object Vulcan.CardPanel; $footer.BackColor = $T.Canvas; $footer.Dock = [System.Windows.Forms.DockStyle]::Fill
        $footer.Add_Paint({ param($s,$e); try { Rs-PaintFooter $e.Graphics $this } catch { WLog "rs footer: $($_.Exception.Message)" } })

        $tl.Controls.Add($verdict, 0, 0); $tl.Controls.Add($body, 0, 1); $tl.Controls.Add($ctl, 0, 2); $tl.Controls.Add($footer, 0, 3)
        $f.Controls.Add($tl)

        $script:dash.Panels = @($verdict, $aq, $occ, $vCards['temp'], $vCards['hum'], $vCards['co2'], $vCards['pres'], $vent, $comf, $outs, $timeline, $footer)
        $script:dash.AnimPanels = @($aq, $vCards['temp'], $vCards['hum'], $vCards['co2'], $vCards['pres'], $vent, $comf)
        $script:dash.Form = $f

        # accessibility: names for assistive tech (colour is never the only signal -
        # every state also carries a label, a position, or an icon).
        $f.AccessibleName = 'Room state dashboard'
        $verdict.AccessibleName = 'Room verdict'
        $aq.AccessibleName = 'Air quality'; $occ.AccessibleName = 'Occupancy'
        $vCards['temp'].AccessibleName = 'Temperature'; $vCards['hum'].AccessibleName = 'Humidity'
        $vCards['co2'].AccessibleName = 'CO2'; $vCards['pres'].AccessibleName = 'Pressure'
        $vent.AccessibleName = 'Ventilation'; $comf.AccessibleName = 'Comfort'; $outs.AccessibleName = 'Outside'; $timeline.AccessibleName = 'Today timeline'

        # timeline: scrub to read any moment; click opens the full zoomable trends graph
        $timeline.Cursor = [System.Windows.Forms.Cursors]::Hand
        $timeline.Add_MouseMove({ param($s,$e); try { $w = $this.Width-40; if ($w -gt 0) { $fr = ($e.X-20)/[double]$w; if ($fr -lt 0) { $fr = 0 }; if ($fr -gt 1) { $fr = 1 }; $script:rsScrubFrac = $fr; $this.Invalidate() } } catch {} })
        $timeline.Add_MouseLeave({ param($s,$e); $script:rsScrubFrac = $null; try { $this.Invalidate() } catch {} })
        $timeline.Add_Click({ try { Show-TrendsWindow } catch {} })

        # unified animation loop: breathing orb + value tweens + verdict cross-fade
        # + state-change settle. Skipped entirely when the OS prefers reduced motion.
        $script:OrbPhase = 1.0; $script:OrbT = 0.0; $script:rsScrubFrac = $null
        if ($script:RsAnimTimer) { try { $script:RsAnimTimer.Stop(); $script:RsAnimTimer.Dispose() } catch {} }
        $script:RsAnimTimer = $null
        if (-not (Rs-ReducedMotion)) {
            $script:OrbPhase = 0.0
            $script:RsAnimTimer = New-Object System.Windows.Forms.Timer; $script:RsAnimTimer.Interval = 40
            $script:RsAnimTimer.Add_Tick({
                if (-not ($script:dash -and $script:dash.Form -and -not $script:dash.Form.IsDisposed)) { return }
                $script:OrbT += 0.04
                $script:OrbPhase = (1 - [Math]::Cos($script:OrbT / 2.4 * 2 * [Math]::PI)) / 2
                $moving = Rs-AnimStep
                $fading = $false
                if ($script:rsVAlpha -lt 1) { $script:rsVAlpha = [Math]::Min(1.0, $script:rsVAlpha + 0.10); $fading = $true }
                $settling = $false
                foreach ($k in @($script:rsSettle.Keys)) { $v = $script:rsSettle[$k]*0.88; if ($v -lt 0.02) { [void]$script:rsSettle.Remove($k) } else { $script:rsSettle[$k] = $v; $settling = $true } }
                if ($script:dash.Orb -and -not $script:dash.Orb.IsDisposed) {
                    if ($fading) { $script:dash.Orb.Invalidate() } else { $script:dash.Orb.Invalidate((New-Object System.Drawing.Rectangle(0,0,40,40))) }
                }
                if ($moving -or $settling) { foreach ($pnl in $script:dash.AnimPanels) { if ($pnl -and -not $pnl.IsDisposed) { $pnl.Invalidate() } } }
            })
            $script:RsAnimTimer.Start()
        }
        $f.Add_FormClosed({ $script:dash = $null; $script:rsScrubFrac = $null; try { if ($script:RsAnimTimer) { $script:RsAnimTimer.Stop(); $script:RsAnimTimer.Dispose(); $script:RsAnimTimer = $null } } catch {} })

        Refresh-Dashboard
        $f.Show(); $f.Activate()
    } catch { WLog "ERROR dashboard: $($_.Exception.Message) :: $($_.ScriptStackTrace)" }
}

# Connection / Aranet toggles shared by the tray menu and the dashboard.
function Toggle-Connection {
    $script:settings.ConnectionEnabled = -not $script:settings.ConnectionEnabled
    Save-Settings
    if ($script:settings.ConnectionEnabled) {
        $script:clockDue = Get-Date; $script:aranetDue = (Get-Date).AddSeconds(20)
        Update-Icon $script:lastText $false; Ensure-AranetWatcher; Scheduler-Tick
    } else {
        Stop-AranetWatcher; Update-Icon $script:lastText $true
        $script:ni.Text = 'LYWSD02  -  connection off (battery saver)'
    }
    Refresh-Menu; if ($script:dash) { $script:dash.ConnTog.Invalidate(); Refresh-Dashboard }
}
function Toggle-Aranet {
    $script:settings.AranetEnabled = -not $script:settings.AranetEnabled
    Save-Settings; Refresh-Menu
    if ($script:settings.AranetEnabled) { if ($script:settings.ConnectionEnabled) { Ensure-AranetWatcher; $script:aranetDue = (Get-Date).AddSeconds(20) } }
    else { Stop-AranetWatcher }
    if ($script:dash) { $script:dash.AranetTog.Invalidate() }
}

# ---- Menu handlers --------------------------------------------------------
$miRead.Add_Click({ Start-Bg -Kind 'read' -LogCsv $true -Notify $true })
$miReadAranet.Add_Click({ Ensure-AranetWatcher; Sample-Aranet -LogCsv $true -Notify $true })
$miSync.Add_Click({ Start-Bg -Kind 'sync' -LogCsv $false -Notify $true })
$miTrends.Add_Click({ Show-Dashboard })
$miConn.Add_Click({ Toggle-Connection })
$miLog.Add_Click({ $script:settings.HourlyLogging = -not $script:settings.HourlyLogging; Save-Settings; Refresh-Menu; if ($script:dash) { $script:dash.LogTog.Invalidate() } })
$miAranet.Add_Click({ Toggle-Aranet })
$miOpen.Add_Click({ Start-Process explorer.exe $LogDir })
$miStartup.Add_Click({ Set-Startup (-not (Test-Startup)); Refresh-Menu })
$miExit.Add_Click({
    try { Stop-AranetWatcher } catch {}
    try { $script:ni.Visible = $false } catch {}
    try { if ($script:iconHandle -ne [IntPtr]::Zero) { [void][LywsdNative.U32]::DestroyIcon($script:iconHandle) } } catch {}
    try { $script:ni.Dispose() } catch {}
    [System.Windows.Forms.Application]::Exit()
})
# Hover shows the graph popup; double-click opens the resizable trends window.
$script:ni.Add_MouseMove({
    $cp = [System.Windows.Forms.Cursor]::Position
    if ($script:popupShown) {
        $script:popupAnchor = $cp
    } elseif ([Environment]::TickCount -ge $script:suppressUntil) {
        Show-Popup $cp.X $cp.Y
    }
})
# Clicking the icon (single or double) dismisses the popup and briefly suppresses
# re-showing, so it doesn't immediately pop back while the cursor is still on the icon.
$script:ni.Add_MouseDown({
    $script:suppressUntil = [Environment]::TickCount + 900
    Hide-Popup
})
$script:ni.Add_MouseDoubleClick({ Show-Dashboard })
$menu.Add_Opening({ Hide-Popup })

Refresh-Menu
# Honour the saved light/dark theme so the hover popup matches before the
# dashboard is first opened.
try { Apply-Theme $(if ($script:settings.Theme) { [string]$script:settings.Theme } else { 'dark' }) } catch {}
WLog "Widget started (addr='$($script:settings.Address)', interval=$($script:settings.IntervalMinutes)m, conn=$($script:settings.ConnectionEnabled))."

# ---- Run ------------------------------------------------------------------
$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)

# Cleanup on exit
try { Stop-AranetWatcher } catch {}
try { if ($script:iconHandle -ne [IntPtr]::Zero) { [void][LywsdNative.U32]::DestroyIcon($script:iconHandle) } } catch {}
try { $script:ni.Dispose() } catch {}
try { $script:mutex.ReleaseMutex() } catch {}
WLog "Widget stopped."
