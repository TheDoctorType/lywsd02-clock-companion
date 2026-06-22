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
    # Left axis = Temperature + Dew point (deg C), colour-coded orange. Auto-fit to
    # the data range (don't force 0) so the variation is visible.
    $area.AxisY.LabelStyle.ForeColor = $cTemp; $area.AxisY.LineColor = $cTemp; $area.AxisY.MajorGrid.LineColor = $grid
    $area.AxisY.IsStartedFromZero = $false
    # Right axis = Humidity, colour-coded green. Also auto-fit. (Colour-coded axes
    # + point markers keep it distinct from the temperature line.)
    $area.AxisY2.Enabled = [System.Windows.Forms.DataVisualization.Charting.AxisEnabled]::True
    $area.AxisY2.IsStartedFromZero = $false
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
    # Auto-fit to the data range instead of forcing 0 (CO2 never gets near 0, and
    # pressure barely moves) so both series spread out vertically.
    $area.AxisY.IsStartedFromZero = $false
    $area.AxisY2.Enabled = [System.Windows.Forms.DataVisualization.Charting.AxisEnabled]::True
    $area.AxisY2.IsStartedFromZero = $false
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
        if ($script:popupShown) { try { $script:popupHdr.Text = Reading-Text; Rebuild-ChartData $script:popupChart '' } catch {} }
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
        if ($c) { try { $c.ChartAreas['main'].AxisX.ScaleView.ZoomReset(0) } catch {} }
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
$script:DashTheme = @{
    Bg     = [System.Drawing.Color]::FromArgb(18,19,24)
    Card   = [System.Drawing.Color]::FromArgb(31,34,42)
    Card2  = [System.Drawing.Color]::FromArgb(42,46,56)
    Border = [System.Drawing.Color]::FromArgb(50,54,64)
    Text   = [System.Drawing.Color]::FromArgb(234,236,242)
    Muted  = [System.Drawing.Color]::FromArgb(140,146,162)
    Temp   = [System.Drawing.Color]::FromArgb(255,122,89)
    Hum    = [System.Drawing.Color]::FromArgb(72,199,142)
    Dew    = [System.Drawing.Color]::FromArgb(86,180,239)
    Co2    = [System.Drawing.Color]::FromArgb(232,176,64)
    Pres   = [System.Drawing.Color]::FromArgb(167,139,238)
    Batt   = [System.Drawing.Color]::FromArgb(120,200,210)
    Good   = [System.Drawing.Color]::FromArgb(72,199,142)
    Warn   = [System.Drawing.Color]::FromArgb(232,176,64)
    Bad    = [System.Drawing.Color]::FromArgb(232,98,98)
    Accent = [System.Drawing.Color]::FromArgb(96,140,250)
}
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
# A rounded card: a panel that paints a rounded filled rect (anti-aliased).
function New-Card([int]$w, [int]$h, $color) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size($w, $h)
    $p.BackColor = $script:DashTheme.Bg
    $p.Tag = @{ Color = $color; Radius = 14 }
    $p.Add_Paint({
        param($s, $e)
        $c = $this
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $br = New-Object System.Drawing.SolidBrush $c.Tag.Color
        $w = [int]$c.Width; $h = [int]$c.Height
        Fill-Round $e.Graphics $br (New-Object System.Drawing.Rectangle(0, 0, ($w - 1), ($h - 1))) $c.Tag.Radius
        $br.Dispose()
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
    try { $g.Clear($panel.Parent.Tag.Color) } catch { $g.Clear($script:DashTheme.Card) }
    $pw = [int]$panel.Width; $ph = [int]$panel.Height
    $track = if ($on) { $script:DashTheme.Good } else { [System.Drawing.Color]::FromArgb(74,78,90) }
    $br = New-Object System.Drawing.SolidBrush $track
    Fill-Round $g $br (New-Object System.Drawing.Rectangle(0, 0, ($pw - 1), ($ph - 1))) ([int]($ph/2))
    $br.Dispose()
    $kd = $ph - 8
    $kx = if ($on) { $pw - $kd - 4 } else { 4 }
    $g.FillEllipse([System.Drawing.Brushes]::White, $kx, 4, $kd, $kd)
}
# A metric tile. Returns @{ Card; Value; Sub; Pill }.
function New-MetricTile($title, $accent) {
    $card = New-Card 170 128 $script:DashTheme.Card
    $cc = $script:DashTheme.Card
    $lt = New-Lbl $title (DashFont 10) $script:DashTheme.Muted $cc 18 16
    $lv = New-Lbl '--' (DashFont 28 'Bold') $accent $cc 16 40
    $ls = New-Lbl '' (DashFont 8.5) $script:DashTheme.Muted $cc 18 92
    $card.Controls.Add($lt); $card.Controls.Add($lv); $card.Controls.Add($ls)
    # status pill (used by CO2 tile)
    $pill = New-Object System.Windows.Forms.Label
    $pill.AutoSize = $false; $pill.Size = New-Object System.Drawing.Size(60, 20)
    $pill.Location = New-Object System.Drawing.Point(96, 16); $pill.TextAlign = 'MiddleCenter'
    $pill.Font = DashFont 8 'Bold'; $pill.ForeColor = [System.Drawing.Color]::White; $pill.BackColor = $cc
    $pill.Visible = $false
    $card.Controls.Add($pill)
    return @{ Card = $card; Value = $lv; Sub = $ls; Pill = $pill }
}
function Restyle-Seg($btns, $current, $accent) {
    foreach ($b in $btns) {
        if ([int]$b.Tag -eq [int]$current) { $b.BackColor = $accent; $b.ForeColor = [System.Drawing.Color]::White }
        else { $b.BackColor = $script:DashTheme.Card2; $b.ForeColor = $script:DashTheme.Muted }
    }
}
function New-DashButton($text, $accent) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Font = DashFont 9.5 'Bold'; $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0; $b.BackColor = $accent; $b.ForeColor = [System.Drawing.Color]::White
    $b.Size = New-Object System.Drawing.Size(150, 38); $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

function Update-Dash-Controls {
    if (-not ($script:dash -and $script:dash.Form -and -not $script:dash.Form.IsDisposed)) { return }
    foreach ($t in @($script:dash.ConnTog, $script:dash.AranetTog, $script:dash.LogTog, $script:dash.StartupTog)) { if ($t) { $t.Invalidate() } }
    Restyle-Seg $script:dash.ClockBtns ([int]$script:settings.IntervalMinutes) $script:DashTheme.Temp
    Restyle-Seg $script:dash.AranetBtns ([int]$script:settings.AranetIntervalMinutes) $script:DashTheme.Co2
}

function Refresh-Dashboard {
    if (-not ($script:dash -and $script:dash.Form -and -not $script:dash.Form.IsDisposed)) { return }
    $T = $script:DashTheme
    $deg = [char]0x00B0; $dot = [char]0x00B7   # avoid literal non-ASCII (PS 5.1 misreads it)
    $r = $script:lastReading; $a = $script:lastAranet
    # CO2 + pressure (Aranet)
    if ($a) {
        $col = switch ($a.Status) { 'green' { $T.Good } 'amber' { $T.Warn } 'red' { $T.Bad } default { $T.Co2 } }
        $script:dash.Tiles.co2.Value.Text = "$([int]$a.Co2)"
        $script:dash.Tiles.co2.Value.ForeColor = $col
        $script:dash.Tiles.co2.Sub.Text = "ppm   $dot   $($a.When.ToString('HH:mm'))"
        $script:dash.Tiles.co2.Pill.Visible = $true
        $script:dash.Tiles.co2.Pill.Text = (@{green='GOOD';amber='FAIR';red='POOR'}[$a.Status])
        $script:dash.Tiles.co2.Pill.BackColor = $col
        $script:dash.Tiles.pres.Value.Text = ("{0:0.0}" -f $a.Pres)
        $script:dash.Tiles.pres.Sub.Text = "hPa   $dot   Aranet4"
    }
    # Temp / humidity / dew (LYWSD02)
    if ($r) {
        $script:dash.Tiles.temp.Value.Text = ("{0:0.0}$deg" -f $r.TempC)
        $script:dash.Tiles.temp.Sub.Text = "$($deg)C   $dot   LYWSD02   $dot   $($r.When.ToString('HH:mm'))"
        $script:dash.Tiles.hum.Value.Text = ("{0}%" -f [int]$r.Humidity)
        $script:dash.Tiles.hum.Sub.Text = "humidity   $dot   LYWSD02"
        $dew = Get-Dewpoint $r.TempC $r.Humidity
        $script:dash.Tiles.dew.Value.Text = ("{0:0.0}$deg" -f $dew)
        $script:dash.Tiles.dew.Sub.Text = "dew point   $dot   $($deg)C"
    }
    # Battery (both)
    $cb = if ($r -and $null -ne $r.Battery) { [int]$r.Battery } else { $null }
    $ab = if ($a -and $null -ne $a.Battery) { [int]$a.Battery } else { $null }
    if ($null -ne $cb) {
        $script:dash.Tiles.batt.Value.Text = "$cb%"
        $bc = if ($cb -lt 15) { $T.Bad } elseif ($cb -lt 35) { $T.Warn } else { $T.Good }
        $script:dash.Tiles.batt.Value.ForeColor = $bc
    }
    $abTxt = if ($null -ne $ab) { "$ab%" } else { '--' }
    $script:dash.Tiles.batt.Sub.Text = "LYWSD02   $dot   Aranet $abTxt"
    # Header status + time
    if ($script:settings.ConnectionEnabled) {
        $script:dash.Status.Text = '  Live'; $script:dash.Status.ForeColor = $T.Good
    } else {
        $script:dash.Status.Text = '  Paused'; $script:dash.Status.ForeColor = $T.Muted
    }
    $script:dash.Updated.Text = "updated $(Get-Date -Format 'HH:mm:ss')"
    Rebuild-Both
}

function Show-Dashboard {
    try {
        if ($script:dash -and $script:dash.Form -and -not $script:dash.Form.IsDisposed) {
            $script:dash.Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $script:dash.Form.Activate(); Refresh-Dashboard; return
        }
        $T = $script:DashTheme
        $script:dash = @{ Tiles = @{}; ClockBtns = @(); AranetBtns = @() }

        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'Sensor Dashboard'
        $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $f.Size = New-Object System.Drawing.Size(1180, 820)
        $f.MinimumSize = New-Object System.Drawing.Size(560, 480)
        $f.BackColor = $T.Bg
        $f.Font = DashFont 9
        try { $f.Icon = [System.Drawing.Icon]::FromHandle($script:iconHandle) } catch {}

        # Scrollable canvas (both directions). Content has a fixed design width so a
        # horizontal scrollbar appears when the window is narrower.
        $scroll = New-Object System.Windows.Forms.Panel
        $scroll.Dock = [System.Windows.Forms.DockStyle]::Fill
        $scroll.AutoScroll = $true
        $scroll.BackColor = $T.Bg
        $f.Controls.Add($scroll)
        $content = New-Object System.Windows.Forms.Panel
        $content.Size = New-Object System.Drawing.Size(1120, 1230)
        $content.BackColor = $T.Bg
        $scroll.Controls.Add($content)

        $L = 24   # left margin
        $W = 1072 # content inner width

        # ---- Header ----
        $content.Controls.Add((New-Lbl 'Sensor Dashboard' (DashFont 19 'Bold') $T.Text $T.Bg $L 20))
        $script:dash.Status = New-Lbl '  Live' (DashFont 11 'Bold') $T.Good $T.Bg ($L + 220) 28
        $content.Controls.Add($script:dash.Status)
        $script:dash.Updated = New-Lbl '' (DashFont 9) $T.Muted $T.Bg ($L + 330) 31
        $content.Controls.Add($script:dash.Updated)

        # ---- Metric tiles ----
        $content.Controls.Add((New-Lbl 'NOW' (DashFont 9 'Bold') $T.Muted $T.Bg $L 66))
        $tileDefs = @(
            @{ Key='co2';  Title='CO2';         Accent=$T.Co2 },
            @{ Key='temp'; Title='Temperature'; Accent=$T.Temp },
            @{ Key='hum';  Title='Humidity';    Accent=$T.Hum },
            @{ Key='dew';  Title='Dew point';   Accent=$T.Dew },
            @{ Key='pres'; Title='Pressure';    Accent=$T.Pres },
            @{ Key='batt'; Title='Battery';     Accent=$T.Batt }
        )
        $tx = $L; $ty = 90
        foreach ($d in $tileDefs) {
            $tile = New-MetricTile $d.Title $d.Accent
            $tile.Card.Location = New-Object System.Drawing.Point($tx, $ty)
            $content.Controls.Add($tile.Card)
            $script:dash.Tiles[$d.Key] = $tile
            $tx += 184
        }

        # ---- Trends ----
        $content.Controls.Add((New-Lbl 'TRENDS' (DashFont 9 'Bold') $T.Muted $T.Bg $L 238))
        # range selector (owner-drawn dark combo)
        $script:cbRange = New-Object System.Windows.Forms.ComboBox
        $script:cbRange.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
        $script:cbRange.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $script:cbRange.BackColor = $T.Card2; $script:cbRange.ForeColor = $T.Text
        $script:cbRange.Width = 150; $script:cbRange.Location = New-Object System.Drawing.Point(($L + $W - 150), 232)
        $script:cbRange.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
        $script:cbRange.Add_DrawItem({
            param($s, $e)
            $sel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
            $bg = if ($sel) { $script:DashTheme.Accent } else { $script:DashTheme.Card2 }
            $bb = New-Object System.Drawing.SolidBrush $bg; $e.Graphics.FillRectangle($bb, $e.Bounds); $bb.Dispose()
            if ($e.Index -ge 0) {
                $tb = New-Object System.Drawing.SolidBrush $script:DashTheme.Text
                $e.Graphics.DrawString([string]$this.Items[$e.Index], $this.Font, $tb, $e.Bounds.X + 4, $e.Bounds.Y + 2); $tb.Dispose()
            }
        })
        foreach ($k in $script:RangeMap.Keys) { [void]$script:cbRange.Items.Add($k) }
        $curCode = $script:settings.TrendRange; if (-not $curCode) { $curCode = '7d' }
        $curLabel = ($script:RangeMap.GetEnumerator() | Where-Object { $_.Value -eq $curCode } | Select-Object -First 1).Key
        if (-not $curLabel) { $curLabel = 'Last 7 days' }
        $script:cbRange.SelectedItem = $curLabel
        $content.Controls.Add($script:cbRange)

        $envChart = New-TrendChart $false; $co2Chart = New-Co2Chart $false
        foreach ($c in @($envChart, $co2Chart)) {
            $c.Width = $W; $c.Height = 252
            $c.Add_MouseEnter({ try { $this.Focus() } catch {} })
            $c.Add_MouseWheel($script:OnChartWheel)
        }
        $envChart.Location = New-Object System.Drawing.Point($L, 264)
        $co2Chart.Location = New-Object System.Drawing.Point($L, 524)
        $content.Controls.Add($envChart); $content.Controls.Add($co2Chart)
        $script:trendChart = $envChart; $script:trendCo2Chart = $co2Chart

        $script:cbRange.Add_SelectedIndexChanged({
            try {
                $sel = $script:cbRange.SelectedItem; if (-not $sel) { return }
                $code = $script:RangeMap[[string]$sel]; if (-not $code) { return }
                $script:settings.TrendRange = $code; Save-Settings
                Rebuild-Both; Zoom-Reset
            } catch {}
        })

        # ---- Controls ----
        $cy = 792
        $content.Controls.Add((New-Lbl 'CONTROLS' (DashFont 9 'Bold') $T.Muted $T.Bg $L $cy))
        $cy += 26

        # Toggle cards (2x2 grid)
        function New-ToggleCard($title, $desc, $togRef) {
            $card = New-Card 524 70 $T.Card
            $card.Controls.Add((New-Lbl $title (DashFont 11 'Bold') $T.Text $T.Card 18 14))
            $card.Controls.Add((New-Lbl $desc (DashFont 8.5) $T.Muted $T.Card 18 40))
            $tog = New-Object System.Windows.Forms.Panel
            $tog.Size = New-Object System.Drawing.Size(50, 26)
            $tog.Location = New-Object System.Drawing.Point(456, 22)
            $tog.BackColor = $T.Card; $tog.Cursor = [System.Windows.Forms.Cursors]::Hand
            $card.Controls.Add($tog)
            return @{ Card = $card; Tog = $tog }
        }

        $tcConn = New-ToggleCard 'Bluetooth connection' 'Master switch for all sensor reads' $null
        $tcConn.Card.Location = New-Object System.Drawing.Point($L, $cy)
        $script:dash.ConnTog = $tcConn.Tog
        $tcConn.Tog.Add_Paint({ param($s,$e); Draw-Toggle $e.Graphics $this ([bool]$script:settings.ConnectionEnabled) })
        $tcConn.Tog.Add_Click({ Toggle-Connection })
        $content.Controls.Add($tcConn.Card)

        $tcAranet = New-ToggleCard 'Track Aranet4 (CO2)' 'Listen for air-quality broadcasts' $null
        $tcAranet.Card.Location = New-Object System.Drawing.Point(($L + 548), $cy)
        $script:dash.AranetTog = $tcAranet.Tog
        $tcAranet.Tog.Add_Paint({ param($s,$e); Draw-Toggle $e.Graphics $this ([bool]$script:settings.AranetEnabled) })
        $tcAranet.Tog.Add_Click({ Toggle-Aranet })
        $content.Controls.Add($tcAranet.Card)
        $cy += 84

        $tcLog = New-ToggleCard 'Log to CSV' 'Record history to logs\*.csv' $null
        $tcLog.Card.Location = New-Object System.Drawing.Point($L, $cy)
        $script:dash.LogTog = $tcLog.Tog
        $tcLog.Tog.Add_Paint({ param($s,$e); Draw-Toggle $e.Graphics $this ([bool]$script:settings.HourlyLogging) })
        $tcLog.Tog.Add_Click({ $script:settings.HourlyLogging = -not $script:settings.HourlyLogging; Save-Settings; $script:dash.LogTog.Invalidate(); Refresh-Menu })
        $content.Controls.Add($tcLog.Card)

        $tcStart = New-ToggleCard 'Start at login' 'Launch the widget when you sign in' $null
        $tcStart.Card.Location = New-Object System.Drawing.Point(($L + 548), $cy)
        $script:dash.StartupTog = $tcStart.Tog
        $tcStart.Tog.Add_Paint({ param($s,$e); Draw-Toggle $e.Graphics $this ([bool](Test-Startup)) })
        $tcStart.Tog.Add_Click({ Set-Startup (-not (Test-Startup)); $script:dash.StartupTog.Invalidate(); Refresh-Menu })
        $content.Controls.Add($tcStart.Card)
        $cy += 84

        # Interval selectors (segmented)
        function New-IntervalCard($title, $unit, $options, $accent, $current) {
            $card = New-Card 524 78 $T.Card
            $card.Controls.Add((New-Lbl $title (DashFont 11 'Bold') $T.Text $T.Card 18 14))
            $btns = @()
            $bx = 18
            foreach ($o in $options) {
                $b = New-Object System.Windows.Forms.Button
                $b.Text = "$o"; $b.Tag = $o; $b.Font = DashFont 8.5 'Bold'
                $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat; $b.FlatAppearance.BorderSize = 0
                $b.Size = New-Object System.Drawing.Size(46, 30); $b.Location = New-Object System.Drawing.Point($bx, 40)
                $b.Cursor = [System.Windows.Forms.Cursors]::Hand
                $card.Controls.Add($b); $btns += $b; $bx += 50
            }
            $card.Controls.Add((New-Lbl $unit (DashFont 8.5) $T.Muted $T.Card $bx 50))
            Restyle-Seg $btns $current $accent
            return @{ Card = $card; Btns = $btns }
        }

        $icClock = New-IntervalCard 'Clock read interval' 'minutes' @(5,10,15,30,60) $T.Temp ([int]$script:settings.IntervalMinutes)
        $icClock.Card.Location = New-Object System.Drawing.Point($L, $cy)
        $script:dash.ClockBtns = $icClock.Btns
        foreach ($b in $icClock.Btns) { $b.Add_Click({ param($s,$e); $script:settings.IntervalMinutes = [int]$s.Tag; $script:clockDue = Get-Date; Save-Settings; Update-Dash-Controls; Refresh-Menu }) }
        $content.Controls.Add($icClock.Card)

        $icAranet = New-IntervalCard 'Aranet4 read interval' 'minutes' @(1,2,3,5,10,15,30) $T.Co2 ([int]$script:settings.AranetIntervalMinutes)
        $icAranet.Card.Location = New-Object System.Drawing.Point(($L + 548), $cy)
        $script:dash.AranetBtns = $icAranet.Btns
        foreach ($b in $icAranet.Btns) { $b.Add_Click({ param($s,$e); $script:settings.AranetIntervalMinutes = [int]$s.Tag; $script:aranetDue = Get-Date; Save-Settings; Update-Dash-Controls; Refresh-Menu }) }
        $content.Controls.Add($icAranet.Card)
        $cy += 92

        # Action buttons
        $bSync = New-DashButton 'Sync clock' $T.Accent
        $bSync.Location = New-Object System.Drawing.Point($L, $cy); $bSync.Add_Click({ Start-Bg -Kind 'sync' -LogCsv $false -Notify $true })
        $bReadC = New-DashButton 'Read clock' $T.Card2
        $bReadC.Location = New-Object System.Drawing.Point(($L + 162), $cy); $bReadC.Add_Click({ Start-Bg -Kind 'read' -LogCsv $true -Notify $true })
        $bReadA = New-DashButton 'Read Aranet4' $T.Card2
        $bReadA.Location = New-Object System.Drawing.Point(($L + 324), $cy); $bReadA.Add_Click({ Ensure-AranetWatcher; Sample-Aranet -LogCsv $true -Notify $true; Refresh-Dashboard })
        $bData = New-DashButton 'Open data folder' $T.Card2
        $bData.Location = New-Object System.Drawing.Point(($L + 486), $cy); $bData.Add_Click({ Start-Process explorer.exe $LogDir })
        $content.Controls.Add($bSync); $content.Controls.Add($bReadC); $content.Controls.Add($bReadA); $content.Controls.Add($bData)

        $script:dash.Form = $f
        $f.Add_FormClosed({ $script:dash = $null; $script:trendChart = $null; $script:trendCo2Chart = $null })
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
