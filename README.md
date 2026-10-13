# DirSizes

A fast disk usage scanner for macOS, with a sunburst chart to find what is taking up space
and a collector to clean it up.

![DirSizes showing a sunburst of a home folder](docs/screenshot.png)

<sub>The screenshot shows made-up data (`make screenshot`), not a real disk.</sub>

## Features

- **Fast scanning.** Directories are read with `getattrlistbulk(2)` (names, types and sizes
  for many entries per system call) by a pool of worker threads, instead of `readdir` plus
  one `lstat` per file.
- **Sunburst chart.** Each ring is one level deeper. Click a folder to zoom in, click the
  center to go back up. Hover to see sizes.
- **Whole disks.** Pick a disk on the start screen and the chart also shows free space and
  space the scan couldn't account for (snapshots, purgeable data, folders without access).
- **Collector.** Drag files and folders from the chart, the list or Finder into the
  collector, then move them to the Trash or delete them in one go.
- **Command-line scanner.** `dirsizes scan` prints the largest entries. `dirsizes bench`
  compares the scanner with `FileManager`, `fts` and `du`.

## Install

```sh
brew tap philipparndt/dirsizes
brew trust philipparndt/dirsizes
brew install --cask dirsizes
```

This installs `DirSizes.app` and links the `dirsizes` command. You can also download the
disk image from [Releases](https://github.com/philipparndt/dirsizes/releases). Builds are
signed with a Developer ID and notarized.

Requires macOS 15 or newer, on Apple silicon or Intel.

### Full Disk Access

macOS hides some folders (Mail, Safari, other apps' containers) from apps until you allow
it. Without that permission those folders count as unreadable and their size shows up as
hidden space. To scan everything, add DirSizes under **System Settings › Privacy & Security ›
Full Disk Access**.

## Command line

```
dirsizes scan  <path> [--threads N] [--top N] [--cross-devices]
dirsizes bench <path> [--runs N] [--skip fm,fts,du]
```

By default `scan` stays on the device it starts on. Add `--cross-devices` to follow mounts.

## Building

You need Xcode (the build uses Xcode's Swift toolchain through `xcrun`).

```sh
make run DIR=~/dev     # build the app and scan a folder
make demo              # launch with made-up data
make install           # copy DirSizes.app to /Applications
make scan DIR=~/dev    # command-line scan
make bench DIR=~/dev   # compare against FileManager, fts and du
```

## Releasing

```sh
make sign-check                       # Developer ID certificate and notarytool profile
make release-publish VERSION=0.2.0    # needs docs/release-notes-0.2.0.md
```

`release-publish` bumps `VERSION`, tags the commit, builds a universal app, signs and
notarizes it, packages and notarizes a disk image, uploads it to a GitHub release and
updates the cask in [philipparndt/homebrew-dirsizes](https://github.com/philipparndt/homebrew-dirsizes).
If only the tap step failed, `make tap VERSION=0.2.0` redoes it.
