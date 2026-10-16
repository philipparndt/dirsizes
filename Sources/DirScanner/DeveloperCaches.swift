import Foundation

/// Caches and build output of developer tools in the home folder, and build output and installed
/// packages inside projects.
public enum DeveloperCacheFinder {
    private struct Location {
        let tool: String
        let title: String
        /// Relative to the home folder.
        let path: String
        let effect: Suggestion.Effect
        let note: String
        /// Offer what's inside one by one (OS versions, simulators) rather than the folder.
        var perItem = false
    }

    private static let xcode = "Xcode"
    private static let javaScript = "JavaScript"
    private static let python = "Python"
    private static let java = "Java and Android"
    private static let other = "Other tools"
    private static let order = [xcode, "Swift", javaScript, python, "Rust", "Go", java, "Ruby, PHP and Dart", other]

    private static let locations: [Location] = [
        Location(tool: xcode, title: "DerivedData", path: "Library/Developer/Xcode/DerivedData", effect: .rebuilt,
                 note: "Build products and indexes of your projects. Xcode builds them again; the next build takes longer.",
                 perItem: true),
        Location(tool: xcode, title: "iOS device support", path: "Library/Developer/Xcode/iOS DeviceSupport",
                 effect: .redownloaded, note: "Symbols copied from your devices, per OS version. Copied again when a device with that version is connected.",
                 perItem: true),
        Location(tool: xcode, title: "watchOS device support", path: "Library/Developer/Xcode/watchOS DeviceSupport",
                 effect: .redownloaded, note: "Symbols copied from your watches, per OS version. Copied again when needed.",
                 perItem: true),
        Location(tool: xcode, title: "tvOS device support", path: "Library/Developer/Xcode/tvOS DeviceSupport",
                 effect: .redownloaded, note: "Symbols copied from your Apple TVs, per OS version. Copied again when needed.",
                 perItem: true),
        Location(tool: xcode, title: "visionOS device support", path: "Library/Developer/Xcode/visionOS DeviceSupport",
                 effect: .redownloaded, note: "Symbols copied from your Vision Pro, per OS version. Copied again when needed.",
                 perItem: true),
        Location(tool: xcode, title: "Archives", path: "Library/Developer/Xcode/Archives", effect: .lost,
                 note: "Builds you archived for distribution. Keep the ones of versions you still need crash reports for: they hold the symbols.",
                 perItem: true),
        Location(tool: xcode, title: "Simulators", path: "Library/Developer/CoreSimulator/Devices", effect: .lost,
                 note: "Simulated devices with the apps installed on them and their data. Quit Simulator first; Xcode creates simulators again when you pick one to run on.",
                 perItem: true),
        Location(tool: xcode, title: "Simulator caches", path: "Library/Developer/CoreSimulator/Caches", effect: .rebuilt,
                 note: "Caches of the simulators, made again when they start."),
        Location(tool: xcode, title: "SwiftUI previews", path: "Library/Developer/Xcode/UserData/Previews", effect: .rebuilt,
                 note: "Builds and simulators for SwiftUI previews, made again when a preview is shown."),
        Location(tool: xcode, title: "Xcode cache", path: "Library/Caches/com.apple.dt.Xcode", effect: .rebuilt,
                 note: "Xcode's own cache."),
        Location(tool: "Swift", title: "Swift packages", path: "Library/Caches/org.swift.swiftpm", effect: .redownloaded,
                 note: "Downloaded package sources, fetched again by the next build that needs them."),
        Location(tool: other, title: "Homebrew downloads", path: "Library/Caches/Homebrew", effect: .redownloaded,
                 note: "Downloaded bottles and casks. `brew cleanup` removes the outdated ones; installed software isn't affected."),
        Location(tool: xcode, title: "CocoaPods", path: "Library/Caches/CocoaPods", effect: .redownloaded,
                 note: "Downloaded pods, fetched again by `pod install`."),
        Location(tool: xcode, title: "Carthage", path: "Library/Caches/org.carthage.CarthageKit", effect: .redownloaded,
                 note: "Downloaded dependencies, fetched again by Carthage."),
        Location(tool: javaScript, title: "npm cache", path: ".npm/_cacache", effect: .redownloaded,
                 note: "Downloaded packages, fetched again by `npm install`."),
        Location(tool: javaScript, title: "Yarn cache", path: "Library/Caches/Yarn", effect: .redownloaded,
                 note: "Downloaded packages, fetched again by `yarn install`."),
        Location(tool: javaScript, title: "pnpm store", path: "Library/pnpm/store", effect: .redownloaded,
                 note: "Packages your projects link to. Installed projects keep working; `pnpm install` fetches them again."),
        Location(tool: javaScript, title: "pnpm cache", path: "Library/Caches/pnpm", effect: .redownloaded,
                 note: "Package metadata, fetched again when needed."),
        Location(tool: javaScript, title: "Bun cache", path: ".bun/install/cache", effect: .redownloaded,
                 note: "Downloaded packages, fetched again by `bun install`."),
        Location(tool: javaScript, title: "Deno cache", path: "Library/Caches/deno", effect: .redownloaded,
                 note: "Downloaded modules, fetched again when needed."),
        Location(tool: javaScript, title: "node-gyp headers", path: "Library/Caches/node-gyp", effect: .redownloaded,
                 note: "Node.js headers for building native modules, fetched again when needed."),
        Location(tool: javaScript, title: "Playwright browsers", path: "Library/Caches/ms-playwright", effect: .redownloaded,
                 note: "Browsers for testing, installed again by `npx playwright install`."),
        Location(tool: javaScript, title: "Puppeteer browsers", path: ".cache/puppeteer", effect: .redownloaded,
                 note: "Browsers for testing, downloaded again when needed."),
        Location(tool: javaScript, title: "Electron downloads", path: "Library/Caches/electron", effect: .redownloaded,
                 note: "Electron builds, downloaded again when needed."),
        Location(tool: python, title: "pip cache", path: "Library/Caches/pip", effect: .redownloaded,
                 note: "Downloaded packages, fetched again by `pip install`."),
        Location(tool: python, title: "uv cache", path: ".cache/uv", effect: .redownloaded,
                 note: "Downloaded packages, fetched again by uv. `uv cache prune` removes only unused ones."),
        Location(tool: python, title: "Poetry cache", path: "Library/Caches/pypoetry", effect: .redownloaded,
                 note: "Downloaded packages and virtual environments Poetry made, made again by `poetry install`."),
        Location(tool: python, title: "Conda packages", path: ".conda/pkgs", effect: .redownloaded,
                 note: "Downloaded packages. `conda clean --all` removes the ones no environment uses."),
        Location(tool: python, title: "Hugging Face models", path: ".cache/huggingface", effect: .redownloaded,
                 note: "Downloaded models and datasets, downloaded again when a program loads them."),
        Location(tool: "Rust", title: "Cargo registry", path: ".cargo/registry", effect: .redownloaded,
                 note: "Downloaded crates and their sources, fetched again by the next build."),
        Location(tool: "Rust", title: "Cargo git checkouts", path: ".cargo/git", effect: .redownloaded,
                 note: "Dependencies from git, fetched again by the next build."),
        Location(tool: "Go", title: "Go modules", path: "go/pkg/mod", effect: .redownloaded,
                 note: "Downloaded modules, fetched again by the next build. `go clean -modcache` does the same."),
        Location(tool: "Go", title: "Go build cache", path: "Library/Caches/go-build", effect: .rebuilt,
                 note: "Compiled packages, compiled again by the next build."),
        Location(tool: java, title: "Gradle caches", path: ".gradle/caches", effect: .redownloaded,
                 note: "Downloaded dependencies and build caches, fetched again by the next build."),
        Location(tool: java, title: "Gradle distributions", path: ".gradle/wrapper/dists", effect: .redownloaded,
                 note: "Gradle versions your projects' wrappers downloaded, downloaded again when a project needs one.",
                 perItem: true),
        Location(tool: java, title: "Maven repository", path: ".m2/repository", effect: .redownloaded,
                 note: "Downloaded dependencies, fetched again by the next build. Also holds what you installed with `mvn install`; that is lost."),
        Location(tool: java, title: "JetBrains caches", path: "Library/Caches/JetBrains", effect: .rebuilt,
                 note: "Indexes and caches of JetBrains IDEs, per version: old versions' folders are left over after updates.",
                 perItem: true),
        Location(tool: java, title: "Android emulators", path: ".android/avd", effect: .lost,
                 note: "Emulated devices with their data. Android Studio's Device Manager creates them again."),
        Location(tool: java, title: "Android cache", path: ".android/cache", effect: .redownloaded,
                 note: "Downloaded SDK metadata, fetched again when needed."),
        Location(tool: "Ruby, PHP and Dart", title: "Dart and Flutter packages", path: ".pub-cache", effect: .redownloaded,
                 note: "Downloaded packages, fetched again by `pub get`."),
        Location(tool: "Ruby, PHP and Dart", title: "Composer cache", path: "Library/Caches/composer", effect: .redownloaded,
                 note: "Downloaded packages, fetched again by `composer install`."),
        Location(tool: "Ruby, PHP and Dart", title: "Bundler cache", path: "Library/Caches/rubygems", effect: .redownloaded,
                 note: "Downloaded gems, fetched again when needed."),
        Location(tool: other, title: "VS Code caches", path: "Library/Application Support/Code/Cache", effect: .rebuilt,
                 note: "VS Code's web cache, made again when it runs."),
        Location(tool: other, title: "VS Code compiled code", path: "Library/Application Support/Code/CachedData", effect: .rebuilt,
                 note: "Compiled code per VS Code version; old versions' folders are left over after updates.", perItem: true),
        Location(tool: other, title: "VS Code extension downloads", path: "Library/Application Support/Code/CachedExtensionVSIXs",
                 effect: .redownloaded, note: "Extension packages kept after installing them."),
        Location(tool: other, title: "Docker disk", path: "Library/Containers/com.docker.docker/Data/vms", effect: .lost,
                 note: "All Docker images, containers and volumes. `docker system prune` frees what isn't used and keeps the rest; removing this resets Docker."),
    ]

