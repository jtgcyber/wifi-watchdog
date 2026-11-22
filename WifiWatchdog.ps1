<#
.SYNOPSIS
    Keeps a headless Windows PC on WiFi. Checks the link every minute and, if it is
    down, escalates until it comes back: reconnect -> restart WLAN service ->
    restart adapter -> restart the USB device. It never gives up.

.DESCRIPTION
    Some USB WiFi adapters (Realtek-based ones especially) occasionally lock up:
    Windows reports "The specific network is not available", makes one attempt to
    reconnect and then sits disconnected indefinitely. Unplugging and replugging
    the dongle fixes it. This script does the software equivalent automatically.

    Health check (every -CheckIntervalSec seconds):
      * the wireless adapter exists and is Up (associated), and
      * the default gateway, or one of -PingTargets, answers a ping.

    After -FailuresBeforeAction failed checks in a row, it works through a
    recovery ladder, stopping as soon as the connection is healthy again:
      1. Re-enable the adapter if it is disabled
      2. netsh wlan connect to the last-used profile
      3. Restart the WLAN AutoConfig service, then reconnect
      4. Restart the network adapter (disable/enable), then reconnect
      5. Restart the USB device itself (pnputil /restart-device), then reconnect
    If the whole ladder fails, it keeps checking every interval and runs the
    ladder again with a growing gap (1, 2, 4, 8, then every 15 minutes), forever.

    It never reboots unless -AllowReboot is given, and even then never while
    imaging software (NINA, PHD2, ...) is running.

    Designed to run as SYSTEM from a scheduled task (see Install-WifiWatchdog.ps1).
    Steps 3-5 need administrator rights.

.EXAMPLE
    .\WifiWatchdog.ps1 -Once -DryRun
    One health check; if unhealthy, logs what it would do without doing it.

.EXAMPLE
    .\WifiWatchdog.ps1 -AdapterName 'WiFi 2'
    Run continuously against a specific adapter (normally done by the scheduled task).
#>
[CmdletBinding()]
param(
    # Network adapter to watch (as shown by Get-NetAdapter). Default: auto-detect.
    [string]$AdapterName,

    # WiFi profile to reconnect to. Default: whichever profile it was last connected to.
    [string]$ProfileName,

    [ValidateRange(10, 3600)]
    [int]$CheckIntervalSec = 60,

    # Consecutive failed checks before taking action (gives Windows time to reconnect itself).
    [ValidateRange(1, 30)]
    [int]$FailuresBeforeAction = 2,

    # Tried after the default gateway.
    [string[]]$PingTargets = @('1.1.1.1', '8.8.8.8'),

    # Where the log and state file live.
    [string]$DataDir = (Join-Path $env:ProgramData 'WifiWatchdog'),

    [int]$MaxLogBytes = 1MB,

    # Allow a reboot as a last resort (off by default).
    [switch]$AllowReboot,

    # Failed recovery cycles before a reboot is considered (only with -AllowReboot).
    [ValidateRange(1, 100)]
    [int]$RebootAfterCycles = 4,

    # A reboot is never done while any of these processes is running.
    [string[]]$BlockRebootProcesses = @('NINA', 'PHD2', 'SharpCap', 'APT', 'Sequence Generator', 'ASIStudio', 'ASIImg'),

    # Log what would be done without changing anything.
    [switch]$DryRun,

    # Run a single check (and one recovery pass if unhealthy), then exit.
    [switch]$Once
)

$LogPath   = Join-Path $DataDir 'watchdog.log'
$StatePath = Join-Path $DataDir 'state.json'

# ---------------------------------------------------------------- helpers

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt $MaxLogBytes) {
            Move-Item -Path $LogPath -Destination "$LogPath.1" -Force
        }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch { }
    Write-Host $line
}

function Format-Span([timespan]$Span) {
    if ($Span.TotalHours -ge 1) { return '{0}h {1:00}m' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes }
    '{0}m {1:00}s' -f [int][math]::Floor($Span.TotalMinutes), $Span.Seconds
}

function Pause-For([int]$Seconds) {
    if (-not $DryRun) { Start-Sleep -Seconds $Seconds }
}

function Read-State {
    $s = @{ LastProfile = $null; LastGateway = $null; LastAdapterName = $null; LastInstanceId = $null }
    if (Test-Path $StatePath) {
        try {
            $j = Get-Content -Path $StatePath -Raw | ConvertFrom-Json
            foreach ($k in @($s.Keys)) {
                if ($j.PSObject.Properties[$k]) { $s[$k] = $j.$k }
            }
        } catch {
            Write-Log "Could not read state file: $($_.Exception.Message)" 'WARN'
        }
    }
    $s
}

