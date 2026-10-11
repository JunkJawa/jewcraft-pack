# Settings for update-server.ps1. Edit once, then leave alone.

# Working folder on the server PC (backups, staging area, old server copies live here)
$Root = "C:\MinecraftServers"

# The live server folder that Crafty runs. The UUID is the one in the Crafty page URL
# (server_detail?id=...). Confirm it matches the folder name under C:\crafty\servers.
$ServerDir = "C:\crafty\servers\630d8a7c-6085-48bc-94cd-9bffb212663b"

# The pack build tool you downloaded earlier
$MrpackInstall = "C:\MinecraftServers\mrpack-install-windows.exe"

# Java memory for the server (the PC has 15.9 GB total, so do not raise Xmx)
$XmsGB = 4
$XmxGB = 10
