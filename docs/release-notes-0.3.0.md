## DirSizes 0.3.0

### Faster permanent delete, with real progress

Delete Immediately now uses the scan to delete files in parallel instead of one item at a
time. On a folder with 145,000 small files it took 15 seconds, where `rm -rf` took over two
minutes. Progress is shown in bytes, with the folder being worked on, and the chart shrinks
while it runs. Stop halts within a moment. Move to Trash now runs several items at once.

### Review the collector

The expand button on the Collector opens a full-window review: a sunburst of just what will
be deleted, next to a tree (or a list sorted by size). Remove anything inside a collected
folder to keep it while the rest stays collected. The tree works with the keyboard: arrows to
move and expand, ⌫ to remove, Esc to go back. The Collector panel itself can now be dragged
taller.

### Files deleted elsewhere turn gray

Items another app deletes after the scan are shown in gray in the chart, the list and the
Collector, with a note and a Rescan link in the status bar. The watcher batches file system
events, so heavy activity in the scanned folder doesn't slow the app down.
