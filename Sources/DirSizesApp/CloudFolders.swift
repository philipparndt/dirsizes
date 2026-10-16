import AppKit
import DirScanner

/// Where a cloud service keeps its files on this Mac: iCloud Drive, or a File Provider app
/// (Dropbox, OneDrive, Google Drive, …) under ~/Library/CloudStorage. Scanning one shows what it
/// takes up locally; files only in the cloud take no space and are never downloaded.
struct CloudFolder: Identifiable {
    let name: String
    let path: String
    let isICloud: Bool
    var id: String { path }

    static let iCloudPath = NSHomeDirectory() + "/Library/Mobile Documents"
    private static let cloudStoragePath = NSHomeDirectory() + "/Library/CloudStorage"

    static func available() -> [CloudFolder] {
        var folders: [CloudFolder] = []
        let files = FileManager.default
        if files.fileExists(atPath: iCloudPath) {
            folders.append(CloudFolder(name: "iCloud Drive", path: iCloudPath, isICloud: true))
        }
        let providers = (try? files.contentsOfDirectory(atPath: cloudStoragePath)) ?? []
        for name in providers.sorted() where !name.hasPrefix(".") {
            let path = cloudStoragePath + "/" + name
            folders.append(CloudFolder(name: files.displayName(atPath: path), path: path, isICloud: false))
        }
        return folders
    }

    /// System Settings at iCloud, whose Manage… button shows the storage of Photos, Mail, Backups,
    /// Family Sharing and each app. Deeper links (to that list) open the Apple Account page instead.
    static func openICloudSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud") {
            NSWorkspace.shared.open(url)
        }
    }

    /// "iCloud Drive" for the iCloud folder, and the app's name for its containers in there
    /// ("1Password" rather than "2BUA8C4S2C~com~agilebits~onepassword-ios"). Nil for other paths.
    static func displayName(ofPath path: String) -> String? {
        let path = DataVolume.displayPath(path)
        if path == iCloudPath { return "iCloud Drive" }
        guard (path as NSString).deletingLastPathComponent == iCloudPath else { return nil }
        return FileManager.default.displayName(atPath: path)
    }
}
