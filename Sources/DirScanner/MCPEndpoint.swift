import Darwin
import Foundation

/// How to reach the running app's MCP server. The app writes it on launch and removes it on
/// quit; `dirsizes mcp` reads it, so MCP clients need no port or token in their config.
public struct MCPEndpoint: Codable, Sendable {
    public let port: UInt16
    public let token: String
    public let pid: Int32

    public init(port: UInt16, token: String, pid: Int32) {
        self.port = port
        self.token = token
        self.pid = pid
    }

    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("de.rnd7.dirsizes/mcp.json")
    }

    /// The endpoint of a running app, or nil when the app isn't running (or crashed and left
    /// a stale file behind).
    public static func read() -> MCPEndpoint? {
        guard let data = try? Data(contentsOf: fileURL),
              let endpoint = try? JSONDecoder().decode(MCPEndpoint.self, from: data),
              kill(endpoint.pid, 0) == 0 || errno == EPERM
        else { return nil }
        return endpoint
    }

    /// Readable by the owner only: the token is what keeps other local users out.
    public func write() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func remove(ifOwnedBy pid: Int32) {
        guard let data = try? Data(contentsOf: fileURL),
              let endpoint = try? JSONDecoder().decode(MCPEndpoint.self, from: data),
              endpoint.pid == pid
        else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
