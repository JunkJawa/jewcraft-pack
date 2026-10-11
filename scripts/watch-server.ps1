<#
JewCraft watcher (Windows PowerShell 5.1 or newer)

Runs every 15 minutes from Task Scheduler and costs nothing when all is well.
It looks for three problems:
  crash    a new file in the server's crash-reports folder
  offline  no Java process for a while (the server stopped or died)
  stuck    Java is running but nothing answers on the game port for a while

When it finds one it:
  1. sends a short push message through ntfy (a headline only, no logs)
  2. runs ONE read only Claude diagnosis, at most once every few hours, saved in reports\
  3. sends a second push when the report is ready

It never changes the server and never restarts anything.
To pause the offline and stuck alerts while you work on the server, create an empty file
named maintenance.flag in C:\MinecraftServers (the Root folder) and delete it when done.

Usage (PowerShell, from the scripts folder):
  .\watch-server.ps1                   a normal run (this is what Task Scheduler does)
  .\watch-server.ps1 -DryRun           show what it sees and would do, send and change nothing
  .\watch-server.ps1 -TestNtfy         send a test push to your phone and stop
  .\watch-server.ps1 -TestNotice       post a test line in game chat through Crafty and stop
  .\watch-server.ps1 -Simulate crash   pretend a crash was found and run the full path
                                       (also: offline, stuck). Uses one real Claude run.
#>
param(
    [switch]$DryRun,
    [switch]$TestNtfy,
    [switch]$TestNotice,
    [string]$Simulate = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "settings.ps1")
$localSettings = Join-Path $PSScriptRoot "settings.local.ps1"
if (Test-Path $localSettings) { . $localSettings }

# Defaults (override any of these in settings.local.ps1)
if (-not $IntervalMinutes)    { $IntervalMinutes = 5 }    # how often Task Scheduler runs this (re-run install-watcher-task.ps1 after changing)
if (-not $StrikesBeforeAlert) { $StrikesBeforeAlert = 3 } # checks in a row before an offline or stuck alert (3 x 5 = 15 minutes)
if (-not $RepeatEvery)        { $RepeatEvery = 72 }       # repeat the alert every this many checks (72 x 5 = 6 hours)
if (-not $CraftyUrl)          { $CraftyUrl = "https://localhost:8443" }
if (-not $NoticePrefix)       { $NoticePrefix = "[JewCraft] " }
if (-not $CooldownHours)      { $CooldownHours = 3 }      # minimum hours between Claude diagnosis runs

$RepoRoot  = Split-Path $PSScriptRoot -Parent
$Reports   = Join-Path $RepoRoot "reports"
$StateFile = Join-Path $Root "watch-state.json"
$LogFile   = Join-Path $Root "watch.log"
$Flag      = Join-Path $Root "maintenance.flag"
$Now       = Get-Date
$NowUnix   = [DateTimeOffset]::Now.ToUnixTimeSeconds()

function Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $msg
    Write-Host $line
    if (-not $DryRun) {
        try { Add-Content -Path $LogFile -Value $line -Encoding ASCII } catch { }
    }
}

function Get-Prop([string]$file, [string]$key, [string]$default) {
    if (Test-Path $file) {
        $m = Select-String -Path $file -Pattern ("^\s*" + [regex]::Escape($key) + "\s*=(.*)$") | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    }
    return $default
}

function Send-Push([string]$title, [string]$msg, [string]$priority, [string]$tags) {
    if (-not $NtfyTopic) { Log "no ntfy topic set in settings.local.ps1, push skipped: $title"; return }
    if ($DryRun) { Log "[dry run] would push: $title | $msg"; return }
    $headers = @{ Title = $title; Priority = $priority }
    if ($tags) { $headers["Tags"] = $tags }
    try {
        Invoke-RestMethod -Uri ("https://ntfy.sh/" + $NtfyTopic) -Method Post -Body $msg -Headers $headers | Out-Null
        Log "push sent: $title"
    } catch {
        Log "push failed: $($_.Exception.Message)"
    }
}

