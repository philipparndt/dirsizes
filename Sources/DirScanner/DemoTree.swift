/// A made-up home folder for screenshots and demos. Nothing is read from disk, and the same
/// tree comes out every time so screenshots are reproducible.
extension FileTree {
    public static func demo(rootName: String = "/Users/demo") -> FileTree {
        let tree = FileTree(rootName: rootName)
        var random = SeededRandom(seed: 42)
        for entry in demoHome {
            tree.add(entry, parent: 0, random: &random)
        }
        tree.finalize()
        return tree
    }

    private func add(_ entry: DemoEntry, parent: Int32, random: inout SeededRandom) {
        switch entry {
        case let .file(name, size):
            append(name: name, parent: parent, size: size, kind: .file)
        case let .dir(name, children):
            let index = append(name: name, parent: parent, size: 0, kind: .directory)
            for child in children { add(child, parent: index, random: &random) }
        case let .filler(name, size, depth):
            addFiller(name: name, size: size, depth: depth, parent: parent, random: &random)
        }
    }

    /// A folder of `size` bytes split unevenly over subfolders and files, `depth` levels deep,
    /// so the outer rings of the chart have something in them.
    private func addFiller(name: String, size: Int64, depth: Int, parent: Int32,
                           random: inout SeededRandom) {
        let index = append(name: name, parent: parent, size: 0, kind: .directory)
        var remaining = size
        let count = depth > 0 ? 3 + random.next(4) : 4 + random.next(8)
        for i in 0..<count {
            let share = i == count - 1 ? remaining : Int64(Double(remaining) * (0.25 + Double(random.next(40)) / 100))
            remaining -= share
            if depth > 0 && i < count - 1 {
                addFiller(name: Self.folderNames[random.next(Self.folderNames.count)] + (i > 0 ? "-\(i)" : ""),
                          size: share, depth: depth - 1, parent: index, random: &random)
            } else {
                let ext = Self.fileExtensions[random.next(Self.fileExtensions.count)]
                append(name: "file-\(i + 1).\(ext)", parent: index, size: max(share, 4096), kind: .file)
            }
        }
    }

    @discardableResult
    private func append(name: String, parent: Int32, size: Int64, kind: Node.Kind) -> Int32 {
        let bytes = Array(name.utf8)
        let offset = UInt32(names.count)
        names.append(contentsOf: bytes)
        nodes.append(Node(size: size, parent: parent, nameOffset: offset, itemCount: 0,
                          nameLength: UInt16(clamping: bytes.count), kind: kind))
        return Int32(nodes.count - 1)
    }

    private static let folderNames = ["src", "assets", "data", "cache", "lib", "build", "media", "archive"]
    private static let fileExtensions = ["bin", "json", "png", "mov", "zip", "db", "log", "pak"]
}

private indirect enum DemoEntry {
    case dir(String, [DemoEntry])
    case file(String, Int64)
    case filler(String, Int64, depth: Int)
}

private let MB: Int64 = 1_000_000
private let GB: Int64 = 1_000_000_000

private let demoHome: [DemoEntry] = [
    .dir("Library", [
        .dir("Developer", [
            .dir("Xcode", [
                .filler("DerivedData", 38 * GB, depth: 3),
                .filler("iOS DeviceSupport", 14 * GB, depth: 2),
                .filler("Archives", 3 * GB, depth: 2),
            ]),
            .filler("CoreSimulator", 21 * GB, depth: 3),
        ]),
        .dir("Caches", [
            .filler("com.apple.dt.Xcode", 6 * GB, depth: 2),
            .filler("Homebrew", 4 * GB, depth: 2),
            .filler("pip", 2 * GB, depth: 2),
            .filler("Google", 3 * GB, depth: 2),
            // Left behind by uninstalled apps, for the cleanup view.
            .filler("com.lumen.VideoStudio", 3 * GB, depth: 2),
        ]),
        .dir("Containers", [
            .filler("com.apple.mail", 13 * GB, depth: 3),
            .filler("net.brightpixel.PhotoLab", 4 * GB, depth: 2),
        ]),
        .dir("Application Support", [
            .filler("Code", 7 * GB, depth: 3),
            .filler("MobileSync", 4 * GB, depth: 2),
            .filler("VideoStudio", 1400 * MB, depth: 2),
            .filler("io.syncbox.agent", 600 * MB, depth: 1),
            .filler("Retroverse", 300 * MB, depth: 1),
        ]),
        .dir("Saved Application State", [
            .dir("com.lumen.VideoStudio.savedState", [.file("windows.plist", 40_000)]),
        ]),
        .dir("Preferences", [
            .file("com.apple.finder.plist", 30_000),
            .file("com.lumen.VideoStudio.plist", 12_000),
            .file("net.brightpixel.PhotoLab.plist", 8_000),
            .file("io.syncbox.agent.plist", 4_096),
        ]),
        .filler("Mail", 5 * GB, depth: 2),
    ]),
    .dir("dev", [
        .dir("web-shop", [
            .filler("node_modules", 2 * GB, depth: 3),
            .filler(".next", 900 * MB, depth: 2),
            .filler("src", 120 * MB, depth: 2),
        ]),
        .dir("ml-experiments", [
            .filler("checkpoints", 26 * GB, depth: 2),
            .filler("datasets", 18 * GB, depth: 2),
            .filler(".venv", 3 * GB, depth: 3),
        ]),
        .dir("game-engine", [
            .filler("target", 9 * GB, depth: 3),
            .filler("assets", 7 * GB, depth: 2),
        ]),
        .dir("mobile-app", [
            .filler(".build", 4 * GB, depth: 3),
            .filler("Pods", 2 * GB, depth: 2),
        ]),
    ]),
    .dir("Movies", [
        .filler("Final Cut Projects", 48 * GB, depth: 2),
        .file("conference-talk.mov", 9 * GB),
        .file("holiday-2025.mp4", 6 * GB),
    ]),
    .dir("Pictures", [
        .filler("Photos Library.photoslibrary", 41 * GB, depth: 3),
        .filler("Screenshots", 2 * GB, depth: 1),
    ]),
    .dir("Downloads", [
        .file("ubuntu-24.04-desktop-arm64.iso", 3 * GB),
        .file("Xcode_27.xip", 12 * GB),
        .filler("old-installers", 5 * GB, depth: 1),
    ]),
    .filler("Documents", 11 * GB, depth: 3),
    .filler("Music", 8 * GB, depth: 2),
    .filler(".docker", 15 * GB, depth: 2),
]

/// Small deterministic generator (SplitMix64); the system one can't be seeded.
private struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(_ upperBound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Int(z % UInt64(upperBound))
    }
}

extension InstalledApps {
    /// The apps "installed" alongside the demo home folder.
    public static let demo: InstalledApps = {
        var apps = InstalledApps()
        apps.add(identifier: "com.microsoft.VSCode", names: ["Code", "Visual Studio Code"])
        apps.add(identifier: "io.syncbox.desktop", names: ["Syncbox"])
        return apps
    }()
}