function Save-State {
    try {
        $script:State | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
    } catch {
        Write-Log "Could not save state file: $($_.Exception.Message)" 'WARN'
    }
}

# Remember what a healthy connection looks like, so recovery knows what to aim for.
function Update-State($Health) {
    $new = @{
        LastAdapterName = $Health.Adapter.Name
        LastInstanceId  = $Health.Adapter.PnPDeviceID
        LastGateway     = $Health.Gateway
        LastProfile     = $Health.Profile
    }
    $changed = $false
    foreach ($k in $new.Keys) {
        if ($new[$k] -and $script:State[$k] -ne $new[$k]) { $script:State[$k] = $new[$k]; $changed = $true }
    }
    if ($changed) {
        Save-State
        Write-Log ("Remembering: adapter '{0}', profile '{1}', gateway {2}" -f $script:State.LastAdapterName, $script:State.LastProfile, $script:State.LastGateway)
    }
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- inspection

function Get-WifiAdapter {
    $name = $AdapterName
    if (-not $name) { $name = $script:State.LastAdapterName }
    if ($name) {
        # Get-NetAdapter -Name also returns adapters that are 'Not Present' (unplugged / fallen off USB).
        $a = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
        if ($a) { return $a }
        if ($AdapterName) { return $null }
    }
    $wifi = @(Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.PhysicalMediaType -eq 'Native 802.11' -and -not $_.Virtual })
    $up = $wifi | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if ($up) { return $up }
    $wifi | Where-Object { $_.Status -ne 'Not Present' } | Select-Object -First 1
}

# Parse `netsh wlan show interfaces` into a hashtable for one interface.
function Get-WlanInfo([string]$Name) {
    $blocks = @()
    $cur = $null
    foreach ($line in (netsh.exe wlan show interfaces 2>$null)) {
        if ($line -match '^\s*([^:]+?)\s*:\s(.*)$') {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim()
            if ($k -eq 'Name') { $cur = @{}; $blocks += , $cur }
            if ($null -ne $cur -and -not $cur.ContainsKey($k)) { $cur[$k] = $v }
        }
    }
    $blocks | Where-Object { $_['Name'] -eq $Name } | Select-Object -First 1
}

function Get-DefaultGateway([int]$IfIndex) {
    $r = Get-NetRoute -InterfaceIndex $IfIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
        Sort-Object RouteMetric | Select-Object -First 1
    if ($r) { $r.NextHop }
}

function Test-Ping([string]$Target, [int]$Count = 2, [int]$TimeoutMs = 1500) {
    $p = New-Object System.Net.NetworkInformation.Ping
    try {
        for ($i = 0; $i -lt $Count; $i++) {
            try { if ($p.Send($Target, $TimeoutMs).Status -eq 'Success') { return $true } } catch { }
        }
    } finally { $p.Dispose() }
    $false
}

function Get-Health {
    $r = [ordered]@{ Healthy = $false; Reason = ''; Adapter = $null; Gateway = $null; Profile = $null; Wlan = $null }
    $a = Get-WifiAdapter
    $r.Adapter = $a
    if (-not $a) { $r.Reason = 'no wireless adapter found'; return [pscustomobject]$r }
    if ($a.Status -ne 'Up') { $r.Reason = "adapter '$($a.Name)' is $($a.Status)"; return [pscustomobject]$r }

    $w = Get-WlanInfo $a.Name
    $r.Wlan = $w
    if ($w) { $r.Profile = $w['Profile'] }

    $gw = Get-DefaultGateway $a.ifIndex
    $r.Gateway = $gw
    $targets = @()
    if ($gw) { $targets += $gw } elseif ($script:State.LastGateway) { $targets += $script:State.LastGateway }
    $targets += $PingTargets

    foreach ($t in $targets) {
        if (Test-Ping $t) { $r.Healthy = $true; $r.Reason = "reply from $t"; return [pscustomobject]$r }
    }
    $r.Reason = "adapter is up but no ping reply from $($targets -join ', ')"
    [pscustomobject]$r
}

