## DirSizes 0.9.0

### Cleanup: five new kinds of suggestions

The Cleanup panel now has a sidebar with seven kinds of suggestions in three groups: **Apps**
(Left Behind, Unused Apps, Startup Items), **Files** (Developer, Old Files, Duplicates) and
**Over Time** (Changes). Every tab shows how much is selected and how much of it is already in
the Collector. As before, suggestions only go into the Collector; you decide there what moves
to the Trash.

- **Developer**: caches of developer tools such as Xcode (DerivedData, device support,
  archives, simulators), Swift packages, Homebrew, CocoaPods, npm, yarn, pnpm, pip, uv, Cargo,
  Go, Gradle, Maven, JetBrains, Android and Docker. It also finds build output and installed
  packages inside your projects (`node_modules`, `target`, `.build`, `Pods`, `.venv`, …),
  either per project, the projects you haven't touched the longest first, or by kind. A badge
  on each entry says what removing it means: rebuilt or downloaded again when needed, or gone.
- **Old Files**: installers, disk images, archives and other files in Downloads, by when you
  downloaded them; iPhone and iPad backups; and device software updates.
- **Duplicates**: files with the same contents, found by comparing them in full. Files that
  are APFS clones of each other share their space, so the space you'd get back counts them
  once. **Add All but the Oldest** keeps the first copy of each file. If every copy of a file
  is in the Collector, the file is marked.
- **Startup Items**: launch agents, launch daemons and helper tools whose app or program is
  gone, and those that may belong to something no longer installed.
- **Changes**: what grew or shrank since an earlier scan of the same folder, folder by
  folder. DirSizes keeps the sizes of the last ten scans of each folder. The first time, it
  compares with the saved scan the new one replaces.

### Suggestions on the main page

After a scan, a line below the chart shows what Cleanup found: how much could be freed in
total and per kind, and what changed since the last scan. Point at a part to see its largest
entries, click it to open that tab. Duplicates show up there after you've searched for them
once.

### What's in hidden space

Clicking **Hidden space** now shows what it's made of: the disk's other volumes (macOS, swap
and sleep image, startup files, recovery, software updates), the rest (local snapshots and
folders that couldn't be read), swap in use, and your local Time Machine snapshots. You can
delete the snapshots after entering an administrator password.

### Smaller changes

- The breadcrumbs above the chart start with **Disks**, which goes back to the list of disks.
- The duplicate search shows its progress with the same bar as a scan.
