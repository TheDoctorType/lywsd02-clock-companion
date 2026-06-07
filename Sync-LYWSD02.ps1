<#
.SYNOPSIS
    Synchronises the time on a Xiaomi LYWSD02 ("Mijia") BLE clock from Windows.

.DESCRIPTION
    Pure-PowerShell, zero-install replacement for the web tool at
    https://saso5.github.io/LYWSD02-clock-sync/ . It drives Bluetooth Low Energy
    directly through the built-in Windows Runtime (WinRT) APIs via a small C#
    helper compiled on the fly, so it needs no Python, no .NET SDK and no
    pre-built binaries. Designed to be run unattended from Task Scheduler.

    Protocol (identical to the web tool / the python `lywsd02` library):
      Service        EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6
      Characteristic EBE0CCB7-7A0A-4B0C-8A1A-6FF2997DA3A6  (Time)
      Payload        5 bytes = uint32 little-endian UTC Unix time + int8 TZ hours

.PARAMETER DeviceName
    BLE advertised name to look for when scanning. Default "LYWSD02".

.PARAMETER Address
    Fixed 48-bit Bluetooth address, e.g. "A4:C1:38:11:22:33". RECOMMENDED for
    scheduled use: skips scanning entirely -> faster and far more reliable.

.PARAMETER TimezoneOffset
    Whole-hour offset stored on the clock. Defaults to this PC's current local
    UTC offset (DST-aware) evaluated at run time.

.PARAMETER ScanSeconds
    Seconds to scan for the clock before giving up. Default 25.

.PARAMETER Survey
    Diagnostic mode: scan and list every BLE advertiser (address / RSSI / name),
    then exit without writing. Use this once to discover your clock's address.
    Survey runs never toggle the scheduled task.

.PARAMETER ReadSensors
    Read mode: connect and report the clock's current temperature, humidity and
    battery level, then exit WITHOUT setting the time. Does not toggle the
    scheduled task. Pair with -Address (or -DeviceName) and -ScanSeconds.

.PARAMETER TaskName
    Name of the scheduled task to toggle. Default "LYWSD02 Clock Sync".

.PARAMETER FromScheduler
    Set by the scheduled task itself. Suppresses the toggle so an automatic run
    never disables its own schedule. You normally never pass this by hand.

.PARAMETER NoToggle
    Run the sync by hand WITHOUT flipping the scheduled task's enabled state.

.PARAMETER LogPath
    Log file. Defaults to .\logs\sync.log next to this script.

.NOTES
    Toggle behaviour: running this script interactively (by hand) flips the
    scheduled task between Enabled and Disabled after the sync attempt, so you
    can switch the automatic sync on/off just by running the app again. Runs
    launched by Task Scheduler pass -FromScheduler and never toggle.

.EXAMPLE
    .\Sync-LYWSD02.ps1 -Survey            # discover what's around
.EXAMPLE
    .\Sync-LYWSD02.ps1                     # scan for "LYWSD02" and sync
.EXAMPLE
    .\Sync-LYWSD02.ps1 -Address A4:C1:38:AA:BB:CC -TimezoneOffset 10
.EXAMPLE
    .\Sync-LYWSD02.ps1 -ReadSensors -Address A4:C1:38:AA:BB:CC  # temp/humidity/battery
#>
[CmdletBinding()]
param(
    [string]$DeviceName = "LYWSD02",
    [string]$Address,
    [int]$TimezoneOffset = [int][math]::Round(([TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now)).TotalHours),
    [int]$ScanSeconds = 25,
    [switch]$Survey,
    [switch]$ReadSensors,
    [switch]$Json,
    [string]$TaskName = "LYWSD02 Clock Sync",
    [switch]$FromScheduler,
    [switch]$NoToggle,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

# Resolve our own folder robustly. $PSScriptRoot is empty in a param default when
# launched via `powershell -File`, so compute it here in the body instead.
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $LogPath) { $LogPath = Join-Path $ScriptDir "logs\sync.log" }

