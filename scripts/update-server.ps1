<#
JewCraft server update script (Windows PowerShell 5.1 or newer)

What it does, in order:
  1. Checks the server is stopped
  2. Backs up the world, whitelist, ops, and configs to a zip
  3. Builds fresh server files from the new .mrpack into a staging folder
  4. Installs the NeoForge version the pack asks for
  5. Copies that NeoForge's launch file to neoforge_args.txt, so the Crafty start command never needs a version number
  6. Removes blocked mods, adds extra server mods, copies server-overrides
  7. Carries over the world, whitelist, ops, bans, and server.properties
  8. Applies the settings in server-config\server.properties.overrides and sets memory
  9. Swaps the new folder into Crafty's server folder (the old one is kept)
 10. Makes sure Crafty's start command is the version free one (needs the Crafty key in settings.local.ps1)

Usage (PowerShell, from the scripts folder):
  .\update-server.ps1 -Pack "C:\path\to\JewCraft 1.1.0.mrpack" -DryRun   # shows the plan, changes nothing
  .\update-server.ps1 -Pack "C:\path\to\JewCraft 1.1.0.mrpack"           # does it

Stop the server in Crafty first. Start it again in Crafty when the script finishes.
#>
param(
    [Parameter(Mandatory = $true)][string]$Pack,
    [string]$NeoForgeVersion = "",
    [switch]$DryRun,
    [switch]$Yes   # skip the "Continue? (y/n)" question (used by the watcher after you tap Go)
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "settings.ps1")
$localSettings = Join-Path $PSScriptRoot "settings.local.ps1"
if (Test-Path $localSettings) { . $localSettings }

# The one start command Crafty should use from now on. It reads neoforge_args.txt,
# which this script refreshes on every update, so a new NeoForge version needs no Crafty change.
$StartCommand = "java @user_jvm_args.txt @neoforge_args.txt nogui"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$stamp    = Get-Date -Format "yyyyMMdd-HHmmss"
$Staging  = Join-Path $Root "staging"
$Backups  = Join-Path $Root "backups"
$OldRoot  = Join-Path $Root "old"
$OldDir   = Join-Path $OldRoot $stamp

function Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Run([string]$desc, [scriptblock]$action) {
    Step $desc
    if ($DryRun) { Write-Host "    (dry run, skipped)" -ForegroundColor DarkGray }
    else { & $action }
}

function Get-Prop([string]$file, [string]$key, [string]$default) {
    if (Test-Path $file) {
        $m = Select-String -Path $file -Pattern ("^\s*" + [regex]::Escape($key) + "\s*=(.*)$") | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    }
    return $default
}

function Set-Props([string]$file, [string]$overrideFile) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path $file) { $lines.AddRange([string[]]@(Get-Content $file)) }
    foreach ($o in Get-Content $overrideFile) {
        $t = $o.Trim()
        if (-not $t -or $t.StartsWith("#") -or ($t -notmatch "=")) { continue }
        $key = $t.Split("=")[0].Trim()
        $idx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ("^\s*" + [regex]::Escape($key) + "\s*=")) { $idx = $i; break }
        }
        if ($idx -ge 0) { $lines[$idx] = $t } else { $lines.Add($t) }
    }
    Set-Content -Path $file -Value $lines -Encoding ascii
}

# Copies NeoForge's win_args.txt to neoforge_args.txt in a server folder.
# Uses the given version, or the newest one found in the folder when no version is given.
function Write-NeoForgeArgs([string]$serverFolder, [string]$version) {
    $base = Join-Path $serverFolder "libraries\net\neoforged\neoforge"
    $src = $null
    if ($version) {
        $src = Join-Path $base "$version\win_args.txt"
        if (-not (Test-Path $src)) { $src = $null }
    } elseif (Test-Path $base) {
        $src = Get-ChildItem $base -Directory | Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName "win_args.txt" } | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $src) { return $false }
    Copy-Item $src (Join-Path $serverFolder "neoforge_args.txt") -Force
    return $true
}

