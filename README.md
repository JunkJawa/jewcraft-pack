# JewCraft pack repo

The source of truth for the JewCraft server and pack. The live server on the PC is never edited by hand.
Change things here (or on the Mac instance), export a new .mrpack, and rebuild the server with the script.

## Layout

| Path | What it is |
|---|---|
| `config/` | Mod config files copied from the Mac instance's `config` folder. Ships to players and the server inside the .mrpack. |
| `server-config/server.properties.overrides` | key=value lines applied to server.properties after every rebuild |
| `server-overrides/` | Files copied onto the server only, after every rebuild (never sent to players) |
| `server-extra-mods/` | Jars copied into the server's mods folder after every rebuild |
| `scripts/update-server.ps1` | The one command that rebuilds the server from a .mrpack |
| `scripts/settings.ps1` | Paths and memory settings for the PC. Edit once. |
| `scripts/blocked-server-mods.txt` | Mod name patterns always deleted from the server |
| `CHANGELOG.md` | What changed in each pack version and why |

## Updating the pack (the routine)

1. On the Mac, change mods in the Modrinth App and configs in the instance's `config` folder.
2. Copy changed configs into this repo's `config/` and add a CHANGELOG entry (this is how edits are kept).
3. Export the instance as `JewCraft x.y.z.mrpack` (bump the version).
4. Copy the .mrpack to the PC.
5. In Crafty, Stop the server and wait for Offline.
6. On the PC, in PowerShell:

```
cd C:\path\to\jewcraft-pack\scripts
powershell -ExecutionPolicy Bypass -File .\update-server.ps1 -Pack "C:\path\to\JewCraft 1.1.0.mrpack" -DryRun
powershell -ExecutionPolicy Bypass -File .\update-server.ps1 -Pack "C:\path\to\JewCraft 1.1.0.mrpack"
```

   The current world is always kept. This script cannot start a new world, and it stops if it cannot find the world.
7. Start the server in Crafty and watch the Terminal for the "Done" line.
8. Send friends the new .mrpack (or publish the new version on Modrinth).

## First time setup on the PC

1. Install Git or just copy this folder to the PC, for example `C:\jewcraft-pack`.
2. Open `scripts\settings.ps1` and confirm `ServerDir` matches the folder under `C:\crafty\servers`.
3. Run the script once with `-DryRun` and read the plan before running it for real.

## Rolling back

The script keeps the previous server folder in `C:\MinecraftServers\old\<timestamp>` and a zip of the world and configs in `C:\MinecraftServers\backups`.
To roll back, stop the server and swap the folders (the script prints the exact commands when it finishes).

## Rules for the admin agent

- Never edit files in the live server folder. Propose a change to this repo (config, overrides, or a mod to add or remove) and explain why in CHANGELOG.md.
- Mods are added and removed in the Modrinth App on the Mac. The agent says which mod to change; Gil does it and re-exports.
- Anything that changes the live server needs Gil's approval first.
- Do not touch the Microsoft or Minecraft account, OneDrive, or anything outside the server folders.

## Not tested yet

The script was written without access to a Windows machine, so it has not been run. Use `-DryRun` first,
and keep the old server folder until the new one has run cleanly with friends on it.
