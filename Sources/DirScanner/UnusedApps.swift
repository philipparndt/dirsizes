import Foundation

/// An installed app with what it takes up: the app itself and its data in the Library folders.
public struct UnusedApp: Sendable, Identifiable {
    public var id: String { bundleID }
    public let name: String
    /// Lowercased.
    public let bundleID: String
    /// When it was last opened, as Spotlight recorded it, or else when it last changed its data;
    /// nil when neither is known.
    public let lastUsed: Date?
    /// `lastUsed` comes from the app's data, not from Spotlight (which often has no record, e.g.
    /// after migrating to a new Mac).
    public let lastUsedFromData: Bool
    /// The app bundle's node, first, then its data, largest first.
    public let items: [Int32]
    public let size: Int64

    public var app: Int32 { items[0] }
}

public enum UnusedAppFinder {
    /// The apps in `appFolders` (absolute paths in `tree`, e.g. /Applications) with their data
    /// in `libraries`. Apple's apps and those in `excluding` (running apps) are left out.
    /// `lastUsed` looks up when an app was last opened. Oldest first, never-opened ones first of all.
    public static func find(in tree: FileTree, appFolders: [String], libraries: [String],
                            excluding: Set<String> = [], lastUsed: (String) -> Date?) -> [UnusedApp] {
        let data = dataByName(in: tree, libraries: libraries)
        var apps: [UnusedApp] = []
        var seen = Set<String>()
        for folder in appFolders {
            guard let folderNode = tree.node(atPath: folder) else { continue }
            for child in tree.children(of: folderNode) {
                let name = tree.name(of: child)
                guard name.hasSuffix(".app"), tree.nodes[Int(child)].isDirectory else { continue }
                let path = folder + "/" + name
                guard let info = bundleInfo(at: path) else { continue }
                let id = info.id.lowercased()
                guard !id.hasPrefix("com.apple."), !excluding.contains(id), seen.insert(id).inserted else { continue }

                var items = [child]
                let dotted = id + "."
                for (key, nodes) in data where key == id || key.hasPrefix(dotted) || key == info.name.lowercased() {
                    items += nodes
                }
                let rest = items.dropFirst().sorted { tree.nodes[Int($0)].size > tree.nodes[Int($1)].size }
                items = [child] + rest
                let opened = lastUsed(DataVolume.displayPath(path))
                let changed = opened == nil ? lastChange(of: rest.map { tree.path(of: $0) }) : nil
                apps.append(UnusedApp(name: info.name, bundleID: id, lastUsed: opened ?? changed,
                                      lastUsedFromData: opened == nil && changed != nil, items: items,
                                      size: items.reduce(0) { $0 + tree.nodes[Int($1)].size }))
            }
        }
        return apps.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
    }

    /// The newest modification among the app's data and what's directly inside it (an app
    /// rewrites its preferences and state when it runs; a folder's own date only changes when
    /// entries are added or removed). Sandboxed apps keep theirs in the container's Data/Library.
    private static func lastChange(of paths: [String]) -> Date? {
        let files = FileManager.default
        var newest: Date?
        func consider(_ path: String) {
            guard let date = (try? files.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        for path in paths {
            consider(path)
            for inner in ["", "/Data/Library/Preferences", "/Data/Library/Application Support",
                          "/Data/Library/Saved Application State"] {
                let folder = path + inner
                for name in ((try? files.contentsOfDirectory(atPath: folder)) ?? []).prefix(200) {
                    consider(folder + "/" + name)
                }
            }
        }
        // Dates in the future (clock trouble, copies) say nothing about use.
        return newest.map { min($0, Date()) }
    }

    /// Entries in the Library folders, by the (lowercased) identifier or name they're named by.
    private static func dataByName(in tree: FileTree, libraries: [String]) -> [String: [Int32]] {
        var result: [String: [Int32]] = [:]
        for library in libraries {
            for (location, naming) in LeftoverFinder.locations {
                guard let folder = tree.node(atPath: library + "/" + location) else { continue }
                for child in tree.children(of: folder) {
                    var name = tree.name(of: child)
                    if name.hasPrefix(".") { continue }
                    for suffix in [".plist", ".savedState", ".binarycookies", ".lockfile"] where name.hasSuffix(suffix) {
                        name.removeLast(suffix.count)
                    }
                    if naming == .groupIdentifier {
                        // "TEAMID1234.com.foo.app" or "group.com.foo.app"; only exact matches count,
                        // since a vendor's apps share group containers.
                        let parts = name.split(separator: ".", maxSplits: 1)
                        if parts.count == 2 { name = String(parts[1]) }
                    }
                    // Folders named like apps only count in Application Support.
                    if naming != .identifierOrName && !LeftoverFinder.isIdentifier(name.lowercased()) { continue }
                    result[name.lowercased(), default: []].append(child)
                }
            }
        }
        return result
    }

    private static func bundleInfo(at path: String) -> (id: String, name: String)? {
        let url = URL(fileURLWithPath: path)
        let plist = url.appendingPathComponent("Contents/Info.plist")
        // iOS apps on Apple Silicon wrap the real bundle.
        let wrapped = (try? FileManager.default.contentsOfDirectory(atPath: path + "/Wrapper"))?
            .first { $0.hasSuffix(".app") }
            .map { url.appendingPathComponent("Wrapper/\($0)/Info.plist") }
        guard let info = (NSDictionary(contentsOf: plist) ?? wrapped.flatMap { NSDictionary(contentsOf: $0) })
                as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String else { return nil }
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (id, name)
    }
}