function Test-GamePort([int]$port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect("127.0.0.1", $port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(3000, $false)) {
            $client.EndConnect($iar)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-ShouldAlert([int]$strikes) {
    if ($strikes -eq $StrikesBeforeAlert) { return $true }
    if ($strikes -gt $StrikesBeforeAlert -and (($strikes - $StrikesBeforeAlert) % $RepeatEvery) -eq 0) { return $true }
    return $false
}

function Find-Claude {
    if ($ClaudeExe -and (Test-Path $ClaudeExe)) { return $ClaudeExe }
    $p = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
    if (Test-Path $p) { return $p }
    $c = Get-Command claude -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Invoke-Diagnosis($finding) {
    $exe = Find-Claude
    if (-not $exe) { Log "claude.exe not found, diagnosis skipped"; return $null }

    $templateFile = Join-Path $PSScriptRoot "agent-diagnose-prompt.txt"
    $prompt = (Get-Content $templateFile -Raw).Replace("{KIND}", $finding.kind).Replace("{DETAIL}", $finding.detail).Replace("{SERVERDIR}", $ServerDir)

    New-Item -ItemType Directory -Force -Path $Reports | Out-Null
    $tag    = (Get-Date).ToString("yyyyMMdd-HHmm") + "-" + $finding.kind
    $report = Join-Path $Reports ($tag + ".md")
    $tmpIn  = Join-Path $Reports ($tag + ".prompt.tmp")
    $tmpErr = Join-Path $Reports ($tag + ".err.tmp")
    Set-Content -Path $tmpIn -Value $prompt -Encoding ASCII

    # Read only: the three tools below, nothing that would need approval, and no prompts at all.
    $cliArgs = @("-p", "--add-dir", $ServerDir, "--allowedTools", "Read,Grep,Glob",
                 "--permission-mode", "dontAsk", "--permission-prompts", "none")
    $proc = Start-Process -FilePath $exe -ArgumentList $cliArgs -WorkingDirectory $RepoRoot `
        -RedirectStandardInput $tmpIn -RedirectStandardOutput $report -RedirectStandardError $tmpErr `
        -NoNewWindow -PassThru
    $null = $proc.Handle   # lets us read ExitCode afterwards

    $finished = $proc.WaitForExit(600000)   # 10 minutes at most
    if (-not $finished) {
        try { $proc.Kill() } catch { }
        Log "diagnosis timed out after 10 minutes"
        Remove-Item $tmpIn, $tmpErr -Force -ErrorAction SilentlyContinue
        return $null
    }

    $size = 0
    if (Test-Path $report) { $size = (Get-Item $report).Length }
    if ($proc.ExitCode -ne 0 -or $size -lt 50) {
        $err = ""
        if (Test-Path $tmpErr) { $err = (Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue) }
        Log "diagnosis failed (exit code $($proc.ExitCode), output $size bytes). $err"
        Remove-Item $tmpIn, $tmpErr -Force -ErrorAction SilentlyContinue
        return $null
    }

    Remove-Item $tmpIn, $tmpErr -Force -ErrorAction SilentlyContinue
    Log "diagnosis saved: $report"
    return $report
}


function Get-CrashLine([string]$crashFile) {
    # Picks the player notice for a crash: the first entry in known-crashes.json whose pattern is found in the report.
    $file = Join-Path $PSScriptRoot "known-crashes.json"
    $generic = "The server crashed and restarted, Gil's looking into it."
    if (-not (Test-Path $file)) { return $generic }
    try {
        $cfg = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.generic) { $generic = [string]$cfg.generic }
        $text = ""
        if ($crashFile -and (Test-Path $crashFile)) { $text = Get-Content $crashFile -Raw -ErrorAction SilentlyContinue }
        foreach ($k in @($cfg.known)) {
            if ($text -match [string]$k.match) { Log "crash matches known entry: $($k.id)"; return [string]$k.line }
        }
        Log "crash matches no known entry, using the generic line"
    } catch {
        Log "known-crashes.json problem: $($_.Exception.Message)"
    }
    return $generic
}

function Send-GameNotice([string]$line) {
    if (-not $CraftyToken) { Log "no Crafty key set in settings.local.ps1, game notice skipped: $line"; return $false }
    if ($DryRun) { Log "[dry run] would post in game: $line"; return $true }
    $serverId = Split-Path $ServerDir -Leaf
    $json = (@{ text = ($NoticePrefix + $line); color = "yellow" } | ConvertTo-Json -Compress)
    $cmd = "tellraw @a " + $json
    $call = @{
        Uri = ($CraftyUrl.TrimEnd("/") + "/api/v2/servers/" + $serverId + "/stdin")
        Method = "Post"; Body = $cmd; ContentType = "text/plain"
        Headers = @{ Authorization = ("Bearer " + $CraftyToken) }
    }
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $call["SkipCertificateCheck"] = $true
        } elseif (-not ("TrustLocalCert" -as [type])) {
            # Crafty uses a self signed certificate. Windows PowerShell needs this to talk to it on this PC.
            Add-Type -TypeDefinition "using System.Net; using System.Security.Cryptography.X509Certificates; public class TrustLocalCert : ICertificatePolicy { public bool CheckValidationResult(ServicePoint sp, X509Certificate c, WebRequest r, int p) { return true; } }"
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustLocalCert
        }
        Invoke-RestMethod @call | Out-Null
        Log "game notice posted: $line"
        return $true
    } catch {
        Log "game notice failed: $($_.Exception.Message)"
        return $false
    }
}

