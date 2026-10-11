<#
Update helper for watch-server.ps1. The watcher loads this file; you do not run it yourself.

What it does:
  1. Checks GitHub for a newer release of the pack (a .mrpack file attached to a release).
  2. Sends a push to your phone with three buttons: Go now, Go at 4:30 AM, Skip.
  3. When you tap Go, it warns players in chat if anyone is online, stops the server through Crafty,
     runs update-server.ps1, starts the server again, and tells you how it went.

It never updates anything until you tap a button. The old server folder and a backup zip are kept every time.
#>

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Format-Tag([string]$t) { return ($t.Trim() -replace '^[vV]', '') }

# ---------- Minecraft status ping (how many players are online) ----------
function ConvertTo-VarInt([int]$value) {
    $bytes = New-Object System.Collections.Generic.List[byte]
    while ($true) {
        if (($value -band -128) -eq 0) { $bytes.Add([byte]$value); break }
        $bytes.Add([byte](($value -band 127) -bor 128))
        $value = $value -shr 7
    }
    return ,$bytes.ToArray()
}

function Read-Exact($stream, [int]$count) {
    $buf = New-Object byte[] $count
    $off = 0
    while ($off -lt $count) {
        $n = $stream.Read($buf, $off, $count - $off)
        if ($n -le 0) { throw "connection closed" }
        $off += $n
    }
    return ,$buf
}

function Read-VarInt($stream) {
    $result = 0
    $shift = 0
    while ($true) {
        $b = $stream.ReadByte()
        if ($b -lt 0) { throw "connection closed" }
        $result = $result -bor (($b -band 127) -shl $shift)
        if (($b -band 128) -eq 0) { break }
        $shift += 7
        if ($shift -gt 35) { throw "bad varint" }
    }
    return $result
}

# Returns the number of players online, or -1 if the server did not answer.
function Get-OnlinePlayers([int]$port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect("127.0.0.1", $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(3000, $false)) { return -1 }
        $client.EndConnect($iar)
        $client.ReceiveTimeout = 5000
        $client.SendTimeout = 5000
        $stream = $client.GetStream()

        $hostBytes = [System.Text.Encoding]::UTF8.GetBytes("localhost")
        $data = New-Object System.Collections.Generic.List[byte]
        $data.Add(0)                                              # handshake packet
        $data.AddRange([byte[]](ConvertTo-VarInt 767))            # protocol version (any value works for a status ping)
        $data.AddRange([byte[]](ConvertTo-VarInt $hostBytes.Length))
        $data.AddRange($hostBytes)
        $data.Add([byte](($port -shr 8) -band 255))
        $data.Add([byte]($port -band 255))
        $data.Add(1)                                              # next state: status
        $packet = New-Object System.Collections.Generic.List[byte]
        $packet.AddRange([byte[]](ConvertTo-VarInt $data.Count))
        $packet.AddRange($data)
        $packet.Add(1)                                            # status request: length 1
        $packet.Add(0)                                            # packet id 0
        $out = $packet.ToArray()
        $stream.Write($out, 0, $out.Length)

        $len = Read-VarInt $stream
        $payload = Read-Exact $stream $len
        $ms = New-Object System.IO.MemoryStream(,$payload)
        $null = Read-VarInt $ms                                   # packet id
        $strLen = Read-VarInt $ms
        $strBytes = Read-Exact $ms $strLen
        $json = [System.Text.Encoding]::UTF8.GetString($strBytes) | ConvertFrom-Json
        return [int]$json.players.online
    } catch {
        return -1
    } finally {
        $client.Close()
    }
}

# ---------- Crafty ----------
function Initialize-LocalCert {
    if (-not ("TrustLocalCert" -as [type])) {
        Add-Type -TypeDefinition "using System.Net; using System.Security.Cryptography.X509Certificates; public class TrustLocalCert : ICertificatePolicy { public bool CheckValidationResult(ServicePoint sp, X509Certificate c, WebRequest r, int p) { return true; } }"
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustLocalCert
}

function Invoke-Crafty([string]$action) {
    $serverId = Split-Path $ServerDir -Leaf
    $call = @{
        Uri = ($CraftyUrl.TrimEnd("/") + "/api/v2/servers/" + $serverId + "/action/" + $action)
        Method = "Post"
        Headers = @{ Authorization = ("Bearer " + $CraftyToken) }
        TimeoutSec = 30
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $call["SkipCertificateCheck"] = $true } else { Initialize-LocalCert }
    Invoke-RestMethod @call | Out-Null
}

function Wait-JavaGone([int]$timeoutSec) {
    $end = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $end) {
        if (@(Get-Process java -ErrorAction SilentlyContinue).Count -eq 0) { return $true }
        Start-Sleep -Seconds $PollSeconds
    }
    return $false
}

