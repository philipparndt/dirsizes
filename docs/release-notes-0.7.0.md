## DirSizes 0.7.0

### All of iCloud in one chart

The new iCloud card on the start screen shows how full your iCloud plan is, and **Scan**
charts all of it:

- iCloud Drive file by file, including files that are only in iCloud (counted at their size,
  drawn see-through; nothing is downloaded). App folders show their app's name ("1Password"
  rather than `2BUA8C4S2C~com~agilebits~onepassword-ios`).
- Photos, Backups, Mail, Messages and the rest of your iCloud storage around it, in iCloud's
  colors, plus what's left in your plan.
- Photos split into the library on this Mac (click it to look inside) and what is only in
  iCloud.

The numbers beyond iCloud Drive come from iCloud.com: sign in once on Apple's own page in a
DirSizes window (your password goes only to Apple). macOS doesn't let other apps read them.
Without signing in, Scan charts iCloud Drive alone.

Other cloud folders (Dropbox, OneDrive, Google Drive, … in `~/Library/CloudStorage`) get
cards too. The new Photos Library card estimates what iCloud Photos stores by adding up your
library.

### Space that isn't a file, in the list

Free and hidden space and the iCloud categories are listed next to the folders. Expand one
to see what DirSizes knows about it: family members' usage, photos vs. videos, or why it
can't be looked into.

### A smoother live chart

The chart while scanning now moves smoothly from one update to the next, and the finished
chart grows out of it. Disk scans show free space from the start and a "not scanned yet"
slice that shrinks as the scan goes.

### Smaller changes

- Disk cards have one **Scan** button; **Clean Scan** (read everything again) is in its menu.
- `dirsizes scan --cloud` counts files only in iCloud at their size.
- `make run` opens the start screen; `make run DIR=…` scans right away.
