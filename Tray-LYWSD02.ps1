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
function New-TrendChart {
    param([bool]$Compact)
    $deg   = [char]0x00B0
    $dark  = [System.Drawing.Color]::FromArgb(24,24,28)
    $panel = [System.Drawing.Color]::FromArgb(32,32,38)
    $grid  = [System.Drawing.Color]::FromArgb(55,55,62)
    $fg    = [System.Drawing.Color]::FromArgb(225,225,225)
    $cTemp = [System.Drawing.Color]::Tomato
    $cDew  = [System.Drawing.Color]::DeepSkyBlue
    $cHum  = [System.Drawing.Color]::MediumSeaGreen
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.BackColor = $dark
    $chart.AntiAliasing = [System.Windows.Forms.DataVisualization.Charting.AntiAliasingStyles]::All
    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea('main')
    $area.BackColor = $panel
    $area.AxisX.LabelStyle.ForeColor = $fg; $area.AxisX.LineColor = $grid; $area.AxisX.MajorGrid.LineColor = $grid
    $area.AxisX.LabelStyle.Format = if ($Compact) {'HH:mm'} else {'ddd HH:mm'}
    $area.AxisX.IntervalType = [System.Windows.Forms.DataVisualization.Charting.DateTimeIntervalType]::Hours
    # Left axis = Temperature + Dew point (deg C), colour-coded orange, auto-scaled.
    $area.AxisY.LabelStyle.ForeColor = $cTemp; $area.AxisY.LineColor = $cTemp; $area.AxisY.MajorGrid.LineColor = $grid
    # Right axis = Humidity, colour-coded green, FIXED 0-100 so it can never
    # coincidentally overlap the temperature line.
    $area.AxisY2.Enabled = [System.Windows.Forms.DataVisualization.Charting.AxisEnabled]::True
    $area.AxisY2.Minimum = 0; $area.AxisY2.Maximum = 100; $area.AxisY2.Interval = 20
    $area.AxisY2.LabelStyle.ForeColor = $cHum; $area.AxisY2.LineColor = $cHum; $area.AxisY2.MajorGrid.Enabled = $false
    if (-not $Compact) {
        $area.AxisY.Title  = "Temperature / Dew point  ($($deg)C)"; $area.AxisY.TitleForeColor = $cTemp
        $area.AxisY2.Title = 'Humidity  (%)'; $area.AxisY2.TitleForeColor = $cHum
    }
    $chart.ChartAreas.Add($area)
    $P=[System.Windows.Forms.DataVisualization.Charting.AxisType]::Primary
    $S=[System.Windows.Forms.DataVisualization.Charting.AxisType]::Secondary
    $mk = {
        param($name,$legend,$axis,$color,$dash,$tip)
        $s = New-Object System.Windows.Forms.DataVisualization.Charting.Series($name)
        $s.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
        $s.XValueType = [System.Windows.Forms.DataVisualization.Charting.ChartValueType]::DateTime
        $s.BorderWidth = 2; $s.Color = $color; $s.YAxisType = $axis; $s.LegendText = $legend
        $s.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle
        $s.MarkerSize = if ($Compact) {5} else {6}; $s.MarkerColor = $color
        $s.ToolTip = $tip   # floats the point's reading on hover (in the windowed view)
        if ($dash) { $s.BorderDashStyle = [System.Windows.Forms.DataVisualization.Charting.ChartDashStyle]::Dash }
        $chart.Series.Add($s)
    }
    # Created in z-order: humidity underneath, then temperature + dew point on top.
    & $mk 'Humidity'    "Humidity (%, right)"          $S $cHum  $false "Humidity  #VALY{0}%  @ #VALX{ddd HH:mm}"
    & $mk 'Temperature' "Temperature ($($deg)C, left)" $P $cTemp $false "Temperature  #VALY{0.0}$($deg)C  @ #VALX{ddd HH:mm}"
    & $mk 'Dew point'   "Dew point ($($deg)C, left)"   $P $cDew  $true  "Dew point  #VALY{0.0}$($deg)C  @ #VALX{ddd HH:mm}"
    $lg = New-Object System.Windows.Forms.DataVisualization.Charting.Legend('L')
    $lg.BackColor = $panel; $lg.ForeColor = $fg
    $lg.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Top
    if ($Compact) { $lg.Font = New-Object System.Drawing.Font('Segoe UI',7) }
    $chart.Legends.Add($lg)
    if (-not $Compact) {
        $ti = New-Object System.Windows.Forms.DataVisualization.Charting.Title('')
        $ti.ForeColor = $fg; $ti.Font = New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Bold)
        $chart.Titles.Add($ti)
    }
    return $chart
}
function Rebuild-ChartData {
    param($chart, [string]$TitleText)
    $b = Get-RangeBounds
    $data = @(Get-SensorSeries | Where-Object { $_.T -ge $b.From -and $_.T -le $b.To })
    $sT = $chart.Series['Temperature']; $sD = $chart.Series['Dew point']; $sH = $chart.Series['Humidity']
    $sT.Points.Clear(); $sD.Points.Clear(); $sH.Points.Clear()
    foreach ($r in $data) {
        [void]$sH.Points.AddXY($r.T, $r.Hum)
        [void]$sT.Points.AddXY($r.T, $r.TempC)
        [void]$sD.Points.AddXY($r.T, $r.Dew)
    }
    # Adapt X-axis labels to the visible span so they don't crowd.
    if ($chart.ChartAreas.Count -gt 0) {
        $ax = $chart.ChartAreas['main'].AxisX
        $spanH = if ($data.Count -ge 2) { ([datetime]$data[-1].T - [datetime]$data[0].T).TotalHours } else { 1 }
        if     ($spanH -gt 72) { $ax.LabelStyle.Format = 'MM-dd' }
        elseif ($spanH -gt 26) { $ax.LabelStyle.Format = 'ddd HH:mm' }
        else                   { $ax.LabelStyle.Format = 'HH:mm' }
    }
    if ($chart.Titles.Count -gt 0 -and $TitleText) { $chart.Titles[0].Text = $TitleText }
}