# Flip the scheduled task between Enabled and Disabled. Used so that re-running
# the app by hand toggles the automatic sync on/off. Scheduled runs pass
# -FromScheduler so they never disable themselves.
function Toggle-Schedule {
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task) { Write-Log "Toggle skipped: no scheduled task named '$TaskName'." "INFO"; return }
        if ($task.State -eq 'Disabled') {
            Enable-ScheduledTask -TaskName $TaskName | Out-Null
            Write-Log "Scheduled task '$TaskName' toggled: Disabled -> ENABLED." "OK"
        } else {
            Disable-ScheduledTask -TaskName $TaskName | Out-Null
            Write-Log "Scheduled task '$TaskName' toggled: Enabled -> DISABLED." "OK"
        }
    } catch {
        Write-Log "Toggle failed: $($_.Exception.Message)" "ERROR"
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    if (-not $Json) { Write-Host $line }
    try {
        $logDir = Split-Path -Parent $LogPath
        if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------------
# Build the list of reference assemblies the C# helper needs, discovering the
# exact paths on THIS machine (GAC facade folders + the newest Windows SDK
# union metadata). This keeps the script portable across Windows 10/11 boxes.
# ---------------------------------------------------------------------------
function Resolve-References {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    $gac = Join-Path $env:WINDIR "Microsoft.NET\assembly\GAC_MSIL"
    function Get-Facade([string]$name) {
        $dir = Join-Path $gac $name
        if (-not (Test-Path $dir)) { throw "Required framework facade '$name' not found in GAC ($dir)." }
        $dll = Get-ChildItem $dir -Recurse -Filter "$name.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $dll) { throw "Facade DLL '$name.dll' not found under $dir." }
        return $dll.FullName
    }
    $refs = @(
        (Get-Facade "System.Runtime"),
        (Get-Facade "System.Threading.Tasks"),
        (Get-Facade "System.ObjectModel"),
        (Get-Facade "System.Runtime.InteropServices.WindowsRuntime"),
        (Get-Facade "System.Runtime.WindowsRuntime")
    )
    # Newest Windows SDK union metadata (Windows.winmd)
    $umRoot = "C:\Program Files (x86)\Windows Kits\10\UnionMetadata"
    if (-not (Test-Path $umRoot)) { throw "Windows SDK UnionMetadata not found at $umRoot. Install the Windows SDK or use an older approach." }
    $winmd = Get-ChildItem $umRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName "Windows.winmd" } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $winmd) { throw "Windows.winmd not found under $umRoot." }
    $refs += $winmd
    return $refs
}

# ---------------------------------------------------------------------------
# The C# BLE helper. Does discovery, connect, and the time write entirely in
# compiled code (WinRT async is awkward to drive from PowerShell directly).
# ---------------------------------------------------------------------------
$csharp = @'
using System;
using System.Text;
using System.Threading;
using System.Collections.Generic;
using Windows.Foundation;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;

public static class LywsdClock {
    static readonly Guid TIME_SERVICE = new Guid("EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6");
    static readonly Guid TIME_CHAR    = new Guid("EBE0CCB7-7A0A-4B0C-8A1A-6FF2997DA3A6");
    static readonly Guid DATA_CHAR    = new Guid("EBE0CCC1-7A0A-4B0C-8A1A-6FF2997DA3A6"); // temp+humidity (notify)
    static readonly Guid BATTERY_CHAR = new Guid("EBE0CCC4-7A0A-4B0C-8A1A-6FF2997DA3A6"); // battery % (read)

