<#
.SYNOPSIS
    Registers (or removes) a Windows Scheduled Task that runs Sync-LYWSD02.ps1
    on a schedule, so your Xiaomi LYWSD02 clock stays in sync automatically.

.PARAMETER Time
    Time of day to run, HH:mm 24h. Default "08:00".

.PARAMETER Interval
    Daily or Weekly. Default Daily.

.PARAMETER DaysOfWeek
    For -Interval Weekly, which day(s), e.g. "Sunday". Default Sunday.

.PARAMETER Address
    Optional fixed Bluetooth address of your clock (recommended once you know it
    - skips scanning, much faster/more reliable). e.g. "A4:C1:38:AA:BB:CC".

.PARAMETER TimezoneOffset
    Force a fixed timezone offset (hours). Omit to auto-detect this PC's offset
    at each run (DST-aware).

.PARAMETER TaskName
    Scheduled task name. Default "LYWSD02 Clock Sync".

.PARAMETER Uninstall
    Remove the scheduled task instead of creating it.

.EXAMPLE
    .\Install-Schedule.ps1                              # daily 08:00, auto-scan
.EXAMPLE
    .\Install-Schedule.ps1 -Time 06:30 -Address A4:C1:38:AA:BB:CC
.EXAMPLE
    .\Install-Schedule.ps1 -Interval Weekly -DaysOfWeek Sunday -Time 09:00
.EXAMPLE
    .\Install-Schedule.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Time = "08:00",
    [ValidateSet("Daily","Weekly")]
    [string]$Interval = "Daily",
    [string[]]$DaysOfWeek = @("Sunday"),
    [string]$Address,
    [int]$TimezoneOffset,
    [int]$ScanSeconds,
    [string]$TaskName = "LYWSD02 Clock Sync",
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot "Sync-LYWSD02.ps1"

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Yellow
    } else {
        Write-Host "No scheduled task named '$TaskName' found."
    }
    return
}

if (-not (Test-Path $scriptPath)) { throw "Cannot find Sync-LYWSD02.ps1 next to this installer." }

# Build the argument string passed to the sync script
$argList = @("-FromScheduler")
if ($Address)        { $argList += "-Address `"$Address`"" }
if ($PSBoundParameters.ContainsKey('TimezoneOffset')) { $argList += "-TimezoneOffset $TimezoneOffset" }
if ($PSBoundParameters.ContainsKey('ScanSeconds'))    { $argList += "-ScanSeconds $ScanSeconds" }
$scriptArgs = $argList -join ' '

$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" $scriptArgs"
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $psArgs

$at = [DateTime]::ParseExact($Time, "HH:mm", $null)
if ($Interval -eq "Daily") {
    $trigger = New-ScheduledTaskTrigger -Daily -At $at
} else {
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DaysOfWeek -At $at
}

# Run in the user's session (BLE needs an interactive user context), whether or
# not on AC power, and retry if the clock happens to be out of range.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

$desc = "Synchronises the Xiaomi LYWSD02 BLE clock time. Runs $Interval at $Time."

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Description $desc -Force | Out-Null

Write-Host "Installed scheduled task '$TaskName'." -ForegroundColor Green
Write-Host "  Runs:    $Interval at $Time$(if($Interval -eq 'Weekly'){' on ' + ($DaysOfWeek -join ', ')})"
Write-Host "  Command: powershell.exe $psArgs"
Write-Host ""
Write-Host "Run it now to test:  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "View log:            Get-Content '$(Join-Path $PSScriptRoot 'logs\sync.log')' -Tail 20"
Write-Host "Remove it later:     .\Install-Schedule.ps1 -Uninstall"
