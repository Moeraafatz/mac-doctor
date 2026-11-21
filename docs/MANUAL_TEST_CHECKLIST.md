# Mac Doctor — Manual Test Checklist

Run through this checklist on a **MacBook Air M4** (macOS 15 and/or macOS 26) after building a Release `.app` or installing from `dist/MacDoctor-<version>.dmg`.

---

## 1. Launch, Packaging & Menu Bar
- [ ] Run `./build_dmg.sh --adhoc` (or Developer ID build) and verify `dist/MacDoctor-<version>.dmg` mounts cleanly with `Mac Doctor.app` and an `Applications` symlink.
- [ ] Drag `Mac Doctor.app` to `/Applications` and launch it (completing Gatekeeper Open Anyway once for ad-hoc builds).
- [ ] Confirm **no Dock icon** appears (`LSUIElement = YES`) and the menu bar stethoscope icon appears.
- [ ] Click the menu bar icon — popover opens smoothly (~380 pt wide) with Liquid Glass surfaces on macOS 26 or translucent materials on macOS 15.
- [ ] Verify the app icon in `/Applications` and Finder displays the Mac Doctor icon cleanly.

## 2. Overview Tab
- [ ] **CPU panel:** Total %, P-core vs E-core cluster split bars, and 60-second sparkline update smoothly on cadence.
- [ ] **GPU tile:** Shows utilization %, model name, and core count (or `"Unavailable"` cleanly if absent).
- [ ] **Memory tile:** Shows used/total GB, pressure state (`Normal` / `Warning` / `Critical`), and swap used when > 0.
- [ ] **Disk tile:** Shows free space, total capacity, and live read/write throughput.
- [ ] **Battery tile:** Shows %, charging/plugged-in/on-battery state, power draw in watts (`W`), and hover tooltip showing health %, cycle count, watts, and battery °C.
- [ ] **Thermal tile:** Matches `ProcessInfo.thermalState` (`Nominal` / `Fair` / `Serious` / `Critical`) and Low Power Mode indicator.
- [ ] **Network tile:** Shows live `↓` download and `↑` upload throughput.

## 3. Temperatures Tab
- [ ] Confirm **no fan section** exists anywhere in the app.
- [ ] Verify live readings populate for **CPU P-cores**, **CPU E-cores**, **GPU**, **SoC die**, **Battery**, and **SSD** (any unreadable group explicitly shows `"Unavailable"`, never fake numbers or 0 °C).
- [ ] Expand multi-sensor rows (e.g. CPU P-cores, SoC die) and verify individual sensor tiles appear with SMC key / HID name tooltips on hover.
- [ ] Generate brief CPU load (`yes > /dev/null` for 15s, then `Ctrl-C`) and verify P-core and Hottest Sensor temperatures rise cleanly.

## 4. Processes (Task Manager) Tab
- [ ] Live list refreshes every 2s (4s in Low Impact Mode on battery) with app icon, name, PID, CPU %, memory, energy, and network columns.
- [ ] Sort by **CPU**, **Memory**, **Energy**, and **Network** — confirm ordering updates immediately without UI jitter.
- [ ] Search by app name, executable name, and numeric PID; verify clear button works.
- [ ] Verify energy values without `ri_energy_nj` are explicitly labelled **`est.`** / **`estimated`** (with legend strip shown when present).
- [ ] **Hard blocklist check:** Search for `kernel_task`, `launchd`, `WindowServer`, `loginwindow`, `logd`, `opendirectoryd`, `coreaudiod`, `securityd`, `trustd`, `mds`, `mds_stores`, `systemstats`, `SystemUIServer`, `Dock`, and `Mac Doctor` — every one shows a disabled lock icon with a descriptive hover tooltip and cannot be quit.
- [ ] **Other-user check:** Verify a `root`-owned process cannot be quit and shows `"Only processes owned by the current user can be quit"`.
- [ ] **Finder check:** Search for `Finder` — shows relaunch icon (`arrow.clockwise.circle.fill`) with tooltip `"Finder cannot be killed — relaunch only"`; clicking opens a **Relaunch Finder** confirmation sheet (never Force Quit) and relaunches Finder cleanly.
- [ ] **GUI App Quit:** Launch TextEdit with unsaved text → click Quit → verify confirmation sheet displays `TextEdit`, PID, and unsaved-work warning → confirm → verify TextEdit prompts to save via `NSRunningApplication.terminate()`.
- [ ] **Background Process Two-Step Escalation (SIGTERM → SIGKILL):**
  1. Run `python3 -c "import signal,time; signal.signal(signal.SIGTERM, lambda *a: None); time.sleep(120)"` in Terminal.
  2. Find `python3` in Mac Doctor → click Quit → confirm Sheet 1 (`SIGTERM`).
  3. Confirm process stays alive and button changes to red **Force** → click **Force** → confirm Sheet 2 (`SIGKILL` warning) → verify process exits immediately.
