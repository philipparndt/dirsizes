## DirSizes 0.11.0

### Old cloud folders

When a OneDrive, Dropbox or Google Drive location is removed or reset, macOS keeps its local
files in `~/Library/CloudStorage`, in a folder named with the date
(`OneDrive-Company (11.11.24 06:23)`), and Finder stops showing it. Nothing syncs these
folders anymore, but they still take space, often hundreds of megabytes.

Cleanup has a new **Cloud** section with **Old Cloud Folders**, listing them after a scan of
your home folder or the startup disk:

- **Kept after a reset**: the dated folders, with when macOS kept them, largest first.
- **Left by cloud apps**: folders the cloud app left behind, usually empty.

Their files are usually also in the cloud, but changes that were never uploaded exist only
here: look before removing them. The summary below the chart shows them too.

The start screen now lists only the cloud locations that are still synced, the same ones
Finder shows.
