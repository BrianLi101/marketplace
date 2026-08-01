import Foundation
import WebKit

/// Webview B — loads item pages so the feed never has to navigate away.
/// Detail pages are ordinary documents: description, condition, posted date,
/// photos and location all render logged out (seller identity does not).
@MainActor
final class DetailEngine: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    private let metrics: MetricsReporter
    private let pacer: RequestPacer
    private var navigationContinuation: CheckedContinuation<Void, Never>?

    private var cache: [String: ListingDetail] = [:]   // §3.2 — session cache, back-then-forward is instant

    init(metrics: MetricsReporter = LocalMetrics.shared, pacer: RequestPacer = RequestPacer()) {
        self.metrics = metrics
        self.pacer = pacer
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 874), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = FeedEngine.mobileUserAgent
    }

    func cachedDetail(for id: String) -> ListingDetail? { cache[id] }

    /// §3.2 — the preview is the screen; this only ever enhances it. Failure is
    /// quiet and the caller keeps showing what it already had.
    func loadDetail(id: String, url: URL) async -> ListingDetail? {
        if let cached = cache[id] { return cached }
        let started = Date()
        guard await pacer.waitForSlot() else { return nil }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navigationContinuation = cont
            webView.load(URLRequest(url: url))
        }
        try? await Task.sleep(for: .milliseconds(900))

        guard let json = try? await webView.evaluateJavaScript(WebLiteScripts.extractDetail) as? String,
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawDetail.self, from: data) else {
            metrics.detailLatency(seconds: Date().timeIntervalSince(started), succeeded: false)
            return nil
        }
        if raw.loginWall {
            metrics.loginWallHit(surface: "detail")
            await pacer.recordBlock()
            metrics.detailLatency(seconds: Date().timeIntervalSince(started), succeeded: false)
            return nil
        }
        await pacer.recordSuccess()

        let detail = ListingDetail(
            description: raw.description,
            photoURLs: raw.photoURLs.compactMap(URL.init(string:)),
            postedText: raw.postedText,
            conditionText: raw.conditionText,
            locationText: raw.locationText,
            sellerName: nil     // login-gated; §4 hands off instead
        )
        cache[id] = detail
        metrics.detailLatency(seconds: Date().timeIntervalSince(started), succeeded: true)
        return detail
    }

    private struct RawDetail: Decodable {
        let description: String?
        let photoURLs: [String]
        let postedText: String?
        let conditionText: String?
        let locationText: String?
        let loginWall: Bool
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.navigationContinuation?.resume()
            self.navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.navigationContinuation?.resume()
            self.navigationContinuation = nil
        }
    }
}
