import Foundation
import WebKit
import os

extension Logger {
    static let feed = Logger(subsystem: "com.brianli101.marketplace", category: "feed")
}

/// Webview A — owns the results page and its pagination state, and never
/// navigates away from it.
///
/// Two behaviours here were established empirically (docs/feasibility-2026-07-31.md)
/// and are load-bearing:
///
///  1. **Pagination only responds to the native scroll view.** `window.scrollTo`
///     and synthesized `TouchEvent`s both leave the page frozen; stepping
///     `scrollView.contentOffset` loads the next batch.
///  2. **Tapping a card is the only way to learn its item id.** The click
///     triggers a navigation to `/marketplace/item/{id}`, which this engine
///     captures and then *cancels* — so the feed keeps its scroll position and
///     the load costs nothing.
@MainActor
final class FeedEngine: NSObject, ObservableObject, WKNavigationDelegate {
    enum LoadState: Equatable {
        case idle, loading, ready, loginWall, failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var canLoadMore = true

    let webView: WKWebView
    private let metrics: MetricsReporter
    private let pacer: RequestPacer

    private var navigationContinuation: CheckedContinuation<Void, Never>?
    private var isResolvingItemURL = false
    private var lastDocHeight: Double = 0
    private var pageIndex = 0

    /// A desktop UA caps results at 15 with no pagination; the stock WKWebView
    /// UA gets a dataless shell. Mobile Safari is the only surface that paginates.
    static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1"

    init(metrics: MetricsReporter = LocalMetrics.shared, pacer: RequestPacer = RequestPacer()) {
        self.metrics = metrics
        self.pacer = pacer

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // §7.1 — never share Safari's or the FB app's session
        config.allowsInlineMediaPlayback = true
        config.suppressesIncrementalRendering = false
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 874), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = Self.mobileUserAgent
        // Scrolling stays enabled. Disabling it made WebLite render a reduced
        // card that omits the location line — and the engine drives scrolling
        // through setContentOffset either way, so there was nothing to gain.
        webView.scrollView.showsVerticalScrollIndicator = false
    }

    // MARK: - Loading

    func load(_ query: SearchQuery) async {
        guard await pacer.waitForSlot() else {
            state = .failed("Paused — too many requests. Try again shortly.")
            return
        }
        state = .loading
        pageIndex = 0
        lastDocHeight = 0
        canLoadMore = true
        Logger.feed.info("loading \(query.url.absoluteString, privacy: .public)")
        await navigate(to: query.url)
        await awaitHydration()
    }

