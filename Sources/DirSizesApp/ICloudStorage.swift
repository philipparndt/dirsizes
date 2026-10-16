import AppKit
import SwiftUI
import WebKit

/// What the iCloud account stores, as System Settings shows it: by category (Photos, Backups,
/// Mail, Messages, Documents, …) and by family member. Apps can't read this from macOS, so it
/// comes from iCloud.com: the user signs in on Apple's own page in a window (the password never
/// passes through DirSizes), and the storage numbers are fetched from inside that page.
/// The endpoint is the one iCloud.com uses; it isn't documented and may change.
@MainActor
@Observable
final class ICloudStorage: NSObject {
    struct Usage: Decodable {
        struct Media: Decodable, Identifiable {
            let mediaKey: String
            let displayLabel: String
            let displayColor: String?
            let usageInBytes: Int64
            var id: String { mediaKey }
        }

        struct Totals: Decodable {
            let usedStorageInBytes: Int64
            let totalStorageInBytes: Int64
        }

        struct Family: Decodable {
            struct Member: Decodable {
                let firstName: String?
                let lastName: String?
                let fullName: String?
                let usageInBytes: Int64

                var name: String {
                    fullName ?? [firstName, lastName].compactMap { $0 }.joined(separator: " ")
                }
            }

            let storageUsageByMember: [Member]?
        }

        let storageUsageByMedia: [Media]
        let storageUsageInfo: Totals
        let familyStorageUsageInfo: Family?
    }

    enum State {
        case signedOut
        case loading
        case signingIn
        case loaded(Usage, account: String?, date: Date)
        case failed(String)
    }

    private(set) var state = State.signedOut

    var isBusy: Bool {
        switch state {
        case .loading, .signingIn: true
        default: false
        }
    }

    private static let signedInKey = "iCloudStorageSignedIn"
    private static let home = URL(string: "https://www.icloud.com/")!
    /// iCloud.com tells unknown browsers to use a supported one. Added to WebKit's own user agent
    /// (rather than replacing it), so it matches what the page can detect about the browser.
    private static let browserName = "Version/26.0 Safari/605.1.15"

    private var webView: WKWebView?
    private var window: NSWindow?
    private var pageLoaded: CheckedContinuation<Void, Never>?
    private var pollTask: Task<Void, Never>?

    /// Whether the user signed in before, so the numbers can be loaded without asking.
    var wasSignedIn: Bool { UserDefaults.standard.bool(forKey: Self.signedInKey) }

    /// Loads the numbers with the saved session; asks to sign in only when `interactive`.
    func refresh(interactive: Bool) {
        guard !isBusy else { return }
        state = .loading
        Task {
            await loadPage()
            switch await fetch() {
            case .success(let usage, let account):
                show(usage, account: account)
            case .signedOut:
                if interactive { signIn() } else { state = .signedOut }
            case .error(let message):
                state = .failed(message)
            }
        }
    }

    /// Shows iCloud.com's sign-in in a window and checks every few seconds whether it's done.
    func signIn() {
        let webView = webView ?? makeWebView()
        state = .signingIn
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Sign In to iCloud"
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.delegate = self
            window.center()
            self.window = window
        }
        if webView.url == nil { webView.load(URLRequest(url: Self.home)) }
        window?.makeKeyAndOrderFront(nil)

        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, window != nil else { return }
                if case .success(let usage, let account) = await fetch() {
                    show(usage, account: account)
                    closeWindow()
                    return
                }
            }
        }
    }

    /// Forgets the session: removes iCloud.com's and Apple's cookies and site data.
    func signOut() {
        UserDefaults.standard.set(false, forKey: Self.signedInKey)
        closeWindow()
        webView = nil
        state = .signedOut
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let apple = records.filter { $0.displayName.contains("icloud") || $0.displayName.contains("apple") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: apple) {}
        }
    }

    private func show(_ usage: Usage, account: String?) {
        UserDefaults.standard.set(true, forKey: Self.signedInKey)
        state = .loaded(usage, account: account, date: Date())
    }

    private func closeWindow() {
        pollTask?.cancel()
        pollTask = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }

    // MARK: - Fetching

    private enum Result {
        case success(Usage, account: String?)
        case signedOut
        case error(String)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = Self.browserName
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 720), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Safari → Develop → this Mac shows the page, for when signing in fails.
        webView.isInspectable = true
        self.webView = webView
        return webView
    }

    /// The requests must come from an iCloud.com page to carry its session.
    private func loadPage() async {
        let webView = webView ?? makeWebView()
        guard webView.url?.host?.hasSuffix("icloud.com") != true else { return }
        await withCheckedContinuation { continuation in
            pageLoaded = continuation
            webView.load(URLRequest(url: Self.home))
        }
    }

    /// Runs in the page: `validate` says whether the session is signed in and gives the account
    /// ID, which `storageUsageInfo` needs.
    private static let script = """
        const params = "clientBuildNumber=2522Project44&clientMasteringNumber=2522B30&clientId=" + crypto.randomUUID();
        const post = async (url) => {
            const response = await fetch(url, { method: "POST", credentials: "include" });
            let body = null;
            try { body = await response.json(); } catch (e) {}
            return { status: response.status, body };
        };
        const validate = await post("https://setup.icloud.com/setup/ws/1/validate?" + params);
        const info = validate.body && validate.body.dsInfo;
        if (!info) { return JSON.stringify({ signedIn: false, status: validate.status }); }
        const storage = await post("https://setup.icloud.com/setup/ws/1/storageUsageInfo?" + params + "&dsid=" + info.dsid);
        return JSON.stringify({ signedIn: true, status: storage.status, account: info.fullName || info.appleId || null,
                                storage: storage.body });
        """

    private struct Response: Decodable {
        let signedIn: Bool
        let status: Int
        let account: String?
    }

    private struct StorageResponse: Decodable {
        let storage: Usage
    }

    private func fetch() async -> Result {
        guard let webView else { return .error("No iCloud.com page") }
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(Self.script, contentWorld: .page)
        } catch {
            return .error("iCloud.com didn't answer: \(error.localizedDescription)")
        }
        guard let json = (value as? String)?.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: json) else {
            return .error("Unexpected answer from iCloud.com")
        }
        guard response.signedIn else { return .signedOut }
        guard let storage = try? JSONDecoder().decode(StorageResponse.self, from: json) else {
            return .error("iCloud.com didn't send the storage numbers (status \(response.status))")
        }
        return .success(storage.storage, account: response.account)
    }
}

extension ICloudStorage: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { resumePageLoaded() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { resumePageLoaded() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: any Error) {
        MainActor.assumeIsolated { resumePageLoaded() }
    }

    private func resumePageLoaded() {
        pageLoaded?.resume()
        pageLoaded = nil
    }
}

extension ICloudStorage: WKUIDelegate {
    /// Apple's sign-in may open a window; it's shown in the same view.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

extension ICloudStorage: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            pollTask?.cancel()
            pollTask = nil
            window = nil
            if case .signingIn = state { state = .signedOut }
        }
    }
}

extension ICloudStorage {
    /// iCloud sends colors as hex ("ffcc00"); a gray stands in when one is missing.
    nonisolated static func color(_ media: Usage.Media) -> Color {
        guard let hex = media.displayColor.flatMap({ UInt32($0.trimmingCharacters(in: ["#"]), radix: 16) }) else {
            return .gray
        }
        return Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                     blue: Double(hex & 0xff) / 255)
    }
}
