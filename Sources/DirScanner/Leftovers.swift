import Foundation

/// The apps on this Mac, for telling which app data belongs to nothing anymore.
public struct InstalledApps: Sendable {
    /// Lowercased bundle identifiers.
    public var identifiers: Set<String>
    /// Normalized names (`normalized(_:)`) apps go by: display, bundle and executable names.
    public var names: Set<String>

    public init(identifiers: Set<String> = [], names: Set<String> = []) {
        self.identifiers = identifiers
        self.names = names
    }

    /// Spotlight's list of app bundles, the usual app folders (in case Spotlight is off or
    /// excludes them) and running apps.
    public static func discover() -> InstalledApps {
        var paths = Set(spotlightApps())
        let fm = FileManager.default
        let folders = ["/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications",
                       "/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices",
                       "/Library/Application Support"]
        for folder in folders {
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".app") {
                paths.insert(folder + "/" + name)
            }
        }
        var apps = InstalledApps()
        for path in paths {
            apps.add(bundleAt: URL(fileURLWithPath: path))
        }
        return apps
    }

    public mutating func add(identifier: String, names: [String] = []) {
        let id = identifier.lowercased()
        identifiers.insert(id)
        // The vendor too: Application Support/JetBrains belongs to com.jetbrains.*.
        let parts = id.split(separator: ".")
        var names = names
        if parts.count >= 3, parts[1].count >= 4 { names.append(String(parts[1])) }
        for name in names {
            let name = Self.normalized(name)
            if name.count >= 3 { self.names.insert(name) }
        }
    }

    mutating func add(bundleAt url: URL) {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        else {
            // iOS apps on Apple Silicon: a wrapper around the real bundle.
            let wrapper = url.appendingPathComponent("Wrapper")
            if let inner = try? FileManager.default.contentsOfDirectory(atPath: wrapper.path)
                .first(where: { $0.hasSuffix(".app") }),
               let info = NSDictionary(contentsOf: wrapper.appendingPathComponent(inner + "/Info.plist")) as? [String: Any],
               let id = info["CFBundleIdentifier"] as? String {
                add(identifier: id, names: Self.names(in: info) + [url.deletingPathExtension().lastPathComponent])
            }
            return
        }
        guard let id = info["CFBundleIdentifier"] as? String else { return }
        add(identifier: id, names: Self.names(in: info) + [url.deletingPathExtension().lastPathComponent])
    }

    private static func names(in info: [String: Any]) -> [String] {
        ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"].compactMap { info[$0] as? String }
    }

    private static func spotlightApps() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Lowercased letters and digits only: "Visual Studio Code" → "visualstudiocode".
    public static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Installed: the identifier itself, one of its helpers ("com.foo.app.helper"), or the app a
    /// helper belongs to.
    func contains(identifier id: String) -> Bool {
        if identifiers.contains(id) { return true }
        var prefix = id
        while let dot = prefix.lastIndex(of: ".") {
            prefix = String(prefix[..<dot])
            if prefix.split(separator: ".").count < 2 { break }
            if identifiers.contains(prefix) { return true }
        }
        // A helper of the app, or a newer generation of it: "com.microsoft.teams" belongs to
        // "com.microsoft.teams2" (which still uses the old one's group container).
        let dotted = id + "."
        return identifiers.contains {
            $0.hasPrefix(dotted) || ($0.hasPrefix(id) && $0.dropFirst(id.count).allSatisfy(\.isNumber))
        }
    }

    /// Another app by the same vendor ("com.docker") is installed.
    func hasVendor(of id: String) -> Bool {
        let parts = id.split(separator: ".")
        guard parts.count >= 2 else { return false }
        let vendor = parts[0] + "." + parts[1] + "."
        return identifiers.contains { $0.hasPrefix(vendor) }
    }
}

/// Data an uninstalled app left behind, grouped by app.
public struct Leftover: Sendable, Identifiable {
    public enum Confidence: Int, Sendable, Comparable {
        /// Named by an identifier no installed app, nor its vendor, has.
        case likely
        /// Named by an unknown identifier from a vendor that still has an app installed (often
        /// a helper's data), or by a name that matches no installed app. Worth a look.
        case check

        public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
    }

    /// The bundle identifier (lowercased) or folder name the items are named by.
    public var id: String
    /// For showing: the app's folder name if it has one ("LM Studio"), else the identifier's
    /// app part as written ("VideoStudio" for "com.lumen.VideoStudio").
    public var name: String
    public var confidence: Confidence
    public var items: [Int32]
    public var size: Int64

    public init(id: String, name: String? = nil, confidence: Confidence, items: [Int32], size: Int64) {
        self.id = id
        self.name = name ?? id
        self.confidence = confidence
        self.items = items
        self.size = size
    }
}