# ---------- Crafty API (for the start command) ----------
function Initialize-LocalCert {
    if (-not ("TrustLocalCert" -as [type])) {
        Add-Type -TypeDefinition "using System.Net; using System.Security.Cryptography.X509Certificates; public class TrustLocalCert : ICertificatePolicy { public bool CheckValidationResult(ServicePoint sp, X509Certificate c, WebRequest r, int p) { return true; } }"
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustLocalCert
}

function Invoke-CraftyServerApi([string]$method, $body) {
    $serverId = Split-Path $ServerDir -Leaf
    $call = @{
        Uri = ($CraftyUrl.TrimEnd("/") + "/api/v2/servers/" + $serverId)
        Method = $method
        Headers = @{ Authorization = ("Bearer " + $CraftyToken) }
        TimeoutSec = 30
    }
    if ($body) { $call["Body"] = ($body | ConvertTo-Json -Compress); $call["ContentType"] = "application/json" }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $call["SkipCertificateCheck"] = $true } else { Initialize-LocalCert }
    return Invoke-RestMethod @call
}

function Get-CraftyStartCommand {
    $r = Invoke-CraftyServerApi "Get" $null
    return [string]$r.data.execution_command
}

# ---------- Preflight (read only, runs even in a dry run) ----------
Step "Preflight checks"

if ($ServerDir -match "PUT-SERVER-UUID-HERE") { throw "Edit scripts\settings.ps1 and set ServerDir first." }
if (-not (Test-Path $Pack))          { throw "Pack file not found: $Pack" }
if (-not (Test-Path $ServerDir))     { throw "Server folder not found: $ServerDir" }
if (-not (Test-Path $MrpackInstall)) { throw "mrpack-install not found: $MrpackInstall" }
if (-not (Get-Command java -ErrorAction SilentlyContinue)) { throw "java is not on PATH." }
if (Get-Process java -ErrorAction SilentlyContinue) { throw "A java process is running. Stop the server in Crafty and wait until it is Offline, then run this again." }

$Pack = (Resolve-Path $Pack).Path

if (-not $NeoForgeVersion) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Pack)
    try {
        $entry = $zip.GetEntry("modrinth.index.json")
        if (-not $entry) { throw "modrinth.index.json not found inside the pack. Is this a .mrpack file?" }
        $reader = New-Object System.IO.StreamReader($entry.Open())
        $index = $reader.ReadToEnd() | ConvertFrom-Json
        $reader.Close()
    } finally { $zip.Dispose() }
    $NeoForgeVersion = $index.dependencies.neoforge
    if (-not $NeoForgeVersion) { throw "This pack does not list a NeoForge version. Pass -NeoForgeVersion 21.1.xxx yourself." }
    Write-Host "    pack: $($index.name) $($index.versionId), NeoForge $NeoForgeVersion"
}

$propsFile = Join-Path $ServerDir "server.properties"
$levelName = Get-Prop $propsFile "level-name" "world"
Write-Host "    world folder: $levelName"
$worldPath = Join-Path $ServerDir $levelName
if (-not (Test-Path $worldPath)) {
    throw "The world folder '$levelName' was not found in the server folder. Stopping so a new world is never created by accident."
}

