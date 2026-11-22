# WiFi Watchdog

A small PowerShell watchdog that keeps a **headless Windows PC** on WiFi. It was
written for an astrophotography PC that sits outside with no screen, where going
out to replug the USB WiFi dongle at 2am in -5°C is not an option.

## The problem

Some USB WiFi adapters (Realtek-based ones especially) occasionally lock up. In the
WLAN AutoConfig event log it looks like this:

```
10:50:38  Network Disconnected            (no normal "disconnected" event)
10:50:43  8000  started a connection to a wireless network
10:50:51  8002  failed to connect: The specific network is not available
          ...nothing for 33 minutes...
11:23:32  8000  started a connection      (dongle unplugged and replugged)
11:23:33  8001  successfully connected
```

The router was fine. The adapter's radio stopped seeing it, and Windows made one
attempt and then gave up. Replugging re-initialises the dongle. This script does
the software equivalent automatically.

## What it does

Every 60 seconds it checks that:

- the WiFi adapter exists and is **Up**, and
- the **default gateway** (or 1.1.1.1 / 8.8.8.8) answers a ping, which also catches
  "connected but dead".

After **2 failed checks in a row** (so Windows' own quick reconnects, normally 10-50 s,
are left alone), it works up a recovery ladder and stops as soon as the link is healthy:

| Step | Action | Roughly equivalent to |
|------|--------|-----------------------|
| 1 | Re-enable the adapter if it's disabled | |
| 2 | `netsh wlan connect` to the **last profile it was connected to** | clicking the network |
| 3 | Restart the WLAN AutoConfig service, then reconnect | |
| 4 | `Restart-NetAdapter` (disable/enable), then reconnect | reloading the driver |
| 5 | `pnputil /restart-device` on the USB WiFi device, then reconnect | unplugging and replugging |

If the whole ladder fails it **keeps going forever**. It still checks every minute
(in case Windows recovers by itself) and reruns the ladder after 1, 2, 4 and 8 minutes,
then every 15 minutes.

### Safety

- **No reboots by default.** A reboot would kill a running imaging session. With
  `-AllowReboot` it can reboot as a last resort, but only after several failed
  cycles, never within 30 minutes of boot, and never while NINA, PHD2, SharpCap,
  APT, SGPro or ASIStudio is running.
- Only the WiFi device is touched. It never resets the parent USB hub or
  controller, so cameras, mount and focuser on the same bus are not affected.
- The installed script lives in `C:\Program Files\WifiWatchdog` (admin-only write),
  because it runs as SYSTEM.
- It remembers the adapter, profile, gateway and USB device ID from the last healthy
  connection, in `C:\ProgramData\WifiWatchdog\state.json`. It does not store passwords;
  it uses the WiFi profiles Windows already has. Profiles must be saved for **all
  users** (the default when connecting through Windows settings) so that SYSTEM can
  use them with nobody logged in.

## Install

From an **administrator** PowerShell in this folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-WifiWatchdog.ps1
```

This auto-detects the WiFi adapter that is connected right now, registers a
scheduled task called **WiFi Watchdog** (runs as SYSTEM, at startup, and re-launched
within 5 minutes if it ever stops), and starts it.

Options:

```powershell
.\Install-WifiWatchdog.ps1 -AdapterName 'WiFi 2'      # pick the adapter explicitly
.\Install-WifiWatchdog.ps1 -ProfileName 'MyNetwork'   # always reconnect to this profile
.\Install-WifiWatchdog.ps1 -CheckIntervalSec 120      # check less often
.\Install-WifiWatchdog.ps1 -AllowReboot               # allow a last-resort reboot when idle
```

Re-run the installer after editing `WifiWatchdog.ps1` to deploy the new version.

## Check on it

```powershell
Get-Content C:\ProgramData\WifiWatchdog\watchdog.log -Tail 40
Get-Content C:\ProgramData\WifiWatchdog\watchdog.log -Tail 20 -Wait   # live
Get-ScheduledTask 'WiFi Watchdog' | Get-ScheduledTaskInfo
```

The log records every drop, what fixed it and how long it was down, plus an hourly
"OK" line with signal strength. It rotates at 1 MB, keeping one old file.

Example:

```
2026-11-23 01:12:04 [WARN] Connection problem: adapter 'WiFi 2' is Disconnected
2026-11-23 01:13:04 [INFO] Recovery attempt 1 (down for 1m 00s; adapter 'WiFi 2' is Disconnected)
2026-11-23 01:13:04 [INFO] Action: connect 'WiFi 2' to profile 'MyNetwork'
2026-11-23 01:13:35 [INFO] Action: restart the WLAN AutoConfig service
2026-11-23 01:14:26 [INFO] Action: restart adapter 'WiFi 2'
2026-11-23 01:14:52 [INFO] Back online after 2m 48s - fixed by: adapter restart
```

## Test without changing anything

From a normal (non-admin) PowerShell:

```powershell
# One health check; logs what it *would* do if the link were down
.\WifiWatchdog.ps1 -Once -DryRun -DataDir $env:TEMP\wifiwatchdog-test

# Exercise the recovery path by pointing it at an adapter that is not connected
.\WifiWatchdog.ps1 -Once -DryRun -AdapterName 'Ethernet' -DataDir $env:TEMP\wifiwatchdog-test
```

## Uninstall

```powershell
.\Uninstall-WifiWatchdog.ps1             # keeps the log
.\Uninstall-WifiWatchdog.ps1 -RemoveData # deletes the log and state too
```

## Requirements

- Windows 10/11 with Windows PowerShell 5.1 (built in). Nothing to install.
- `pnputil /restart-device` needs Windows 10 2004 or later. Older builds fall back to
  disable/enable of the device.

## A watchdog is a safety net, not a cure

If the drops are frequent, look at the cause too: USB 3 noise near the dongle (move
it away on an extension cable, or use a USB 2 port), USB power saving, the driver,
or use Ethernet if you can.
