# JewCraft changelog

Newest first. One entry per pack version. Paste the entry into the Modrinth version notes.

## 1.3.0 (planned): Create Aeronautics and Sophisticated Storage

Tested on the Mac in the "JewCraft 1.2.0" instance (loads, joins a world, flies). Released as 1.3.0 because the
server already runs a pack tagged 1.2.0 (installed 25 Oct 2026, NeoForge 21.1.213), and the updater ignores a
release whose tag matches what is installed. Same world; players update their existing instance.

Added
- Create Aeronautics 1.3.2 (bundled jar, includes Sable 2.0.6)
- Sophisticated Storage 1.6.13, Sophisticated Storage and Backpacks Create Integrations
- JewCraft Names resource pack (addons/JewCraft Names.zip): gives Smokeleaf's Unfinished Hemp Core its missing name.
  Players switch it on once under Options, Resource Packs.

Updated
- NeoForge 21.1.213 to 21.1.265
- Create 6.0.8 to 6.0.10 or newer
- Sodium 0.6.13 to 0.8.13; Iris to 1.8.14-beta.1
- Sophisticated Core 1.3.89 to 1.5.23, Sophisticated Backpacks 3.25.14 to 3.26.12
- Armourer's Workshop 3.2.7-beta to 3.4.0-beta.3 (the older one crashes with Backpacks 3.26)
- Supplementaries and Moonlight Lib to latest (older ones crash with Sodium 0.8)
- Accessories, owo-lib, Accessories Compatibility Layer
- Sinytra Connector to 2.0.0-beta.14, Forgified Fabric API to 0.116.15
- Xaero's maps
- More Culling to 1.0.11 (1.0.6 freezes on Sodium 0.8)

Removed (client only, all broke on Sodium 0.8)
- Sodium Leaf Culling, Sodium Extras, Sodium Options API, Sodium Options Mod Compat, Sodium Shadowy Path Blocks

Config
- config/mekanismcovers.json: disableAdvancedCoverRendering = true (otherwise it crashes with Sodium 0.8)
- spark is off on the Mac client (its background profiler crashes the game on Apple Silicon through the native
  libasyncProfiler). The server keeps it: spark-1.10.124-neoforge.jar copied from the live server into
  server-extra-mods (jars there are gitignored, so it lives only on the PC).

Server scripts
- Version free start command. Crafty now starts the server with `java @user_jvm_args.txt @neoforge_args.txt nogui`.
  update-server.ps1 loads settings.local.ps1, copies the new NeoForge's win_args.txt to neoforge_args.txt on every
  update (and stops before swapping anything if it is missing), writes one into the kept old folder too so a rollback
  uses the same command, shows Crafty's current start command in preflight (also in a dry run), and sets it through
  the Crafty API after the swap. If it cannot, it prints the line to paste into Crafty and exits with code 3;
  updater.ps1 then marks the version installed, leaves the server off, and sends a high priority push with the line.

Before releasing
- Load a copy of the real world from a server backup on the Mac and open several backpacks (Core jumps 1.3 to 1.5).
- Tick the config and resourcepacks folders in the export.
- Known open question: one native Java crash (StringTable) about 4 seconds after Sable's macOS physics library loaded.
  Not repeated yet. If it does, report it to Sable with the hs_err_pid file (remove the accessToken part first).

## 1.1.0 (planned)

New world. Players need to import the new pack and delete the old instance.

Removed
- Stellaris: picking up its items (space suit helmet) threw an item-saving error with Bonded data and dropped players with "Connection reset"
- Vampirism, Vampirism Integrations, Vampire's Delight: removed for performance and to simplify the pack
- C2ME (Concurrent Chunk Management Engine): caused a 60 second main thread freeze that restarted the server

Config changes (set these in the Mac instance's config/DistantHorizons.toml so they ship in the pack)
- maxGenerationRequestDistance = 64 (was 4096)
- generationRequestRateLimit = 2 (was 20)
- real time updates = false
- adaptive transfer speed = true
- global upload cap = 1000 KB/s (home upload is about 23 Mbps)

Server only (server-config/server.properties.overrides)
- view-distance=8, simulation-distance=6

## 1.0.0

First release, built from CatTech 2 (Minecraft 1.21.1, NeoForge 21.1.213, 222 mods).

## Unreleased
- Added the watcher (scripts\watch-server.ps1, install-watcher-task.ps1, agent-diagnose-prompt.txt) for phone alerts and read only crash diagnosis. No change to the pack or the live server.
- Crash notices: after a crash and restart the watcher posts one line in game chat through Crafty, chosen from scripts\known-crashes.json. Watcher now checks every 5 minutes (alerts for offline or stuck still wait 15 minutes).
- ImmediatelyFast: hud_batching = false (config/immediatelyfast.json). With it on, Iris's Shader Packs screen opened blank, so nobody could pick a shader. Tested on Iris 1.8.12, Sodium 0.6.13, ImmediatelyFast 1.6.7. Players need the new pack for this, the server is not affected.
- Watcher, one night only (13-14 Oct 2026, Gil asked): once the server is empty it sends "difficulty easy" through Crafty, because a player had set it to Peaceful. Runs once, stops by itself at noon on 14 Oct, and leaves C:\MinecraftServers\easy-tonight.done. The block in watch-server.ps1 can be deleted afterwards.
- Watcher, one time only (15 Oct 2026, Gil asked): same Easy reset as above, because the difficulty was set to Peaceful again on 14 Oct. Runs once when the server is empty, stops by itself at the end of 15 Oct, leaves C:\MinecraftServers\easy-2026-10-15.done.
- More ore (server only): new datapack server-overrides\config\openloader\packs\jewcraft-ores. Doubles every vanilla overworld ore and adds iron (y -64 to -24), coal (y -64 to 0) and copper (y -64 to -16) to the deep caves, so the basics are easier to get and players can explore the modded content. Only newly generated land gets the extra ore; the world is not changed. Needs the server-only mod Open Loader (NeoForge 1.21.1) in server-extra-mods. Written for Minecraft 1.21.1, NeoForge 21.1.213, Terralith 2.5.8. Players do not need a new pack.
- Ores: addons\boosted-ores_3.zip replaces boosted-ores_2.zip in world\datapacks (Gil swaps it by hand with the server stopped). Adds iron x2 and redstone x2 to the existing diamonds x2, ancient debris x2, emeralds x1.5. Only new land is affected. Written for Minecraft 1.21.1 / NeoForge 21.1.213. Note: the Open Loader pack (server-overrides\config\openloader\jewcraft-ores) stays unused because Open Loader is not installed; do not install Open Loader while boosted-ores is in use or the two will clash.

- Added addons/JewCraft Names.zip, a tiny client resource pack that gives Smokeleaf Industries 0.5.1's
  unfinished_hemp_core its missing English name ("Unfinished Hemp Core"). The mod's own en_us.json leaves it out,
  so the raw ID showed in recipe viewers. Name only; the recipe already works. Ships via the Mac instance's
  resourcepacks folder and a re-export.
- Gold gear vs Aether golden ring: Industrial Foregoing 3.6.36's gold_gear and Aether 1.5.10's golden_ring use the
  same 4-gold-ingot diamond pattern. No change made: Polymorph (already in the pack, client + server) adds a button
  next to the crafting output to pick which result you get.
- Cleanup (1 Nov 2026): removed the expired one-time Easy block from watch-server.ps1 (it stopped on 16 Oct; the
  Send-ServerCommand helper stays). Removed the unused Open Loader ore pack from server-overrides\config\openloader,
  since boosted-ores_3 in world\datapacks does the job and the two would clash if Open Loader were ever added.
