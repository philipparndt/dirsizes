import DirScanner
import Foundation

let usage = """
    usage:
      dirsizes scan  <path> [--threads N] [--top N] [--cross-devices]
      dirsizes bench <path> [--runs N] [--skip fm,fts,du]
      dirsizes mcp

    scan   Scan <path> with the parallel getattrlistbulk scanner and print the largest entries.
    bench  Compare the scanner (1 thread and N threads) against FileManager, fts and du.
           Runs are warm-cache; run `sudo purge` first for a cold-cache number.
    mcp    MCP server on stdio for AI clients, forwarding to the DirSizes app (started if needed).
           Lets the AI scan, explore and fill the collector; it cannot delete anything.
    """

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func seconds(_ duration: Duration) -> Double {
    let c = duration.components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
}

func time<T>(_ body: () -> T) -> (T, Double) {
    let clock = ContinuousClock()
    var result: T!
    let elapsed = clock.measure { result = body() }
    return (result, seconds(elapsed))
}

struct Options {
    var command = ""
    var path = ""
    var threads = ProcessInfo.processInfo.activeProcessorCount
    var top = 20
    var runs = 1
    var skip: Set<String> = []
    var crossDevices = false
}

func parseOptions() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    var options = Options()
    func value(_ flag: String) -> String {
        guard !args.isEmpty else { fail("\(flag) needs a value") }
        return args.removeFirst()
    }
    var positional: [String] = []
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--threads": options.threads = Int(value(arg)) ?? options.threads
        case "--top": options.top = Int(value(arg)) ?? options.top
        case "--runs": options.runs = max(1, Int(value(arg)) ?? 1)
        case "--skip": options.skip = Set(value(arg).split(separator: ",").map(String.init))
        case "--cross-devices": options.crossDevices = true
        case "-h", "--help": print(usage); exit(0)
        default: positional.append(arg)
        }
    }
    guard positional.count == 2 else { fail(usage) }
    options.command = positional[0]
    options.path = positional[1]
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - scan

func runScan(_ options: Options) {
    let scanner = DiskScanner(path: options.path, threads: options.threads, stayOnDevice: !options.crossDevices)

    // Only create the timer when it will run: releasing a never-resumed dispatch source traps.
    let interactive = isatty(STDERR_FILENO) != 0
    let progress = interactive ? DispatchSource.makeTimerSource(queue: .global()) : nil
    if let progress {
        progress.schedule(deadline: .now() + 0.2, repeating: 0.2)
        progress.setEventHandler {
            let files = scanner.filesScanned.load(ordering: .relaxed)
            let bytes = scanner.bytesScanned.load(ordering: .relaxed)
            FileHandle.standardError.write(Data("\r\u{1B}[K  \(files) files, \(formatBytes(bytes))".utf8))
        }
        progress.resume()
    }

    let result = scanner.scan()
    if let progress {
        progress.cancel()
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    }

    let tree = result.tree
    print("\(tree.name(of: 0))  \(formatBytes(result.totalBytes))")
    print(String(format: "%d files, %d directories, %d errors in %.2fs (%d threads)\n",
                 result.files, result.directories, result.errors, seconds(result.duration), options.threads))
    for child in tree.children(of: 0).prefix(options.top) {
        let node = tree.nodes[Int(child)]
        let marker = node.isDirectory ? "/" : ""
        let items = node.isDirectory ? Int(node.itemCount) : 1
        print(formatBytes(node.size).leftPad(10) + String(items).leftPad(11) + "  " + tree.name(of: child) + marker)
    }
}

// MARK: - bench

func runBench(_ options: Options) {
    let path = options.path
    let cores = ProcessInfo.processInfo.activeProcessorCount

    var methods: [(name: String, run: () -> (files: Int, bytes: Int64))] = [
        ("getattrlistbulk, 1 thread", {
            let r = DiskScanner(path: path, threads: 1).scan(); return (r.files, r.totalBytes)
        }),
        ("getattrlistbulk, \(cores) threads", {
            let r = DiskScanner(path: path, threads: cores).scan(); return (r.files, r.totalBytes)
        }),
        ("getattrlistbulk, \(cores * 2) threads", {
            let r = DiskScanner(path: path, threads: cores * 2).scan(); return (r.files, r.totalBytes)
        }),
    ]
    if !options.skip.contains("fts") {
        methods.append(("fts (readdir + lstat)", { let t = Baselines.fts(path); return (t.files, t.bytes) }))
    }
    if !options.skip.contains("fm") {
        methods.append(("FileManager.enumerator", { let t = Baselines.fileManager(path); return (t.files, t.bytes) }))
    }
    if !options.skip.contains("du") {
        methods.append(("du -skx", { let t = Baselines.du(path); return (t.files, t.bytes) }))
    }

    FileHandle.standardError.write(Data("warming up cache...\n".utf8))
    _ = DiskScanner(path: path).scan()

    var rows: [(name: String, time: Double, files: Int, bytes: Int64)] = []
    for method in methods {
        FileHandle.standardError.write(Data("running \(method.name)...\n".utf8))
        var times: [Double] = []
        var last = (files: 0, bytes: Int64(0))
        for _ in 0..<options.runs {
            let (result, elapsed) = time(method.run)
            times.append(elapsed)
            last = result
        }
        rows.append((method.name, times.sorted()[times.count / 2], last.files, last.bytes))
    }

    let baseline = rows.first { $0.name.hasPrefix("FileManager") }?.time ?? rows[0].time
    print("\nPath: \((path as NSString).expandingTildeInPath)   (median of \(options.runs) warm run(s))\n")
    print("method                           time      files        size    vs FileManager")
    print(String(repeating: "-", count: 82))
    for row in rows {
        let files = row.files < 0 ? "-" : String(row.files)
        print(row.name.padding(toLength: 30, withPad: " ", startingAt: 0)
              + String(format: "%8.2fs", row.time)
              + files.leftPad(11)
              + formatBytes(row.bytes).leftPad(12)
              + String(format: "%14.1fx", baseline / row.time))
    }
}

extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? " " + self : String(repeating: " ", count: width - count) + self
    }
}

if CommandLine.arguments.dropFirst().first == "mcp" { runMCPBridge() }

let options = parseOptions()
switch options.command {
case "scan": runScan(options)
case "bench": runBench(options)
default: fail(usage)
}
