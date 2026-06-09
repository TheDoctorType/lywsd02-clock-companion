<#
.SYNOPSIS
    Reads the current CO2 / temperature / humidity / pressure / battery from a
    nearby Aranet4 air-quality monitor, passively from its BLE advertisement.

.DESCRIPTION
    When "Smart Home Integration" is enabled in the Aranet4 app, the device
    broadcasts its readings in the BLE advertisement manufacturer data
    (company id 0x0702). This reads them with NO pairing and NO connection -
    it just listens for an advertisement that carries measurements.

    Identified by company id 0x0702 (SAF Tehnika), not a fixed address, because
    the Aranet uses a rotating resolvable-private address.

    Payload (measurement-bearing advertisement): 8-byte header (bit 0x20 of byte
    0 set = measurements present), then at offset 8:
      CO2 u16 LE (ppm) | temp u16 LE /20 (C) | pressure u16 LE /10 (hPa)
      | humidity u8 (%) | battery u8 (%) | status u8 | interval u16 | ago u16

.PARAMETER ScanSeconds
    How long to listen for a measurement-bearing advertisement. Default 90.
    (The data advert is only sent every measurement interval, so be generous.)

.PARAMETER Json
    Emit a single machine-readable JSON line instead of the formatted block.

.PARAMETER LogPath
    Log file. Defaults to .\logs\aranet.log next to this script.

.EXAMPLE
    .\Read-Aranet4.ps1
.EXAMPLE
    .\Read-Aranet4.ps1 -Json -ScanSeconds 60
#>
[CmdletBinding()]
param(
    [int]$ScanSeconds = 90,
    [switch]$Json,
    [string]$LogPath
)
$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $LogPath) { $LogPath = Join-Path $ScriptDir 'logs\aranet.log' }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $Json) { Write-Host $line }
    try {
        $d = Split-Path -Parent $LogPath
        if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch {}
}

function Resolve-References {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    $gac = Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL'
    function Get-Facade([string]$n) {
        $dll = Get-ChildItem (Join-Path $gac $n) -Recurse -Filter "$n.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $dll) { throw "Required framework facade '$n' not found in GAC." }
        $dll.FullName
    }
    $refs = @(
        (Get-Facade 'System.Runtime'), (Get-Facade 'System.Threading.Tasks'),
        (Get-Facade 'System.ObjectModel'), (Get-Facade 'System.Runtime.InteropServices.WindowsRuntime'),
        (Get-Facade 'System.Runtime.WindowsRuntime')
    )
    $umRoot = 'C:\Program Files (x86)\Windows Kits\10\UnionMetadata'
    if (-not (Test-Path $umRoot)) { throw "Windows SDK UnionMetadata not found at $umRoot." }
    $winmd = Get-ChildItem $umRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName 'Windows.winmd' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $winmd) { throw "Windows.winmd not found under $umRoot." }
    $refs + $winmd
}

$csharp = @'
using System;
using System.Text;
using System.Threading;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Storage.Streams;

public static class AranetBle {
    // Listen for a measurement-bearing Aranet advertisement (company 0x0702,
    // byte0 bit 0x20 set, length >= 16). Returns "ADDR\tRSSI\tHEX" or "".
    public static string Scan(int seconds) {
        var w = new BluetoothLEAdvertisementWatcher();
        w.ScanningMode = BluetoothLEScanningMode.Active;
        string hex = ""; ulong addr = 0; short rssi = -127;
        var done = new ManualResetEvent(false);
        w.Received += (s, e) => {
            foreach (var m in e.Advertisement.ManufacturerData) {
                if (m.CompanyId != 0x0702) continue;
                var r = DataReader.FromBuffer(m.Data);
                var b = new byte[m.Data.Length]; r.ReadBytes(b);
                if (b.Length >= 16 && (b[0] & 0x20) != 0) {
                    var sb = new StringBuilder();
                    foreach (var x in b) sb.Append(x.ToString("X2"));
                    hex = sb.ToString(); addr = e.BluetoothAddress; rssi = e.RawSignalStrengthInDBm;
                    done.Set();
                }
            }
        };
        w.Start();
        done.WaitOne(TimeSpan.FromSeconds(seconds));
        w.Stop();
        if (hex == "") return "";
        return string.Format("{0:X12}\t{1}\t{2}", addr, rssi, hex);
    }
}
'@

Write-Log "Reading Aranet4 (passive, listening up to ${ScanSeconds}s)..."
try {
    if (-not ([System.Management.Automation.PSTypeName]'AranetBle').Type) {
        $cp = New-Object System.CodeDom.Compiler.CompilerParameters
        foreach ($r in (Resolve-References)) { [void]$cp.ReferencedAssemblies.Add($r) }
        Add-Type -TypeDefinition $csharp -CompilerParameters $cp -ErrorAction Stop
    }

    $res = [AranetBle]::Scan($ScanSeconds)
    if (-not $res) {
        Write-Log "No Aranet4 measurement advertisement seen. Is 'Smart Home Integration' enabled in the Aranet app, and the device in range?" "ERROR"
        if ($Json) { Write-Output '{"ok":false,"error":"not_found"}' }
        exit 3
    }
    $parts = $res -split "`t"
    $hex = $parts[2]
    $b = for ($i=0; $i -lt $hex.Length; $i+=2) { [Convert]::ToByte($hex.Substring($i,2),16) }
    $b = @($b)
    $o = 8
    $co2 = $b[$o] + ($b[$o+1] * 256)
    $tmp = [math]::Round(($b[$o+2] + ($b[$o+3] * 256)) / 20.0, 1)
    $prs = [math]::Round(($b[$o+4] + ($b[$o+5] * 256)) / 10.0, 1)
    $hum = [int]$b[$o+6]
    $bat = [int]$b[$o+7]
    $st  = [int]$b[$o+8]
    $stTxt = @{1='green';2='amber';3='red'}[$st]; if (-not $stTxt) { $stTxt = "status$st" }

    # Sanity check the decode before trusting it.
    if ($co2 -lt 0 -or $co2 -gt 60000 -or $tmp -lt -40 -or $tmp -gt 85 -or $hum -gt 100 -or $prs -lt 300 -or $prs -gt 1200) {
        Write-Log "Decoded values look implausible (co2=$co2 temp=$tmp hum=$hum prs=$prs). Raw: $hex" "ERROR"
        if ($Json) { Write-Output '{"ok":false,"error":"decode"}' }
        exit 7
    }

    Write-Log ("ARANET co2=${co2}ppm temp=${tmp}C humidity=${hum}% pressure=${prs}hPa battery=${bat}% status=$stTxt") "OK"
    if ($Json) {
        Write-Output ('{{"ok":true,"co2":{0},"tempC":{1},"humidity":{2},"pressure":{3},"battery":{4},"status":"{5}"}}' -f $co2,$tmp,$hum,$prs,$bat,$stTxt)
    } else {
        Write-Host ""
        Write-Host ("  CO2         : {0} ppm  ({1})" -f $co2, $stTxt)
        Write-Host ("  Temperature : {0:0.0} C" -f $tmp)
        Write-Host ("  Humidity    : {0}%" -f $hum)
        Write-Host ("  Pressure    : {0:0.0} hPa" -f $prs)
        Write-Host ("  Battery     : {0}%" -f $bat)
        Write-Host ""
    }
    exit 0
}
catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" "ERROR"
    if ($Json) { Write-Output ('{{"ok":false,"error":{0}}}' -f (ConvertTo-Json $_.Exception.Message)) }
    exit 1
}
