# LYWSD02 Clock Sync (Windows)

A zero-install Windows tool that sets the time on a **Xiaomi LYWSD02 ("Mijia")
Bluetooth clock** — the local equivalent of the web tool at
<https://saso5.github.io/LYWSD02-clock-sync/>, but runnable unattended from
**Task Scheduler**.

It drives Bluetooth LE through the built-in Windows Runtime APIs (via a tiny C#
helper compiled on the fly). **No Python, no .NET SDK, no extra installs.**

## Files

| File | Purpose |
|------|---------|
| `Sync-LYWSD02.ps1`   | The core app. Scans for the clock and writes the time / reads sensors. |
| `Install-Schedule.ps1` | Creates/removes the scheduled time-sync task. |
| `Tray-LYWSD02.ps1`   | System-tray widget (temperature in the taskbar, hourly logging, toggles). |
| `Install-Widget.ps1` | Installs/removes the tray widget + login startup. |
| `Start-Widget.vbs`   | Launches the widget with no console window. |
| `settings.json`      | Widget settings (address, interval, toggles). |
| `logs\sensors.csv`   | Hourly temperature/humidity/battery history. |
| `logs\sync.log`, `logs\widget.log` | Run logs. |

## Taskbar widget

A system-tray widget shows the **current temperature right in the taskbar** and
keeps an hourly history. Install / start it with:

```powershell
.\Install-Widget.ps1 -Address E7:2E:01:92:C1:1F
```

It adds a Startup shortcut (so it returns after reboot) and launches immediately.
Find the icon in the tray (click the `^` overflow, then drag it onto the taskbar
to keep it visible). **Right-click** the icon for the menu:

| Menu item | What it does |
|-----------|--------------|
| **Read now** | Read temperature/humidity/battery immediately (also logs to CSV). |
| **Sync clock now** | Set the clock's time over Bluetooth. |
| **Show trends...** | Open the graph in a resizable window. |
| **Connection enabled / disabled** | Toggle BLE on/off. Disabled = battery saver: no hourly polling, icon greys out. |
| **Log hourly to CSV** | Turn the hourly `sensors.csv` logging on/off. |
| **Open data folder** | Open the `logs` folder (CSV + logs). |
| **Run at login** | Toggle the Startup shortcut. |
| **Exit** | Close the widget. |

The icon shows the rounded temperature (e.g. `23`). **Hovering** pops up a
frameless graph of temperature, humidity and dew point with the current reading
in the header. **Clicking the popup**, **double-clicking the icon**, or
*Show trends…* opens the same graph in a resizable window.

In the **window**:

- **Hover over any data point** to float that point's exact reading and time.
- A **Range** dropdown filters the time frame: *Last hour / 6 hours / 24 hours /
  7 days / 30 days / All*, or **Custom range…** (which reveals two date pickers).
  The choice is remembered between sessions and **defaults to the last 7 days**.
- **Refresh** re-reads the CSV; **Open CSV** opens the data file.

As history grows the graph can get busy, so the range filter keeps it readable
(and the X-axis labels switch between time-of-day and date automatically based on
the visible span).

### The trends graph

One chart shows all three series together, with each axis colour-matched to its
line so it's clear which scale belongs to which colour:

- **Temperature** (orange) — **left** axis, °C
- **Dew point** (dashed blue) — **left** axis, °C (computed from temp + humidity
  via the Magnus formula, `a=17.62, b=243.12`)
- **Humidity** (green) — **right** axis, fixed **0–100 %**

The humidity axis is pinned to 0–100 % (rather than auto-scaled) so the green
line can never coincidentally land on top of the temperature line, and every
reading is drawn as a point marker — so the three series stay readable even when
values are nearly flat.

Dew point is the temperature at which the air would become saturated — when the
room temperature gets close to the dew-point line, it feels muggy / condensation
is likely. The graph reads straight from `sensors.csv`, so it fills out as the
hourly history grows.

Each hour (configurable via `-IntervalMinutes`) the widget reads and appends a
row to `logs\sensors.csv`:

```
timestamp,tempC,tempF,humidity,battery
2026-06-06 18:50:15,22.96,73.3,46,9
```

Remove it with `.\Install-Widget.ps1 -Uninstall` (keeps your CSV and settings).

> **Why the system tray and not next to the weather icon?** In Windows 11 the
> weather icon on the *left* opens the **Widgets board**, and placing a tile
> there requires a signed, MSIX-packaged widget provider (Windows App SDK +
> Adaptive Cards) — that can't be delivered as a script. The system-tray icon
> (right side, by the clock) is the script-installable equivalent and still
> shows the temperature on the taskbar.

## How the time is set

Identical protocol to the web tool / the python `lywsd02` library:

- Service `EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6`
- Characteristic `EBE0CCB7-7A0A-4B0C-8A1A-6FF2997DA3A6` (Time)
- Payload = **5 bytes**: `uint32` little-endian UTC Unix time + `int8` timezone (hours)

