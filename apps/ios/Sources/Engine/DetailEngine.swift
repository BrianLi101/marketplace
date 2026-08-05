import Foundation
import WebKit
import os

extension Logger {
    static let detail = Logger(subsystem: "com.brianli101.marketplace", category: "detail")
}

/// Webview B — the fallback path to an item page, plus the session cache.
///
/// This used to be how every listing was opened. It no longer is: tapping a
/// card lands `FeedEngine` on the item page with the full document already in
/// its DOM, so loading the same page a second time here cost ~4.4s of a ~6.5s
/// tap for nothing. What remains is the route for cards the tap can't reach —
/// resolve the id by searching the desktop surface, then load the page — and
/// the cache both paths write into.
///
/// Detail pages are ordinary documents: description, condition, posted date,
/// photos and location all render logged out (seller identity does not).
@MainActor
final class DetailEngine: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    private let metrics: MetricsReporter
    private let pacer: RequestPacer


    /// The desktop surface is used here, not the mobile one. It caps search
    /// results at 15 with no pagination — irrelevant for a lookup — but unlike
    /// mobile it exposes real `/marketplace/item/{id}` anchors, which is the
    /// only reliable way to learn a listing's canonical URL. Its detail pages
    /// are also the richer ones.
    /// Item pages are loaded with the *mobile* UA: it is the only surface that
    /// publishes the seller's name, join date and rating. Condition used to be
    /// the reason for preferring desktop here, and that reason is gone — it now
    /// arrives on the card's own aria-label. The desktop UA is still needed for
    /// `resolveItemURL`, which is why the agent is set per load rather than once.
    static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1"

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
    /// Last resort, not the main path. Tapping the card in the hidden feed
    /// does work — `FeedEngine.openItem` clicks it and the feed lands on the
    /// item page — so this runs only when there is no cached `itemURL` and the
    /// tap produced nothing, e.g. a card index gone stale under the feed. It
    /// costs one page load and a fuzzy title match, which is why it is the
    /// fallback rather than the mechanism.
    ///
    /// The fuzzy match could be retired: a listing's fbcdn filename segment is
    /// identical on both surfaces, so the desktop result can be joined to the
    /// mobile card exactly. See docs/surface-strategy.md §5a — and note the
    /// key is the *filename* segment, not the payload's
    /// `primary_listing_photo.id`, which is a different number.
    func resolveItemURL(for listing: Listing, citySlug: String?) async -> URL? {
        guard let title = listing.title, !title.isEmpty else { return nil }
        guard await pacer.waitForSlot() else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.facebook.com"
        components.path = "/marketplace/\(citySlug ?? "sanfrancisco")/search/"
        components.queryItems = [URLQueryItem(name: "query", value: title)]
        guard let searchURL = components.url else { return nil }

        let started = Date()
        webView.customUserAgent = Self.desktopUserAgent
        await beginLoad(searchURL)

        guard let result = await poll(Self.itemLinksJS, as: ItemLinks.self,
                                      until: { !$0.items.isEmpty },
                                      timeout: .seconds(8)) else { return nil }

        guard let id = ItemMatcher.bestMatch(title: listing.title,
                                             priceText: listing.priceText,
                                             candidates: result.items) else {
            Logger.detail.info("no confident match for \(title, privacy: .public) among \(result.items.count)")
            return nil
        }
        await pacer.recordSuccess()
        Logger.detail.info("resolve ok in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
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

    /// Starts a load without waiting for it to finish, so `poll` can read the
    /// DOM the moment the content exists. `didFinish` on an item page waits for
    /// every photo to finish downloading, which is seconds after the
    /// description and the gallery URLs are already in the document.
    ///
    /// The outgoing document is marked first: a freshly loaded page won't carry
    /// the flag, which is how `poll` tells the new page from the old one
    /// without depending on URL matching that Facebook may rewrite.
    private func beginLoad(_ url: URL) async {
        _ = try? await webView.evaluateJavaScript("window.__mpStale = true")
        webView.load(URLRequest(url: url))
    }

    /// Evaluates `script` every `interval` until `isReady` accepts the decoded
    /// result, or `timeout` elapses — returning the last successful decode
    /// either way, so a partial read is still usable.
    ///
    /// This replaces a fixed `Task.sleep`, which was wrong in both directions:
    /// it burned the remainder of the wait on pages that hydrated early, and on
    /// slower ones it read a half-built DOM and reported failure for a page
    /// that would have loaded perfectly well a moment later.
    private func poll<T: Decodable>(_ script: String,
                                    as type: T.Type,
                                    until isReady: (T) -> Bool,
                                    timeout: Duration,
                                    interval: Duration = .milliseconds(150)) async -> T? {
        // Yields null while the outgoing document is still in place, so a
        // half-navigated webview can never hand us the previous listing.
        let guarded = "(function(){ if (window.__mpStale) return null; return \(script); })()"
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var latest: T?
        while clock.now < deadline {
            if let json = try? await webView.evaluateJavaScript(guarded) as? String,
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(type, from: data) {
                latest = decoded
                if isReady(decoded) { return decoded }
            }
            try? await Task.sleep(for: interval)
        }
        return latest
    }

    /// §3.2 — the preview is the screen; this only ever enhances it. Failure is
    /// quiet and the caller keeps showing what it already had.
    ///
    /// Deliberately uncached. Caching moved to `ListingCache`, which persists
    /// across launches — and every call that reaches here is now a *revalidation*,
    /// asked for precisely because the caller already has a cached copy and
    /// wants to know whether the price or the sold status has moved.
    func loadDetail(id: String, url: URL) async -> ListingDetail? {
        let started = Date()
        guard await pacer.waitForSlot() else { return nil }

        // The page must be the listing we asked for. A redirect, a wall, or
        // Marketplace's own landing page all render fine and would otherwise be
        // extracted as if they were the listing — that is how "Buy and sell in
        // your community on Marketplace" ended up as a description.
        let expectedID = url.marketplaceItemID

        webView.customUserAgent = Self.mobileUserAgent
        await beginLoad(url)

        // The description lands well before the gallery does, so requiring only
        // one of them returns a listing with no photos. Wait for both — `poll`
        // still hands back whatever it last saw if the gallery never arrives.
        // A login wall counts as ready: there's nothing more to wait for, and
        // polling the full ceiling would only delay the backoff.
        guard let raw = await poll(WebLiteScripts.extractDetail, as: RawDetail.self,
                                   until: { $0.loginWall || ($0.description != nil && !$0.photoURLs.isEmpty) },
                                   timeout: .seconds(8)) else {
            Logger.detail.warning("detail parse failed for \(url.absoluteString, privacy: .public)")
            metrics.detailLatency(seconds: Date().timeIntervalSince(started), succeeded: false)
            return nil
        }
        Logger.detail.info("detail ok: desc=\(raw.description != nil) photos=\(raw.photoURLs.count) cond=\(raw.conditionText != nil) coord=\(raw.latitude ?? "none", privacy: .public),\(raw.longitude ?? "none", privacy: .public)")
        if !raw.matches(expectedID) {
            Logger.detail.warning("wrong page: wanted \(expectedID ?? "none", privacy: .public), got \(raw.itemId ?? "none", privacy: .public)")
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

        metrics.detailLatency(seconds: Date().timeIntervalSince(started), succeeded: true)
        return raw.listingDetail
    }

    /// Facebook prints a seller's score as "4.8 (12)" — the star average and
    /// the number of ratings behind it, in one run of text.
    static func rating(from text: String?) -> Double? {
        guard let head = text?.split(separator: "(").first else { return nil }
        return Double(head.trimmingCharacters(in: .whitespaces))
    }

    static func ratingCount(from text: String?) -> Int? {
        guard let text, let open = text.firstIndex(of: "("),
              let close = text.firstIndex(of: ")"), open < close else { return nil }
        return Int(text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Logger.detail.warning("navigation failed: \(error.localizedDescription, privacy: .public)")
    }
}
