import Foundation
import WebKit
import os

/// Facebook's default feed for wherever the user is, for the home screen to
/// scroll through.
///
/// The home screen used to be entirely local — saved listings and recently
/// viewed, both read from disk. That is the right content for someone coming
/// *back*, and nothing at all for someone arriving: a new install saw an empty
/// state and a search field, and had to think of something to type before the
/// app did anything. This is the section that gives them something to scroll
/// instead.
///
/// **Its own engine, for the same reason `ComparableSearch` has one.** Sharing
/// the browse tab's `DesktopFeedEngine` would mean the home feed and the user's
/// search taking turns navigating one webview — and since the home feed loads
/// on launch, the race is with the *first* search anyone runs. It costs one
/// more idle webview and no extra request budget: `RequestPacer` is a shared
/// actor, so this counts against the same session cap and backs off with
/// everything else.
///
/// **Markup only, deliberately.** The embedded payload that makes desktop
/// search worth using is effectively absent on `/marketplace/<place>/`:
/// measured on a live browse page, the extractor found six `"listing"` blocks
/// against twenty rendered cards, and **not one carried a title, a price or a
/// photo** — only an id and a timestamp. The DOM, by contrast, is complete:
/// 20 of 20 anchors had a full `aria-label` and an image. So this reads cards
/// the way the search tail is read, and callers get no exact timestamps, no
/// delivery types and no sold state for these listings. Opening one enriches it
/// from its item page like any other card.
@MainActor
final class DiscoverFeed: ObservableObject {
    @Published private(set) var listings: [Listing] = []
    @Published private(set) var isLoading = false

    /// How stale a cached feed may be before a visit refreshes it. Long enough
    /// that flicking between tabs costs nothing, short enough that a feed left
    /// open overnight isn't yesterday's.
    static let freshness: TimeInterval = 30 * 60

    private let engine: DesktopFeedEngine
    private let cache: ListingCache
    /// What the current `listings` belong to. Both halves matter: changing city
    /// must reload rather than show the previous place's feed under the new
    /// name, and so must signing in, which changes the result set outright
    /// rather than merely lengthening it.
    private var loadedURL: String?
    private var loadedSession: BrowserSession?
    private var loadedAt: Date?

    /// Has to be in the view hierarchy for WebKit to render it — see
    /// `RootView`. Same constraint as every other engine.
    var webView: WKWebView { engine.webView }

    init(engine: DesktopFeedEngine? = nil, cache: ListingCache = .shared) {
        self.engine = engine ?? DesktopFeedEngine()
        self.cache = cache
    }

    /// Facebook's default listings for a place.
    ///
    /// Local pickup only, which is the one filter this applies: a home feed
    /// full of things that ship from three states away is not a local
    /// marketplace, and it is the same call the browse tab's default makes.
    /// Everything else — sort, price, condition — is deliberately left alone,
    /// because this section is "what's around", not a search the user shaped.
    ///
    /// The user's radius is **not** in here, and that is deliberate rather than
    /// an omission. It changes nothing at Facebook (`docs/filter-parameters.md`
    /// §3, §11) but it would change this URL, and the URL is the cache key — so
    /// every nudge of the distance control would throw the feed away and reload
    /// it to get the same cards back. Distance is applied on-device, where
    /// re-filtering is instant and free.
    func query(citySlug: String) -> SearchQuery {
        SearchQuery(
            kind: .browse,
            radiusKM: 40,           // sent for shape only, as everywhere else
            citySlug: citySlug,
            coordinate: nil,
            delivery: .localPickup
        )
    }

    /// Loads once per place per session, and then leaves it alone.
    ///
    /// Called every time the home screen appears, which is why the guards
    /// matter more than the loading does: returning from a listing, or from the
    /// seller tab, must not cost a page load. `force` is the pull-to-refresh
    /// path.
    func loadIfNeeded(citySlug: String,
                      session: BrowserSession,
                      force: Bool = false) async {
        let query = query(citySlug: citySlug)
        let url = query.url.absoluteString
        let isCurrent = url == loadedURL && session == loadedSession

        if !force, isCurrent, !listings.isEmpty,
           let loadedAt, Date().timeIntervalSince(loadedAt) < Self.freshness {
            return
        }
        guard !isLoading else { return }

        // Last session's feed on the first frame. The live load behind it takes
        // seconds, and this screen's whole job is to have something to scroll
        // the moment it opens — a skeleton where we already know the answer is
        // just a slower version of the same screen.
        if !isCurrent || listings.isEmpty,
           let cached = cache.discoverResults(for: query, session: session) {
            listings = cached.listings
            loadedURL = url
            loadedSession = session
            loadedAt = cached.savedAt
            if !force, Date().timeIntervalSince(cached.savedAt) < Self.freshness { return }
        } else if !isCurrent {
            // Different place or different session, and nothing cached for it.
            // The old feed is now actively wrong, so it goes.
            listings = []
        }

        isLoading = listings.isEmpty
        defer { isLoading = false }

        _ = await engine.load(query)
        let parsed = await engine.renderedCards().enumerated()
            .compactMap { index, card in DesktopCardParser.parse(card, cardIndex: index) }

        // Nothing rendered is not a reason to blank the screen. A login wall, a
        // pacer refusal or a slow page all land here, and whatever was already
        // showing is still the most honest thing we have.
        guard !parsed.isEmpty else {
            Logger.discover.info("no cards for \(query.displayName, privacy: .public) [\(String(describing: self.engine.state), privacy: .public)]")
            return
        }

        var seen = Set<String>()
        listings = parsed.filter { seen.insert($0.id).inserted }
        loadedURL = url
        loadedSession = session
        loadedAt = Date()
        cache.saveDiscover(listings, for: query, session: session)
        Logger.discover.info("\(self.listings.count, privacy: .public) cards")
    }
}

extension Logger {
    static let discover = Logger(subsystem: "lol.frens.openmarket", category: "discover")
}
