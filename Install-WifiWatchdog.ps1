#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs WifiWatchdog.ps1 as a scheduled task that runs as SYSTEM, starts at boot,
    and is restarted automatically if it ever stops.

.DESCRIPTION
    * Copies WifiWatchdog.ps1 to Program Files (writable only by administrators,
      because SYSTEM runs it).
    * Registers the task with two triggers: at startup, and every 5 minutes. If the
      watchdog is already running, the 5-minute trigger does nothing; if it has died,
      that trigger starts it again.
    * Starts it straight away.

    Re-running this script updates an existing install.

.EXAMPLE
    .\Install-WifiWatchdog.ps1
    Auto-detects the WiFi adapter that is connected right now.

.EXAMPLE
    .\Install-WifiWatchdog.ps1 -AdapterName 'WiFi 2' -CheckIntervalSec 60 -AllowReboot
#>
[CmdletBinding()]
param(
    [string]$AdapterName,
    [string]$ProfileName,
    [ValidateRange(10, 3600)][int]$CheckIntervalSec = 60,
    [ValidateRange(1, 30)][int]$FailuresBeforeAction = 2,
    [switch]$AllowReboot,
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'WifiWatchdog'),
    [string]$TaskName = 'WiFi Watchdog'
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'WifiWatchdog.ps1'
if (-not (Test-Path $source)) { throw "WifiWatchdog.ps1 not found next to this installer ($PSScriptRoot)" }

if (-not $AdapterName) {
    $a = Get-NetAdapter | Where-Object { $_.PhysicalMediaType -eq 'Native 802.11' -and $_.Status -eq 'Up' -and -not $_.Virtual } |
        Select-Object -First 1
    if (-not $a) { throw 'No connected WiFi adapter found to auto-detect. Pass -AdapterName (see Get-NetAdapter).' }
    $AdapterName = $a.Name
    Write-Host "Detected WiFi adapter: '$AdapterName' ($($a.InterfaceDescription))"
} elseif (-not (Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue)) {
    throw "No network adapter named '$AdapterName'. Check Get-NetAdapter."
}

# Copy the script somewhere only admins can modify.
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$target = Join-Path $InstallDir 'WifiWatchdog.ps1'
Copy-Item -Path $source -Destination $target -Force
Write-Host "Copied watchdog to $target"

# If a copy is already running, stop it so the new version takes over.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*WifiWatchdog.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$argList = @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', "`"$target`"",
    '-AdapterName', "`"$AdapterName`"",
    '-CheckIntervalSec', $CheckIntervalSec,
    '-FailuresBeforeAction', $FailuresBeforeAction
)
if ($ProfileName) { $argList += @('-ProfileName', "`"$ProfileName`"") }
if ($AllowReboot) { $argList += '-AllowReboot' }

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argList -join ' ')
$atBoot    = New-ScheduledTaskTrigger -AtStartup
$keepAlive = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($atBoot, $keepAlive) -Principal $principal `
    -Settings $settings -Description 'Keeps WiFi connected: reconnects / resets the adapter when the link drops. See WifiWatchdog.ps1.' `
    -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

$log = Join-Path $env:ProgramData 'WifiWatchdog\watchdog.log'
Write-Host ''
Write-Host "Installed and started scheduled task '$TaskName' (runs as SYSTEM)."
Write-Host "Log: $log"
Write-Host "Watch it live:  Get-Content '$log' -Tail 30 -Wait"
