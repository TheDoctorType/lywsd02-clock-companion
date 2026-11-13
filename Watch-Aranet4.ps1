<#
.SYNOPSIS
    Persistent background listener for the Aranet4. Runs a single continuous BLE
    advertisement watcher and writes the latest CO2/temp/humidity/pressure reading
    to logs\aranet-latest.json every time the device broadcasts one.

.DESCRIPTION
    The Aranet broadcasts a measurement packet only intermittently, so repeated
    short scans miss it. A single long-lived watcher captures each packet whenever
    it appears. The tray widget launches this once and samples the JSON file.

    The widget pauses the scan (without killing this process) while it talks to
    the clock, by setting the named event 'LYWSD02_Aranet_Pause'; the scan resumes
    when the event is cleared, or by itself after four minutes as a safety net.

    Single-instance via a named mutex. Exits on its own when -ParentPid is given
    and that process is gone.
#>
[CmdletBinding()]
param([string]$OutPath, [int]$ParentPid = 0)
$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogDir = Join-Path $ScriptDir 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
if (-not $OutPath) { $OutPath = Join-Path $LogDir 'aranet-latest.json' }
$LogPath = Join-Path $LogDir 'aranet.log'
$PidPath = Join-Path $LogDir 'aranet-watcher.pid'
function WLog($m){ try { Add-Content -Path $LogPath -Value ("{0} [WATCH] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch {} }

# Single instance.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'LYWSD02_Aranet_Watcher_Mutex', [ref]$createdNew)
if (-not $createdNew) { return }
try { Set-Content -Path $PidPath -Value $PID -Encoding ASCII } catch {}

function Resolve-References {
    $gac = Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL'
    function Get-Facade([string]$n) {
        $dll = Get-ChildItem (Join-Path $gac $n) -Recurse -Filter "$n.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $dll) { throw "Facade '$n' not found." }
        $dll.FullName
    }
    $refs = @((Get-Facade 'System.Runtime'),(Get-Facade 'System.Threading.Tasks'),(Get-Facade 'System.ObjectModel'),(Get-Facade 'System.Runtime.InteropServices.WindowsRuntime'),(Get-Facade 'System.Runtime.WindowsRuntime'))
    $um = 'C:\Program Files (x86)\Windows Kits\10\UnionMetadata'
    $winmd = Get-ChildItem $um -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+\.\d+\.\d+' } |
        Sort-Object { [version]$_.Name } -Descending | ForEach-Object { Join-Path $_.FullName 'Windows.winmd' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $winmd) { throw 'Windows.winmd not found.' }
    $refs + $winmd
}

# The watcher + decode + file-write all happen in compiled C# (WinRT events can't
# be handled from PowerShell directly).
$csharp = @'
using System;
using System.IO;
using System.Globalization;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Storage.Streams;
public static class AranetWatch {
    public static BluetoothLEAdvertisementWatcher W;
    public static string OutPath;
    public static long Count = 0;
    public static void Begin(string outPath) { OutPath = outPath; Resume(); }
    public static void Pause() {
        try { if (W != null) { W.Received -= OnRecv; W.Stop(); } } catch {}
        W = null;
    }
    // A fresh watcher each time: restarting a stopped/aborted one is not reliable.
    public static bool Resume() {
        try {
            if (W != null && W.Status == BluetoothLEAdvertisementWatcherStatus.Started) return true;
            Pause();
            W = new BluetoothLEAdvertisementWatcher();
            W.ScanningMode = BluetoothLEScanningMode.Active;
            W.Received += OnRecv;
            W.Start();
            return true;
        } catch { W = null; return false; }
    }
    public static bool Running { get { try { return W != null && W.Status == BluetoothLEAdvertisementWatcherStatus.Started; } catch { return false; } } }
    static void OnRecv(BluetoothLEAdvertisementWatcher s, BluetoothLEAdvertisementReceivedEventArgs e) {
        foreach (var m in e.Advertisement.ManufacturerData) {
            if (m.CompanyId != 0x0702) continue;
            var r = DataReader.FromBuffer(m.Data);
            var b = new byte[m.Data.Length]; r.ReadBytes(b);
            if (b.Length < 17 || (b[0] & 0x20) == 0) continue;
            int o = 8;
            int co2 = b[o] | (b[o+1] << 8);
            double temp = (b[o+2] | (b[o+3] << 8)) / 20.0;
            double pres = (b[o+4] | (b[o+5] << 8)) / 10.0;
            int hum = b[o+6]; int bat = b[o+7]; int st = b[o+8];
            if (co2 < 0 || co2 > 60000 || temp < -40 || temp > 85 || hum > 100 || pres < 300 || pres > 1200) continue;
            // measurement interval and seconds since the measurement was taken; lets
            // the widget stamp each reading with when it was MEASURED, not overheard.
            int interval = -1, age = -1;
            if (b.Length >= o + 13) {
                interval = b[o+9] | (b[o+10] << 8); age = b[o+11] | (b[o+12] << 8);
                if (interval < 30 || interval > 3600 || age < 0 || age > interval + 120) { interval = -1; age = -1; }
            }
            string status = st == 1 ? "green" : st == 2 ? "amber" : st == 3 ? "red" : ("status" + st);
            string ts = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            var ci = CultureInfo.InvariantCulture;
            string json = "{\"ok\":true,\"co2\":" + co2 +
                ",\"tempC\":" + temp.ToString("0.0", ci) +
                ",\"humidity\":" + hum +
                ",\"pressure\":" + pres.ToString("0.0", ci) +
                ",\"battery\":" + bat +
                ",\"interval\":" + interval + ",\"age\":" + age +
                ",\"status\":\"" + status + "\",\"ts\":\"" + ts + "\"}";
            try { File.WriteAllText(OutPath, json); Count++; } catch {}
        }
    }
}
'@

try {
    . (Join-Path $ScriptDir 'Compile-Cache.ps1')
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    $how = Import-CachedAssembly -Name 'aranet-watch' -Source $csharp -CacheDir (Join-Path $LogDir 'cache') -ProbeType 'AranetWatch' -References { Resolve-References }
    [AranetWatch]::Begin($OutPath)
    WLog "Watcher started ($how); writing latest readings to $OutPath"
    $pause = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'LYWSD02_Aranet_Pause')
    $paused = $false; $pausedAt = Get-Date; $lastAlive = Get-Date; $tick = 0
    while ($true) {
        Start-Sleep -Milliseconds 400
        $tick++
        $want = $pause.WaitOne(0)
        if ($want -and $paused -and ((Get-Date) - $pausedAt).TotalSeconds -gt 240) { [void]$pause.Reset(); $want = $false }   # never stay paused
        if ($want -and -not $paused) { [AranetWatch]::Pause(); $paused = $true; $pausedAt = Get-Date }
        elseif (-not $want -and ($paused -or -not [AranetWatch]::Running)) {
            # resume after a pause, or recover if Bluetooth was switched off and back on
            if ($paused -or ($tick % 25) -eq 0) {
                $was = $paused
                if ([AranetWatch]::Resume()) {
                    $paused = $false
                    if ($was) { WLog ("scan resumed after a {0:0} s pause for the clock (packets so far: {1})" -f ((Get-Date) - $pausedAt).TotalSeconds, [AranetWatch]::Count) }
                    else { WLog 'scan restarted (the Bluetooth radio had stopped it)' }
                }
            }
        }
        if ($ParentPid -gt 0 -and ($tick % 12) -eq 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
        if (((Get-Date) - $lastAlive).TotalMinutes -ge 60) { $lastAlive = Get-Date; WLog "alive (packets captured: $([AranetWatch]::Count))" }
    }
    [AranetWatch]::Pause()
}
catch {
    WLog "ERROR: $($_.Exception.Message)"
    exit 1
}
finally {
    try { Remove-Item $PidPath -Force -ErrorAction SilentlyContinue } catch {}
}
