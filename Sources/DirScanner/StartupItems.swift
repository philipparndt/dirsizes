import Foundation

/// A launch agent or daemon (or a privileged helper tool) that may have been left behind by an
/// app that's gone.
public struct StartupItem: Sendable, Identifiable {
    public enum Kind: Sendable {
        /// ~/Library/LaunchAgents: starts when you log in.
        case userAgent
        /// /Library/LaunchAgents: starts when anyone logs in.
        case agent
        /// /Library/LaunchDaemons: starts with the Mac.
        case daemon
        /// /Library/PrivilegedHelperTools, with no daemon starting it.
        case helperTool
    }

    public enum Status: Int, Sendable, Comparable {
        /// What it starts doesn't exist anymore (or its app isn't installed): likely left behind.
        case missing
        /// It exists, but outside any installed app, or whose it is can't be told. Worth a look.
        case check

        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    /// The plist's (or helper tool's) path on disk.
    public var id: String { path }
    public let path: String
    public let label: String
    /// The app's name when known, else a name made from the label.
    public let name: String
    public let kind: Kind
    /// The executable it starts, when known.
    public let program: String?
    public let status: Status
    /// Why it is listed, for showing.
    public let reason: String
    /// launchd has it loaded right now.
    public let isLoaded: Bool
    /// The plist's node, then the helper tool it starts, if that is in /Library/PrivilegedHelperTools.
    public let items: [Int32]
    public let size: Int64
}

public enum StartupItemFinder {
    /// Where launchd's jobs and the helper tools they start are, as users know the paths.
    public static var folders: [String] {
        [NSHomeDirectory() + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons",
         helperTools]
    }

    static let helperTools = "/Library/PrivilegedHelperTools"

    /// Runs a command given as arguments; the script or app it runs is in those.
    private static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "env", "python", "python3", "perl", "ruby", "osascript", "open", "node", "launchctl",
    ]

    /// Commands installed by package managers or macOS itself, not by apps.
    private static let toolPrefixes = [
        "/opt/homebrew/", "/usr/local/", "/opt/local/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/",
        "/sbin/", "/System/", "/nix/",
    ]

