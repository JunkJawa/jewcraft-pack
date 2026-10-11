<#
Sets up (or removes) the Windows Task Scheduler job that runs watch-server.ps1 every few minutes (5 by default, set IntervalMinutes in settings.local.ps1 to change).

  .\install-watcher-task.ps1            create or replace the job
  .\install-watcher-task.ps1 -Remove    delete the job

The job runs as you, only while you are logged in (the PC auto logs in), because Claude Code's
login lives in your Windows profile. It runs hidden and stops itself if it runs longer than 90 minutes (an update can take a while).
#>
param([switch]$Remove)

$taskName = "JewCraft Watcher"

if ($Remove) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed the '$taskName' task." -ForegroundColor Green
    exit 0
}

. (Join-Path $PSScriptRoot "settings.ps1")
$localSettings = Join-Path $PSScriptRoot "settings.local.ps1"
if (Test-Path $localSettings) { . $localSettings }
if (-not $IntervalMinutes) { $IntervalMinutes = 5 }

$script = Join-Path $PSScriptRoot "watch-server.ps1"
if (-not (Test-Path $script)) { throw "watch-server.ps1 not found next to this script." }

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
    -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 90)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Created the '$taskName' task. It first runs in about a minute, then every $IntervalMinutes minutes." -ForegroundColor Green
Write-Host "Run it now with:  Start-ScheduledTask -TaskName '$taskName'"
Write-Host "Its log is C:\MinecraftServers\watch.log"