public enum LeftoverFinder {
    /// Only apps leave data here (command-line tools also write caches, preferences and, through
    /// URLSession, HTTPStorages); an identifier is a likely leftover only with something here.
    private static let appOnlyLocations: Set<String> = [
        "Containers", "Group Containers", "Saved Application State", "WebKit", "Application Scripts",
    ]

    /// Where apps keep their data, relative to a Library folder, and how entries there are named.
    static let locations: [(path: String, naming: Naming)] = [
        ("Application Support", .identifierOrName),
        ("Caches", .identifier),
        ("Containers", .identifier),
        ("Group Containers", .groupIdentifier),
        ("Preferences", .identifier),
        ("Saved Application State", .identifier),
        ("Logs", .identifier),
        ("HTTPStorages", .identifier),
        ("WebKit", .identifier),
        ("Cookies", .identifier),
        ("Application Scripts", .identifier),
        ("LaunchAgents", .identifier),
        ("LaunchDaemons", .identifier),
        ("PrivilegedHelperTools", .identifier),
    ]

    enum Naming {
        case identifier, groupIdentifier, identifierOrName
    }

    /// Folders in Application Support named after macOS itself or shared by many apps.
    private static let systemNames: Set<String> = [
        "addressbook", "animoji", "appstore", "callhistorydb", "callhistorytransactions", "clouddocs",
        "cloudkit", "crashreporter", "diskimages", "dock", "facetime", "fileprovider", "icloud",
        "icdd", "knowledge", "mobilesync", "networkserviceproxy", "syncservices", "coreparsec",
        "accounts", "apple", "audio", "contextstoreagent", "dmd", "familycircle", "homeenergyd",
        "identityservicesd", "locationaccessstored", "quicklook", "replayd", "siri", "spotlight",
        "tipsd", "translation", "videoconference", "virtualization", "metadata", "chromium",
        "microsoft", "google", "mozilla", "adobe", "oracle", "javafx", "sharedfilelist",
        "fontregistry", "com", "org", "net", "io", "cache", "caches", "logs", "temp", "tmp",
        "backup", "backups", "data", "plugins", "plug-ins", "scripts", "documentation", "presets",
        "gamekit", "gamecontroller", "default", "homebrew", "ssh", "keychain", "keychains",
        "ilifemediabrowser", "differentialprivacy", "btserver", "isolatedstorage", "mobiledevice",
        "applepushservice", "bluetooth", "colorsync", "composition", "corescreensaver", "keyboard",
        "printers", "screensavers", "userpictures", "webserver", "mail", "messages", "photos",
    ]

    /// Finds leftovers in the Library folders of `libraries` (absolute paths in `tree`, e.g. the
    /// home folder's and /Library). Largest first.
    public static func find(in tree: FileTree, libraries: [String], installed: InstalledApps) -> [Leftover] {
        var groups: [String: Leftover] = [:]
        var appEvidence = Set<String>()
        for library in libraries {
            for (path, naming) in locations {
                guard let folder = tree.node(atPath: library + "/" + path) else { continue }
                for child in tree.children(of: folder) {
                    let name = tree.name(of: child)
                    guard let (key, display, confidence) = classify(name, naming: naming,
                                                                    isDirectory: tree.nodes[Int(child)].isDirectory,
                                                                    installed: installed)
                    else { continue }
                    if appOnlyLocations.contains(path) { appEvidence.insert(key) }
                    var group = groups[key] ?? Leftover(id: key, name: display, confidence: confidence, items: [], size: 0)
                    group.confidence = min(group.confidence, confidence)
                    group.items.append(child)
                    group.size += tree.nodes[Int(child)].size
                    groups[key] = group
                }
            }
        }
        for (key, group) in groups where group.confidence == .likely && !appEvidence.contains(key) {
            groups[key]?.confidence = .check
        }
        // A folder named like the app joins its identifier's group: "DaisyDisk" with
        // "com.daisydiskapp.daisydiskstandalone".
        for (name, group) in groups where !isIdentifier(name) {
            let normalized = InstalledApps.normalized(name)
            guard let key = groups.keys.filter({ isIdentifier($0) && $0.replacingOccurrences(of: "-", with: "").contains(normalized) })
                .max(by: { groups[$0]!.size < groups[$1]!.size })
            else { continue }
            groups[key]?.name = name
            groups[key]?.items += group.items
            groups[key]?.size += group.size
            groups[name] = nil
        }
        for key in groups.keys {
            groups[key]?.items.sort { tree.nodes[Int($0)].size > tree.nodes[Int($1)].size }
        }
        return groups.values.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }

