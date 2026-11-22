#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the WiFi Watchdog scheduled task and its installed script.
    The log and state file are kept unless -RemoveData is given.
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'WiFi Watchdog',
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'WifiWatchdog'),
    [string]$DataDir = (Join-Path $env:ProgramData 'WifiWatchdog'),
    [switch]$RemoveData
)

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'."
} else {
    Write-Host "No scheduled task named '$TaskName'."
}

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*WifiWatchdog.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "Stopped PID $($_.ProcessId)." }

if (Test-Path $InstallDir) { Remove-Item -Path $InstallDir -Recurse -Force; Write-Host "Removed $InstallDir." }
if ($RemoveData -and (Test-Path $DataDir)) { Remove-Item -Path $DataDir -Recurse -Force; Write-Host "Removed $DataDir." }
elseif (Test-Path $DataDir) { Write-Host "Kept log/state in $DataDir (use -RemoveData to delete)." }
