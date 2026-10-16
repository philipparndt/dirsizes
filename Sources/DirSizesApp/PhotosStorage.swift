import Photos
import SwiftUI

/// Estimates what the Photos library stores in iCloud Photos: the sizes of all originals and
/// edits, also those not downloaded to this Mac. Apps can't ask iCloud for the real number,
/// so this is the closest available.
@MainActor
@Observable
final class PhotosStorage {
    struct Kind {
        var count = 0
        var bytes: Int64 = 0
    }

    struct Summary {
        var photos = Kind()
        var videos = Kind()
        var other = Kind()
        var total: Int64 { photos.bytes + videos.bytes + other.bytes }
        var count: Int { photos.count + videos.count + other.count }
    }

    enum State {
        case idle
        case denied
        case counting(done: Int, total: Int)
        case done(Summary)
    }

    private(set) var state = State.idle

    var isCounting: Bool {
        if case .counting = state { return true }
        return false
    }

    func count() {
        guard !isCounting else { return }
        state = .counting(done: 0, total: 0)
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else {
                state = .denied
                return
            }
            let summary = await Task.detached(priority: .userInitiated) {
                Self.summarize { done, total in
                    Task { @MainActor in
                        if self.isCounting { self.state = .counting(done: done, total: total) }
                    }
                }
            }.value
            state = .done(summary)
        }
    }

    /// The library iCloud Photos syncs with: the one in ~/Pictures with iCloud's sync folder,
    /// else the one used last. Apps can't ask Photos which library is the system library.
    nonisolated static func systemLibraryPath() -> String? {
        let pictures = NSHomeDirectory() + "/Pictures"
        let files = FileManager.default
        let libraries = ((try? files.contentsOfDirectory(atPath: pictures)) ?? [])
            .filter { $0.hasSuffix(".photoslibrary") }
            .map { pictures + "/" + $0 }
        func lastUsed(_ path: String) -> Date {
            let database = path + "/database/Photos.sqlite"
            return ((try? files.attributesOfItem(atPath: database))?[.modificationDate] as? Date) ?? .distantPast
        }
        let synced = libraries.filter { files.fileExists(atPath: $0 + "/resources/cpl") }
        return (synced.isEmpty ? libraries : synced).max { lastUsed($0) < lastUsed($1) }
    }

    /// Adds up every resource (original, edited version, Live Photo video, …) of every asset.
    private nonisolated static func summarize(progress: @escaping @Sendable (Int, Int) -> Void) -> Summary {
        let assets = PHAsset.fetchAssets(with: nil)
        let total = assets.count
        var summary = Summary()
        var done = 0
        assets.enumerateObjects { asset, _, _ in
            // `fileSize` isn't public API; it's what Photos itself reports. 0 if it ever goes away.
            let bytes = PHAssetResource.assetResources(for: asset).reduce(Int64(0)) { sum, resource in
                sum + ((resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0)
            }
            switch asset.mediaType {
            case .image:
                summary.photos.count += 1
                summary.photos.bytes += bytes
            case .video:
                summary.videos.count += 1
                summary.videos.bytes += bytes
            default:
                summary.other.count += 1
                summary.other.bytes += bytes
            }
            done += 1
            if done % 500 == 0 { progress(done, total) }
        }
        return summary
    }
}

/// Start screen card for the Photos estimate.
struct PhotosCard: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        let photos = model.photos
        HStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Photos Library")
                    .font(.headline)
                Group {
                    switch photos.state {
                    case .idle:
                        Text("Estimate what iCloud Photos stores, including photos not on this Mac")
                    case .denied:
                        Text("No access to Photos. Allow it in System Settings → Privacy & Security → Photos.")
                    case .counting(let done, let total):
                        Text(total > 0 ? "Adding up \(done.formatted()) of \(total.formatted())…" : "Adding up…")
                    case .done(let summary):
                        Text("About \(formatBytes(summary.total)) in iCloud Photos · "
                             + "\(summary.photos.count.formatted()) photos (\(formatBytes(summary.photos.bytes))), "
                             + "\(summary.videos.count.formatted()) videos (\(formatBytes(summary.videos.bytes)))")
                            .help("Originals and edits of everything in the library. iCloud may store slightly "
                                  + "more or less; Shared Albums don't count toward your storage.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            if photos.isCounting {
                ProgressView().controlSize(.small)
            } else {
                Button(isDone ? "Count Again" : "Count") { photos.count() }
                    .controlSize(.large)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    private var isDone: Bool {
        if case .done = model.photos.state { return true }
        return false
    }
}