    /// WebLite renders its cards well after `didFinish` — several seconds on a
    /// cold load. Polling the DOM costs nothing (no network), so wait for cards
    /// to actually appear rather than guessing a delay.
    /// A cold `nonPersistent` store means every load is a first load, and
    /// WebLite can take 15-20s to paint its first cards. Poll generously.
    private func awaitHydration(timeout: Duration = .seconds(35)) async {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: timeout)
        var polls = 0
        while ContinuousClock.now < deadline {
            if let json = await evaluate(WebLiteScripts.extract),
               let data = json.data(using: .utf8),
               let result = try? JSONDecoder().decode(ExtractResult.self, from: data) {
                if !result.cards.isEmpty || result.loginWall {
                    Logger.feed.info("hydrated: \(result.cards.count) cards after \(polls) polls")
                    return
                }
            }
            polls += 1
            if polls % 8 == 0 {
                let probe = await evaluateRaw("JSON.stringify({t:document.title.slice(0,40),len:(document.body.innerText||'').length,h:document.body.scrollHeight,imgs:document.querySelectorAll('img').length,aid:document.querySelectorAll('div[data-action-id]').length})")
                Logger.feed.info("poll \(polls): \(probe ?? "nil", privacy: .public)")
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
        Logger.feed.warning("hydration timed out with no cards after \(polls) polls")
    }

    private func navigate(to url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navigationContinuation = cont
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - Extraction

    struct RawCard: Decodable {
        let index: Int
        let actionId: String?
        let imageURL: String?
        let label: String?
        let texts: [String]
        let fullText: String
    }

    private struct ExtractResult: Decodable {
        let cards: [RawCard]
        let docHeight: Double
        let loginWall: Bool
        let url: String
    }

    /// Reads every card currently in the DOM. Cheap and side-effect free — no
    /// network, so it can be called after each pagination step.
    func extractCards() async -> [RawCard] {
        guard let json = await evaluate(WebLiteScripts.extract),
              let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(ExtractResult.self, from: data) else {
            state = .failed("Couldn't read the page.")
            return []
        }
        if result.loginWall {
            state = .loginWall
            metrics.loginWallHit(surface: "feed")
            await pacer.recordBlock()
            return []
        }
        if result.cards.isEmpty && state == .loading {
            state = .loginWall              // an empty results page reads the same as a wall
            metrics.loginWallHit(surface: "feed-empty")
            await pacer.recordBlock()
            return []
        }
        if let sample = result.cards.dropFirst().first {
            let cities = await evaluateRaw("""
            (function(){
              var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), n, all = 0, hits = [];
              while ((n = w.nextNode())) {
                var t = (n.textContent || '').trim();
                if (!t) continue;
                all++;
                if (/^[A-Z][A-Za-z .'-]+,\\s*[A-Z]{2}$/.test(t)) hits.push(t);
              }
              return JSON.stringify({textNodes: all, cityNodes: hits.length, sample: hits.slice(0,2)});
            })()
            """) ?? "?"
            Logger.feed.info("cities=\(cities, privacy: .public) sample=\(sample.texts.joined(separator: " ¦ "), privacy: .public)")
        }
        lastDocHeight = result.docHeight
        state = .ready
        await pacer.recordSuccess()
        metrics.pageLoaded(index: pageIndex, listings: result.cards.count)
        return result.cards
    }

    /// Drives the native scroll view until the document grows, which is what
    /// loading the next batch looks like. Returns false when the feed is
    /// exhausted (or the page stopped responding), so callers stop asking.
    @discardableResult
    func loadNextBatch() async -> Bool {
        guard canLoadMore, state == .ready else { return false }
        guard await pacer.waitForSlot() else { return false }

        let startHeight = lastDocHeight
        let scrollView = webView.scrollView

        for _ in 0..<Self.maxScrollStepsPerBatch {
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let next = min(scrollView.contentOffset.y + scrollView.bounds.height * 0.9, maxY)
            scrollView.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            try? await Task.sleep(for: .milliseconds(700))

            if let json = await evaluate(WebLiteScripts.pageMetrics),
               let data = json.data(using: .utf8),
               let metricsResult = try? JSONDecoder().decode(PageMetrics.self, from: data) {
                if metricsResult.docHeight > startHeight + 100 {
                    lastDocHeight = metricsResult.docHeight
                    pageIndex += 1
                    return true
                }
            }
        }
        canLoadMore = false     // height never grew: end of the feed
        return false
    }

    private struct PageMetrics: Decodable {
        let docHeight: Double
        let scrollY: Double
    }

    private static let maxScrollStepsPerBatch = 8

    // MARK: - Resolving a listing's canonical URL

    /// Clicks the card and catches the navigation it triggers, without letting
    /// it happen. Costs no network and leaves the feed exactly where it was.
    /// Taps a card and reads the listing id out of the resulting URL.
    ///
    /// WebLite routes the tap **client-side** through `history.replaceState`,
    /// so no navigation ever reaches `decidePolicyFor`. Waiting on the
    /// navigation delegate — which is what this used to do — timed out after
    /// ten seconds every time while the tap was working perfectly. Poll
    /// `location.href` instead, then wind the history back so the feed is
    /// exactly where the user left it: verified to restore all 26 cards.
    func resolveItemURL(cardIndex: Int) async -> URL? {
        isResolvingItemURL = true
        defer { isResolvingItemURL = false }

        _ = await evaluate(WebLiteScripts.click(index: cardIndex))

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(6)
        var found: URL?
        while clock.now < deadline {
            if let href = await evaluateRaw("location.href"),
               href.contains("/marketplace/item/") {
                found = URL(string: href)
                break
            }
            try? await Task.sleep(for: .milliseconds(150))
        }

        // Restore the feed whether or not the tap landed — a stranded item page
        // would break the next extraction.
        _ = await evaluateRaw("(function(){ history.back(); return 'back'; })()")
        try? await Task.sleep(for: .milliseconds(800))

        Logger.feed.info("tap card \(cardIndex): \(found?.absoluteString ?? "no id", privacy: .public)")
        return found
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.navigationContinuation?.resume()
            self.navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
            self.navigationContinuation?.resume()
            self.navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
            self.navigationContinuation?.resume()
            self.navigationContinuation = nil
        }
    }

    private func evaluate(_ script: String) async -> String? {
        do {
            let result = try await webView.evaluateJavaScript(script)
            return result as? String
        } catch {
            Logger.feed.error("JS failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func evaluateRaw(_ script: String) async -> String? {
        (try? await webView.evaluateJavaScript(script)) as? String
    }
}
