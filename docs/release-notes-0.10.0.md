## DirSizes 0.10.0

### Hidden and free space, opened like folders

After scanning a disk, the chart shows what hidden space and free space are made of, in a
ring outside their wedges:

- **Hidden space** splits into the disk's other volumes (macOS, swap and sleep image,
  startup files, recovery, software updates) and **Unread folders and system data**, the
  rest that's in the scanned volume but not in its files.
- **Free space** splits into **Available now** and **Purgeable**: space macOS frees on its
  own when it runs low, mostly local Time Machine snapshots, also caches and files that are
  also in iCloud. macOS counts it as free, so it's under free space, not hidden space.

Click hidden or free space, in the chart or the list, to open it like a folder: the chart zooms
into its parts, the list shows them, and the breadcrumbs read `Macintosh HD › Hidden space`.
Expand a part in the list to see what it is. Swap in use is under **Swap and sleep image**,
the folders the scan couldn't read under **Unread folders and system data**, and your local
snapshots, with **Delete Local Snapshots…**, under **Purgeable**.