    // List every advertiser: "ADDRHEX\tRSSI\tNAME" per line.
    public static string Survey(int seconds) {
        var w = new BluetoothLEAdvertisementWatcher();
        w.ScanningMode = BluetoothLEScanningMode.Active;
        var name = new Dictionary<ulong, string>();
        var rssi = new Dictionary<ulong, short>();
        w.Received += (s, e) => {
            if (!name.ContainsKey(e.BluetoothAddress) || !string.IsNullOrEmpty(e.Advertisement.LocalName))
                name[e.BluetoothAddress] = e.Advertisement.LocalName ?? "";
            rssi[e.BluetoothAddress] = e.RawSignalStrengthInDBm;
        };
        w.Start();
        new ManualResetEvent(false).WaitOne(TimeSpan.FromSeconds(seconds));
        w.Stop();
        var sb = new StringBuilder();
        foreach (var kv in name) sb.AppendLine(string.Format("{0:X12}\t{1}\t{2}", kv.Key, rssi[kv.Key], kv.Value));
        return sb.ToString();
    }

    // Return the address of the first advertiser matching the name (case-
    // insensitive) OR the given address filter (when addrFilter != 0). 0 if none.
    public static ulong FindAny(string targetName, ulong addrFilter, int seconds) {
        var w = new BluetoothLEAdvertisementWatcher();
        w.ScanningMode = BluetoothLEScanningMode.Active;
        ulong found = 0;
        var done = new ManualResetEvent(false);
        w.Received += (s, e) => {
            bool nameHit = !string.IsNullOrEmpty(targetName) &&
                           string.Equals(e.Advertisement.LocalName, targetName, StringComparison.OrdinalIgnoreCase);
            bool addrHit = addrFilter != 0 && e.BluetoothAddress == addrFilter;
            if (nameHit || addrHit) { found = e.BluetoothAddress; done.Set(); }
        };
        w.Start();
        done.WaitOne(TimeSpan.FromSeconds(seconds));
        w.Stop();
        return found;
    }

    // All-in-one: actively scan for the clock (by name or address), then connect
    // and write the time IMMEDIATELY while the OS advertisement cache is hot.
    // Retries the connect a few times since BLE links are flaky.
    public static string Sync(string targetName, ulong addrFilter, int tzOffset, int scanSeconds) {
        ulong addr = FindAny(targetName, addrFilter, scanSeconds);
        if (addr == 0)
            return "ERROR: device not seen during scan (looked for name='" + targetName +
                   "'" + (addrFilter != 0 ? (" or address " + addrFilter.ToString("X12")) : "") + ")";
        string last = "";
        for (int i = 0; i < 3; i++) {
            last = SyncByAddress(addr, tzOffset);
            if (last.StartsWith("OK")) return last + " addr=" + addr.ToString("X12");
            Thread.Sleep(700);
        }
        return last + " (addr=" + addr.ToString("X12") + ")";
    }

    // Connect to the given address and write the current time. Returns a status
    // string beginning with "OK:" on success or "ERROR:" on failure.
    public static string SyncByAddress(ulong addr, int tzOffset) {
        BluetoothLEDevice dev = null;
        GattDeviceService svc = null;
        try {
            dev = BluetoothLEDevice.FromBluetoothAddressAsync(addr).AsTask().GetAwaiter().GetResult();
            if (dev == null) return "ERROR: could not open device for that address";

            var svcRes = dev.GetGattServicesForUuidAsync(TIME_SERVICE, BluetoothCacheMode.Uncached)
                            .AsTask().GetAwaiter().GetResult();
            if (svcRes.Status != GattCommunicationStatus.Success || svcRes.Services.Count == 0)
                return "ERROR: time service not found (status=" + svcRes.Status + "); is the clock in range and awake?";
            svc = svcRes.Services[0];

            var chRes = svc.GetCharacteristicsForUuidAsync(TIME_CHAR, BluetoothCacheMode.Uncached)
                           .AsTask().GetAwaiter().GetResult();
            if (chRes.Status != GattCommunicationStatus.Success || chRes.Characteristics.Count == 0)
                return "ERROR: time characteristic not found (status=" + chRes.Status + ")";
            var ch = chRes.Characteristics[0];

            long unix = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            byte[] p = new byte[5];
            p[0] = (byte)(unix & 0xFF);
            p[1] = (byte)((unix >> 8) & 0xFF);
            p[2] = (byte)((unix >> 16) & 0xFF);
            p[3] = (byte)((unix >> 24) & 0xFF);
            p[4] = (byte)((sbyte)tzOffset);

            var writer = new DataWriter();
            writer.WriteBytes(p);
            var wr = ch.WriteValueWithResultAsync(writer.DetachBuffer(), GattWriteOption.WriteWithResponse)
                       .AsTask().GetAwaiter().GetResult();
            if (wr.Status != GattCommunicationStatus.Success)
                return "ERROR: write failed (status=" + wr.Status + ", protocolError=" + wr.ProtocolError + ")";

            return "OK: unix=" + unix + " tz=" + tzOffset;
        } catch (Exception ex) {
            return "ERROR: exception: " + ex.Message;
        } finally {
            if (svc != null) try { svc.Dispose(); } catch {}
            if (dev != null) try { dev.Dispose(); } catch {}
        }
    }

