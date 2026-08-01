import Foundation
import WebKit
import os

extension Logger {
    static let detail = Logger(subsystem: "com.brianli101.marketplace", category: "detail")
}

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

    /// The desktop surface is used here, not the mobile one. It caps search
    /// results at 15 with no pagination — irrelevant for a lookup — but unlike
    /// mobile it exposes real `/marketplace/item/{id}` anchors, which is the
    /// only reliable way to learn a listing's canonical URL. Its detail pages
    /// are also the richer ones.
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.7 Safari/605.1.15"

    init(metrics: MetricsReporter = LocalMetrics.shared, pacer: RequestPacer = RequestPacer()) {
        self.metrics = metrics
        self.pacer = pacer
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 900), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = Self.desktopUserAgent
    }

    // MARK: - Resolving a listing's canonical URL

    /// Finds the item URL by searching the desktop surface for the listing's
    /// own title and matching the result back against its price and title.
    ///
    /// This replaces tapping the card in the hidden feed, which never fired
    /// WebLite's server-side action from inside the app. It costs one page
    /// load, for a listing the user has actually opened.
    func resolveItemURL(for listing: Listing, citySlug: String?) async -> URL? {
        guard let title = listing.title, !title.isEmpty else { return nil }
        guard await pacer.waitForSlot() else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.facebook.com"
        components.path = "/marketplace/\(citySlug ?? "sanfrancisco")/search/"
        components.queryItems = [URLQueryItem(name: "query", value: title)]
        guard let searchURL = components.url else { return nil }

        await navigate(to: searchURL)
        try? await Task.sleep(for: .milliseconds(1500))

        guard let json = try? await webView.evaluateJavaScript(Self.itemLinksJS) as? String,
              let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(ItemLinks.self, from: data) else { return nil }

        guard let id = ItemMatcher.bestMatch(title: listing.title,
                                             priceText: listing.priceText,
                                             candidates: result.items) else {
            Logger.detail.info("no confident match for \(title, privacy: .public) among \(result.items.count)")
            return nil
        }
        await pacer.recordSuccess()
        return URL(string: "https://www.facebook.com/marketplace/item/\(id)/")
    }

    struct ItemCandidate: Decodable {
        let id: String
        let text: String
    }

    private struct ItemLinks: Decodable {
        let items: [ItemCandidate]
    }

    private static let itemLinksJS = """
    (function(){
      var links = Array.prototype.slice.call(document.querySelectorAll('a[href*="/marketplace/item/"]'));
      var seen = {}, out = [];
      links.forEach(function(a){
        var m = (a.getAttribute('href') || '').match(/marketplace\\/item\\/(\\d+)/);
        if (!m || seen[m[1]]) return;
        seen[m[1]] = 1;
        out.push({id: m[1], text: (a.textContent || '').slice(0, 200)});
      });
      return JSON.stringify({items: out});
    })()
    """

    private func navigate(to url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navigationContinuation = cont
            webView.load(URLRequest(url: url))
        }
    }

    func cachedDetail(for id: String) -> ListingDetail? { cache[id] }

    /// §3.2 — the preview is the screen; this only ever enhances it. Failure is
    /// quiet and the caller keeps showing what it already had.
    func loadDetail(id: String, url: URL) async -> ListingDetail? {
        if let cached = cache[id] { return cached }
        let started = Date()
        guard await pacer.waitForSlot() else { return nil }

        await navigate(to: url)
        try? await Task.sleep(for: .milliseconds(1500))

        guard let json = try? await webView.evaluateJavaScript(WebLiteScripts.extractDetail) as? String,
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawDetail.self, from: data) else {
            Logger.detail.warning("detail parse failed for \(url.absoluteString, privacy: .public)")
            metrics.detailLatency(seconds: Date().timeIntervalSince(started), succeeded: false)
            return nil
        }
        Logger.detail.info("detail ok: desc=\(raw.description != nil) photos=\(raw.photoURLs.count) cond=\(raw.conditionText != nil)")
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
