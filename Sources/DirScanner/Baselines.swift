import Darwin
import Foundation

/// Reference implementations used by the benchmark. They only total up sizes,
/// they do not build a tree, so they are a lower bound for what an app using them would cost.
public enum Baselines {
    public struct Totals: Sendable {
        public var files = 0
        public var bytes: Int64 = 0
    }

    /// `FileManager.enumerator` with prefetched allocated-size keys: the idiomatic Foundation way.
    public static func fileManager(_ path: String) -> Totals {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey]
        var totals = Totals()
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return totals }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isDirectory != true else { continue }
            totals.files += 1
            totals.bytes += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return totals
    }

    /// Classic BSD `fts(3)` walk: readdir + lstat per entry, single-threaded (what `du` does).
    public static func fts(_ path: String) -> Totals {
        var totals = Totals()
        var seenHardLinks = Set<UInt64>()
        let expanded = (path as NSString).expandingTildeInPath
        let cPath = strdup(expanded)
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]

        guard let handle = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return totals }
        defer { fts_close(handle) }

        while let entry = fts_read(handle) {
            switch Int32(entry.pointee.fts_info) {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = entry.pointee.fts_statp?.pointee else { continue }
                if st.st_nlink > 1 && !seenHardLinks.insert(st.st_ino).inserted { continue }
                totals.files += 1
                totals.bytes += Int64(st.st_blocks) * 512
            default:
                continue
            }
        }
        return totals
    }

    /// Shells out to `/usr/bin/du -skx`. Includes directory blocks, so totals differ slightly.
    public static func du(_ path: String) -> Totals {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-skx", (path as NSString).expandingTildeInPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Totals() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let kilobytes = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first.flatMap { Int64($0) } ?? 0
        return Totals(files: -1, bytes: kilobytes * 1024)
    }
}