    /// The app an entry belongs to (as a grouping key), or nil when it belongs to an installed
    /// app, to macOS, or can't be told.
    static func classify(_ name: String, naming: Naming, isDirectory: Bool,
                         installed: InstalledApps) -> (key: String, name: String, Leftover.Confidence)? {
        if name.hasPrefix(".") { return nil }
        var id = name
        for suffix in [".plist", ".savedState", ".binarycookies", ".lockfile"] where id.hasSuffix(suffix) {
            id.removeLast(suffix.count)
        }
        if naming == .groupIdentifier {
            // "TEAMID1234.com.foo.shared" or "group.com.foo.shared"
            let parts = id.split(separator: ".", maxSplits: 1)
            if parts.count == 2, parts[0] == "group" || isTeamIdentifier(parts[0]) { id = String(parts[1]) }
        }
        let lower = id.lowercased()
        if isIdentifier(lower) {
            if isSystem(lower) || installed.contains(identifier: lower) { return nil }
            // Group containers are shared by a vendor's apps, so any of them may still use it.
            if naming == .groupIdentifier && installed.hasVendor(of: lower) { return nil }
            // Group the app's helpers with it: "com.foo.app.helper" under "com.foo.app".
            let key = lower.split(separator: ".").prefix(3).joined(separator: ".")
            if installed.contains(identifier: key) { return nil }
            // Command-line tools name their data like apps do: "org.swift.swiftpm" is the swift
            // tool's, "com.docker.socket" docker's. With a tool named like the vendor installed,
            // it is in use. (Only the vendor: app parts such as "install" or "softwareupdate"
            // would match macOS's own commands.)
            if hasCommandLineTool(named: String(lower.split(separator: ".")[1])) { return nil }
            return (key, displayName(of: id), installed.hasVendor(of: lower) ? .check : .likely)
        }
        // App folders are named like apps ("LM Studio"); tools use lowercase ("gopls").
        guard naming == .identifierOrName, isDirectory, id.first?.isUppercase == true else { return nil }
        let normalized = InstalledApps.normalized(id)
        guard normalized.count >= 3, !systemNames.contains(normalized),
              !installed.names.contains(where: { $0 == normalized || ($0.count >= 4 && normalized.contains($0))
                  || (normalized.count >= 4 && $0.contains(normalized)) }),
              !hasCommandLineTool(named: id)
        else { return nil }
        return (id, id, .check)
    }

    /// Reverse-DNS with at least three parts ("com.foo.app"); two-part names such as "Foo.app"
    /// or "node.js" are too vague.
    static func isIdentifier(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, ["com", "org", "net", "io", "de", "co", "app", "dev", "me", "us", "uk", "fr", "ch",
                                  "at", "nl", "jp", "ru", "cn", "it", "se", "info", "eu", "ai", "tv"].contains(String(parts[0]))
        else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    private static let genericParts: Set<String> = ["mac", "macos", "osx", "app", "desktop", "client", "mas", "macapp", "free", "pro", "lite"]

    /// "com.zenangst.Gray" → "Gray"; when the app part says nothing ("com.raycast.macos",
    /// "com.sublimetext.4"), the vendor: "Raycast", "Sublimetext".
    static func displayName(of id: String) -> String {
        let parts = id.split(separator: ".").map(String.init)
        let app = parts[2]
        let generic = genericParts.contains(app.lowercased()) || app.count < 3
            || app.dropFirst(app.first == "v" ? 1 : 0).allSatisfy(\.isNumber)
        let name = generic ? parts[1] : app
        return name.first!.isLowercase ? name.prefix(1).uppercased() + name.dropFirst() : name
    }

    private static func isSystem(_ id: String) -> Bool {
        // Sparkle's shared helpers serve every app that updates with it.
        id.hasPrefix("com.apple.") || id.hasPrefix("systemgroup.") || id.hasPrefix("group.com.apple.")
            || id.hasPrefix("org.sparkle-project.")
    }

    private static func isTeamIdentifier(_ part: Substring) -> Bool {
        part.count == 10 && part.allSatisfy { ($0.isUppercase && $0.isLetter) || $0.isNumber }
    }

    private static let toolFolders: [String] = {
        let home = NSHomeDirectory()
        var folders = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", home + "/.local/bin", home + "/go/bin",
                       home + "/.cargo/bin", home + "/.bun/bin", home + "/.deno/bin"]
        for folder in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            folders.append(String(folder))
        }
        return folders
    }()

    /// An executable file of that name in one of the tool folders (not a folder named so).
    private static func hasCommandLineTool(named name: String) -> Bool {
        let tool = name.lowercased()
        return toolFolders.contains { folder in
            var isDirectory: ObjCBool = false
            let path = folder + "/" + tool
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
    }
}
