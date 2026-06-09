<#
.SYNOPSIS
    Persistent background listener for the Aranet4. Runs a single continuous BLE
    advertisement watcher and writes the latest CO2/temp/humidity/pressure reading
    to logs\aranet-latest.json every time the device broadcasts one.

.DESCRIPTION
    The Aranet broadcasts a measurement packet only intermittently (~once a minute,
    with occasional multi-minute gaps), so repeated short scans miss it. A single
    long-lived watcher captures each packet whenever it appears. The tray widget
    launches this once and just samples the JSON file on its own schedule.

    Runs until the process is killed. Single-instance via a named mutex.
#>
[CmdletBinding()]
param([string]$OutPath)
$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogDir = Join-Path $ScriptDir 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
if (-not $OutPath) { $OutPath = Join-Path $LogDir 'aranet-latest.json' }
$LogPath = Join-Path $LogDir 'aranet.log'
function WLog($m){ try { Add-Content -Path $LogPath -Value ("{0} [WATCH] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch {} }

# Single instance.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'LYWSD02_Aranet_Watcher_Mutex', [ref]$createdNew)
if (-not $createdNew) { WLog 'Another watcher already running; exiting.'; return }

function Resolve-References {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
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
    public static void Begin(string outPath) {
        OutPath = outPath;
        W = new BluetoothLEAdvertisementWatcher();
        W.ScanningMode = BluetoothLEScanningMode.Active;
        W.Received += OnRecv;
        W.Start();
    }
    static void OnRecv(BluetoothLEAdvertisementWatcher s, BluetoothLEAdvertisementReceivedEventArgs e) {
        foreach (var m in e.Advertisement.ManufacturerData) {
            if (m.CompanyId != 0x0702) continue;
            var r = DataReader.FromBuffer(m.Data);
            var b = new byte[m.Data.Length]; r.ReadBytes(b);
            if (b.Length < 16 || (b[0] & 0x20) == 0) continue;
            int o = 8;
            int co2 = b[o] | (b[o+1] << 8);
            double temp = (b[o+2] | (b[o+3] << 8)) / 20.0;
            double pres = (b[o+4] | (b[o+5] << 8)) / 10.0;
            int hum = b[o+6]; int bat = b[o+7]; int st = b[o+8];
            if (co2 < 0 || co2 > 60000 || temp < -40 || temp > 85 || hum > 100 || pres < 300 || pres > 1200) continue;
            string status = st == 1 ? "green" : st == 2 ? "amber" : st == 3 ? "red" : ("status" + st);
            string ts = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            var ci = CultureInfo.InvariantCulture;
            string json = "{\"ok\":true,\"co2\":" + co2 +
                ",\"tempC\":" + temp.ToString("0.0", ci) +
                ",\"humidity\":" + hum +
                ",\"pressure\":" + pres.ToString("0.0", ci) +
                ",\"battery\":" + bat +
                ",\"status\":\"" + status + "\",\"ts\":\"" + ts + "\"}";
            try { File.WriteAllText(OutPath, json); Count++; } catch {}
        }
    }
}
'@

try {
    $cp = New-Object System.CodeDom.Compiler.CompilerParameters
    foreach ($r in (Resolve-References)) { [void]$cp.ReferencedAssemblies.Add($r) }
    Add-Type -TypeDefinition $csharp -CompilerParameters $cp -ErrorAction Stop
    [AranetWatch]::Begin($OutPath)
    WLog "Watcher started; writing latest readings to $OutPath"
    # Keep the process alive; the C# Received handler runs on background threads.
    while ($true) { Start-Sleep -Seconds 300; WLog "alive (packets captured: $([AranetWatch]::Count))" }
}
catch {
    WLog "ERROR: $($_.Exception.Message)"
    exit 1
}
