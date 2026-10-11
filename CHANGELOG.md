# JewCraft changelog

Newest first. One entry per pack version. Paste the entry into the Modrinth version notes.

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
