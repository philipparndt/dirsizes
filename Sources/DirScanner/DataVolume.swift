import Foundation

/// The startup disk's writable data volume. Some folders of the read-only system volume are
/// "firmlinks" into it (/Users, /Applications, /Library, /private, …), so /Users/x is
/// /System/Volumes/Data/Users/x; other paths, such as /System/Library, are not on it.
public enum DataVolume {
    public static let path = "/System/Volumes/Data"

    /// From /usr/share/firmlinks, which lists them for the running macOS.
    private static let firmlinks: [String] = {
        let list = (try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)) ?? ""
        let paths = list.split(separator: "\n").compactMap { $0.split(separator: "\t").first.map(String.init) }
        return paths.isEmpty ? ["/Applications", "/Library", "/Users", "/Volumes", "/opt", "/private", "/usr/local"] : paths
    }()

    /// Where a startup-disk path is on the data volume, or nil when it isn't there.
    public static func dataPath(for path: String) -> String? {
        if path == Self.path || path.hasPrefix(Self.path + "/") { return path }
        guard firmlinks.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return nil }
        return Self.path + path
    }

    /// `path` itself, and its data-volume path when that differs: the ways it can appear in a
    /// scan.
    public static func candidates(for path: String) -> [String] {
        guard let data = dataPath(for: path), data != path else { return [path] }
        return [path, data]
    }

    /// The path as users know it: /Users/x rather than /System/Volumes/Data/Users/x.
    public static func displayPath(_ path: String) -> String {
        guard path.hasPrefix(Self.path) else { return path }
        let rest = path.dropFirst(Self.path.count)
        return rest.isEmpty ? "/" : String(rest)
    }
}
