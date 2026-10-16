## DirSizes 0.5.1

### Copies made by APFS are no longer counted twice

APFS can copy a file without duplicating its data: the copy (a clone) shares the original's
blocks until one of them changes. DirSizes counted every clone at its full size, so a disk
could add up to more than its capacity. Chrome, for example, keeps hundreds of clones of
itself in a temporary folder, which showed up as hundreds of gigabytes. Pure clones are now
counted once, like hard links, and the totals match what the disk actually uses.