function Wait-PortUp([int]$port, [int]$timeoutSec) {
    $end = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $end) {
        if (Test-GamePort $port) { return $true }
        Start-Sleep -Seconds $PollSeconds
    }
    return $false
}

# ---------- GitHub releases ----------
function Get-LatestRelease {
    try {
        $r = Invoke-RestMethod -Uri ($GitHubApi.TrimEnd("/") + "/repos/" + $ReleaseRepo + "/releases/latest") `
            -Headers @{ "User-Agent" = "jewcraft-watcher"; Accept = "application/vnd.github+json" } -TimeoutSec 20
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 404) { Log "no release published yet on $ReleaseRepo" } else { Log "release check failed: $($_.Exception.Message)" }
        return $null
    }
    $asset = @($r.assets) | Where-Object { $_.name -like "*.mrpack" } | Select-Object -First 1
    if (-not $asset) { Log "release $($r.tag_name) has no .mrpack file attached, ignoring it"; return $null }
    $pub = $r.published_at
    if ($pub -is [DateTime]) { $unix = ([DateTimeOffset]$pub.ToUniversalTime()).ToUnixTimeSeconds() }
    else { $unix = [DateTimeOffset]::Parse([string]$pub, [System.Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds() }
    return @{ tag = [string]$r.tag_name; published = [long]$unix; url = [string]$asset.browser_download_url; notes = [string]$r.body }
}

# ---------- Phone buttons ----------
function Read-Commands {
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Uri ($NtfyServer.TrimEnd("/") + "/" + $NtfyCommandTopic + "/json?poll=1&since=" + $state.lastCmdTime)
    } catch {
        Log "command check failed: $($_.Exception.Message)"
        return @()
    }
    $text = ""
    if ($resp.Content -is [byte[]]) { $text = [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { $text = [string]$resp.Content }
    $found = @()
    foreach ($line in ($text -split "`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        try { $m = $t | ConvertFrom-Json } catch { continue }
        if ($m.event -eq "message" -and [long]$m.time -gt [long]$state.lastCmdTime) {
            $found += ,@{ time = [long]$m.time; text = ([string]$m.message).Trim() }
        }
    }
    return $found
}

function Get-NextUpdateTime {
    $t = (Get-Date).Date.AddHours($UpdateHour).AddMinutes($UpdateMinute)
    if ($t -le (Get-Date)) { $t = $t.AddDays(1) }
    return $t
}

function Get-Buttons([string]$tag, [bool]$offerSchedule) {
    $url = $NtfyServer.TrimEnd("/") + "/" + $NtfyCommandTopic
    $when = (Get-NextUpdateTime).ToString("h:mm tt")
    $b = @("http, Go now, $url, method=POST, body=go-now:$tag, clear=true")
    if ($offerSchedule) {
        $b += "http, Go at $when, $url, method=POST, body=go-tonight:$tag, clear=true"
        $b += "http, Skip, $url, method=POST, body=skip:$tag, clear=true"
    } else {
        $b += "http, Cancel, $url, method=POST, body=cancel:$tag, clear=true"
    }
    return ($b -join "; ")
}

function Send-UpdateOffer([string]$tag, [string]$notes) {
    $short = ($notes -replace '\s+', ' ').Trim()
    if ($short.Length -gt 250) { $short = $short.Substring(0, 250) + "..." }
    $msg = "JewCraft $tag is ready. The server is on $($state.installedTag)."
    if ($short) { $msg += " Notes: $short" }
    Send-Push "JewCraft update ready" $msg "default" "package" (Get-Buttons $tag $true)
}

# ---------- The update itself ----------
function Test-Pack([string]$file) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($file)
    try {
        $entry = $zip.GetEntry("modrinth.index.json")
        if (-not $entry) { throw "The downloaded file is not a valid .mrpack (no modrinth.index.json inside)." }
        $reader = New-Object System.IO.StreamReader($entry.Open())
        $index = $reader.ReadToEnd() | ConvertFrom-Json
        $reader.Close()
    } finally { $zip.Dispose() }
    if (-not $index.dependencies.neoforge) { throw "The pack does not list a NeoForge version." }
}