The clock displays `UTC + timezone`. The timezone defaults to this PC's current
offset (DST-aware) at run time.

## Your clock

- Address: **`E7:2E:01:92:C1:1F`**  (advertised name `LYWSD02`)
- Timezone: auto-detected as **UTC+10**

The scheduled task is already installed: **weekly on Wednesday at 12:00**,
90-second scan, matching by that address (and by name as a fallback).

## Toggle: turning automatic sync on/off

Running the app **by hand** flips the scheduled task between **Enabled** and
**Disabled** (after attempting the sync). So to pause automatic syncing, just
run it once; run it again to switch automation back on:

```powershell
.\Sync-LYWSD02.ps1 -Address E7:2E:01:92:C1:1F      # syncs AND toggles the schedule
```

Each run logs the new state, e.g. `toggled: Enabled -> DISABLED`.

- Runs launched by **Task Scheduler** pass `-FromScheduler` and **never** toggle,
  so the weekly Wednesday sync can't disable itself.
- To sync by hand **without** touching the schedule, add `-NoToggle`.
- `-Survey` runs never toggle either.

## Reading temperature / humidity / battery

```powershell
.\Sync-LYWSD02.ps1 -ReadSensors -Address E7:2E:01:92:C1:1F -ScanSeconds 60
```

Example output:

```
  Temperature : 23.3 C  (74.0 F)
  Humidity    : 44%
  Battery     : 9%
```

How it works: temperature + humidity come from a BLE *notification* on
characteristic `EBE0CCC1` (3 bytes = int16 temperature ×100 little-endian,
then 1 byte humidity %); battery is a direct read of `EBE0CCC4`. Temperature is
always reported in Celsius by the device (Fahrenheit is computed for
convenience). `-ReadSensors` only reads — it never sets the time and never
toggles the scheduled task. Because the clock advertises intermittently, give it
a generous `-ScanSeconds` (and press the clock's button to wake it if needed).

## Everyday use

```powershell
# One-off manual sync (uses your installed address + name)
.\Sync-LYWSD02.ps1 -Address E7:2E:01:92:C1:1F

# Read temperature, humidity and battery (no time change)
.\Sync-LYWSD02.ps1 -ReadSensors -Address E7:2E:01:92:C1:1F -ScanSeconds 60

# Just scan and list everything nearby (find the address again if needed)
.\Sync-LYWSD02.ps1 -Survey

# Force a specific timezone instead of auto-detect
.\Sync-LYWSD02.ps1 -Address E7:2E:01:92:C1:1F -TimezoneOffset 10

# Run the scheduled task right now
Start-ScheduledTask -TaskName 'LYWSD02 Clock Sync'

# See recent results
Get-Content .\logs\sync.log -Tail 20
```

## Changing the scheduled time

Re-run `Install-Schedule.ps1` with the new time/day — it overwrites the existing
task in place:

```powershell
# Current setting: weekly on Wednesday at 12:00
.\Install-Schedule.ps1 -Interval Weekly -DaysOfWeek Wednesday -Time 12:00 -Address E7:2E:01:92:C1:1F -ScanSeconds 90

# Change to weekly on Sunday at 09:00
.\Install-Schedule.ps1 -Interval Weekly -DaysOfWeek Sunday -Time 09:00 -Address E7:2E:01:92:C1:1F -ScanSeconds 90

# Or daily at 06:30
.\Install-Schedule.ps1 -Interval Daily -Time 06:30 -Address E7:2E:01:92:C1:1F -ScanSeconds 90

# Remove it entirely
.\Install-Schedule.ps1 -Uninstall
```

`-DaysOfWeek` accepts multiple days, e.g. `-DaysOfWeek Monday,Thursday`.

## Notes & troubleshooting

- **The clock must be powered and within a few metres of the PC.** It advertises
  only intermittently, so the script scans (up to `-ScanSeconds`) until it sees
  the clock, then connects and writes immediately. A miss on one day is harmless
  — the clock drifts only ~1 min/month, and the task retries up to 3×.
- **The PC must be on and awake** at the scheduled time (it runs in your user
  session — BLE needs an interactive context). Pick a time your PC is normally on.
- **If syncing suddenly fails after a battery change**, the clock's Bluetooth
  address may have changed. Run `.\Sync-LYWSD02.ps1 -Survey`, note the new
  address next to name `LYWSD02`, and re-run `Install-Schedule.ps1` with it.
- **Exit codes:** `0` success · `1` unexpected error · `3` clock not seen ·
  `7` connected but write failed. All runs are logged to `logs\sync.log`.
- Requires Windows 10/11 with a Bluetooth LE radio and the Windows SDK union
  metadata present (it was on this machine at
  `Windows Kits\10\UnionMetadata\10.0.19041.0`).