function Format-Status($Health) {
    $w = $Health.Wlan
    if (-not $w) { $w = @{} }
    "OK - profile '{0}' on '{1}', signal {2} ({3} dBm), {4} ch {5}, rx/tx {6}/{7} Mbps" -f `
        $Health.Profile, $Health.Adapter.Name, $w['Signal'], $w['Rssi'], $w['Band'], $w['Channel'],
        $w['Receive rate (Mbps)'], $w['Transmit rate (Mbps)']
}

function Wait-Healthy([int]$Seconds) {
    if ($DryRun) {
        $h = Get-Health
        if ($h.Healthy) { return $h }
        return $null
    }
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        Start-Sleep -Seconds 5
        $h = Get-Health
        if ($h.Healthy) { return $h }
    } while ((Get-Date) -lt $deadline)
    $null
}

# ---------------------------------------------------------------- actions

# Run one recovery action, sending all its output to the log (never to the pipeline).
function Invoke-Step {
    param([string]$Description, [scriptblock]$Action, [object[]]$ArgumentList = @())
    if ($DryRun) { Write-Log "DRY RUN - would $Description"; return }
    Write-Log "Action: $Description"
    try {
        & $Action @ArgumentList 2>&1 | ForEach-Object {
            $t = "$_".Trim()
            if ($t) { Write-Log "    $t" }
        }
    } catch {
        Write-Log "    failed: $($_.Exception.Message)" 'WARN'
    }
}

function Connect-Profile([string]$Adapter) {
    $p = $ProfileName
    if (-not $p) { $p = $script:State.LastProfile }
    if (-not $p) {
        Write-Log 'No known WiFi profile yet, so leaving the reconnect to Windows' 'WARN'
        return
    }
    Invoke-Step "connect '$Adapter' to profile '$p'" {
        param($prof, $iface)
        netsh.exe wlan connect name="$prof" interface="$iface"
    } @($p, $Adapter)
}

function Restart-WifiDevice([string]$InstanceId) {
    pnputil.exe /restart-device "$InstanceId" 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -eq 3010) {
        'pnputil says a reboot is needed to finish restarting the device'
    } elseif ($LASTEXITCODE -ne 0) {
        "pnputil exit code $LASTEXITCODE; trying disable/enable instead"
        Disable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 5
        Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
        'device disabled and re-enabled'
    }
}

# Work up the ladder. Returns @{Step; Health} on success, $null if everything failed.
function Invoke-Recovery {
    $a = Get-WifiAdapter
    $name = $null
    $id = $null
    # The remembered device ID is only trusted if it belongs to the adapter we're watching.
    if (-not $AdapterName -or $AdapterName -eq $script:State.LastAdapterName) { $id = $script:State.LastInstanceId }
    if ($a) {
        $name = $a.Name
        if ($a.PnPDeviceID) { $id = $a.PnPDeviceID }
    }
    $present = $a -and $a.Status -ne 'Not Present'

    if ($present) {
        if ($a.Status -eq 'Disabled') {
            Invoke-Step "enable adapter '$name' (it was disabled)" { param($n) Enable-NetAdapter -Name $n -Confirm:$false } @($name)
            Pause-For 15
            $h = Wait-Healthy 30
            if ($h) { return @{ Step = 're-enable adapter'; Health = $h } }
        }

        Connect-Profile $name
        $h = Wait-Healthy 30
        if ($h) { return @{ Step = 'reconnect'; Health = $h } }

        Invoke-Step 'restart the WLAN AutoConfig service' { Restart-Service -Name WlanSvc -Force }
        Pause-For 10
        Connect-Profile $name
        $h = Wait-Healthy 40
        if ($h) { return @{ Step = 'WLAN service restart'; Health = $h } }

        Invoke-Step "restart adapter '$name'" { param($n) Restart-NetAdapter -Name $n -Confirm:$false } @($name)
        Pause-For 15
        Connect-Profile $name
        $h = Wait-Healthy 45
        if ($h) { return @{ Step = 'adapter restart'; Health = $h } }
    } else {
        $what = 'not found'
        if ($a) { $what = 'Not Present' }
        Write-Log "WiFi adapter is $what in Windows - the USB device may have dropped off the bus" 'WARN'
        Invoke-Step 'rescan for hardware changes' { pnputil.exe /scan-devices }
        Pause-For 10
        $h = Wait-Healthy 20
        if ($h) { return @{ Step = 'hardware rescan'; Health = $h } }
    }

    if ($id) {
        Invoke-Step "restart the WiFi device ($id)" { param($i) Restart-WifiDevice $i } @($id)
        Pause-For 20
        $a2 = Get-WifiAdapter
        if ($a2 -and $a2.Status -ne 'Not Present') { Connect-Profile $a2.Name }
        $h = Wait-Healthy 60
        if ($h) { return @{ Step = 'USB device restart'; Health = $h } }
    } else {
        Write-Log 'No USB device ID known yet, so the device cannot be restarted' 'WARN'
    }
    $null
}

function Test-RebootAllowed {
    if (-not $AllowReboot) { return $false }
    $uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    if ($uptime.TotalMinutes -lt 30) { Write-Log 'Reboot skipped: PC started less than 30 minutes ago'; return $false }
    $busy = @(Get-Process -Name $BlockRebootProcesses -ErrorAction SilentlyContinue)
    if ($busy.Count -gt 0) {
        Write-Log "Reboot skipped: $(($busy | Select-Object -ExpandProperty Name -Unique) -join ', ') running"
        return $false
    }
    $true
}

# ---------------------------------------------------------------- main

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

$mutex = $null
if (-not $Once) {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\WifiWatchdog')
    if (-not $mutex.WaitOne(0)) { Write-Log 'Another watchdog instance is already running; exiting'; exit 0 }
}

$script:State = Read-State
$mode = 'continuous'
if ($Once) { $mode = 'single check' }
if ($DryRun) { $mode += ', DRY RUN' }
Write-Log ("WiFi watchdog started ({0}; PID {1}; adapter '{2}'; check every {3}s; act after {4} failures; reboot {5})" -f `
    $mode, $PID, $(if ($AdapterName) { $AdapterName } else { 'auto' }), $CheckIntervalSec, $FailuresBeforeAction,
    $(if ($AllowReboot) { 'allowed' } else { 'never' }))
