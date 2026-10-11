<#
JewCraft server update script (Windows PowerShell 5.1 or newer)

What it does, in order:
  1. Checks the server is stopped
  2. Backs up the world, whitelist, ops, and configs to a zip
  3. Builds fresh server files from the new .mrpack into a staging folder
  4. Installs the NeoForge version the pack asks for
  5. Removes blocked mods, adds extra server mods, copies server-overrides
  6. Carries over the world, whitelist, ops, bans, and server.properties
  7. Applies the settings in server-config\server.properties.overrides and sets memory
  8. Swaps the new folder into Crafty's server folder (the old one is kept)

Usage (PowerShell, from the scripts folder):
  .\update-server.ps1 -Pack "C:\path\to\JewCraft 1.1.0.mrpack" -DryRun   # shows the plan, changes nothing
  .\update-server.ps1 -Pack "C:\path\to\JewCraft 1.1.0.mrpack"           # does it

Stop the server in Crafty first. Start it again in Crafty when the script finishes.
#>
param(
    [Parameter(Mandatory = $true)][string]$Pack,
    [string]$NeoForgeVersion = "",
    [switch]$NewWorld,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "settings.ps1")

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
if ($NewWorld) { Write-Host "    -NewWorld given: the old world will NOT be carried over" -ForegroundColor Yellow }

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
            if (-not $DryRun) {
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
        # Older Windows PowerShell can fail on very large archives. The old server folder is kept in full anyway.
        Write-Host "    zip backup failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "    continuing; the complete old server folder is kept in $OldRoot" -ForegroundColor Yellow
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
    if (-not $NewWorld) {
        $oldWorld = Join-Path $OldDir $levelName
        if (Test-Path $oldWorld) { Move-Item $oldWorld (Join-Path $ServerDir $levelName) }
    }
    Set-Content -Path (Join-Path $ServerDir ".last-build") -Value $stamp -Encoding ascii
}

Write-Host ""
if ($DryRun) {
    Write-Host "Dry run finished. Nothing was changed." -ForegroundColor Green
} else {
    Write-Host "Done." -ForegroundColor Green
    Write-Host "Next: start the server in Crafty and wait for the 'Done' line in the Terminal."
    Write-Host "Backup zip:  $Backups\jewcraft-$stamp.zip"
    Write-Host "Old server:  $OldDir"
    Write-Host ""
    Write-Host "To roll back: stop the server, then run"
    Write-Host "  Move-Item `"$ServerDir`" `"$Root\failed-$stamp`""
    Write-Host "  Move-Item `"$OldDir`" `"$ServerDir`""
}
