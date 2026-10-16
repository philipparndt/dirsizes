import CoreServices
import Foundation

/// Downloads, device backups and device software updates: files that pile up and are rarely
/// looked at again.
public enum OldFileFinder {
    private static let installers: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "app", "img", "ipsw"]
    private static let archives: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst"]

    /// `home` is the home folder's path in `tree`.
    public static func find(in tree: FileTree, home: String) -> [SuggestionSection] {
        var sections: [SuggestionSection] = []

        if let downloads = tree.node(atPath: home + "/Downloads") {
            var installerItems: [Suggestion] = []
            var archiveItems: [Suggestion] = []
            var otherItems: [Suggestion] = []
            for child in tree.children(of: downloads) {
                let name = tree.name(of: child)
                guard !name.hasPrefix("."), tree.nodes[Int(child)].size > 0, tree.nodes[Int(child)].kind != .cloudFile
                else { continue }
                let path = tree.path(of: child)
                let ext = (name as NSString).pathExtension.lowercased()
                let date = dateAdded(path)
                if installers.contains(ext) {
                    installerItems.append(Suggestion(
                        id: path, title: name, effect: .redownloaded,
                        note: "An installer or disk image. Once the app is installed, it isn't needed anymore; it can be downloaded again.",
                        items: [child], date: date, tree: tree))
                } else if archives.contains(ext) {
                    archiveItems.append(Suggestion(
                        id: path, title: name, effect: .lost,
                        note: "An archive. Check whether you unpacked it (or can download it again) before removing it.",
                        items: [child], date: date, tree: tree))
                } else {
                    otherItems.append(Suggestion(
                        id: path, title: name, effect: .lost,
                        note: "A download. Move what you want to keep somewhere else first.",
                        items: [child], date: date, tree: tree))
                }
            }
            let oldestFirst = { (a: Suggestion, b: Suggestion) in (a.date ?? .distantPast) < (b.date ?? .distantPast) }
            if !installerItems.isEmpty {
                sections.append(SuggestionSection(title: "Installers and disk images in Downloads", byAge: true,
                                                  suggestions: installerItems.sorted(by: oldestFirst)))
            }
            if !archiveItems.isEmpty {
                sections.append(SuggestionSection(title: "Archives in Downloads", byAge: true,
                                                  suggestions: archiveItems.sorted(by: oldestFirst)))
            }
            if !otherItems.isEmpty {
                sections.append(SuggestionSection(title: "Other downloads", byAge: true,
                                                  suggestions: otherItems.sorted(by: oldestFirst)))
            }
        }

        // Backups the Finder (or iTunes) made of iPhones and iPads.
        if let backups = tree.node(atPath: home + "/Library/Application Support/MobileSync/Backup") {
            let found = tree.children(of: backups).compactMap { backup -> Suggestion? in
                let path = tree.path(of: backup)
                let info = NSDictionary(contentsOfFile: path + "/Info.plist") as? [String: Any]
                let device = info?["Device Name"] as? String ?? "Device backup"
                let product = info?["Product Name"] as? String
                let date = info?["Last Backup Date"] as? Date
                    ?? (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                return Suggestion(
                    id: path, title: device, subtitle: product, effect: .lost,
                    note: "A backup of the device made on this Mac. Only needed to restore the device or set up a new one; "
                        + "check that it's backed up to iCloud or that you have a newer backup.",
                    items: [backup], date: date, tree: tree)
            }
            if !found.isEmpty {
                sections.append(SuggestionSection(title: "iPhone and iPad backups", byAge: true,
                                                  suggestions: found.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }))
            }
        }

        // Software updates downloaded to restore or update devices.
        var updates: [Suggestion] = []
        for folder in ["iPhone Software Updates", "iPad Software Updates", "iPod Software Updates", "Apple TV Software Updates"] {
            guard let node = tree.node(atPath: home + "/Library/iTunes/" + folder) else { continue }
            for child in tree.children(of: node) where tree.name(of: child).lowercased().hasSuffix(".ipsw") {
                let path = tree.path(of: child)
                updates.append(Suggestion(
                    id: path, title: tree.name(of: child), effect: .redownloaded,
                    note: "Device software downloaded to update or restore a device. Downloaded again when needed.",
                    items: [child], date: (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                    tree: tree))
            }
        }
        if !updates.isEmpty {
            sections.append(SuggestionSection(title: "Device software updates", byAge: true, suggestions: updates))
        }
        return sections
    }

    /// When the file was downloaded (added to its folder), else when it was last changed.
    private static func dateAdded(_ path: String) -> Date? {
        if let item = MDItemCreate(nil, path as CFString), let date = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date {
            return date
        }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
        return values?.addedToDirectoryDate ?? values?.contentModificationDate
    }
}
