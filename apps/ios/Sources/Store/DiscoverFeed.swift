import Foundation
import WebKit
import os

/// The home screen's feed, built out of what this user has been looking for.
///
/// **Not Facebook's own picks, deliberately.** The first version of this loaded
/// `/marketplace/<place>/` — the "Today's picks" browse feed — and it was a bad
/// recommendation surface: three loads of the identical URL in one session gave
/// 0 of 5 top cards in common between the first and second, 17 of 20 between the
/// second and third, and a fourth that reverted to the first's contents. The
/// geography swung with it, from 9-of-20 in San Francisco to an East Bay spread
/// reaching Napa and Antioch, 50 mi out. It reads as a couple of cached
/// popularity pools being alternated, and logged out there is nothing much for
/// Facebook to personalise it with anyway: an IP, an anonymous cookie, and
/// whatever item pages that cookie has opened.
///
/// The app knows more than that, and knows it locally. Recent searches are the
/// one strong statement of interest anyone makes here, so this runs a few of
/// them and mixes the results. What it loses is novelty — this cannot show you
/// something in a category you've never asked about — and that is the trade
/// being made: relevance over surprise, from signals that never leave the
/// device.
///
/// **Its own engine**, for the reason `ComparableSearch` has one: sharing the
/// browse tab's would mean the home feed and the user's first search taking
/// turns navigating one webview. It costs no extra request budget —
/// `RequestPacer` is a shared actor — but it does cost `searchCount` page loads
/// per fill, which is why the fill happens once.
///
/// **Session-scoped, and nothing is written to disk.** The feed survives moving
/// between tabs and opening listings, and is rebuilt only when the app is
/// launched again or the user pulls to refresh. Nothing persists a feed that is
/// half random by construction: restoring one from disk would show a shuffle
/// somebody generated yesterday and call it today's.
@MainActor
final class DiscoverFeed: ObservableObject {
    @Published private(set) var listings: [Listing] = []
    @Published private(set) var isLoading = false
    /// The searches this feed was built from, so the screen can say so. A feed
    /// assembled out of someone's history should admit which parts of it.
    @Published private(set) var terms: [String] = []

    /// How many searches one fill runs. Three is a judgement, not a
    /// measurement: enough for the mix to feel like more than one topic,
    /// few enough that a fill is three page loads rather than a crawl.
    static let searchCount = 3
    /// How many cards to keep from each. Taken *after* shuffling the search's
    /// results, so this is a random sample of what came back rather than its
    /// top ten — otherwise Discover would be the first rows of three searches,
    /// which the user could have got by running them.
    static let perSearch = 10

    private let engine: DesktopFeedEngine
    private let prefs: Preferences
    private var hasLoaded = false

    /// Has to be in the view hierarchy for WebKit to render it — see
    /// `RootView`. Same constraint as every other engine.
    var webView: WKWebView { engine.webView }

    init(engine: DesktopFeedEngine? = nil, prefs: Preferences = .shared) {
        self.engine = engine ?? DesktopFeedEngine()
        self.prefs = prefs
    }

    /// Fills once per launch. `force` is the pull-to-refresh path, and the only
    /// other thing that rebuilds it.
    ///
    /// Note what is *not* a trigger: running a search. Recent searches are the
    /// seed, so every search would otherwise invalidate the feed the user is
    /// about to come back to — they'd return from a search to a screen that had
    /// thrown itself away and was reloading. The new term is picked up by the
    /// next launch, or by a pull.
    func loadIfNeeded(citySlug: String, force: Bool = false) async {
        guard force || !hasLoaded, !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        let seeds = Self.seeds(recent: prefs.recentSearches)
        terms = seeds

        // Published after each search rather than at the end, so the screen
        // fills as it goes instead of showing a skeleton for three sequential
        // page loads. Positions shift while that happens, which is what a feed
        // arriving looks like; once the last search lands the order is fixed
        // until the next refresh.
        //
        // The existing cards are left alone until the first new batch replaces
        // them, so a pull-to-refresh never blanks the screen it is refreshing.
        var buckets: [[Listing]] = []
        var seen = Set<String>()
        for term in seeds {
            buckets.append(await batch(for: term, citySlug: citySlug, excluding: &seen))
            listings = Self.interleave(buckets)
        }
        Logger.discover.info("\(self.listings.count, privacy: .public) cards from \(seeds.count, privacy: .public) searches")
    }

    /// What to search for: the user's own recent terms, newest first.
    ///
    /// The fallback matters more than it looks — on a new install there is no
    /// history at all, and this is the screen that install lands on. The
    /// suggested categories are the same list the search field offers, shuffled
    /// so that two launches of a fresh app don't produce the same three.
    static func seeds(recent: [String]) -> [String] {
        var out: [String] = []
        func add(_ candidate: String) {
            let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, out.count < searchCount,
                  !out.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
            out.append(term)
        }
        recent.forEach(add)
        Preferences.suggestedCategories.shuffled().forEach(add)
        return out
    }

    /// One search's contribution: a random sample of its results, minus
    /// anything already taken by an earlier search in this fill.
    private func batch(for term: String,
                       citySlug: String,
                       excluding seen: inout Set<String>) async -> [Listing] {
        let payload = await engine.load(query(for: term, citySlug: citySlug))
        var parsed = payload.enumerated().map { index, item in item.makeListing(cardIndex: index) }
        // Same fallback as everywhere else: a page served entirely client-side
        // renders cards with no embedded listing block behind them, and the
        // markup carries everything a card needs.
        if parsed.isEmpty {
            parsed = await engine.renderedCards().enumerated()
                .compactMap { index, card in DesktopCardParser.parse(card, cardIndex: index) }
        }

        var kept: [Listing] = []
        for listing in parsed {
            // Ships-only cards are not what a local marketplace's home screen is
            // for. Only the markup path sets this badge, so it catches the tail
            // rather than everything — the query's delivery filter is what does
            // the real work when the user has one set.
            guard listing.badgeText != "Ships" else { continue }
            guard seen.insert(listing.id).inserted else { continue }
            kept.append(listing)
        }
        return Array(kept.shuffled().prefix(Self.perSearch))
    }

    /// The same query a search for this term would build, filters and all.
    ///
    /// Deliberately the user's own filters rather than a neutral set: this feed
    /// claims to be built from what they search for, and a Discover that
    /// quietly ignored their delivery method or price range would be showing
    /// them results their own search wouldn't.
    private func query(for term: String, citySlug: String) -> SearchQuery {
        SearchQuery(
            kind: .search(term),
            // Sent for shape only; no surface filters on it logged out, and
            // signed in the account's own setting wins (`docs/filter-parameters.md`
            // §3, §11). Distance is applied on-device.
            radiusKM: prefs.radiusKM == 0 ? 40 : prefs.radiusKM,
            citySlug: citySlug,
            coordinate: nil,
            sort: prefs.sort,
            delivery: prefs.delivery,
            conditions: prefs.conditions,
            minPrice: prefs.minPrice,
            maxPrice: prefs.maxPrice
        )
    }

    /// Round-robin across the searches, so the mix is visible from the first
    /// row rather than being three blocks stacked on each other. Each bucket is
    /// already shuffled, so this is a mixed sample and not an interleaved
    /// ranking.
    static func interleave(_ buckets: [[Listing]]) -> [Listing] {
        var out: [Listing] = []
        let depth = buckets.map(\.count).max() ?? 0
        for index in 0..<depth {
            for bucket in buckets where index < bucket.count {
                out.append(bucket[index])
            }
        }
        return out
    }
}

extension Logger {
    static let discover = Logger(subsystem: "lol.frens.openmarket", category: "discover")
}