    /// The jobs in those of `folders` the scan covers (`tree` finds each plist's node), apart from
    /// Apple's and those whose program belongs to an installed app. `loaded` are the labels
    /// launchd has loaded (`loadedLabels()`). Left behind first, then by name.
    public static func find(in tree: FileTree, folders: [String], installed: InstalledApps,
                            loaded: Set<String>) -> [StartupItem] {
        let files = FileManager.default
        func node(_ path: String) -> Int32? {
            DataVolume.candidates(for: path).lazy.compactMap { tree.node(atPath: $0) }.first
        }

        // Helper tools, to pair them with the daemons that start them.
        var helpers: [String: Int32] = [:]
        if folders.contains(helperTools) {
            for name in (try? files.contentsOfDirectory(atPath: helperTools)) ?? [] where !name.hasPrefix(".") {
                let path = helperTools + "/" + name
                if let node = node(path) { helpers[path] = node }
            }
        }
        var startedHelpers = Set<String>()
        var items: [StartupItem] = []

        for folder in folders where folder != helperTools {
            let kind: StartupItem.Kind = folder == "/Library/LaunchDaemons" ? .daemon
                : folder == "/Library/LaunchAgents" ? .agent : .userAgent
            for name in (try? files.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".plist") {
                let path = folder + "/" + name
                guard let plistNode = node(path),
                      let data = files.contents(atPath: path),
                      let job = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                else { continue }
                let label = (job["Label"] as? String) ?? String(name.dropLast(".plist".count))
                guard !label.lowercased().hasPrefix("com.apple.") else { continue }

                let arguments = (job["ProgramArguments"] as? [String]) ?? []
                let program = (job["Program"] as? String) ?? arguments.first
                let associated = (job["AssociatedBundleIdentifiers"] as? [String])
                    ?? (job["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
                let target = program.flatMap { executable(program: $0, arguments: arguments) }
                if let target { startedHelpers.insert(target) }

                guard let (status, reason, appName) = classify(label: label, target: target, program: program,
                                                                bundleProgram: job["BundleProgram"] as? String,
                                                                associated: associated, installed: installed)
                else { continue }
                var nodes = [plistNode]
                if let target, let helper = helpers[target] { nodes.append(helper) }
                items.append(StartupItem(path: path, label: label, name: appName ?? displayName(of: label), kind: kind,
                                         program: target ?? program, status: status, reason: reason,
                                         isLoaded: loaded.contains(label), items: nodes,
                                         size: nodes.reduce(0) { $0 + tree.nodes[Int($1)].size }))
            }
        }

        // Helper tools no daemon starts anymore do nothing; their app usually left them behind.
        for (path, helper) in helpers where !startedHelpers.contains(path) {
            let label = (path as NSString).lastPathComponent
            let id = label.lowercased()
            guard !id.hasPrefix("com.apple."), !installed.contains(identifier: id) else { continue }
            items.append(StartupItem(path: path, label: label, name: displayName(of: label), kind: .helperTool,
                                     program: path, status: installed.hasVendor(of: id) ? .check : .missing,
                                     reason: "No launch daemon starts this helper tool anymore",
                                     isLoaded: loaded.contains(label), items: [helper],
                                     size: tree.nodes[Int(helper)].size))
        }
        return items.sorted { ($0.status, $0.name.lowercased()) < ($1.status, $1.name.lowercased()) }
    }

    /// The file a job runs: its program, or for a shell or interpreter, the first absolute path
    /// among its arguments that isn't macOS's own. Nil when it can't be told.
    static func executable(program: String, arguments: [String]) -> String? {
        let command = (program as NSString).lastPathComponent
        guard interpreters.contains(command) || !program.hasPrefix("/") else { return program }
        let words = arguments.dropFirst().flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        return words.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"';&|()")) }
            .first { $0.hasPrefix("/") && !$0.hasPrefix("/dev/") && !$0.hasPrefix("/tmp/")
                && !["/bin/", "/usr/bin/", "/usr/sbin/", "/sbin/"].contains(where: $0.hasPrefix) }
    }

    /// Whether a job is listed (nil when it belongs to something installed), why, and its app's
    /// name if known.
    private static func classify(label: String, target: String?, program: String?, bundleProgram: String?,
                                 associated: [String], installed: InstalledApps)
        -> (StartupItem.Status, String, String?)? {
        let ids = ([label] + associated).map { $0.lowercased() }
        let owned = ids.contains { installed.contains(identifier: $0) }
        let vendor = ids.contains { LeftoverFinder.isIdentifier($0) && installed.hasVendor(of: $0) }

        guard let target else {
            if program == nil, let bundleProgram {
                // Runs a program inside the app named by AssociatedBundleIdentifiers.
                if owned { return nil }
                return (.missing, "Runs \(bundleProgram) inside an app that isn't installed", nil)
            }
            if program == nil {
                // Uninstallers sometimes empty the plist instead of deleting it.
                return (.missing, "Starts nothing: the plist names no program", nil)
            }
            if owned || vendor { return nil }
            return (.check, "Runs a script; can't tell which app it belongs to", nil)
        }
        guard FileManager.default.fileExists(atPath: target) else {
            return (.missing, "\(target) doesn't exist anymore", nil)
        }
        if let range = target.range(of: ".app/") {
            let app = String(target[..<range.lowerBound]) + ".app"
            let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") as? [String: Any]
            let name = (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            guard let id = (info?["CFBundleIdentifier"] as? String)?.lowercased() else {
                return (.check, "Inside \(name), which isn't a complete app", name)
            }
            if installed.contains(identifier: id) || owned { return nil }
            return (.check, "Inside \(name), which isn't among your installed apps", name)
        }
        if owned || vendor || toolPrefixes.contains(where: target.hasPrefix) { return nil }
        return (.check, "No installed app could be found for it", nil)
    }

    /// "com.valvesoftware.steamclean" → "Steamclean"; other labels as they are.
    private static func displayName(of label: String) -> String {
        LeftoverFinder.isIdentifier(label.lowercased()) ? LeftoverFinder.displayName(of: label) : label
    }

    /// The labels launchd has loaded, in your login session and the system's.
    public static func loadedLabels() -> Set<String> {
        var labels = Set<String>()
        for domain in ["gui/\(getuid())", "system"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", domain]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // "services = {" lists one job per line: PID, last exit status, label.
            var inServices = false
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "services = {" {
                    inServices = true
                } else if inServices {
                    if trimmed == "}" { break }
                    if let label = trimmed.split(whereSeparator: \.isWhitespace).last { labels.insert(String(label)) }
                }
            }
        }
        return labels
    }
}
