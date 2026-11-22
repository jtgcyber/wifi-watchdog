# WiFi Watchdog

A small PowerShell watchdog that keeps a **headless Windows PC** on WiFi. It was
written for an astrophotography PC that sits outside with no screen, where going
out to replug the USB WiFi dongle at 2am in -5°C is not an option.

## Background: the problem this solves

### The setup

The PC is a small fanless mini PC (Celeron N5095, Windows 11) that runs an
astrophotography rig in the garden: a USB 3 cooled colour camera, a USB 2 guide
camera, and the mount on a USB-serial cable, all on the same USB 3 controller.
N.I.N.A. runs the imaging sequence and PHD2 does the guiding. It has no screen,
keyboard or Ethernet. Everything is done over Remote Desktop, through a TP-Link
USB WiFi dongle with a Realtek chipset.

So WiFi is the only way in. If it drops and stays down, the imaging carries on,
but I can't see it, check focus, fix a guiding problem or end the session. The
only fix is to go outside and replug the dongle.

### Round one: constant drops (fixed)

The first problem was the dongle dropping every 30-60 seconds, about 130 times in
three days. The WLAN AutoConfig log showed *"The network is disconnected by the
driver"*, then a failed reassociation (*"The operation was cancelled"*), then a
reconnect a few seconds later. Signal was fine (around -60 dBm on 5 GHz, with a
nearly empty channel), so I suspected roaming between access points and spent a
while on that.

The real pattern was in the timestamps. The drops only happened while the imaging
gear was running, and they started 37 seconds after the cameras connected. The dongle
was sitting right next to the USB 3 camera and its cables. USB 3 is a well-known
source of 2.4/5 GHz interference. Moving the dongle away on an extension took it
from 15-48 drops an hour to **zero across a full 12-hour imaging night**.

### Round two: the drop that never recovers (this script)

Even with the noise fixed, the dongle still drops occasionally. Usually Windows
reconnects within 10-50 seconds and nobody notices. But sometimes it doesn't
reconnect at all. Here is the WLAN AutoConfig log from one of those times:

```
10:49-10:50  security stopped/started repeatedly (link flapping)
10:50:38     Network Disconnected     (no normal "disconnected by the driver" event)
10:50:43     8000  started a connection to a wireless network
10:50:51     8002  failed to connect: "The specific network is not available"
             ...nothing at all for 33 minutes, not even a retry...
11:23:32     8000  started a connection   (dongle unplugged and replugged)
11:23:33     8001  successfully connected
```

The access point was up and other devices were fine. *"The specific network is not
available"* means the adapter's own scan couldn't see it: the dongle's radio had
locked up. Windows made one attempt and then gave up, and nothing recovers it short of
re-initialising the hardware. Replugging does that, but at 2am in -5°C that is
not a fix.

That has two consequences for the design:

1. **Just running `netsh wlan connect` isn't enough.** If the radio is wedged, a
   reconnect request fails the same way Windows' own attempt did. The watchdog has
   to be able to reset the adapter and, as a last step, restart the USB device, which
   is the software version of a replug.
2. **It has to keep trying, forever, unattended.** It must run with nobody logged in,
   survive reboots, and never give up. It also must never do anything that would wreck
   an imaging session in progress, such as rebooting the PC or resetting the USB
   controller the cameras share.

Off-the-shelf "WiFi reconnect" tools mostly do the first thing only: a reconnect or an
internet check, running in the logged-in user's session. So I wrote this instead.

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