    static byte[] BufToBytes(IBuffer buf) {
        var r = DataReader.FromBuffer(buf);
        var b = new byte[buf.Length];
        r.ReadBytes(b);
        return b;
    }

    // Connect and read temperature + humidity (via notification) and battery
    // (direct read). Returns "OK: tempC=.. humidity=.. battery=.." or "ERROR:..".
    public static string ReadSensors(ulong addr, int notifySeconds) {
        BluetoothLEDevice dev = null;
        GattDeviceService svc = null;
        GattCharacteristic dataCh = null;
        TypedEventHandler<GattCharacteristic, GattValueChangedEventArgs> handler = null;
        try {
            dev = BluetoothLEDevice.FromBluetoothAddressAsync(addr).AsTask().GetAwaiter().GetResult();
            if (dev == null) return "ERROR: could not open device for that address";

            var svcRes = dev.GetGattServicesForUuidAsync(TIME_SERVICE, BluetoothCacheMode.Uncached)
                            .AsTask().GetAwaiter().GetResult();
            if (svcRes.Status != GattCommunicationStatus.Success || svcRes.Services.Count == 0)
                return "ERROR: data service not found (status=" + svcRes.Status + "); is the clock in range and awake?";
            svc = svcRes.Services[0];

            // Battery: direct read (optional - don't fail the whole read if absent).
            int battery = -1;
            var batRes = svc.GetCharacteristicsForUuidAsync(BATTERY_CHAR, BluetoothCacheMode.Uncached)
                            .AsTask().GetAwaiter().GetResult();
            if (batRes.Status == GattCommunicationStatus.Success && batRes.Characteristics.Count > 0) {
                var br = batRes.Characteristics[0].ReadValueAsync(BluetoothCacheMode.Uncached)
                            .AsTask().GetAwaiter().GetResult();
                if (br.Status == GattCommunicationStatus.Success) {
                    var bytes = BufToBytes(br.Value);
                    if (bytes.Length >= 1) battery = bytes[0];
                }
            }

            // Temp + humidity arrive as a notification: 3 bytes = int16 tempx100 LE, uint8 humidity%.
            var dRes = svc.GetCharacteristicsForUuidAsync(DATA_CHAR, BluetoothCacheMode.Uncached)
                          .AsTask().GetAwaiter().GetResult();
            if (dRes.Status != GattCommunicationStatus.Success || dRes.Characteristics.Count == 0)
                return "ERROR: temp/humidity characteristic not found (status=" + dRes.Status + ")";
            dataCh = dRes.Characteristics[0];

            double tempC = double.NaN; int humidity = -1;
            var got = new ManualResetEvent(false);
            handler = (s, e) => {
                var b = BufToBytes(e.CharacteristicValue);
                if (b.Length >= 3) {
                    short t = (short)(b[0] | (b[1] << 8));
                    tempC = t / 100.0;
                    humidity = b[2];
                    got.Set();
                }
            };
            dataCh.ValueChanged += handler;

            var cccd = dataCh.WriteClientCharacteristicConfigurationDescriptorWithResultAsync(
                           GattClientCharacteristicConfigurationDescriptorValue.Notify)
                           .AsTask().GetAwaiter().GetResult();
            if (cccd.Status != GattCommunicationStatus.Success)
                return "ERROR: could not enable notifications (status=" + cccd.Status + ")";

            bool ok = got.WaitOne(TimeSpan.FromSeconds(notifySeconds));

            try {
                dataCh.WriteClientCharacteristicConfigurationDescriptorWithResultAsync(
                    GattClientCharacteristicConfigurationDescriptorValue.None)
                    .AsTask().GetAwaiter().GetResult();
            } catch {}

            string bs = battery >= 0 ? battery.ToString() : "?";
            if (!ok)
                return "ERROR: no temp/humidity notification within " + notifySeconds + "s (battery=" + bs + "%)";
            return "OK: tempC=" + tempC.ToString("0.00") + " humidity=" + humidity + " battery=" + bs;
        } catch (Exception ex) {
            return "ERROR: exception: " + ex.Message;
        } finally {
            if (dataCh != null && handler != null) try { dataCh.ValueChanged -= handler; } catch {}
            if (svc != null) try { svc.Dispose(); } catch {}
            if (dev != null) try { dev.Dispose(); } catch {}
        }
    }