# Report Crafty's current start command (read only)
if ($CraftyToken -and $CraftyUrl) {
    try {
        $current = Get-CraftyStartCommand
        if ($current -eq $StartCommand) { Write-Host "    Crafty start command: already version free" }
        else { Write-Host "    Crafty start command is '$current'. It will be changed to '$StartCommand' after the swap." }
    } catch {
        Write-Host "    Could not read Crafty's start command: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host "    No Crafty key in settings.local.ps1, so the start command cannot be checked or changed automatically." -ForegroundColor Yellow
}

# Config drift report: files edited on the server since the last build
$marker = Join-Path $ServerDir ".last-build"
if (Test-Path $marker) {
    $since = (Get-Item $marker).LastWriteTime
    $cfg = Join-Path $ServerDir "config"
    if (Test-Path $cfg) {
        $changed = Get-ChildItem $cfg -Recurse -File | Where-Object { $_.LastWriteTime -gt $since }
        if ($changed) {
            Write-Host "    These config files changed on the server since the last build." -ForegroundColor Yellow
            Write-Host "    They will be replaced by the pack's versions. Some are just mods rewriting their own files." -ForegroundColor Yellow
            $changed | ForEach-Object { Write-Host "      $($_.FullName.Substring($ServerDir.Length + 1))" }
            Write-Host "    If any edit should be kept, copy it into the Mac pack config (or server-overrides) before continuing." -ForegroundColor Yellow
            if (-not $DryRun -and -not $Yes) {
                $ans = Read-Host "    Continue? (y/n)"
                if ($ans -ne "y") { throw "Stopped by you." }
            }
        }
    }
}

# ---------- Work ----------
Run "Backing up to $Backups" {
    New-Item -ItemType Directory -Force -Path $Backups | Out-Null
    $dest  = Join-Path $Backups "jewcraft-$stamp.zip"
    $items = @($levelName, "whitelist.json", "ops.json", "banned-players.json", "banned-ips.json", "server.properties", "user_jvm_args.txt", "config") |
        ForEach-Object { Join-Path $ServerDir $_ } | Where-Object { Test-Path $_ }
    try {
        Compress-Archive -Path $items -DestinationPath $dest -CompressionLevel Fastest
        Write-Host "    saved $dest"
    } catch {
        # Older Windows PowerShell can fail on very large archives. Copy the world folder instead.
        # The world is moved into the new server later, so this copy is the safety net. If it fails too, stop.
        Write-Host "    zip backup failed: $($_.Exception.Message)" -ForegroundColor Yellow
        $worldCopy = Join-Path $Backups "world-$stamp"
        Write-Host "    copying the world folder instead: $worldCopy" -ForegroundColor Yellow
        Copy-Item $worldPath $worldCopy -Recurse -Force
        if (-not (Test-Path $worldCopy)) { throw "Could not back up the world. Stopping before anything is changed." }
    }
}

Run "Building server files from the pack" {
    if (Test-Path $Staging) { Remove-Item $Staging -Recurse -Force }
    & $MrpackInstall $Pack --server-dir $Staging
    if ($LASTEXITCODE -ne 0) { throw "mrpack-install failed (exit code $LASTEXITCODE)." }
}

Run "Installing NeoForge $NeoForgeVersion" {
    $jar = Join-Path $Staging "neoforge-installer.jar"
    $url = "https://maven.neoforged.net/releases/net/neoforged/neoforge/$NeoForgeVersion/neoforge-$NeoForgeVersion-installer.jar"
    Invoke-WebRequest -Uri $url -OutFile $jar
    Push-Location $Staging
    try {
        & java -jar $jar --installServer
        if ($LASTEXITCODE -ne 0) { throw "NeoForge installer failed (exit code $LASTEXITCODE)." }
    } finally { Pop-Location }
    Remove-Item $jar -Force
    Remove-Item (Join-Path $Staging "neoforge-installer.jar.log") -Force -ErrorAction SilentlyContinue
}

Run "Writing neoforge_args.txt for NeoForge $NeoForgeVersion" {
    if (-not (Write-NeoForgeArgs $Staging $NeoForgeVersion)) {
        throw "NeoForge $NeoForgeVersion did not leave a win_args.txt in libraries. Nothing has been swapped yet; the live server is unchanged."
    }
}

Run "Removing blocked mods and adding extra server mods" {
    $mods = Join-Path $Staging "mods"
    New-Item -ItemType Directory -Force -Path $mods | Out-Null
    $patterns = Get-Content (Join-Path $PSScriptRoot "blocked-server-mods.txt") | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith("#") }
    foreach ($p in $patterns) {
        Get-ChildItem $mods -Filter $p.Trim() -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "    removed $($_.Name)"
            Remove-Item $_.FullName -Force
        }
    }
    $extra = Join-Path $RepoRoot "server-extra-mods"
    if (Test-Path $extra) {
        Get-ChildItem $extra -Filter *.jar -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "    added $($_.Name)"
            Copy-Item $_.FullName $mods -Force
        }
    }
}