# ---------- Test push ----------
if ($TestNtfy) {
    $DryRunSaved = $DryRun
    $DryRun = $false
    Send-Push "JewCraft test" "If you can read this on your phone, alerts are working." "default" "white_check_mark"
    $DryRun = $DryRunSaved
    exit 0
}

if ($TestNotice) {
    $ok = Send-GameNotice "This is a test of the crash notice system. Nothing is wrong."
    if (-not $ok) { Write-Host "The test notice did not go through. See the lines above." -ForegroundColor Yellow }
    exit 0
}

# ---------- Read state ----------
$state = @{ lastCrashCheck = $NowUnix; offlineStrikes = 0; stuckStrikes = 0; lastDiagnosis = 0; pendingNotice = ""; pendingSince = 0 }
if (Test-Path $StateFile) {
    try {
        $j = Get-Content $StateFile -Raw | ConvertFrom-Json
        $state.lastCrashCheck = [long]$j.lastCrashCheck
        $state.offlineStrikes = [int]$j.offlineStrikes
        $state.stuckStrikes   = [int]$j.stuckStrikes
        $state.lastDiagnosis  = [long]$j.lastDiagnosis
        $state.pendingNotice  = [string]$j.pendingNotice
        $state.pendingSince   = [long]$j.pendingSince
    } catch {
        Log "state file unreadable, starting fresh"
    }
} else {
    Log "first run: crash reports that already exist will not be reported"
}

# During an update the server folder is briefly missing. Nothing to check then.
if (-not (Test-Path $ServerDir)) {
    Log "server folder not found right now (an update may be running), skipping this check"
    exit 0
}

# ---------- Checks ----------
$findings = @()

# 1. New crash report
$crashDir = Join-Path $ServerDir "crash-reports"
if (Test-Path $crashDir) {
    $since = [DateTimeOffset]::FromUnixTimeSeconds([long]$state.lastCrashCheck).LocalDateTime
    $new = @(Get-ChildItem $crashDir -Filter "crash-*.txt" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $since } | Sort-Object LastWriteTime)
    Log ("new crash reports since the last check: {0}" -f $new.Count)
    if ($new.Count -gt 0) {
        $newest = $new[$new.Count - 1]
        $state.pendingNotice = Get-CrashLine $newest.FullName
        $state.pendingSince = $NowUnix
        $findings += @{
            kind = "crash"; priority = "high"; tags = "rotating_light"; title = "JewCraft crashed"
            push = "New crash report: $($newest.Name)."
            detail = "A new crash report appeared: $($newest.Name), written at $($newest.LastWriteTime). There were $($new.Count) new crash report(s) since the last check."
        }
    }
}

# 2 and 3. Offline or stuck
$gamePort = $GamePort
if (-not $gamePort) { $gamePort = [int](Get-Prop (Join-Path $ServerDir "server.properties") "server-port" "25565") }
$javaRunning = (@(Get-Process java -ErrorAction SilentlyContinue)).Count -gt 0

