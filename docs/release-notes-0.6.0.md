## DirSizes 0.6.0

### Rescans only read what changed

DirSizes now saves each scan and uses the macOS change history to read only the folders that
changed since then. Rescanning a large folder takes seconds instead of minutes. Scanning a
subfolder of a saved scan, or of the scan on screen, reuses it the same way.

- Disk cards show when a disk was last scanned and offer **Update**; hold ⌥ for **Full Scan**.
- The toolbar's Rescan turns into **Full Rescan** with ⌥ (also ⌥⌘R in the File menu).
- External and network drives get a full scan by default, since they may have changed on
  another computer; ⌥ switches to an update.

### Live chart while scanning

The progress screen shows the top three levels filling in while the scan runs.

### Fixes

- System folders such as `/System/Library` are no longer mixed up with the data volume.
- Hard links and APFS clones stay counted once across rescans.