Run "Carrying over whitelist, ops, bans, EULA and server.properties" {
    foreach ($name in @("whitelist.json", "ops.json", "banned-players.json", "banned-ips.json", "usercache.json", "eula.txt", "server.properties")) {
        $src = Join-Path $ServerDir $name
        if (Test-Path $src) { Copy-Item $src (Join-Path $Staging $name) -Force }
    }
    if (-not (Test-Path (Join-Path $Staging "eula.txt"))) {
        Set-Content -Path (Join-Path $Staging "eula.txt") -Value "eula=true" -Encoding ascii
    }
}

Run "Copying server-overrides" {
    $ov = Join-Path $RepoRoot "server-overrides"
    if (Test-Path $ov) { Copy-Item (Join-Path $ov "*") $Staging -Recurse -Force }
}

Run "Applying server.properties overrides" {
    $ovf = Join-Path $RepoRoot "server-config\server.properties.overrides"
    if (Test-Path $ovf) { Set-Props (Join-Path $Staging "server.properties") $ovf }
}

Run "Setting memory (Xms ${XmsGB}G, Xmx ${XmxGB}G)" {
    $f = Join-Path $Staging "user_jvm_args.txt"
    $keep = @()
    if (Test-Path $f) { $keep = @(Get-Content $f | Where-Object { $_ -notmatch '^\s*-Xm[sx]' }) }
    $keep + "-Xms${XmsGB}G" + "-Xmx${XmxGB}G" | Set-Content -Path $f -Encoding ascii
}

Run "Swapping the new server into place" {
    New-Item -ItemType Directory -Force -Path $OldRoot | Out-Null
    Move-Item $ServerDir $OldDir
    Move-Item $Staging $ServerDir
    # The existing world always goes into the new server. This script never creates a new world.
    Move-Item (Join-Path $OldDir $levelName) (Join-Path $ServerDir $levelName)
    if (-not (Test-Path (Join-Path $ServerDir $levelName))) { throw "The world did not make it into the new server folder. Do the rollback steps in the README." }
    Set-Content -Path (Join-Path $ServerDir ".last-build") -Value $stamp -Encoding ascii
    # Give the kept old folder its own neoforge_args.txt too, so a rollback starts with the same command.
    if (Write-NeoForgeArgs $OldDir "") { Write-Host "    old folder can roll back with the same start command" }
}

$commandOk = $true
Run "Making sure Crafty's start command is version free" {
    if (-not ($CraftyToken -and $CraftyUrl)) {
        $script:commandOk = $false
        return
    }
    try {
        if ((Get-CraftyStartCommand) -ne $StartCommand) {
            Invoke-CraftyServerApi "Patch" @{ execution_command = $StartCommand } | Out-Null
            if ((Get-CraftyStartCommand) -ne $StartCommand) { throw "Crafty accepted the request but the command did not change." }
            Write-Host "    changed to: $StartCommand"
        } else {
            Write-Host "    already set"
        }
    } catch {
        Write-Host "    Could not change it automatically: $($_.Exception.Message)" -ForegroundColor Yellow
        $script:commandOk = $false
    }
}

Write-Host ""
if ($DryRun) {
    Write-Host "Dry run finished. Nothing was changed." -ForegroundColor Green
} else {
    Write-Host "Done." -ForegroundColor Green
    if (-not $commandOk) {
        Write-Host ""
        Write-Host "ONE MANUAL STEP: in Crafty, open the server's Config tab and set the start command to:" -ForegroundColor Yellow
        Write-Host "  $StartCommand" -ForegroundColor Yellow
        Write-Host "You only ever do this once. After that, NeoForge changes need nothing in Crafty." -ForegroundColor Yellow
        # Exit code 3 tells the watcher not to start the server until the command is fixed.
        Write-Host ""
    }
    Write-Host "Next: start the server in Crafty and wait for the 'Done' line in the Terminal."
    Write-Host "Backup zip:  $Backups\jewcraft-$stamp.zip"
    Write-Host "Old server:  $OldDir"
    Write-Host ""
    Write-Host "To roll back: stop the server, then run"
    Write-Host "  Move-Item `"$ServerDir`" `"$Root\failed-$stamp`""
    Write-Host "  Move-Item `"$OldDir`" `"$ServerDir`""
    if (-not $commandOk) { exit 3 }
}
