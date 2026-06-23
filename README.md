# LYWSD02 Clock Companion (Windows)

Zero-install Windows tools for the **Xiaomi LYWSD02 ("Mijia") Bluetooth clock**,
with optional **Aranet4 air-quality (CO₂)** monitoring:

- **Set the clock's time** over Bluetooth LE (a local, scriptable equivalent of
  the web tool at <https://saso5.github.io/LYWSD02-clock-sync/>), runnable
  unattended from **Task Scheduler**.
- **A system-tray widget** that shows the current temperature in the taskbar,
  logs temperature/humidity/battery to CSV, and graphs temperature, humidity and
  dew point.
- **Optional Aranet4 support** — if you have an Aranet4 CO₂ monitor nearby, the
  widget also captures **CO₂ / temperature / humidity / pressure** (passively,
  no pairing) and graphs it as a second device alongside the clock.

Everything is plain PowerShell that drives Bluetooth LE through the built-in
Windows Runtime (WinRT) APIs via a tiny C# helper compiled on the fly.
**No Python, no .NET SDK, no pre-built binaries.**

> Throughout this README, replace `AA:BB:CC:DD:EE:FF` with your own clock's
> Bluetooth address (see [Quick start](#quick-start)).

## Requirements

- Windows 10 or 11 with a **Bluetooth LE** radio.
- **Windows PowerShell 5.1** (built in).
- The Windows SDK **union metadata** (`Windows.winmd`) — already present if you
  have the Windows 10/11 SDK or Visual Studio with the Windows workload. The
  scripts auto-detect the newest version under
  `C:\Program Files (x86)\Windows Kits\10\UnionMetadata\`.
- The clock must be powered and within a few metres of the PC. It advertises
  intermittently, so wake it (press a button) when first setting things up.

## Quick start

```powershell
# 1. Find your clock's Bluetooth address (press a button on the clock first).
.\Sync-LYWSD02.ps1 -Survey
#    Note the ADDRESS on the row whose NAME is "LYWSD02".

# 2. Test a one-off time sync.
.\Sync-LYWSD02.ps1 -Address AA:BB:CC:DD:EE:FF

# 3. Install the tray widget (auto-starts at login).
.\Install-Widget.ps1 -Address AA:BB:CC:DD:EE:FF

# 4. (Optional) Schedule automatic time sync, e.g. weekly on Wednesday at noon.
.\Install-Schedule.ps1 -Address AA:BB:CC:DD:EE:FF -Interval Weekly -DaysOfWeek Wednesday -Time 12:00
```

If you omit `-Address`, the scripts scan for the advertised name `LYWSD02`
instead — slower and less reliable, so passing the address is recommended.

The time written is **UTC + a timezone offset**; the offset defaults to this PC's
current local offset (DST-aware) at run time, or pass `-TimezoneOffset <hours>`.

## Files

| File | Purpose |
|------|---------|
| `Sync-LYWSD02.ps1`   | The core app. Scans for the clock and writes the time / reads sensors. |
| `Install-Schedule.ps1` | Creates/removes the scheduled time-sync task. |
| `Tray-LYWSD02.ps1`   | System-tray widget (taskbar temperature, logging, graphs, toggles). |
| `Install-Widget.ps1` | Installs/removes the tray widget + login startup. |
| `Start-Widget.vbs`   | Launches the widget with no console window. |
| `Read-Aranet4.ps1`   | Standalone CLI: read CO₂/temp/humidity/pressure from a nearby Aranet4. |
| `Watch-Aranet4.ps1`  | Persistent Aranet4 listener used by the widget (writes latest reading to JSON). |
| `settings.json`      | Widget settings — generated locally, git-ignored. |
| `logs\sensors.csv`   | LYWSD02 temperature/humidity/battery history — generated locally, git-ignored. |
| `logs\aranet4.csv`   | Aranet4 CO₂/temp/humidity/pressure history — generated locally, git-ignored. |
| `logs\*.log`, `logs\aranet-latest.json` | Run logs / latest Aranet reading — generated locally, git-ignored. |

## Taskbar widget

A system-tray widget shows the **current temperature right in the taskbar** and
keeps an hourly history. Install / start it with:

```powershell
.\Install-Widget.ps1 -Address AA:BB:CC:DD:EE:FF
```

It adds a Startup shortcut (so it returns after reboot) and launches immediately.
Find the icon in the tray (click the `^` overflow, then drag it onto the taskbar
to keep it visible). **Right-click** the icon for the menu:

| Menu item | What it does |
|-----------|--------------|
| **Read clock now** | Read the LYWSD02 temperature/humidity/battery immediately (also logs). |
| **Read Aranet4 now** | Sample the latest captured CO₂ reading immediately (also logs). |
| **Sync clock now** | Set the clock's time over Bluetooth. |
| **Open dashboard...** | Open the full dashboard window. |
| **Connection enabled / disabled** | Toggle all BLE on/off. Disabled = battery saver: icon greys out. |
| **Log hourly to CSV** | Turn CSV logging on/off (both devices). |
| **LYWSD02 read interval ▸** | How often to read the clock (5 / 10 / 15 / 30 / 60 min). |
| **Track Aranet4 (CO2)** | Enable/disable the Aranet4 listener. |
| **Aranet4 read interval ▸** | How often to log CO₂ (1 / 2 / 3 / 5 / 10 / 15 / 30 min). |
| **Open data folder** | Open the `logs` folder (CSVs + logs). |
| **Run at login** | Toggle the Startup shortcut. |
| **Exit** | Close the widget. |

The icon shows the rounded temperature (e.g. `23`). **Hovering** pops up a
frameless Room State mini-summary — the plain-language verdict, the four current
readings, and a CO₂ sparkline — styled to match the dashboard. Click it to open
the full dashboard.

## Dashboard

**Double-click the tray icon** (or right-click → *Open dashboard…*, or click the
hover popup) to open the **dashboard** — a *Room State* view that reads the room
and presents the **meaning, not the raw gauges**. It leads with one plain-language
verdict and a small set of quiet cards, each answering a human question. A healthy
room is almost silent: one accent colour, and no motion beyond a single breathing
dot. The interface raises its voice only when something needs attention. Light and
dark are both first-class (toggle in the controls strip).

- **Room verdict** (top, flush) — one synthesised line ("Fresh and comfortable.
  Likely one person.") with a soft state orb that breathes, and a quiet timestamp.
- **Air quality** (feature card) — CO₂ in ppm over a low-chroma threshold band
  (fresh / acceptable / stuffy / poor) with a marker at the current value, plus a
  rebreathed-air percentage and a plain-language note on likely focus.
- **Live vitals** — four quiet tiles (temperature, humidity, CO₂, pressure), each
  with a 6-hour sparkline and a small trend delta. Reference, not the headline.
- **Occupancy** — headcount from a CO₂ **mass balance** (`n ≈ ACH · V · (CO₂ −
  outdoor) / per-person output`), using the estimated air-changes/hour and the
  **room volume** you set in the controls strip. With thin person glyphs and an
  activity guess, captioned with the room volume and *no camera*. A single CO₂
  sensor can't separate people from room size, so the volume setting is what
  makes the count meaningful — still ±1 (per-person output and ACH vary).
- **Ventilation** — air changes per hour against a healthy 4–6 target band, with
  an estimate of time to clear if the room is vacated (derived from CO₂ decay).
- **Comfort** — dew point and absolute humidity, with relative humidity shown on
  the shared 40–60% comfort band.
- **Outside** — pressure tendency (rising / falling, hPa over 3h) and a one-line
  weather nowcast, inferred through the wall (there is no outdoor sensor).
- **Today** — a 24-hour timeline overlaying CO₂ (filled area) and occupancy
  (stepped line), with day/night shading and a "now" marker. Hover to scrub and
  read any moment; click to open the full zoomable trends graph.
- **Controls** (slim strip) — toggles for connection, Aranet tracking, CSV logging,
  start-at-login and **light/dark theme**; per-device read-interval selectors; a
  **room volume (m³)** setting that feeds the occupancy estimate; and buttons to
  sync the clock, read a device now, or open the data folder.

Everything you change is saved and mirrored in the tray menu. The occupancy,
ventilation and outdoor figures are **inferences** from the five inputs
(temperature, humidity, CO₂, pressure, clock), not direct measurements.

Live updates are physical, never jarring: numbers tween to their new value,
the verdict word-cross-fades, and the affected card gives a brief settle when a
state changes. Each card also handles its own **loading** (skeleton), **empty**
("waiting for sensor"), and **stale** (dimmed + "Xm ago") states, and a single
caution dot appears in the footer if a sensor goes quiet. If Windows is set to
**reduce motion**, all tweens and the breathing dot are disabled and changes
apply instantly.

The full zoomable trends charts (smooth splines, scroll-wheel zoom, range filter)
live in their own window — right-click the tray icon → *Trends graph…*.

Configure with `Install-Widget.ps1` parameters: `-Address`, `-IntervalMinutes`
(clock, default 60), `-AranetIntervalMinutes` (CO₂, default 5), `-ScanSeconds`
(default 90), `-NoStartup`. Remove with `.\Install-Widget.ps1 -Uninstall`
(keeps your CSVs and settings).

### The trends graph

The window shows the two devices as **separate stacked charts** (the Aranet4
chart only appears once it has data):

**Top — LYWSD02 (clock).** One chart, axes colour-matched to the lines:

- **Temperature** (orange) — **left** axis, °C
- **Dew point** (dashed blue) — **left** axis, °C (computed from temp + humidity
  via the Magnus formula, `a=17.62, b=243.12`)
- **Humidity** (green) — **right** axis, %

**Bottom — Aranet4 (air quality).**

- **CO₂** (gold) — **left** axis, ppm
- **Pressure** (purple) — **right** axis, hPa

Every axis **auto-fits its data range** (rather than starting at zero) so the real
variation is visible — CO₂ never gets near 0, pressure and humidity move only a
little, and forcing zero would squash them flat. Each series is colour-matched to
its axis and drawn with point markers, so the lines stay distinct where they
cross. Dew point is the temperature at which the air would become saturated —
when the room temperature nears the dew-point line, it feels muggy.

Each chart reads straight from its CSV and fills out as history grows:

```
# logs\sensors.csv  (LYWSD02, every -IntervalMinutes, default 60)
timestamp,tempC,tempF,humidity,battery
2026-01-31 18:50:15,22.96,73.3,46,87

# logs\aranet4.csv  (Aranet4, every AranetIntervalMinutes, default 5)
timestamp,co2,tempC,humidity,pressure,battery,status
2026-01-31 18:50:15,684,22.8,53,1030.8,36,green
```

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
offset (DST-aware) at run time, or pass `-TimezoneOffset <hours>`.

## Reading temperature / humidity / battery

```powershell
.\Sync-LYWSD02.ps1 -ReadSensors -Address AA:BB:CC:DD:EE:FF -ScanSeconds 60
```

Example output:

```
  Temperature : 23.3 C  (74.0 F)
  Humidity    : 44%
  Battery     : 87%
```

Temperature + humidity come from a BLE *notification* on characteristic
`EBE0CCC1` (3 bytes = int16 temperature ×100 little-endian, then 1 byte
humidity %); battery is a direct read of `EBE0CCC4`. Temperature is always
reported in Celsius by the device (Fahrenheit is computed for convenience).
`-ReadSensors` only reads — it never sets the time. Add `-Json` for a single
machine-readable line (used internally by the widget).

## Air quality (Aranet4, optional)

If you have an **Aranet4** CO₂ monitor nearby, the widget can capture its
readings too — **passively, with no pairing and no connection**.

**Enable broadcasting first:** in the **Aranet Home app**, turn on
**Smart Home Integration** for the device. It then advertises its measurements in
the BLE advertisement (manufacturer id `0x0702`).

Read it from the command line:

```powershell
.\Read-Aranet4.ps1            # or -Json for a machine-readable line
```

```
  CO2         : 684 ppm  (green)
  Temperature : 22.8 C
  Humidity    : 53%
  Pressure    : 1030.8 hPa
  Battery     : 36%
```

**How the widget captures it.** The Aranet broadcasts its measurement packet only
in bursts (≈ once a minute, with occasional multi-minute gaps), so a single short
scan often misses it. Instead the widget runs a **persistent background listener**
(`Watch-Aranet4.ps1`) that stays on and writes the latest reading to
`logs\aranet-latest.json` whenever a packet arrives. The widget then **samples**
that file every *Aranet4 read interval* minutes (instant, no radio) and appends a
row to `logs\aranet4.csv`. The listener is paused only during the rare clock scan
so the two never compete for the radio.

- The device is matched by **company id `0x0702`**, not a fixed address (its
  address rotates for privacy).
- The read interval is independent of the clock's, selectable from the tray menu
  (**Aranet4 read interval**) or `Install-Widget.ps1 -AranetIntervalMinutes <n>`.
- Turn capture off entirely with **Track Aranet4 (CO2)** in the menu.

**Decode** (advertisement manufacturer data `0x0702`): an 8-byte header (bit
`0x20` of byte 0 set = measurements present), then at offset 8 —
`CO₂` u16 ppm · `temp` u16 ÷20 °C · `pressure` u16 ÷10 hPa · `humidity` u8 % ·
`battery` u8 % · `status` u8 (1 green / 2 amber / 3 red).

## Scheduling automatic sync

```powershell
# Weekly on Wednesday at 12:00
.\Install-Schedule.ps1 -Interval Weekly -DaysOfWeek Wednesday -Time 12:00 -Address AA:BB:CC:DD:EE:FF -ScanSeconds 90

# Daily at 06:30
.\Install-Schedule.ps1 -Interval Daily -Time 06:30 -Address AA:BB:CC:DD:EE:FF -ScanSeconds 90

# Multiple days
.\Install-Schedule.ps1 -Interval Weekly -DaysOfWeek Monday,Thursday -Time 09:00 -Address AA:BB:CC:DD:EE:FF

# Run the task now / remove it
Start-ScheduledTask -TaskName 'LYWSD02 Clock Sync'
.\Install-Schedule.ps1 -Uninstall
```

Re-running `Install-Schedule.ps1` overwrites the existing task in place, so it
doubles as the way to change the time/day.

### Toggling automatic sync on/off

Running `Sync-LYWSD02.ps1` **by hand** flips the scheduled task between
**Enabled** and **Disabled** after the sync, so you can pause/resume automation
just by running it again:

```powershell
.\Sync-LYWSD02.ps1 -Address AA:BB:CC:DD:EE:FF      # syncs AND toggles the schedule
```

- Runs launched by **Task Scheduler** pass `-FromScheduler` and **never** toggle,
  so a recurring sync can't disable itself.
- To sync by hand **without** touching the schedule, add `-NoToggle`.
- `-Survey` and `-ReadSensors` runs never toggle.

## Everyday use

```powershell
# One-off manual sync
.\Sync-LYWSD02.ps1 -Address AA:BB:CC:DD:EE:FF

# Read temperature, humidity and battery (no time change)
.\Sync-LYWSD02.ps1 -ReadSensors -Address AA:BB:CC:DD:EE:FF -ScanSeconds 60

# List every BLE advertiser nearby (find / re-find the clock's address)
.\Sync-LYWSD02.ps1 -Survey

# Force a specific timezone instead of auto-detect
.\Sync-LYWSD02.ps1 -Address AA:BB:CC:DD:EE:FF -TimezoneOffset 10

# See recent results
Get-Content .\logs\sync.log -Tail 20
```

## Notes & troubleshooting

- **The clock advertises only intermittently**, so the scripts scan (up to
  `-ScanSeconds`) until they see it, then connect and write immediately. A miss
  on one run is harmless — the clock drifts only ~1 min/month, and the scheduled
  task retries up to 3×.
- **The PC must be on and awake** at the scheduled time (it runs in your user
  session — BLE needs an interactive context). Pick a time your PC is normally on.
- **If syncing suddenly fails after a battery change**, the clock's Bluetooth
  address may have changed (it uses a static-random address that can change on
  power loss). Run `.\Sync-LYWSD02.ps1 -Survey`, note the new address next to
  name `LYWSD02`, and re-run `Install-Widget.ps1` / `Install-Schedule.ps1` with
  it. The widget also re-learns the address automatically when it sees the clock
  by name.
- **No Aranet4 readings?** Make sure **Smart Home Integration** is enabled in the
  Aranet app (without it the device doesn't broadcast measurements). Its broadcast
  is bursty, so the first capture after launch can take a few minutes; the
  persistent listener catches up as soon as a packet arrives.
- **Exit codes** (`Sync-LYWSD02.ps1`): `0` success · `1` unexpected error ·
  `2` WinRT load failed · `3` clock not seen · `7` connected but write failed.
  All runs are logged to `logs\sync.log`; the widget logs to `logs\widget.log`.
- **PowerShell execution policy:** the install scripts and scheduled task launch
  with `-ExecutionPolicy Bypass`, so you don't need to change your machine policy.

## License

MIT — see [LICENSE](LICENSE).