    // Scan for the clock (by name or address) then read its sensors immediately.
    public static string ScanRead(string targetName, ulong addrFilter, int scanSeconds, int notifySeconds) {
        ulong addr = FindAny(targetName, addrFilter, scanSeconds);
        if (addr == 0)
            return "ERROR: device not seen during scan (looked for name='" + targetName +
                   "'" + (addrFilter != 0 ? (" or address " + addrFilter.ToString("X12")) : "") + ")";
        string last = "";
        for (int i = 0; i < 3; i++) {
            last = ReadSensors(addr, notifySeconds);
            if (last.StartsWith("OK")) return last + " addr=" + addr.ToString("X12");
            Thread.Sleep(700);
        }
        return last + " (addr=" + addr.ToString("X12") + ")";
    }
}
'@

function Initialize-Helper {
    if (-not ([System.Management.Automation.PSTypeName]'LywsdClock').Type) {
        $refs = Resolve-References
        $cp = New-Object System.CodeDom.Compiler.CompilerParameters
        foreach ($r in $refs) { [void]$cp.ReferencedAssemblies.Add($r) }
        Add-Type -TypeDefinition $csharp -CompilerParameters $cp -ErrorAction Stop
    }
}

function ConvertTo-BtAddress {
    param([string]$s)
    $clean = ($s -replace '0x','' -replace '[:\-\s]','').Trim()
    if ($clean -notmatch '^[0-9A-Fa-f]{12}$') { throw "Invalid Bluetooth address: '$s' (expected 12 hex digits)." }
    return [Convert]::ToUInt64($clean, 16)
}

