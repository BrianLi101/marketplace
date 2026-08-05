import Foundation
import WebKit
import os

extension Logger {
    static let desktop = Logger(subsystem: "com.brianli101.marketplace", category: "desktop")
}

/// Search on the desktop surface, reading the GraphQL payload Facebook embeds
/// in the page it already serves.
///
/// This is the primary search path (`docs/decision-desktop-primary.md`). It
/// exists rather than extending `FeedEngine` because almost nothing is shared:
/// desktop has real listing anchors, an embedded payload, working filters and a
/// hard result cap, where WebLite has none of those and paginates forever. One
/// engine pretending to be both would be a pile of branches.
///
/// Three properties of this surface shape the design:
///
/// * **The payload covers only the first ~15 cards.** Everything past the first
///   server-rendered page is markup, signed in or out. Cards therefore come back
///   in two grades and callers must handle both — see `PayloadCoverage`.
/// * **Results are capped without a session** at 15, behind a login overlay that
///   allows exactly one dismissal. Signed in, the feed scrolls indefinitely.
/// * **The feed virtualises.** Cards are recycled out of the DOM as they leave
///   the viewport, so pagination has to harvest as it goes rather than scroll to
///   the end and read once.
@MainActor
final class DesktopFeedEngine: NSObject, ObservableObject, WKNavigationDelegate {
    enum LoadState: Equatable {
        case idle, loading, ready, loginWall, failed(String)
    }

    /// How much of the result set arrived with structured data behind it.
    ///
    /// Reported rather than inferred because "this card has no payload" and
    /// "extraction failed" look identical downstream and are not the same
    /// problem — the first is expected past card 15, the second is a bug.
    struct PayloadCoverage: Equatable {
        var rendered: Int
        var withPayload: Int
        var isSuspicious: Bool { rendered > 0 && withPayload == 0 }
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var coverage = PayloadCoverage(rendered: 0, withPayload: 0)

    let webView: WKWebView
    let session: BrowserSession
    private let pacer: RequestPacer
    private var navContinuation: CheckedContinuation<Void, Never>?

    init(session: BrowserSession = .authed, pacer: RequestPacer = RequestPacer()) {
        self.session = session
        self.pacer = pacer
        let config = WKWebViewConfiguration.make(session: session)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900),
                            configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = Surface.desktop.userAgent
        webView.scrollView.showsVerticalScrollIndicator = false
    }

    // MARK: - Loading

    func load(_ query: SearchQuery) async -> [PayloadListing] {
        guard await pacer.waitForSlot() else {
            state = .failed("Paused — too many requests. Try again shortly.")
            return []
        }
        state = .loading
        Logger.desktop.info("loading \(query.url.absoluteString, privacy: .public)")
        await navigate(to: query.url)
        return await harvest()
    }

    /// Polls for the payload rather than waiting on `didFinish`.
    ///
    /// On item pages the payload is readable ~0.9s into a ~1.85s load, so
    /// waiting for the document to finish spends roughly half the time on
    /// images and third-party chrome nobody is going to look at. Search pages
    /// behave the same way.
    private func harvest(timeout: Duration = .seconds(20)) async -> [PayloadListing] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var last: [PayloadListing] = []

        while ContinuousClock.now < deadline {
            guard let json = await evaluate(DesktopScripts.extractSearchPayload),
                  let result = decode(json) else {
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }

            if result.loginWall {
                state = .loginWall
                Logger.desktop.info("login wall on search")
                return []
            }

            coverage = PayloadCoverage(rendered: result.renderedCount,
                                       withPayload: result.payloadCount)
            last = result.listings

            // Done as soon as the payload matches what's on screen, or as soon
            // as there is a payload at all and the page has stopped growing.
            if !result.listings.isEmpty {
                state = .ready
                await pacer.recordSuccess()
                Logger.desktop.info("payload \(result.payloadCount)/\(result.renderedCount) cards")
                return result.listings
            }
            try? await Task.sleep(for: .milliseconds(150))
        }

        // Cards on screen but no payload parsed is the signature of a broken
        // extractor, not an empty result — worth saying so plainly rather than
        // returning [] and letting it look like "nothing found".
        if coverage.isSuspicious {
            Logger.desktop.error("\(self.coverage.rendered) cards rendered but no payload parsed")
            state = .failed("Couldn't read these results.")
        } else {
            state = .ready
        }
        return last
    }

    private struct PayloadResult: Decodable {
        let listings: [PayloadListing]
        let renderedIDs: [String]
        let renderedCount: Int
        let payloadCount: Int
        let loginWall: Bool
    }

    private func decode(_ json: String) -> PayloadResult? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PayloadResult.self, from: data)
    }

    // MARK: - The login overlay

    /// Dismisses the "See more on Facebook" overlay if it offers a way out.
    ///
    /// Logged out there is exactly **one** free dismissal per page load: it
    /// unlocks the document (600px → 2340px) and scrolling then paginates
    /// 15 → 39, after which the overlay returns as a different modal with no
    /// close control at all — Escape and backdrop clicks are both no-ops.
    ///
    /// Not worth using for depth, because cards 16–39 carry no payload and are
    /// therefore no better than mobile's. Kept for the case where the overlay
    /// is merely covering the first 15.
    @discardableResult
    func dismissOverlayIfPresent() async -> Bool {
        let result = await evaluate(Self.dismissOverlayJS)
        return result?.contains("dismissed") ?? false
    }

    private static let dismissOverlayJS = """
    (function(){
      var dialogs = document.querySelectorAll('[role="dialog"]');
      for (var i = 0; i < dialogs.length; i++) {
        var buttons = dialogs[i].querySelectorAll('[aria-label], [role="button"]');
        for (var j = 0; j < buttons.length; j++) {
          var label = (buttons[j].getAttribute('aria-label') || buttons[j].innerText || '').trim();
          if (label === 'Close' || label === 'Not now') {
            buttons[j].click();
            return 'dismissed';
          }
        }
      }
      return 'none';
    })()
    """

    // MARK: - Plumbing

    private func navigate(to url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navContinuation = cont
            webView.load(URLRequest(url: url))
        }
    }

    func evaluate(_ script: String) async -> String? {
        do {
            let result = try await webView.evaluateJavaScript(script)
            return result as? String
        } catch {
            return nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            navContinuation?.resume()
            navContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
            navContinuation?.resume()
            navContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
            navContinuation?.resume()
            navContinuation = nil
        }
    }
}