- [ ] **Top Offenders banner:** Run `yes > /dev/null` for >60s → confirm `yes` appears in **TOP OFFENDERS** with sustained CPU duration; clicking the banner entry filters to its PID.

## 5. Network Tab
- [ ] Live `↓ Download` / `↑ Upload` rates and dual-series 60s throughput graph react during a file download or video stream.
- [ ] **Speed Test:**
  - Click **Run Test** → verify progress spinner + elapsed seconds appear → click **Cancel** → verify `/usr/bin/networkQuality` terminates cleanly.
  - Run a full speed test → verify Download Mbps, Upload Mbps, Responsiveness (RPM), and Latency (ms) appear and save into **History (1/20)** across app restarts.
- [ ] **Ping:**
  - Run against `1.1.1.1` and `8.8.8.8` → confirm Latency, Jitter, min/max, and Packet Loss populate.
  - Choose **Custom** → test invalid/injection inputs (`1.1.1.1; id`, `-f`, `$(whoami)`, `http://apple.com`) → verify red indicator and disabled **Ping** button.
  - Enter `apple.com` → verify ping completes cleanly.
- [ ] **Connection & Wi-Fi:** Verify Interface (`Wi-Fi` / `Ethernet`), Local IP, Router IP, RSSI, Noise, SNR, Channel & Band.
- [ ] **SSID privacy:** Before granting Location Services, confirm SSID shows **`Hidden (permission needed)`** with an **Allow** button; after granting, confirm the real SSID displays.
- [ ] **Public IP privacy:** Confirm Public IP shows **`Hidden`** by default with zero background traffic; tap **Show** → verify public IP loads with **Copy** and **Hide** controls.

## 6. Settings, Menu Bar & Alerts
- [ ] Switch **Live Readout** across `Icon`, `CPU`, `Temp`, and `Net`, and switch **Icon** between `Stethoscope` and `Vitals` — confirm menu bar updates live even when popover is closed.
- [ ] Toggle `°C` ↔ `°F` and confirm Settings slider, Temps tab, and menu bar temp readout all update immediately.
- [ ] Switch **Refresh Interval** (`1s` / `2s` / `5s`) and confirm active polling interval updates.
- [ ] Unplug power with **Low Impact Mode** enabled → confirm `"Active on battery · polling every 5s"` (or `10s` at `5s` base) appears.
- [ ] Toggle **Launch at Login** on/off from `/Applications/Mac Doctor.app` → confirm it registers/unregisters in **System Settings → General → Login Items & Extensions**.
- [ ] Enable **macOS Notifications** → grant permission → click **Send Test** → verify local banner appears.
- [ ] Trigger a threshold alert (e.g. lower CPU threshold to `60%` + run `yes > /dev/null` for 35s, or lower temp threshold temporarily) → verify the menu bar icon turns **amber/red** and delivers one notification (with 5-minute cooldown). Click **Reset Defaults** afterward.

## 7. Accessibility, Appearance & Resource Budget
- [ ] Test both **Light Mode** and **Dark Mode** across all 5 tabs.
- [ ] Enable **Reduce Transparency** (System Settings → Accessibility → Display) → confirm glass surfaces switch cleanly to opaque system surfaces with crisp contrast.
- [ ] Enable **Reduce Motion** → confirm tab transitions, gauges, and button animations disable cleanly.
- [ ] **Privacy check:** Launch Mac Doctor without touching Speed Test / Ping / Show Public IP and inspect network connections (`lsof -i -a -p $(pgrep "Mac Doctor")` or Little Snitch) — confirm **zero outbound network connections**.
- [ ] **Performance budget check:** Leave Mac Doctor running for 5+ minutes with popover closed and inspect in Activity Monitor — confirm average CPU **< 1%** and memory footprint **~60 MB** or lower.
- [ ] Check `log stream --predicate 'subsystem == "com.macdoctor.app"'` in Terminal to verify clean logging with no unexpected errors.
