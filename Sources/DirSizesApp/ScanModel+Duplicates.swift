import DirScanner
import Foundation

extension ScanModel {
    var findingDuplicates: Bool { duplicateSearch != nil }

    /// Looks for duplicate files of at least `minimumSize` in the scan, off the main thread. Reading
    /// the files can take minutes on a full disk; `duplicateProgress` follows it, and a new scan
    /// stops it.
    func findDuplicates(minimumSize: Int64) {
        guard let tree else { return }
        duplicateSearch?.cancel()
        let search = DuplicateSearch(minimumSize: minimumSize)
        duplicateSearch = search
        duplicateProgress = search.progress
        Task.detached(priority: .userInitiated) {
            let found = search.run(in: tree)
            await MainActor.run {
                guard self.duplicateSearch === search else { return }
                self.duplicateSearch = nil
                guard self.tree === tree, !search.isCancelled else { return }
                // Deletions while it ran.
                self.duplicates = found.compactMap { $0.remaining(in: tree) }
                self.duplicatesMinimumSize = minimumSize
            }
        }
        // Polled rather than reported: the workers update it for every megabyte read.
        Task {
            while duplicateSearch === search {
                duplicateProgress = search.progress
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Stops a running search and forgets what was found (for a new scan).
    func resetDuplicates() {
        duplicateSearch?.cancel()
        duplicateSearch = nil
        duplicates = nil
        duplicatesMinimumSize = 0
    }
}
