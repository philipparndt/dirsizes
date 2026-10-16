import DirScanner
import Foundation

/// What the hidden space of a scanned APFS volume is made of: the other volumes sharing its
/// container (macOS itself, Preboot, Recovery, swap) take space from the same pool, and the
/// rest is in the scanned volume but not in its files (snapshots, unreadable folders).
struct HiddenSpace: Sendable {
    struct Part: Sendable, Identifiable {
        var id: String { name }
        let name: String
        let icon: String
        let bytes: Int64
        let note: String
    }

    /// The container's other volumes, largest first.
    let volumes: [Part]
    /// Local Time Machine snapshots of the startup disk, oldest first.
    let snapshots: [Date]
    /// Swap in use, from the kernel.
    let swapUsed: Int64?

    var volumesTotal: Int64 { volumes.reduce(0) { $0 + $1.bytes } }

    /// Asks diskutil (and tmutil for snapshots of the startup disk). Takes a moment.
    static func load(volumePath: String) -> HiddenSpace? {
        guard let info = plist(["info", "-plist", volumePath]),
              let device = info["DeviceIdentifier"] as? String,
              let container = info["APFSContainerReference"] as? String,
              let list = plist(["apfs", "list", "-plist"]),
              let containers = list["Containers"] as? [[String: Any]],
              let ours = containers.first(where: { $0["ContainerReference"] as? String == container }),
              let volumes = ours["Volumes"] as? [[String: Any]]
        else { return nil }

        let parts = volumes.compactMap { volume -> Part? in
            guard let id = volume["DeviceIdentifier"] as? String, id != device,
                  let bytes = (volume["CapacityInUse"] as? NSNumber)?.int64Value, bytes > 0 else { return nil }
            let name = volume["Name"] as? String ?? id
            switch (volume["Roles"] as? [String])?.first {
            case "System":
                return Part(name: "macOS", icon: "apple.logo", bytes: bytes,
                            note: "The read-only system volume (\(name)).")
            case "VM":
                return Part(name: "Swap and sleep image", icon: "memorychip", bytes: bytes,
                            note: "Memory written to disk when RAM runs short, and the sleep image. Shrinks after restarting.")
            case "Preboot":
                return Part(name: "Startup files", icon: "power", bytes: bytes,
                            note: "Files needed to start up (Preboot), including the parts of macOS kept for each installed version.")
            case "Recovery":
                return Part(name: "Recovery", icon: "cross.case", bytes: bytes, note: "macOS Recovery.")
            case "Update":
                return Part(name: "Software updates", icon: "arrow.down.circle", bytes: bytes,
                            note: "Software updates being prepared.")
            default:
                return Part(name: name, icon: "externaldrive", bytes: bytes, note: "Another volume on the same disk.")
            }
        }

        let isStartup = volumePath == "/" || volumePath == DataVolume.path
        return HiddenSpace(volumes: parts.sorted { $0.bytes > $1.bytes },
                           snapshots: isStartup ? localSnapshots() : [],
                           swapUsed: isStartup ? swapUsage() : nil)
    }

    private static func plist(_ arguments: [String]) -> [String: Any]? {
        guard let data = run("/usr/sbin/diskutil", arguments) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// From `tmutil listlocalsnapshotdates /`: "2026-10-15-223943" per line.
    private static func localSnapshots() -> [Date] {
        guard let data = run("/usr/bin/tmutil", ["listlocalsnapshotdates", "/"]) else { return [] }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd-HHmmss"
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .compactMap { format.date(from: String($0)) }
            .sorted()
    }

    private static func swapUsage() -> Int64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Int64(usage.xsu_used)
    }

    /// Deletes the startup disk's local Time Machine snapshots, after asking for an administrator
    /// password. Returns an error message, or nil when done.
    static func deleteLocalSnapshots() async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"/usr/bin/tmutil deletelocalsnapshots /\" with administrator privileges"]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            do { try process.run() } catch { return error.localizedDescription }
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            if process.terminationStatus == 0 { return nil }
            return message.contains("-128") ? "Cancelled." : message.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