function Invoke-Update([bool]$countdown) {
    $tag = [string]$state.pendingTag
    $safe = ($tag -replace '[^A-Za-z0-9._-]', '_')
    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $downloads = Join-Path $Root "downloads"
    $pack = Join-Path $downloads ("jewcraft-" + $safe + ".mrpack")
    $logFile = Join-Path $Root ("update-" + $stamp + ".log")

    if ($DryRun) { Log "[dry run] would update the server to $tag (download, warn players, stop, run update-server.ps1, start)"; return }

    $state.updatingSince = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $state.scheduleAt = 0
    $state.scheduleTries = 0
    Save-State
    Send-Push "JewCraft updating" "Updating to $tag now. This takes about 10 minutes." "default" "arrows_counterclockwise"

    $restartOld = $false
    try {
        New-Item -ItemType Directory -Force -Path $downloads | Out-Null
        Log "downloading $($state.pendingUrl)"
        Invoke-WebRequest -UseBasicParsing -Uri $state.pendingUrl -OutFile $pack -TimeoutSec 900
        Test-Pack $pack

        if ($countdown) {
            $n = Get-OnlinePlayers $gamePort
            if ($n -gt 0) {
                Log "$n player(s) online, warning them"
                $mins = [Math]::Round($CountdownSeconds / 60)
                Send-GameNotice "The server restarts for an update in $mins minutes and will be back in about 10 minutes. Update the pack in your launcher before you rejoin." | Out-Null
                Start-Sleep -Seconds ([Math]::Max(0, $CountdownSeconds - 60))
                Send-GameNotice "The server restarts for an update in 1 minute." | Out-Null
                Start-Sleep -Seconds ([Math]::Min(60, $CountdownSeconds))
            }
        }

        Log "stopping the server through Crafty"
        Invoke-Crafty "stop_server"
        if (-not (Wait-JavaGone $StopTimeoutSec)) { throw "The server did not stop within $StopTimeoutSec seconds. Nothing was changed." }
        Start-Sleep -Seconds $SettleSeconds

        Log "running update-server.ps1 (log: $logFile)"
        $argList = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Pack "{1}" -Yes' -f (Join-Path $PSScriptRoot "update-server.ps1"), $pack
        $proc = Start-Process -FilePath $PowerShellExe -ArgumentList $argList -NoNewWindow -PassThru `
            -RedirectStandardOutput $logFile -RedirectStandardError ($logFile + ".err")
        $null = $proc.Handle
        if (-not $proc.WaitForExit(2400000)) { try { $proc.Kill() } catch { }; throw "The update script ran longer than 40 minutes and was stopped. Check the server folder before starting it." }
        if ($proc.ExitCode -ne 0) {
            $restartOld = Test-Path (Join-Path $ServerDir "server.properties")
            $tail = ""
            if (Test-Path ($logFile + ".err")) {
                $tail = ((Get-Content ($logFile + ".err") -ErrorAction SilentlyContinue) | Where-Object { $_.Trim() } | Select-Object -First 2) -join " "
                $tail = ($tail -replace "$([char]27)\[[0-9;]*m", "")
            }
            throw "update-server.ps1 failed (exit code $($proc.ExitCode)). $tail"
        }

        Log "update script finished, starting the server"
        Invoke-Crafty "start_server"
        $state.installedTag = $tag
        $state.installedPub = [long]$state.pendingPub
        $state.pendingTag = ""; $state.pendingUrl = ""; $state.pendingPub = 0
        if (Wait-PortUp $gamePort $StartTimeoutSec) {
            Send-Push "JewCraft updated" "Now on $tag. The server is back online." "default" "white_check_mark"
        } else {
            Send-Push "JewCraft updated, slow to start" "Files are updated to $tag but the server has not answered yet. Check Crafty." "high" "warning"
        }
    } catch {
        $msg = $_.Exception.Message
        Log "update failed: $msg"
        $extra = ""
        if ($restartOld) {
            try { Invoke-Crafty "start_server"; $extra = " The old version is starting again." } catch { $extra = " Start the server in Crafty." }
        }
        $retry = ""
        if ($state.pendingTag) { $retry = Get-Buttons $state.pendingTag $true }
        Send-Push "JewCraft update failed" ($msg + $extra + " Details: update-" + $stamp + ".log in " + $Root + ".") "high" "x" $retry
    } finally {
        $state.updatingSince = 0
        $state.offlineStrikes = 0
        $state.stuckStrikes = 0
        Save-State
    }
}

# ---------- Called once per watcher run ----------
function Invoke-UpdateCycle {
    if (-not $ReleaseRepo) { return }
    if (-not $CraftyToken) { Log "update checks need a Crafty key in settings.local.ps1, skipped"; return }
    if (-not $NtfyTopic) { Log "update checks need an ntfy topic in settings.local.ps1, skipped"; return }
    if (-not $state.installedTag) {
        Log "update checks are waiting: tell the watcher which version the server runs, for example .\watch-server.ps1 -SetInstalled 1.1.0"
        return
    }

    # A previous run died in the middle of an update (power cut, reboot). Do not retry on our own.
    if ([long]$state.updatingSince -gt 0) {
        Log "a previous update did not finish"
        Send-Push "JewCraft update interrupted" "An earlier update did not finish. Check Crafty and the server folder before doing anything else." "high" "warning"
        $state.updatingSince = 0
        Save-State
        return
    }

    # 1. Is there a newer release?
    $rel = Get-LatestRelease
    if ($rel) {
        $tagNew = Format-Tag $rel.tag
        $isNewer = ($tagNew -ne (Format-Tag $state.installedTag)) -and ($rel.published -gt [long]$state.installedPub)
        $alreadyHandled = ($tagNew -eq (Format-Tag $state.skippedTag)) -or ($tagNew -eq (Format-Tag $state.pendingTag))
        if ($isNewer -and -not $alreadyHandled) {
            Log "new release found: $($rel.tag)"
            $state.pendingTag = $rel.tag
            $state.pendingUrl = $rel.url
            $state.pendingPub = $rel.published
            $state.scheduleAt = 0
            $state.scheduleTries = 0
            Save-State
            Send-UpdateOffer $rel.tag $rel.notes
        }
    }

    # 2. Did you tap a button?
    $goNow = $false
    $commands = @(Read-Commands)
    foreach ($c in $commands) {
        $state.lastCmdTime = [Math]::Max([long]$state.lastCmdTime, [long]$c.time)
        $parts = $c.text -split ":", 2
        $verb = $parts[0].Trim().ToLower()
        $tag = ""
        if ($parts.Count -gt 1) { $tag = $parts[1].Trim() }
        if (-not $state.pendingTag -or (Format-Tag $tag) -ne (Format-Tag $state.pendingTag)) {
            Log "ignored button press '$($c.text)' (no matching update is waiting)"
            continue
        }
        switch ($verb) {
            "go-now" { $goNow = $true }
            "go-tonight" {
                $at = Get-NextUpdateTime
                $state.scheduleAt = ([DateTimeOffset]$at).ToUnixTimeSeconds()
                $state.scheduleTries = 0
                Log "update scheduled for $at"
                Send-Push "JewCraft update scheduled" ("Will update to " + $state.pendingTag + " at " + $at.ToString("h:mm tt on ddd") + ", once nobody is online.") "default" "alarm_clock" (Get-Buttons $state.pendingTag $false)
            }
            "skip" {
                $state.skippedTag = $state.pendingTag
                Log "skipping $($state.pendingTag)"
                Send-Push "JewCraft update skipped" ("Skipped " + $state.pendingTag + ". I will wait for the next release.") "low" "no_entry_sign"
                $state.pendingTag = ""; $state.pendingUrl = ""; $state.pendingPub = 0; $state.scheduleAt = 0
            }
            "cancel" {
                $state.scheduleAt = 0
                Log "schedule cancelled"
                Send-Push "JewCraft schedule cancelled" "Still waiting for your go." "low" "no_entry_sign" (Get-Buttons $state.pendingTag $true)
            }
            default { Log "ignored unknown button press '$($c.text)'" }
        }
    }
    if ($commands.Count -gt 0) { Save-State }

    # 3. Time to act?
    if ($goNow) {
        Invoke-Update $true
    } elseif ($state.pendingTag -and [long]$state.scheduleAt -gt 0 -and $NowUnix -ge [long]$state.scheduleAt) {
        $players = Get-OnlinePlayers $gamePort
        if ($players -gt 0) {
            $state.scheduleTries = [int]$state.scheduleTries + 1
            if ($state.scheduleTries -ge 6) {
                Log "players stayed online, giving up on the scheduled update"
                $state.scheduleAt = 0
                Send-Push "JewCraft update not done" ("Players were online for 3 hours past the scheduled time, so " + $state.pendingTag + " was not installed. Tap a button to try again.") "default" "hourglass" (Get-Buttons $state.pendingTag $true)
            } else {
                $state.scheduleAt = $NowUnix + 1800
                Log "$players player(s) online, trying the scheduled update again in 30 minutes"
            }
            Save-State
        } else {
            Invoke-Update $false
        }
    }
}
