## DirSizes 0.5.0

### Find what uninstalled apps left behind

The new Cleanup view (💡 in the toolbar) lists caches, settings, containers, saved state and
launch agents in `~/Library` and `/Library` that belong to apps no longer on your Mac,
grouped by app and sorted by size. Entries that may still belong to something installed (an
app by the same vendor, a command-line tool) are marked "Check". Tick what you want gone,
or select rows and press Space, then delete it from the collector as usual. It works on any
scan that includes your home folder or the startup disk.

AI assistants can ask for the same list through the new `leftovers` MCP tool, and
`dirsizes leftovers` prints it in the terminal. Neither deletes anything.

### Modern macOS look

DirSizes is now built for the current macOS SDK, so on macOS 26 it uses the new design and
the toolbar buttons no longer look disabled.
