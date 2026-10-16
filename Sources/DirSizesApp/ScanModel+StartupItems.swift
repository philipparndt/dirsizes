import DirScanner
import Foundation

extension ScanModel {
    /// The launch agent, launch daemon and helper tool folders the scan covers.
    var scannedStartupFolders: [String] {
        guard let tree else { return [] }
        return StartupItemFinder.folders.filter { path in
            DataVolume.candidates(for: path).contains { tree.node(atPath: $0) != nil }
        }
    }

    /// Lists launch agents and daemons whose app is gone. Reading the plists, the installed apps
    /// and what launchd has loaded takes a moment, so it runs off the main thread.
    func findStartupItems() {
        guard let tree, !findingStartupItems else { return }
        let folders = scannedStartupFolders
        guard !folders.isEmpty else {
            startupItems = []
            return
        }
        let known = installedApps
        findingStartupItems = true
        Task.detached(priority: .userInitiated) {
            let installed = known ?? InstalledApps.discover()
            let loaded = StartupItemFinder.loadedLabels()
            let found = tree.read {
                StartupItemFinder.find(in: $0, folders: folders, installed: installed, loaded: loaded)
            }
            await MainActor.run {
                self.findingStartupItems = false
                if self.tree === tree { self.startupItems = found }
            }
        }
    }
}