# ===========================================================================
Write-Log "Starting LYWSD02 time sync (PID $PID)."
try {
    Initialize-Helper

    if ($Survey) {
        Write-Log "SURVEY: scanning $ScanSeconds s for all BLE advertisers..."
        $raw = [LywsdClock]::Survey($ScanSeconds)
        Write-Host ""
        Write-Host ("{0,-14} {1,-6} {2}" -f "ADDRESS","RSSI","NAME")
        Write-Host ("{0,-14} {1,-6} {2}" -f "-------","----","----")
        foreach ($l in ($raw -split "`r?`n" | Where-Object { $_ })) {
            $f = $l -split "`t"
            $addrPretty = ($f[0] -replace '(..)(?=.)','$1:')
            Write-Host ("{0,-14} {1,-6} {2}" -f $addrPretty, $f[1], $f[2])
        }
        Write-Host ""
        Write-Log "Survey complete. Note the address whose NAME is '$DeviceName' (or strongest RSSI near your clock)."
        exit 0
    }

    $addrFilter = [uint64]0
    if ($Address) {
        $addrFilter = ConvertTo-BtAddress $Address
        Write-Log ("Target: address {0} (name '{1}' also accepted)." -f $Address, $DeviceName)
    } else {
        Write-Log ("Target: advertiser named '{0}'." -f $DeviceName)
    }

    if ($ReadSensors) {
        $notifyWait = [Math]::Max(15, [int]($ScanSeconds / 2))
        Write-Log ("READ: scanning up to {0}s, then reading temperature/humidity/battery (notify wait {1}s)..." -f $ScanSeconds, $notifyWait)
        $r = [LywsdClock]::ScanRead($DeviceName, $addrFilter, $ScanSeconds, $notifyWait)
        if ($r -like "OK:*") {
            $tc = [double]([regex]::Match($r,'tempC=([\-0-9.]+)').Groups[1].Value)
            $hu = [int]([regex]::Match($r,'humidity=([0-9]+)').Groups[1].Value)
            $bm = [regex]::Match($r,'battery=([0-9?]+)').Groups[1].Value
            $tf = [math]::Round($tc * 9/5 + 32, 1)
            Write-Log ("SENSORS  temp={0:0.0}C humidity={1}% battery={2}%" -f $tc, $hu, $bm) "OK"
            if ($Json) {
                $bv = if ($bm -eq '?') { 'null' } else { $bm }
                $ad = [regex]::Match($r,'addr=([0-9A-Fa-f]{12})').Groups[1].Value
                $adPretty = if ($ad) { ($ad -replace '(..)(?=.)','$1:') } else { '' }
                Write-Output ('{{"ok":true,"tempC":{0},"humidity":{1},"battery":{2},"addr":"{3}"}}' -f $tc, $hu, $bv, $adPretty)
            } else {
                Write-Host ""
                Write-Host ("  Temperature : {0:0.0} C  ({1:0.0} F)" -f $tc, $tf)
                Write-Host ("  Humidity    : {0}%" -f $hu)
                Write-Host ("  Battery     : {0}%" -f $bm)
                Write-Host ""
            }
            exit 0
        } elseif ($r -like "*not seen during scan*") {
            Write-Log $r "ERROR"; if ($Json) { Write-Output '{"ok":false,"error":"not_found"}' }; exit 3
        } else {
            Write-Log $r "ERROR"; if ($Json) { Write-Output ('{{"ok":false,"error":{0}}}' -f (ConvertTo-Json $r)) }; exit 7
        }
    }

    $tz = [int]$TimezoneOffset
    if ($tz -lt -12 -or $tz -gt 14) { throw "TimezoneOffset $tz out of range (-12..14)." }

    $preview = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours($tz)).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Log ("Scanning up to {0}s, then writing time (TZ {1:+0;-0}h) -> clock should read {2}" -f $ScanSeconds, $tz, $preview)

    $result = [LywsdClock]::Sync($DeviceName, $addrFilter, $tz, $ScanSeconds)
    if ($result -like "OK:*") {
        Write-Log "SUCCESS: clock time synchronised. ($result)" "OK"
        if ($Json) { Write-Output '{"ok":true}' }
        exit 0
    } elseif ($result -like "*not seen during scan*") {
        Write-Log $result "ERROR"
        Write-Log "Tip: keep the clock within a few metres of the PC. It advertises intermittently, so a longer -ScanSeconds helps." "INFO"
        if ($Json) { Write-Output '{"ok":false,"error":"not_found"}' }
        exit 3
    } else {
        Write-Log $result "ERROR"
        if ($Json) { Write-Output ('{{"ok":false,"error":{0}}}' -f (ConvertTo-Json $result)) }
        exit 7
    }
}
catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" "ERROR"
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace "ERROR" }
    exit 1
}
finally {
    # A manual (interactive) run toggles the scheduled task on/off. Scheduled
    # runs pass -FromScheduler so the automatic sync never disables itself.
    # Survey and -NoToggle runs are left alone.
    if (-not $Survey -and -not $ReadSensors -and -not $FromScheduler -and -not $NoToggle) {
        Toggle-Schedule
    }
}