if (Test-Path $Flag) {
    Log "maintenance.flag is present: offline and stuck checks skipped"
    $state.offlineStrikes = 0
    $state.stuckStrikes = 0
} elseif (-not $javaRunning) {
    $state.offlineStrikes++
    $state.stuckStrikes = 0
    Log "no Java process running (check $($state.offlineStrikes) in a row)"
    if (Test-ShouldAlert $state.offlineStrikes) {
        $minutes = $state.offlineStrikes * $IntervalMinutes
        $findings += @{
            kind = "offline"; priority = "default"; tags = "zzz"; title = "JewCraft offline"
            push = "The server has not been running for about $minutes minutes."
            detail = "No Java process has been running for about $minutes minutes, so the server is not running."
        }
    }
} else {
    $state.offlineStrikes = 0
    if (Test-GamePort $gamePort) {
        $state.stuckStrikes = 0
        Log "game port $gamePort answers: the server looks healthy"
    } else {
        $state.stuckStrikes++
        Log "Java is running but game port $gamePort does not answer (check $($state.stuckStrikes) in a row)"
        if (Test-ShouldAlert $state.stuckStrikes) {
            $minutes = $state.stuckStrikes * $IntervalMinutes
            $findings += @{
                kind = "stuck"; priority = "high"; tags = "hourglass"; title = "JewCraft stuck"
                push = "Java is running but nobody can join. Port $gamePort has not answered for about $minutes minutes."
                detail = "A Java process is running but nothing has answered on game port $gamePort for about $minutes minutes. The server may be stuck while starting or stopping."
            }
        }
    }
}

# Simulation for testing the full path
if ($Simulate) {
    switch ($Simulate) {
        "crash"   { $findings += @{ kind = "crash"; priority = "high"; tags = "rotating_light"; title = "JewCraft crashed (TEST)"; push = "This is a simulated crash for testing."; detail = "SIMULATED TEST. Pretend a new crash report just appeared. Diagnose the newest real crash report." } }
        "offline" { $findings += @{ kind = "offline"; priority = "default"; tags = "zzz"; title = "JewCraft offline (TEST)"; push = "This is a simulated offline alert for testing."; detail = "SIMULATED TEST. Pretend the server has been offline for 30 minutes. Diagnose from the latest log." } }
        "stuck"   { $findings += @{ kind = "stuck"; priority = "high"; tags = "hourglass"; title = "JewCraft stuck (TEST)"; push = "This is a simulated stuck alert for testing."; detail = "SIMULATED TEST. Pretend Java is running but the game port has not answered for 30 minutes. Diagnose from the latest log." } }
        default   { throw "-Simulate must be crash, offline, or stuck." }
    }
}

# Post the pending crash notice once the server is back up (and drop it if it is stale)
if ($state.pendingNotice) {
    if (($NowUnix - [long]$state.pendingSince) -gt 1800) {
        Log "crash notice expired without the server coming back, dropping it"
        $state.pendingNotice = ""
    } elseif (Test-GamePort $gamePort) {
        if (Send-GameNotice $state.pendingNotice) { $state.pendingNotice = "" }
    } else {
        Log "crash notice is waiting for the server to come back up"
    }
}

# ---------- Act ----------
if ($findings.Count -eq 0) {
    Log "all quiet"
} else {
    $order = @{ crash = 0; stuck = 1; offline = 2 }
    $primary = $findings | Sort-Object { $order[$_.kind] } | Select-Object -First 1
    $cooldownOk = (($NowUnix - [long]$state.lastDiagnosis) -ge ($CooldownHours * 3600))

    foreach ($f in $findings) {
        $msg = $f.push
        if ([object]::ReferenceEquals($f, $primary) -and $cooldownOk) { $msg += " A diagnosis is running." }
        Send-Push $f.title $msg $f.priority $f.tags
    }

    if (-not $cooldownOk) {
        Log "diagnosis skipped: one already ran in the last $CooldownHours hours"
    } elseif ($DryRun) {
        Log "[dry run] would start a read only Claude diagnosis for: $($primary.kind)"
    } else {
        Log "starting read only diagnosis for: $($primary.kind)"
        $report = Invoke-Diagnosis $primary
        $state.lastDiagnosis = $NowUnix
        if ($report) {
            Send-Push "JewCraft report ready" ("Saved as reports\" + (Split-Path $report -Leaf) + ". Ask your agent to read it.") "default" "memo"
        } else {
            Send-Push "JewCraft diagnosis failed" "Claude could not write a report. See watch.log in C:\MinecraftServers." "default" "warning"
        }
    }
}

# ---------- Save state ----------
if (-not $DryRun) {
    $state.lastCrashCheck = $NowUnix
    try { $state | ConvertTo-Json | Set-Content -Path $StateFile -Encoding ASCII } catch { Log "could not save state: $($_.Exception.Message)" }
}
