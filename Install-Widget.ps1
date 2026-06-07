<#
.SYNOPSIS
    Installs (or removes) the LYWSD02 system-tray widget: writes settings.json,
    adds a Startup shortcut so it launches at login, and starts it now.

.PARAMETER Address
    Bluetooth address of your clock, e.g. "E7:2E:01:92:C1:1F". Recommended.

.PARAMETER IntervalMinutes
    How often to read + log temperature/humidity. Default 60 (hourly).

.PARAMETER ScanSeconds
    BLE scan window per read. Default 90 (the clock advertises intermittently).

.PARAMETER NoStartup
    Don't add the login Startup shortcut (just configure + run once).

.PARAMETER Uninstall
    Stop the widget, remove the Startup shortcut. Leaves settings.json and CSV.

.EXAMPLE
    .\Install-Widget.ps1 -Address E7:2E:01:92:C1:1F
.EXAMPLE
    .\Install-Widget.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Address,
    [int]$IntervalMinutes = 60,
    [int]$ScanSeconds = 90,
    [switch]$NoStartup,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$settingsPath = Join-Path $dir 'settings.json'
$vbs = Join-Path $dir 'Start-Widget.vbs'
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'LYWSD02 Widget.lnk'

function Stop-Widget {
    # Kill any running tray instance (a powershell launched with -File ...Tray-LYWSD02.ps1).
    # Require '-File' (real launches use it) and exclude our own PID so a caller whose
    # command line merely mentions the script name can't be killed by accident.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*-File*Tray-LYWSD02.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
}

if ($Uninstall) {
    Stop-Widget
    if (Test-Path $startupLnk) { Remove-Item $startupLnk -Force; Write-Host "Removed Startup shortcut." -ForegroundColor Yellow }
    Write-Host "Widget stopped and startup disabled. (settings.json and logs kept.)"
    return
}

# Merge/update settings.json
$settings = [ordered]@{
    Address           = $Address
    DeviceName        = 'LYWSD02'
    ScanSeconds       = $ScanSeconds
    IntervalMinutes   = $IntervalMinutes
    ConnectionEnabled = $true
    HourlyLogging     = $true
    TrendRange        = '7d'
    TrendFrom         = ''
    TrendTo           = ''
}
if (Test-Path $settingsPath) {
    try {
        $old = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if (-not $Address -and $old.Address) { $settings.Address = $old.Address }
        if ($null -ne $old.ConnectionEnabled) { $settings.ConnectionEnabled = [bool]$old.ConnectionEnabled }
        if ($null -ne $old.HourlyLogging)     { $settings.HourlyLogging = [bool]$old.HourlyLogging }
        if ($old.TrendRange) { $settings.TrendRange = $old.TrendRange }
        if ($old.TrendFrom)  { $settings.TrendFrom  = $old.TrendFrom }
        if ($old.TrendTo)    { $settings.TrendTo    = $old.TrendTo }
    } catch {}
}
($settings | ConvertTo-Json) | Set-Content -Path $settingsPath -Encoding UTF8
Write-Host "Wrote settings: $settingsPath" -ForegroundColor Green
Write-Host ("  Address={0}  Interval={1}m  Scan={2}s" -f ($(if($settings.Address){$settings.Address}else{'(scan by name)'})), $settings.IntervalMinutes, $settings.ScanSeconds)

# Startup shortcut
if (-not $NoStartup) {
    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($startupLnk)
    $sc.TargetPath = $vbs
    $sc.WorkingDirectory = $dir
    $sc.Description = 'LYWSD02 tray widget'
    $sc.Save()
    Write-Host "Added Startup shortcut: $startupLnk" -ForegroundColor Green
}

# (Re)start it now
Stop-Widget
Start-Sleep -Milliseconds 400
Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$vbs`""
Write-Host "Widget launched. Look for the temperature icon in the system tray (click the ^ to find it, then drag it onto the taskbar)." -ForegroundColor Cyan
Write-Host "Remove later with:  .\Install-Widget.ps1 -Uninstall"