if (-not (Test-IsAdmin) -and -not $DryRun) {
    Write-Log 'Not running as administrator: only the reconnect step will work' 'WARN'
}

$failCount = 0
$cycle = 0
$downSince = $null
$nextRecovery = [datetime]::MinValue
$lastHeartbeat = [datetime]::MinValue

while ($true) {
    try {
        $h = Get-Health
        if ($h.Healthy) {
            if ($downSince) {
                Write-Log "Back online after $(Format-Span ((Get-Date) - $downSince)) - Windows reconnected by itself"
                $lastHeartbeat = [datetime]::MinValue
            }
            $failCount = 0; $cycle = 0; $downSince = $null; $nextRecovery = [datetime]::MinValue
            Update-State $h
            if ($Once -or ((Get-Date) - $lastHeartbeat).TotalMinutes -ge 60) {
                Write-Log (Format-Status $h)
                $lastHeartbeat = Get-Date
            }
        } else {
            $failCount++
            if (-not $downSince) {
                $downSince = Get-Date
                Write-Log "Connection problem: $($h.Reason)" 'WARN'
            }
            if (($Once -or $failCount -ge $FailuresBeforeAction) -and (Get-Date) -ge $nextRecovery) {
                $cycle++
                Write-Log "Recovery attempt $cycle (down for $(Format-Span ((Get-Date) - $downSince)); $($h.Reason))"
                $result = Invoke-Recovery
                if ($result) {
                    Write-Log "Back online after $(Format-Span ((Get-Date) - $downSince)) - fixed by: $($result.Step)"
                    Update-State $result.Health
                    Write-Log (Format-Status $result.Health)
                    $lastHeartbeat = Get-Date
                    $failCount = 0; $cycle = 0; $downSince = $null; $nextRecovery = [datetime]::MinValue
                } else {
                    $delay = [int][math]::Min(900, 60 * [math]::Pow(2, [math]::Min($cycle - 1, 4)))
                    $nextRecovery = (Get-Date).AddSeconds($delay)
                    Write-Log ("Recovery attempt {0} failed. Still checking every {1}s; next attempt no earlier than {2:HH:mm:ss}" -f `
                        $cycle, $CheckIntervalSec, $nextRecovery) 'WARN'
                    if ($cycle -ge $RebootAfterCycles -and (Test-RebootAllowed)) {
                        Write-Log 'Rebooting the PC as a last resort' 'WARN'
                        if (-not $DryRun) { Restart-Computer -Force }
                    }
                }
            }
        }
    } catch {
        Write-Log "Unexpected error: $($_.Exception.Message)" 'ERROR'
    }
    if ($Once) { break }
    Start-Sleep -Seconds $CheckIntervalSec
}

if ($mutex) { $mutex.Dispose() }
