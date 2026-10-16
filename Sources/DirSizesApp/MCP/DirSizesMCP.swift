import AppKit
import DirScanner
import Observation

/// The app's MCP server: lets an AI scan, look through the results and fill the collector.
/// There is deliberately no tool that deletes; that stays a button the user presses.
@MainActor
@Observable
final class DirSizesMCP {
    /// Set once the server listens; shown in the setup popover.
    private(set) var port: UInt16?
    private(set) var startError: String?

    @ObservationIgnored private let model: ScanModel
    @ObservationIgnored private let server: MCPServer

    /// The startup disk is scanned at its data volume; paths below it are reported and accepted
    /// without this prefix, the way Finder and the shell see them.

    init(model: ScanModel) {
        self.model = model
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        server = MCPServer(name: "dirsizes", version: version, instructions: """
            DirSizes is a disk usage analyzer running on the user's Mac. Scan a folder or disk, \
            then explore what takes up space with list, largest and search. Sizes are allocated \
            bytes on disk. To suggest a cleanup, add items to the collector with collect: they \
            appear in the app's Collector panel, where the user reviews them and decides whether \
            to move them to the Trash. You cannot delete anything yourself.
            """)
        registerTools()
    }

    func start() {
        Task {
            do {
                let port = try await server.start()
                self.port = port
                let pid = ProcessInfo.processInfo.processIdentifier
                try MCPEndpoint(port: port, token: server.token, pid: pid).write()
                NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                       object: nil, queue: .main) { _ in
                    MCPEndpoint.remove(ifOwnedBy: pid)
                }
            } catch {
                startError = error.localizedDescription
                FileHandle.standardError.write(Data("MCP server failed to start: \(error)\n".utf8))
            }
        }
    }

    /// The command that registers this app with Claude Code. Uses the short `dirsizes` when
    /// Homebrew linked it to this very bundle, otherwise the full path to the bundled CLI.
    var setupCommand: String {
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/dirsizes")
        let linked = ["/opt/homebrew/bin/dirsizes", "/usr/local/bin/dirsizes"].contains {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == cli.resolvingSymlinksInPath().path
        }
        let program = linked ? "dirsizes" : "'\(cli.path)'"
        return "claude mcp add --scope user dirsizes -- \(program) mcp"
    }

    // MARK: - Tools

    private func registerTools() {
        tool("status", "Current state: what was scanned, totals, scan progress and the collector.",
             properties: [:]) { [unowned self] _ in
            json(status())
        }

        tool("list_disks", "Mounted disks with capacity, used and free space. Pass a disk's path to scan.",
             properties: [:]) { [unowned self] _ in
            model.loadVolumes()
            return json(["disks": model.volumes.map { volume -> [String: Any] in
                ["name": volume.name, "path": volume.url.path, "format": volume.format,
                 "kind": "\(volume.kind)", "total": sizeInfo(volume.totalBytes),
                 "used": sizeInfo(volume.usedBytes), "free": sizeInfo(volume.availableBytes)]
            }])
        }

        tool("scan", """
            Scans a folder or a whole disk (pass its path from list_disks, e.g. "/") and shows it \
            in the app, replacing the current scan and clearing the collector. Scanning the same \
            place again only reads folders that changed since, so it is quick. Waits for the scan \
            to finish up to wait_seconds; call status to check on a scan that is still running.
            """, readOnly: false,
             properties: [
                "path": ["type": "string", "description": "Folder or disk to scan. ~ is expanded."],
                "wait_seconds": ["type": "number", "description": "How long to wait for the result (default 120)."],
             ], required: ["path"]) { [unowned self] args in
            let path = ((args["path"] as? String ?? "") as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw MCPServer.ToolError("Not a folder: \(path)")
            }
            model.open(path: path)
            let deadline = Date().addingTimeInterval(number(args["wait_seconds"]) ?? 120)
            while model.phase == .scanning || model.asksForFullDiskAccess, Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            if model.asksForFullDiskAccess {
                throw MCPServer.ToolError("DirSizes is asking the user for Full Disk Access; the scan "
                    + "starts once they answer in the app. Call status to check on it.")
            }
            return json(status())
        }

        tool("list", "Contents of a folder from the scan, largest first.",
             properties: [
                "path": ["type": "string", "description": "Folder, absolute or relative to the scanned root (default: the root)."],
                "limit": ["type": "integer", "description": "Maximum entries (default 50)."],
             ]) { [unowned self] args in
            let (tree, node) = try resolve(args["path"])
            let limit = int(args["limit"]) ?? 50
            let children = tree.children(of: node)
            let parentSize = max(tree.nodes[Int(node)].size, 1)
            return json([
                "folder": entry(node, in: tree),
                "entries": children.prefix(limit).map { child -> [String: Any] in
                    var info = entry(child, in: tree)
                    info["share_of_folder"] = decimal(Double(tree.nodes[Int(child)].size) / Double(parentSize), digits: 3)
                    return info
                },
                "more_entries": max(children.count - limit, 0),
            ])
        }

        tool("largest", "The largest files (or folders) anywhere below a folder.",
             properties: [
                "path": ["type": "string", "description": "Folder to search in (default: the scanned root)."],
                "kind": ["type": "string", "enum": ["files", "folders"], "description": "Default: files."],
                "limit": ["type": "integer", "description": "Maximum results (default 25)."],
             ]) { [unowned self] args in
            let (tree, node) = try resolve(args["path"])
            let wantFolders = (args["kind"] as? String) == "folders"
            let mask = tree.subtreeMask(of: node)
            var matches: [Int32] = []
            for i in 0..<tree.nodes.count where mask[i] && i != Int(node) {
                if tree.nodes[i].isDirectory == wantFolders { matches.append(Int32(i)) }
            }
            return json(["results": top(matches, int(args["limit"]) ?? 25, in: tree).map { entry($0, in: tree) }])
        }

        tool("search", """
            Finds files and folders by name below a folder, largest first. A query with * or ? is a \
            glob (e.g. "*.dmg"), otherwise a case-insensitive substring. By default a match inside \
            another match is skipped, so "node_modules" lists each project's folder once.
            """,
             properties: [
                "query": ["type": "string"],
                "path": ["type": "string", "description": "Folder to search in (default: the scanned root)."],
                "limit": ["type": "integer", "description": "Maximum results (default 50)."],
                "include_nested": ["type": "boolean", "description": "Also list matches inside other matches."],
             ], required: ["query"]) { [unowned self] args in
            let (tree, node) = try resolve(args["path"])
            let query = (args["query"] as? String ?? "").lowercased()
            guard !query.isEmpty else { throw MCPServer.ToolError("query is empty") }
            let isGlob = query.contains("*") || query.contains("?")
            let nested = args["include_nested"] as? Bool ?? false
            let mask = tree.subtreeMask(of: node)
            // Forward pass: parents come before children, so "inside a match" is known in time.
            var insideMatch = [Bool](repeating: false, count: tree.nodes.count)
            var matches: [Int32] = []
            for i in 0..<tree.nodes.count where mask[i] && i != Int(node) {
                let parent = Int(tree.nodes[i].parent)
                let covered = insideMatch[parent]
                let name = tree.name(of: Int32(i)).lowercased()
                let hit = isGlob ? fnmatch(query, name, 0) == 0 : name.contains(query)
                if hit && (nested || !covered) { matches.append(Int32(i)) }
                insideMatch[i] = covered || hit
            }
            let total = matches.reduce(Int64(0)) { $0 + (nested ? 0 : tree.nodes[Int($1)].size) }
            var result: [String: Any] = [
                "matches": matches.count,
                "results": top(matches, int(args["limit"]) ?? 50, in: tree).map { entry($0, in: tree) },
            ]
            if !nested { result["total"] = sizeInfo(total) }
            return json(result)
        }

        tool("leftovers", """
            Data left behind by apps that are no longer installed (caches, preferences, containers, \
            saved state, launch agents in ~/Library and /Library), grouped by app, largest first. \
            Needs a scan that covers the home folder or the startup disk. Confidence "likely": \
            named after an app that isn't installed, with data only apps write. "check": may \
            still belong to something installed (an app by the same vendor, a command-line tool); \
            tell the user rather than collecting these without asking. Pass items to collect.
            """,
             properties: [
                "include_check": ["type": "boolean", "description": "Also list \"check\" entries (default true)."],
                "limit": ["type": "integer", "description": "Maximum groups (default 50)."],
             ]) { [unowned self] args in
            let tree = try requireTree()
            guard !model.scannedLibraries.isEmpty else {
                throw MCPServer.ToolError("The scan covers no Library folder. Scan the home folder (~) or the startup disk (/) first.")
            }
            model.findLeftovers()
            while model.findingLeftovers {
                try await Task.sleep(for: .milliseconds(100))
            }
            let includeCheck = args["include_check"] as? Bool ?? true
            let groups = (model.leftovers ?? []).filter { includeCheck || $0.confidence == .likely }
            let limit = int(args["limit"]) ?? 50
            return json([
                "groups": groups.prefix(limit).map { group -> [String: Any] in
                    [
                        "app": group.name,
                        "identifier": group.id,
                        "confidence": group.confidence == .likely ? "likely" : "check",
                        "size": sizeInfo(group.size),
                        "items": group.items.map { entry($0, in: tree) },
                    ]
                },
                "more_groups": max(groups.count - limit, 0),
                "total_size": sizeInfo(groups.reduce(0) { $0 + $1.size }),
            ])
        }

        tool("collector", "Items in the collector, which the user can move to the Trash from the app.",
             properties: [:]) { [unowned self] _ in
            json(collectorInfo())
        }

        tool("collect", """
            Adds files or folders from the scan to the collector, for the user to review and delete \
            in the app. Adding a folder replaces items already collected inside it.
            """, readOnly: false,
             properties: [
                "paths": ["type": "array", "items": ["type": "string"],
                          "description": "Absolute, or relative to the scanned root."],
             ], required: ["paths"]) { [unowned self] args in
            let tree = try requireTree()
            var skipped: [[String: String]] = []
            for path in args["paths"] as? [String] ?? [] {
                guard let node = node(at: path, in: tree) else {
                    skipped.append(["path": path, "reason": "not in the scan"]); continue
                }
                if node == 0 {
                    skipped.append(["path": path, "reason": "the scanned root can't be collected"])
                } else if model.isCollected(node) {
                    skipped.append(["path": path, "reason": "already collected"])
                } else {
                    model.collect(node)
                }
            }
            var result = collectorInfo()
            if !skipped.isEmpty { result["skipped"] = skipped }
            return json(result)
        }

        tool("uncollect", "Removes items from the collector (nothing is deleted).", readOnly: false,
             properties: [
                "paths": ["type": "array", "items": ["type": "string"]],
             ], required: ["paths"]) { [unowned self] args in
            let tree = try requireTree()
            for path in args["paths"] as? [String] ?? [] {
                if let node = node(at: path, in: tree) { model.uncollect(node) }
            }
            return json(collectorInfo())
        }

        tool("clear_collector", "Empties the collector (nothing is deleted).", readOnly: false,
             properties: [:]) { [unowned self] _ in
            model.clearCollector()
            return json(collectorInfo())
        }
    }

    private func tool(_ name: String, _ description: String, readOnly: Bool = true,
                      properties: [String: Any], required: [String] = [],
                      handler: @escaping @MainActor ([String: Any]) async throws -> String) {
        server.register(MCPServer.Tool(
            name: name, description: description,
            inputSchema: ["type": "object", "properties": properties, "required": required],
            readOnly: readOnly, handler: handler))
    }

    // MARK: - Results

    private func status() -> [String: Any] {
        var info: [String: Any] = [:]
        switch model.phase {
        case .idle: info["state"] = "idle"
        case .scanning: info["state"] = "scanning"
        case .done: info["state"] = "done"
        }
        guard let rootPath = model.rootPath else {
            info["hint"] = "Nothing scanned yet. Use scan, or list_disks to pick a disk."
            return info
        }
        info["root"] = display(rootPath)
        if let volume = model.scannedVolume { info["disk"] = volume.name }
        switch model.phase {
        case .scanning:
            info["files_so_far"] = model.filesScanned
            info["scanned_so_far"] = sizeInfo(model.bytesScanned)
            if let progress = model.progress { info["progress"] = decimal(progress, digits: 2) }
        case .done:
            info["files"] = model.filesScanned
            info["size"] = sizeInfo(model.tree?.root.size ?? 0)
            let seconds = Double(model.duration.components.seconds)
                + Double(model.duration.components.attoseconds) / 1e18
            info["scan_seconds"] = decimal(seconds, digits: 1)
            // Scans after the first only read folders that changed since.
            info["scan_kind"] = model.changedFolders.map { "incremental (\($0) changed folders read again)" } ?? "full"
            if model.errors > 0 {
                info["unreadable_folders"] = model.errors
                info["unreadable_hint"] = "Grant DirSizes Full Disk Access to scan protected folders."
            }
            for (special, bytes) in model.extras {
                switch special {
                case .free: info["free_space"] = sizeInfo(bytes)
                case .hidden: info["hidden_space"] = sizeInfo(bytes)
                case .iCloud(let key): info["icloud_" + key] = ["label": model.label(of: special), "size": sizeInfo(bytes)]
                case .photosInCloud: info["icloud_photos_not_on_this_mac"] = sizeInfo(bytes)
                }
            }
            info["collector"] = ["items": model.collected.count, "size": sizeInfo(model.collectedBytes)]
            let gone = model.goneSummary
            if gone.count > 0 {
                info["deleted_elsewhere"] = ["items": gone.count, "size": sizeInfo(gone.bytes),
                                             "hint": "Deleted by another app since the scan; scan again to update totals."]
            }
            if let deletion = model.deletion {
                info["deleting"] = ["done": deletion.done, "total": deletion.total]
            }
        case .idle:
            break
        }
        return info
    }

    private func collectorInfo() -> [String: Any] {
        guard let tree = model.tree else { return ["items": []] }
        return ["items": model.collected.map { entry($0, in: tree) }, "total": sizeInfo(model.collectedBytes)]
    }

    private func entry(_ node: Int32, in tree: FileTree) -> [String: Any] {
        let item = tree.nodes[Int(node)]
        var info: [String: Any] = [
            "path": display(tree.path(of: node)),
            "kind": item.isDirectory ? "folder" : item.kind == .symlink ? "symlink"
                : item.kind == .cloudFile ? "file only in iCloud" : "file",
            "size": sizeInfo(item.size),
        ]
        if item.isDirectory { info["files"] = Int(item.itemCount) }
        if model.isCollected(node) { info["collected"] = true }
        if model.isGone(node) { info["deleted_elsewhere"] = true }
        return info
    }

    private func sizeInfo(_ bytes: Int64) -> [String: Any] {
        ["bytes": bytes, "text": formatBytes(bytes)]
    }

    /// A Double serializes with float noise (0.34999999999999998); a decimal number doesn't.
    private func decimal(_ value: Double, digits: Int) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(digits)f", value), locale: Locale(identifier: "en_US_POSIX"))
    }

    private func top(_ nodes: [Int32], _ limit: Int, in tree: FileTree) -> [Int32] {
        Array(nodes.sorted { tree.nodes[Int($0)].size > tree.nodes[Int($1)].size }.prefix(limit))
    }

    private func json(_ object: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: - Paths

    private func requireTree() throws -> FileTree {
        if let tree = model.tree { return tree }
        throw MCPServer.ToolError(model.phase == .scanning
            ? "A scan is still running; check status and try again when it is done."
            : "Nothing scanned yet. Use scan first.")
    }

    private func resolve(_ argument: Any?) throws -> (FileTree, Int32) {
        let tree = try requireTree()
        guard let path = argument as? String, !path.isEmpty else { return (tree, 0) }
        guard let node = node(at: path, in: tree) else {
            throw MCPServer.ToolError("Not in the scan: \(path) (scanned root: \(display(tree.path(of: 0))))")
        }
        return (tree, node)
    }

    /// Accepts absolute paths, paths relative to the root, and startup-disk paths without the
    /// data volume prefix.
    private func node(at path: String, in tree: FileTree) -> Int32? {
        let root = tree.path(of: 0)
        var path = (path as NSString).expandingTildeInPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if !path.hasPrefix("/") { path = (root as NSString).appendingPathComponent(path) }
        if let node = tree.node(atPath: path) { return node }
        if root.hasPrefix(DataVolume.path), let data = DataVolume.dataPath(for: path), data != path {
            return tree.node(atPath: data)
        }
        return nil
    }

    private func display(_ path: String) -> String {
        DataVolume.displayPath(path)
    }

    private func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue.clamped(to: 1...1000) }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