    /// What a project folder holds that its tools make again, by folder name, with the files next
    /// to it that say which tool made it.
    private static let outputs: [String: (markers: [String], effect: Suggestion.Effect)] = [
        "node_modules": (["package.json"], .redownloaded),
        "target": (["Cargo.toml", "pom.xml"], .rebuilt),
        ".build": (["Package.swift"], .rebuilt),
        "build": (["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "pubspec.yaml"], .rebuilt),
        ".gradle": (["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], .rebuilt),
        "Pods": (["Podfile"], .redownloaded),
        ".next": (["package.json"], .rebuilt),
        ".nuxt": (["package.json"], .rebuilt),
        ".dart_tool": (["pubspec.yaml"], .rebuilt),
        ".venv": ([], .redownloaded),
        "venv": ([], .redownloaded),
        "DerivedData": ([], .rebuilt),
    ]

    private static let packages: Set<String> = ["app", "framework", "bundle", "photoslibrary", "xcodeproj",
                                                 "xcworkspace", "xcassets", "lproj"]

    /// Folders not to look for projects in.
    private static let skipped: Set<String> = ["Library", "Applications", ".Trash", "Pictures", "Music", "Movies"]

    /// Sections by tool, then "Projects": build output per project, untouched projects first.
    /// `home` is the home folder's path in `tree`; projects are looked for below `projects`
    /// (the home folder, or the scanned folder inside it).
    public static func find(in tree: FileTree, home: String?, projects: Int32?) -> [SuggestionSection] {
        var byTool: [String: [Suggestion]] = [:]
        if let home {
            for location in locations {
                guard let node = tree.node(atPath: home + "/" + location.path), tree.nodes[Int(node)].size > 0
                else { continue }
                var items = [node]
                var labels: [Int32: String] = [:]
                if location.perItem {
                    items = tree.children(of: node).filter { !tree.name(of: $0).hasPrefix(".") }
                    if location.path.hasSuffix("CoreSimulator/Devices") {
                        for item in items { labels[item] = simulatorName(at: tree.path(of: item)) }
                        items = items.filter { labels[$0] != nil }
                    }
                }
                guard !items.isEmpty else { continue }
                byTool[location.tool, default: []].append(
                    Suggestion(id: location.path, title: location.title, effect: location.effect, note: location.note,
                               items: items, itemLabels: labels, tree: tree))
            }
        }
        var sections = order.compactMap { tool in
            byTool[tool].map { SuggestionSection(title: tool, suggestions: $0.sorted { $0.size > $1.size }) }
        }
        if let projects {
            let found = findProjects(in: tree, below: projects, home: home)
            if !found.isEmpty {
                sections.append(SuggestionSection(title: "Projects", byAge: true, suggestions: found))
            }
        }
        return sections
    }

    /// "iPhone 15 Pro · iOS 17.2", from the simulator's device.plist.
    private static func simulatorName(at path: String) -> String? {
        guard let info = NSDictionary(contentsOfFile: path + "/device.plist") as? [String: Any],
              let name = info["name"] as? String else { return nil }
        guard let runtime = (info["runtime"] as? String)?.split(separator: ".").last else { return name }
        // "iOS-17-2" → "iOS 17.2"
        let parts = runtime.split(separator: "-")
        return name + " · " + parts[0] + (parts.count > 1 ? " " + parts.dropFirst().joined(separator: ".") : "")
    }

    /// Project folders with build output or installed packages, those changed longest ago first.
    private static func findProjects(in tree: FileTree, below start: Int32, home: String?) -> [Suggestion] {
        var found: [(project: Int32, outputs: [Int32], effect: Suggestion.Effect)] = []
        var stack = [start]
        while let folder = stack.popLast() {
            let children = tree.liveChildren(of: folder).filter { tree.nodes[Int($0)].isDirectory }
            let candidates = children.filter { outputs[tree.name(of: $0)] != nil }
            var matched = Set<Int32>()
            if !candidates.isEmpty {
                let names = Set(tree.liveChildren(of: folder).map { tree.name(of: $0) })
                var effects: [Suggestion.Effect] = []
                for child in candidates {
                    let name = tree.name(of: child)
                    let (markers, effect) = outputs[name]!
                    let isOutput: Bool
                    switch name {
                    case ".venv", "venv":
                        isOutput = tree.liveChildren(of: child).contains { tree.name(of: $0) == "pyvenv.cfg" }
                    case "DerivedData":
                        // Xcode projects set to keep build output next to the project.
                        isOutput = names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
                    default:
                        isOutput = markers.contains(where: names.contains)
                    }
                    if isOutput, tree.nodes[Int(child)].size > 0 {
                        matched.insert(child)
                        effects.append(effect)
                    }
                }
                if !matched.isEmpty {
                    found.append((folder, Array(matched), effects.contains(.redownloaded) ? .redownloaded : .rebuilt))
                }
            }
            for child in children where !matched.contains(child) {
                let name = tree.name(of: child)
                // Hidden folders, app bundles and packages' own folders hold no projects of yours.
                if name.hasPrefix(".") || packages.contains((name as NSString).pathExtension) { continue }
                if folder == start && skipped.contains(name) { continue }
                if name == "node_modules" { continue }
                stack.append(child)
            }
        }

        let homePrefix = home.map { DataVolume.displayPath($0) }
        return found.map { project, nodes, effect in
            let path = tree.path(of: project)
            var shown = DataVolume.displayPath((path as NSString).deletingLastPathComponent)
            if let homePrefix, shown == homePrefix || shown.hasPrefix(homePrefix + "/") {
                shown = "~" + shown.dropFirst(homePrefix.count)
            }
            let names = nodes.map { tree.name(of: $0) }
            return Suggestion(id: path, title: tree.name(of: project), subtitle: shown, effect: effect,
                              note: "Build output and installed packages (\(names.sorted().joined(separator: ", "))). "
                                  + "Building the project or installing its packages makes them again.",
                              items: nodes, date: SuggestionDates.lastChange(of: path, except: Set(names)), tree: tree)
        }
        .filter { $0.size >= 1_000_000 }
        .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }
}
