# LYWSD02 Clock Companion (Windows)

Zero-install Windows tools for the **Xiaomi LYWSD02 ("Mijia") Bluetooth clock**,
with optional **Aranet4 air-quality (CO₂)** monitoring:

- **Set the clock's time** over Bluetooth LE (a local, scriptable equivalent of
  the web tool at <https://saso5.github.io/LYWSD02-clock-sync/>), runnable
  unattended from **Task Scheduler**.
- **A system-tray widget** that shows the current temperature in the taskbar,
  logs temperature/humidity/battery to CSV, opens a **Room state** dashboard that
  reads the room for you, and **alerts you** when something needs attention.
- **Optional Aranet4 support** — if you have an Aranet4 CO₂ monitor nearby, the
  widget also captures **CO₂ / temperature / humidity / pressure** (passively,
  no pairing) and graphs it as a second device alongside the clock.

Everything is plain PowerShell plus a little C# that Windows PowerShell compiles
itself (once; the result is cached in `logs\cache`). Bluetooth LE goes through
the built-in Windows Runtime (WinRT) APIs.
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
| `Tray-LYWSD02.ps1`   | System-tray widget: tray icon, dashboard, alerts, scheduling. |
| `Vulcan.Core.cs`     | Compiled core used by the widget: in-memory history, the inference maths, drawing, custom controls. |
| `Compile-Cache.ps1`  | Shared helper: compile a C# source once and reuse the cached DLL. |
| `Install-Widget.ps1` | Installs/removes the tray widget + login startup. |
| `Start-Widget.vbs`   | Launches the widget with no console window. |
| `Read-Aranet4.ps1`   | Standalone CLI: read CO₂/temp/humidity/pressure from a nearby Aranet4. |
| `Watch-Aranet4.ps1`  | Persistent Aranet4 listener used by the widget (writes latest reading to JSON). |
| `settings.json`      | Widget settings — generated locally, git-ignored. |
| `logs\sensors.csv`   | LYWSD02 temperature/humidity/battery history — generated locally, git-ignored. |
| `logs\aranet4.csv`   | Aranet4 CO₂/temp/humidity/pressure history — generated locally, git-ignored. |
| `logs\*.log`, `logs\aranet-latest.json` | Run logs (each kept under 1 MB) / latest Aranet reading — generated locally, git-ignored. |
| `logs\cache\`       | Compiled helper DLLs — rebuilt automatically when the source changes. |

## Taskbar widget

A system-tray widget shows the **current temperature right in the taskbar** and
keeps a history. Install / start it with:

```powershell
.\Install-Widget.ps1 -Address AA:BB:CC:DD:EE:FF
```

It adds a Startup shortcut (so it returns after reboot) and launches immediately.
Find the icon in the tray (click the `^` overflow, then drag it onto the taskbar
to keep it visible).

The icon shows the rounded temperature (e.g. `23`) and its **colour is the room's
state**: blue when all is well, amber when something wants attention, red when
you should act, grey when Bluetooth is off. **Hovering** pops up a frameless
summary — the verdict, the four current readings, a 6-hour CO₂ sparkline and any
active alert. Click it, or double-click the icon, to open the dashboard.

**Right-click** the icon for the menu:

| Menu item | What it does |
|-----------|--------------|
| **Open dashboard** / **Trends…** | Open the Room state window / the zoomable history graphs. |
| **Read now** | Read the clock over Bluetooth and show the latest Aranet4 measurement. |
| **Sync clock time** | Set the clock's time over Bluetooth. |
| **Bluetooth connection** | Toggle all BLE on/off. Off = battery saver; the icon greys out. |
| **Aranet4 CO2 monitor** | Enable/disable the Aranet4 listener. |
| **Log readings to CSV** | Turn CSV logging on/off (both devices). |
| **Notifications** | Turn alert pop-ups on/off (alerts still show in the dashboard). |
| **Clock read interval ▸** | How often to read the clock (5 / 10 / 15 / 30 / 60 min). |
| **Open data folder** | Open the `logs` folder (CSVs + logs). |
| **Start when I sign in** | Toggle the Startup shortcut. |
| **Exit** | Close the widget. |

On launch the widget shows the **last logged values at once** rather than waiting
for the first Bluetooth read.

## Dashboard

**Double-click the tray icon** (or use the menu, or click the hover popup) to open
the **Room state** window. It reads the room and presents the **meaning, not the
raw gauges**: one plain-language verdict, then a small set of quiet cards that each
answer a human question. A healthy room is almost silent — one accent colour, and
no motion beyond a single breathing dot. Light and dark are both first-class.

- **Room verdict** (top) — one line ("Air is getting stuffy and comfortable. One
  or two people.") with a state dot that breathes. Under it, the **room name —
  click it to rename the room in place** — and when the view was last worked out.
- **Alerts** — a strip of chips that appears under the verdict only while
  something needs attention (see [Alerts](#alerts)).
- **Air quality** — CO₂ in ppm on a threshold band (fresh / fine / stuffy / poor),
  how fast it is rising or falling, the share of each breath that is rebreathed
  air, and a plain note on what that level does to concentration.
- **Occupancy** — a **band** (empty / 1–2 / several / a crowd), never an exact
  count. See [How the inferences are made](#how-the-inferences-are-made).
- **Live vitals** — temperature, humidity, CO₂ and pressure, each with a 6-hour
  sparkline and the change over the last hour. Temperature and humidity come from
  the clock; if the clock goes quiet the Aranet4's own sensor fills in (the tile
  says *via Aranet4*).
- **Ventilation** — a band (poor / moderate / good / breezy) from the room's
  air-change rate, labelled either *measuring now* (a CO₂ fall is in progress) or
  *usual for this room* (the median of the falls seen over 30 days).
- **Comfort** — dew point, how that feels, relative humidity on the 40–60% comfort
  band, and absolute humidity.
- **Outside** — pressure tendency over 3 hours in standard terms (steady / falling
  slowly / falling / falling quickly) with a one-line outlook. There is no
  outdoor sensor; this is read through the wall.
- **Today** — a 24-hour timeline of CO₂ (filled area) and inferred occupancy
  (stepped line), with night shading and a "now" marker. Hover to read any moment;
  click to open the full trends graphs.
- **Action bar** (bottom) — **Read now** (also `F5`), **Sync clock time**,
  **Trends**, **Settings**. To its right, a quiet status line (last read of each
  device, batteries, the Aranet's measurement interval) which is replaced for a
  few seconds by the result whenever a read finishes.
- **Settings** (slides in from the right; `Esc` closes) — room name and **volume
  (m³)**, Bluetooth connection, Aranet4 tracking, CSV logging, clock read
  interval, notifications and quiet hours, light/dark theme, start at sign-in,
  and a button to open the data folder.

Everything you change is saved at once and mirrored in the tray menu.

Numbers tween to their new value, the verdict cross-fades, and a card settles
briefly when the room's state changes; nothing animates otherwise. Each card
handles its own **loading**, **empty** ("waiting for sensor") and **stale**
(dimmed, with the age) states. If Windows is set to reduce motion, all of it is
switched off and changes apply instantly.

### Alerts

The widget speaks up only for things worth interrupting you for. Each alert shows
as a chip in the dashboard, turns the tray icon amber or red, and (unless
notifications are off, or it is between 22:00 and 07:00 with *quiet at night* on)
raises one Windows notification. Nothing is announced while the PC is locked; if
it is still true when you unlock, you are told then. Each has a margin so it does not flap at the
threshold, a hold time so a blip is ignored, and a re-notify interval so it does
not nag.

| Alert | Raised when | Clears when |
|-------|-------------|-------------|
| **CO₂ is high** | ≥ 1400 ppm for 3 min | below 1200 ppm |
| **CO₂ is very high** | ≥ 2000 ppm for 2 min | below 1800 ppm |
| **Humidity is high** | ≥ 70% RH for 30 min (mould risk) | below 66% |
| **Air is very dry** | ≤ 25% RH for 30 min | above 28% |
| **Room is hot / cold** | ≥ 30 °C / ≤ 12 °C for 15 min | 29 °C / 13 °C |
| **Aranet4 is quiet** | no broadcast for 45 min while you are at the PC | a broadcast arrives |
| **Clock not reached** | no successful read for 3 intervals (min. 60 min) | a read succeeds |
| **Battery low** | clock ≤ 10%, Aranet4 ≤ 15% | after new batteries |
| **Pressure dropping fast** | falling ≥ 3.6 hPa in 3 h (dashboard only) | slower than 3 hPa |

### How the inferences are made

Occupancy, ventilation and the outdoor outlook are **inferences** from five inputs
(temperature, humidity, CO₂, pressure, time) — not measurements. The maths lives
in `Vulcan.Core.cs` (`Model`), where it can be read and tested.

- **Outdoor baseline.** Rather than assuming 420 ppm, the widget takes the 2nd
  percentile of the last 14 days of CO₂ (a room that is ever aired bottoms out at
  outdoor level), clamped to 380–500 ppm. This also absorbs the sensor's
  calibration offset.
- **Ventilation (air changes per hour, ACH).** CO₂ in a room follows
  `dC/dt = S − k·(C − C_out)`. Whenever CO₂ **falls**, the excess decays as
  `exp(−k·t)`, so `ln(C − C_out)` against time is a straight line of slope `−k`.
  The widget finds every fall in the data (a peak down to a trough, confirmed by
  a 30 ppm reversal, at least 40 ppm and 7 minutes), fits it, and keeps those with
  a good fit. If people stay in the room the fall levels off *above* outdoor and
  that simple fit reads low, so when the levelling-off is unmistakable the
  asymptote is fitted too. A fall in progress is shown as a live measurement;
  otherwise the card shows the median of the falls from the last 30 days, so it
  always has an answer once one fall has been seen.
- **Occupancy.** From the same mass balance, including the transient term:
  `n = V·(dC/dt + k·(C − C_out)) / G`, with `V` the room volume you set, `k` the
  air-change rate (the live value during a fall, otherwise the room's
  closed-window rate — the lower quartile of the 30-day falls), and `G` the CO₂ one
  person adds (0.0186 m³/h awake, 0.013 m³/h asleep at night). The transient term
  matters: a room that has just emptied reads *empty* while its CO₂ is still
  high, and a room that is filling reads correctly before it plateaus. While a
  window is open the balance cannot tell "empty" from "occupied and airing", so
  the count from just before the airing is held and the card says so. Because
  three uncertain inputs are multiplied, the result is shown as a **band**.
- **Rebreathed air.** `(C − C_out) / 38000` — the fraction of each breath that
  has already been exhaled by someone in the room (Rudnick & Milton).
- **Dew point** uses the Magnus formula (`a = 17.62`, `b = 243.12 °C`);
  **absolute humidity** is `216.7 · e / (273.15 + T)` g/m³ with `e` the vapour
  pressure from the same formula.
- **Pressure tendency** is the least-squares slope over the last 3 hours (it needs
  at least an hour of readings), reported per 3 hours.

Configure with `Install-Widget.ps1` parameters: `-Address`, `-IntervalMinutes`
(clock, default 60), `-ScanSeconds` (default 90), `-NoStartup`. Remove with
`.\Install-Widget.ps1 -Uninstall` (keeps your CSVs and settings).

### The trends graph

Open it from **Trends** in the dashboard or tray menu, or by clicking the *Today*
card. The window shows the two devices as **separate stacked charts**. Pick a
range (last hour to all time, or custom dates), **scroll to zoom** around the
cursor and drag the scrollbar to pan; both charts stay time-aligned. Long ranges
are thinned to about 2,000 real samples per line (keeping peaks and shape) so
months of data draw instantly, and a zoomed view is re-sampled at full detail.
Lines break only across real outages of two hours or more.

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
its axis, so the lines stay distinct where they cross (point markers appear when
the data is sparse enough for them to help). Dew point is the temperature at which the air would become saturated —
when the room temperature nears the dew-point line, it feels muggy.

The history lives in two plain CSV files, loaded into memory once at launch and
appended as readings arrive:

```
# logs\sensors.csv  (LYWSD02, one row per read, every -IntervalMinutes)
timestamp,tempC,tempF,humidity,battery
2026-01-31 18:50:15,22.96,73.3,46,87

