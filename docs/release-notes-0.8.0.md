## DirSizes 0.8.0

### App cleaner: find apps you don't use anymore

The Cleanup panel has a new **Unused Apps** tab next to **Left Behind**. It lists the apps in
`/Applications`, `/Applications/Utilities` and `~/Applications` together with their data in
the Library folders (caches, containers, preferences, application support, saved state, …),
the apps you haven't used the longest first.

- Each app shows when it was last opened, as Spotlight recorded it. When Spotlight has no
  record (common after migrating to a new Mac), it shows when the app last changed its data
  instead, or "no record of use".
- Choose how long an app must have gone unused: 3, 6, 12 or 24 months, or any time.
- Expand an app to see its data item by item, and add the app with all of its data, or single
  items, to the Collector.
- Apple's apps and apps that are running are left out.

### Removing apps installed by the App Store or an installer

Apps installed by the App Store or by an installer package belong to the system, so moving
them to the Trash failed with "you don't have permission". DirSizes now hands them to Finder,
which asks for your administrator password once for all of them, just as when you drag them
to the Trash yourself. The first time, macOS asks whether DirSizes may control Finder.

### Smaller changes

- **Left Behind** no longer lists data of command-line tools you have installed, such as
  `org.swift.swiftpm` when Swift is installed.
- Builds made with `make app` are signed with your Developer ID when you have one, so they
  keep Full Disk Access just like the released app. `make run` starts the app through
  `open`, so macOS checks the app's own permissions rather than your terminal's.