# ---- Air-quality chart (Aranet4: CO2 + pressure) --------------------------
function New-Co2Chart {
    param([bool]$Compact)
    $dark  = [System.Drawing.Color]::FromArgb(24,24,28)
    $panel = [System.Drawing.Color]::FromArgb(32,32,38)
    $grid  = [System.Drawing.Color]::FromArgb(55,55,62)
    $fg    = [System.Drawing.Color]::FromArgb(225,225,225)
    $cCo2  = [System.Drawing.Color]::Goldenrod
    $cPres = [System.Drawing.Color]::MediumPurple
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.BackColor = $dark
    $chart.AntiAliasing = [System.Windows.Forms.DataVisualization.Charting.AntiAliasingStyles]::All
    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea('main')
    $area.BackColor = $panel
    $area.AxisX.LabelStyle.ForeColor = $fg; $area.AxisX.LineColor = $grid; $area.AxisX.MajorGrid.LineColor = $grid
    $area.AxisX.LabelStyle.Format = if ($Compact) {'HH:mm'} else {'ddd HH:mm'}
    $area.AxisX.IntervalType = [System.Windows.Forms.DataVisualization.Charting.DateTimeIntervalType]::Hours
    $area.AxisY.LabelStyle.ForeColor = $cCo2; $area.AxisY.LineColor = $cCo2; $area.AxisY.MajorGrid.LineColor = $grid
    $area.AxisY2.Enabled = [System.Windows.Forms.DataVisualization.Charting.AxisEnabled]::True
    $area.AxisY2.LabelStyle.ForeColor = $cPres; $area.AxisY2.LineColor = $cPres; $area.AxisY2.MajorGrid.Enabled = $false
    if (-not $Compact) {
        $area.AxisY.Title  = 'CO2 (ppm)'; $area.AxisY.TitleForeColor = $cCo2
        $area.AxisY2.Title = 'Pressure (hPa)'; $area.AxisY2.TitleForeColor = $cPres
    }
    $chart.ChartAreas.Add($area)
    $P=[System.Windows.Forms.DataVisualization.Charting.AxisType]::Primary
    $S=[System.Windows.Forms.DataVisualization.Charting.AxisType]::Secondary
    $mk = {
        param($name,$legend,$axis,$color,$tip)
        $s = New-Object System.Windows.Forms.DataVisualization.Charting.Series($name)
        $s.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
        $s.XValueType = [System.Windows.Forms.DataVisualization.Charting.ChartValueType]::DateTime
        $s.BorderWidth = 2; $s.Color = $color; $s.YAxisType = $axis; $s.LegendText = $legend
        $s.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle
        $s.MarkerSize = if ($Compact) {5} else {6}; $s.MarkerColor = $color
        $s.ToolTip = $tip
        $chart.Series.Add($s)
    }
    & $mk 'CO2'      'CO2 (ppm, left)'        $P $cCo2  "CO2  #VALY{0} ppm  @ #VALX{ddd HH:mm}"
    & $mk 'Pressure' 'Pressure (hPa, right)'  $S $cPres "Pressure  #VALY{0.0} hPa  @ #VALX{ddd HH:mm}"
    $lg = New-Object System.Windows.Forms.DataVisualization.Charting.Legend('L')
    $lg.BackColor = $panel; $lg.ForeColor = $fg
    $lg.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Top
    if ($Compact) { $lg.Font = New-Object System.Drawing.Font('Segoe UI',7) }
    $chart.Legends.Add($lg)
    if (-not $Compact) {
        $ti = New-Object System.Windows.Forms.DataVisualization.Charting.Title('')
        $ti.ForeColor = $fg; $ti.Font = New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Bold)
        $chart.Titles.Add($ti)
    }
    return $chart
}
function Rebuild-Co2Data {
    param($chart, [string]$TitleText)
    $b = Get-RangeBounds
    $data = @(Get-AranetSeries | Where-Object { $_.T -ge $b.From -and $_.T -le $b.To })
    $sC = $chart.Series['CO2']; $sP = $chart.Series['Pressure']
    $sC.Points.Clear(); $sP.Points.Clear()
    foreach ($r in $data) {
        [void]$sC.Points.AddXY($r.T, $r.Co2)
        [void]$sP.Points.AddXY($r.T, $r.Pres)
    }
    if ($chart.ChartAreas.Count -gt 0) {
        $ax = $chart.ChartAreas['main'].AxisX
        $spanH = if ($data.Count -ge 2) { ([datetime]$data[-1].T - [datetime]$data[0].T).TotalHours } else { 1 }
        if     ($spanH -gt 72) { $ax.LabelStyle.Format = 'MM-dd' }
        elseif ($spanH -gt 26) { $ax.LabelStyle.Format = 'ddd HH:mm' }
        else                   { $ax.LabelStyle.Format = 'HH:mm' }
    }
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
$miTrends     = New-Item 'Show trends...'
$miConn       = New-Item 'Connection enabled'
$miLog        = New-Item 'Log hourly to CSV'
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

$menu.Items.AddRange(@(
    $miTitle, $miReading,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $miRead, $miReadAranet, $miSync, $miTrends,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $miConn, $miLog, $miAranet, $miAranetIvl, $miOpen, $miStartup,
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
    if ($script:aranetWatcherPid) {
        $alive = $false
        try { $alive = [bool](Get-Process -Id $script:aranetWatcherPid -ErrorAction SilentlyContinue) } catch {}
        if ($alive) { return }
    }
    Stop-AranetWatcher
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
    $script:lastAranet = @{
        Co2=[int]$data.co2; TempC=[double]$data.tempC; Hum=[int]$data.humidity;
        Pres=[double]$data.pressure; Battery=$data.battery; Status=[string]$data.status; When=(Get-Date)
    }
    if ($isNew) {
        $script:lastAranetTs = $ts
        if ($LogCsv) { Append-AranetCsv -Co2 $script:lastAranet.Co2 -TempC $script:lastAranet.TempC -Humidity $script:lastAranet.Hum -Pressure $script:lastAranet.Pres -Battery $script:lastAranet.Battery -Status $script:lastAranet.Status }
        WLog "INFO aranet co2=$($script:lastAranet.Co2) status=$($script:lastAranet.Status) (captured $ts)"
    }
    if ($Notify) { $script:ni.ShowBalloonTip(4000,'Aranet4', ("{0} ppm CO2 ({1})   {2:0.0} hPa   (as of {3})" -f $script:lastAranet.Co2,$script:lastAranet.Status,$script:lastAranet.Pres,$ts), [System.Windows.Forms.ToolTipIcon]::Info) }
    Set-Tooltip
    $miReading.Text = Reading-Text
    if ($script:popupShown) { try { $script:popupHdr.Text = Reading-Text } catch {} }
    if ($script:trendForm -and -not $script:trendForm.IsDisposed -and $script:trendCo2Chart) { try { Rebuild-Co2Data $script:trendCo2Chart 'Aranet4 (air quality)' } catch {} }
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
        if ($script:popupShown) { try { $script:popupHdr.Text = Reading-Text; Rebuild-ChartData $script:popupChart '' } catch {} }
        if ($script:trendForm -and -not $script:trendForm.IsDisposed) {
            try {
                Rebuild-ChartData $script:trendChart ("LYWSD02   -   " + (Reading-Text))
                if ($script:trendCo2Chart) { Rebuild-Co2Data $script:trendCo2Chart '' }
            } catch {}
        }
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

$script:popup = New-Object NoActivatePopup
$script:popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$script:popup.ControlBox      = $false
$script:popup.ShowInTaskbar   = $false
$script:popup.TopMost         = $true
$script:popup.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
$script:popup.Size            = New-Object System.Drawing.Size(440,260)
$script:popup.BackColor       = [System.Drawing.Color]::FromArgb(24,24,28)
$script:popupChart = New-TrendChart $true
$script:popupChart.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:popupHdr = New-Object System.Windows.Forms.Label
$script:popupHdr.Dock = [System.Windows.Forms.DockStyle]::Top
$script:popupHdr.Height = 28
$script:popupHdr.ForeColor = [System.Drawing.Color]::White
$script:popupHdr.BackColor = [System.Drawing.Color]::FromArgb(24,24,28)
$script:popupHdr.Font = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
$script:popupHdr.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$script:popup.Controls.Add($script:popupChart)   # Fill added first
$script:popup.Controls.Add($script:popupHdr)     # Top added last
# Force handle + layout once, offscreen, so the first hover paints correctly.
$script:popup.Location = New-Object System.Drawing.Point(-4000,-4000)
$script:popup.Show(); $script:popup.Hide()
# Clicking anywhere on the hover popup opens the full, resizable trends window.
$popupClick = { Hide-Popup; Show-TrendsWindow }
$script:popup.Add_Click($popupClick)
$script:popupChart.Add_Click($popupClick)
$script:popupHdr.Add_Click($popupClick)

function Show-Popup {
    param([int]$cx,[int]$cy)
    try {
        $script:popupHdr.Text = Reading-Text
        Rebuild-ChartData $script:popupChart ''
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

function Show-TrendsWindow {
    try {
        if ($script:trendForm -and -not $script:trendForm.IsDisposed) {
            Rebuild-ChartData $script:trendChart ("LYWSD02 (clock)   -   " + (Reading-Text))
            if ($script:trendCo2Chart) { Rebuild-Co2Data $script:trendCo2Chart 'Aranet4 (air quality)' }
            $script:trendForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $script:trendForm.Activate(); return
        }
        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'Environment trends  -  LYWSD02 clock + Aranet4'
        $f.Size = New-Object System.Drawing.Size(920,640)
        $f.MinimumSize = New-Object System.Drawing.Size(580,420)
        $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $f.BackColor = [System.Drawing.Color]::FromArgb(24,24,28)
        $fg = [System.Drawing.Color]::FromArgb(225,225,225)
        # Two devices, two stacked charts: LYWSD02 (top) and Aranet4 (bottom).
        $envChart = New-TrendChart $false; $envChart.Dock = [System.Windows.Forms.DockStyle]::Fill
        $co2Chart = New-Co2Chart  $false; $co2Chart.Dock = [System.Windows.Forms.DockStyle]::Fill
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

# ---- Menu handlers --------------------------------------------------------
$miRead.Add_Click({ Start-Bg -Kind 'read' -LogCsv $true -Notify $true })
$miReadAranet.Add_Click({ Ensure-AranetWatcher; Sample-Aranet -LogCsv $true -Notify $true })
$miSync.Add_Click({ Start-Bg -Kind 'sync' -LogCsv $false -Notify $true })
$miTrends.Add_Click({ Show-TrendsWindow })
$miConn.Add_Click({
    $script:settings.ConnectionEnabled = -not $script:settings.ConnectionEnabled
    Save-Settings
    if ($script:settings.ConnectionEnabled) {
        $script:clockDue = Get-Date; $script:aranetDue = (Get-Date).AddSeconds(20)   # read clock soon, sample Aranet shortly after
        Update-Icon $script:lastText $false
        Ensure-AranetWatcher
        Scheduler-Tick
        $script:ni.ShowBalloonTip(3000,'LYWSD02','Bluetooth connection enabled.',[System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        Stop-AranetWatcher
        Update-Icon $script:lastText $true
        $script:ni.Text = 'LYWSD02  -  connection off (battery saver)'
        $script:ni.ShowBalloonTip(3000,'LYWSD02','Bluetooth connection disabled to save battery.',[System.Windows.Forms.ToolTipIcon]::Info)
    }
    Refresh-Menu
})
$miLog.Add_Click({ $script:settings.HourlyLogging = -not $script:settings.HourlyLogging; Save-Settings; Refresh-Menu })
$miAranet.Add_Click({
    $script:settings.AranetEnabled = -not $script:settings.AranetEnabled
    Save-Settings; Refresh-Menu
    if ($script:settings.AranetEnabled) {
        if ($script:settings.ConnectionEnabled) { Ensure-AranetWatcher; $script:aranetDue = (Get-Date).AddSeconds(20) }
    } else {
        Stop-AranetWatcher
    }
})
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
$script:ni.Add_MouseDoubleClick({ Show-TrendsWindow })
$menu.Add_Opening({ Hide-Popup })

Refresh-Menu
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
