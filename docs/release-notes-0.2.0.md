## DirSizes 0.2.0

### Use with Claude

DirSizes now has an MCP server, so an AI assistant can answer "what is taking up space?" and
suggest a cleanup. It can scan folders and disks, list, search and find the largest items, and
add things to the collector. It cannot delete anything: collected items show up in the app,
where you decide whether to move them to the Trash.

Click the ✨ button in the toolbar for the command that adds DirSizes to Claude Code, with a
Copy button. Other MCP clients can run `dirsizes mcp` as a stdio server; it starts the app
when it isn't running.
