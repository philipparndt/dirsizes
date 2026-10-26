import Foundation

/// ~/Library/CloudStorage, where File Provider apps (Dropbox, OneDrive, Google Drive, …) keep
/// their folders. Not every folder there is synced: when a location is removed or reset, macOS
/// keeps its local files in a folder named with the date ("OneDrive-Foo (11.11.24 06:23)"), and
/// apps leave empty folders behind. Finder shows only the synced ones.
public enum CloudStorage {
    /// Synced: macOS tags the folder of a File Provider location with its domain. Only a
    /// folder known to lack the tag counts as not synced (not one that couldn't be read).
    public static func isSynced(_ path: String) -> Bool {
        getxattr(path, "com.apple.file-provider-domain-id", nil, 0, 0, 0) >= 0 || errno != ENOATTR
    }

    /// The provider's own working folder ("OneDrive-OneDriveCloudTemp"), synced but hidden in
    /// Finder.
    public static func isInternal(_ name: String) -> Bool {
        name.hasSuffix("CloudTemp")
    }

    /// The folders in `home`'s Library/CloudStorage that nothing syncs anymore: what macOS kept
    /// of a removed or reset location, and folders the cloud app left. Finder doesn't show them.
    public static func oldFolders(in tree: FileTree, home: String) -> [SuggestionSection] {
        guard let folder = tree.node(atPath: home + "/Library/CloudStorage") else { return [] }
        var kept: [Suggestion] = []
        var left: [Suggestion] = []
        for child in tree.children(of: folder) where tree.nodes[Int(child)].isDirectory {
            let name = tree.name(of: child)
            let path = tree.path(of: child)
            guard !name.hasPrefix("."), !isSynced(path) else { continue }
            // "OneDrive-Foo (11.11.24 06:23)": when macOS kept it.
            if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
                kept.append(Suggestion(
                    id: path, title: String(name[..<open.lowerBound]),
                    subtitle: "kept " + name[open.upperBound...].dropLast(), effect: .lost,
                    note: """
                        The local files of a cloud location that was removed or reset. Nothing syncs them \
                        anymore; what's here is usually also in the cloud, but changes that were never \
                        uploaded exist only here. Look before removing it.
                        """,
                    items: [child], date: SuggestionDates.lastChange(of: path), tree: tree))
            } else {
                left.append(Suggestion(
                    id: path, title: name, effect: .lost,
                    note: "A folder the cloud app left behind. Nothing syncs it anymore; it's usually empty.",
                    items: [child], date: SuggestionDates.lastChange(of: path), tree: tree))
            }
        }
        var sections: [SuggestionSection] = []
        if !kept.isEmpty {
            sections.append(SuggestionSection(title: "Kept after a reset", suggestions: kept.sorted { $0.size > $1.size }))
        }
        if !left.isEmpty {
            sections.append(SuggestionSection(title: "Left by cloud apps", suggestions: left.sorted { $0.title < $1.title }))
        }
        return sections
    }
}
