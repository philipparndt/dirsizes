import Foundation

/// A mounted disk as shown on the start screen.
struct VolumeInfo: Identifiable, Equatable {
    enum Kind {
        case internalDisk
        case externalDisk
        case network
    }

    var id: URL { url }
    let url: URL
    let name: String
    let format: String
    let kind: Kind
    let totalBytes: Int64
    /// Free space as Finder reports it (includes purgeable space macOS can reclaim).
    let availableBytes: Int64
    /// What to scan: the startup disk's data volume instead of the read-only system volume,
    /// because the scanner stays on one volume and `/Users` etc. live on the data volume.
    let scanPath: String

    var usedBytes: Int64 { max(totalBytes - availableBytes, 0) }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    static func mounted() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                          options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0
            else { return nil }

            // "Important usage" includes purgeable space (what Finder shows on APFS), but some file
            // systems (e.g. Mac OS Extended disk images) report 0 for it, so take the larger value.
            let available = max(values.volumeAvailableCapacityForImportantUsage ?? 0,
                                Int64(values.volumeAvailableCapacity ?? 0))
            let kind: Kind = values.volumeIsLocal == false ? .network
                : values.volumeIsInternal == true ? .internalDisk : .externalDisk
            let dataVolume = "/System/Volumes/Data"
            let scanPath = url.path == "/" && FileManager.default.fileExists(atPath: dataVolume + "/Users")
                ? dataVolume : url.path

            return VolumeInfo(url: url, name: values.volumeName ?? url.lastPathComponent,
                              format: values.volumeLocalizedFormatDescription ?? "",
                              kind: kind, totalBytes: Int64(total), availableBytes: available,
                              scanPath: scanPath)
        }
        // Startup disk first, then the rest by name.
        .sorted { ($0.url.path == "/" ? 0 : 1, $0.name) < ($1.url.path == "/" ? 0 : 1, $1.name) }
    }
}