# logs\aranet4.csv  (Aranet4, one row per measurement, stamped when it was measured)
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

**How the widget captures it.** The Aranet measures on its own timer (1, 2, 5 or
10 minutes, set in the Aranet app) and cannot be commanded, and a short scan
often misses its broadcast. So the widget runs one **persistent background
listener** (`Watch-Aranet4.ps1`) that writes each broadcast to
`logs\aranet-latest.json`. The widget picks up every new **measurement** within a
few seconds and logs it once, stamped with the time it was actually measured
(each broadcast says how old its measurement is). While the widget talks to the
clock the listener **pauses its scan** — it is not restarted — so the two never
compete for the radio.

- The device is matched by **company id `0x0702`**, not a fixed address (its
  address rotates for privacy).
- **Read now** shows the latest measurement and how old it is; if nothing has been
  heard for a while it waits up to 90 seconds for the next broadcast.
- Turn capture off entirely with **Aranet4 CO2 monitor** in the menu or Settings.

**Decode** (advertisement manufacturer data `0x0702`): an 8-byte header (bit
`0x20` of byte 0 set = measurements present), then at offset 8 —
`CO₂` u16 ppm · `temp` u16 ÷20 °C · `pressure` u16 ÷10 hPa · `humidity` u8 % ·
`battery` u8 % · `status` u8 (1 green / 2 amber / 3 red) · `interval` u16 s ·
`age` u16 s (seconds since the measurement was taken).

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
  The widget trims each log to its most recent 256 KB once it passes 1 MB.
- **Checking the widget after a change:** `.\Tray-LYWSD02.ps1 -SelfTest <folder>`
  builds every window against your real data, saves screenshots to the folder and
  prints timings. It touches no device or setting, and can run while the widget
  is running.
- **PowerShell execution policy:** the install scripts and scheduled task launch
  with `-ExecutionPolicy Bypass`, so you don't need to change your machine policy.

## License

MIT — see [LICENSE](LICENSE).
