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
/// **Before there is any history**, the seeds are the interests picked during
/// onboarding (`Interest`, `OnboardingView`). That is what the required
/// three-interest step is for: this class is the reason it exists, and without
/// it a new install's home screen was a hardcoded category list searched in a
/// hardcoded city.
///
/// **Its own engines**, one per search, for the reason `ComparableSearch` has
/// one: sharing the browse tab's would mean the home feed and the user's first
/// search taking turns navigating one webview. One each means the searches
/// overlap instead of queueing, so a fill is about as long as its slowest page
/// rather than the sum of three. No extra request budget either — `RequestPacer`
/// is a shared actor and still spaces the starts.
///
/// **A fill publishes once, when all of it is in.** The grid used to arrive in
/// three instalments and reflow twice under whoever was reading it. Cards moving
/// out from under a thumb is the one thing a feed must not do, and staging the
/// wait made it look longer than it was.
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
    /// What this feed was built from, so the screen can say so. A feed
    /// assembled out of someone's history should admit which parts of it.
    @Published private(set) var seeds: [Seed] = []

    /// One search behind the feed, and where it came from.
    ///
    /// The origin is carried rather than inferred because it changes what the
    /// screen can honestly claim: "from your searches for lamp · desk" is a
    /// statement about the user's own history, and on a new install — where
    /// there is no history — the same sentence would be a lie about a list they
    /// picked off a menu thirty seconds ago.
    struct Seed: Equatable, Identifiable {
        enum Origin: Equatable { case search, interest }

        /// What gets searched.
        let term: String
        /// What the screen prints. Differs from `term` for interests, whose
        /// label is a category and whose term is what a listing might say.
        let label: String
        let origin: Origin

        var id: String { "\(origin)-\(term)" }
    }

    /// How many searches one fill runs. Three is a judgement, not a
    /// measurement: enough for the mix to feel like more than one topic,
    /// few enough that a fill is three page loads rather than a crawl.
    static let searchCount = 3
    /// How many cards to keep from each. Taken *after* shuffling the search's
    /// results, so this is a random sample of what came back rather than its
    /// top ten — otherwise Discover would be the first rows of three searches,
    /// which the user could have got by running them.
    static let perSearch = 10

    /// One engine per search, so the searches can run at the same time.
    ///
    /// They can't share one. An engine is a single `WKWebView` with a single
    /// in-flight navigation, and the markup fallback reads whatever document is
    /// currently loaded in it — three concurrent searches through one engine
    /// would be three navigations fighting over one page and reading each
    /// other's cards.
    ///
    /// The cost is two more hidden webviews resident for the app's lifetime.
    /// Worth it: a fill was three page loads end to end, and the screen has
    /// nothing to show until it finishes, so that time was the entire wait on
    /// the home screen. Concurrent, it is roughly one load. No extra request
    /// budget either — `RequestPacer` is shared and still spaces the starts.
    private let engines: [DesktopFeedEngine]
    private let prefs: Preferences
    private var hasLoaded = false

    /// All of them have to be in the view hierarchy for WebKit to render them —
    /// see `RootView`. Same constraint as every other engine.
    var webViews: [WKWebView] { engines.map(\.webView) }

    init(engines: [DesktopFeedEngine]? = nil, prefs: Preferences = .shared) {
        self.engines = engines ?? (0..<Self.searchCount).map { _ in DesktopFeedEngine() }
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

        let seeds = Self.seeds(recent: prefs.recentSearches, interests: prefs.chosenInterests)
        self.seeds = seeds

        // All searches at once, one engine each, and nothing is published until
        // every one of them is back.
        //
        // This used to run them one after another and republish after each, so
        // the grid arrived in three instalments and reflowed twice under
        // whoever was already reading it. Cards moved out from under a thumb —
        // which is the one thing a feed must not do — and it made the wait
        // *look* longer than it was by drawing attention to each stage of it.
        //
        // `Task {}` inherits this actor, so the three bodies interleave at their
        // awaits rather than running truly in parallel: the page loads overlap,
        // which is where the time goes, and nothing touches shared state
        // concurrently.
        let tasks = zip(seeds, engines).map { seed, engine in
            Task { await self.batch(for: seed.term, using: engine, citySlug: citySlug) }
        }
        var buckets: [[Listing]] = []
        for task in tasks {
            buckets.append(await task.value)
        }
        // Replaced in one assignment, which is also what keeps a pull-to-refresh
        // honest: the old cards stay exactly where they are until the whole new
        // feed is ready to take their place.
        listings = Self.interleave(buckets)
        Logger.discover.info("\(self.listings.count, privacy: .public) cards from \(seeds.count, privacy: .public) searches")
    }

    /// Drops the "already filled" flag without touching what's on screen.
    ///
    /// For a change that makes the current feed answer the wrong question —
    /// editing interests in Settings, and nothing else so far. The cards stay
    /// up until the next fill replaces them, because blanking a screen the
    /// moment a preference changes is a worse answer than a stale one.
    func markStale() { hasLoaded = false }

    /// What to search for: the user's own recent terms first, topped up from
    /// the interests they chose during onboarding.
    ///
    /// That order is the whole design. A search is the strongest statement of
    /// intent anyone makes in this app and it is about *now*; an interest is a
    /// standing statement made once, and its job is to answer the question "what
    /// should the first screen be" for someone who has not searched yet. So
    /// interests fill the gap and recede as the history grows — a user with
    /// three recent searches never sees an interest-seeded row again until they
    /// clear their history.
    ///
    /// Interests are shuffled because there are usually more than three of them
    /// and the array is in the order they were tapped: taking the first three
    /// every launch would make the last-picked interests decorative.
    static func seeds(recent: [String], interests: [Interest]) -> [Seed] {
        var out: [Seed] = []
        func add(_ seed: Seed) {
            let term = seed.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, out.count < searchCount,
                  !out.contains(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) else { return }
            out.append(seed)
        }
        recent.forEach { add(Seed(term: $0, label: $0, origin: .search)) }
        interests.shuffled().forEach {
            add(Seed(term: $0.term, label: $0.label, origin: .interest))
        }
        return out
    }

    /// What the section header says it was built from — or nil when there is
    /// nothing to describe yet.
    ///
    /// Load-bearing, not decoration: a shuffled feed with no stated basis is
    /// indistinguishable from a random one, which is exactly the complaint that
    /// got the previous version of this screen deleted.
    var caption: String? {
        guard !seeds.isEmpty else { return nil }
        let names = seeds.map(\.label).joined(separator: " · ")
        switch (seeds.contains { $0.origin == .search }, seeds.contains { $0.origin == .interest }) {
        case (true, false): return "From your searches for \(names)"
        case (false, true): return "From your interests: \(names)"
        default: return "From your searches and interests: \(names)"
        }
    }

    /// One search's contribution: a random sample of its results.
    ///
    /// Takes its engine rather than reaching for a shared one, because the
    /// markup fallback below reads the document that engine is *currently*
    /// showing — the one thing that would go wrong if these ran concurrently
    /// through one webview.
    ///
    /// Cross-search dedupe is not done here any more. It can't be: the searches
    /// no longer finish in a defined order, so a set threaded through them would
    /// decide which of two identical cards survives by whichever page happened
    /// to load first. `interleave` does it instead, in seed order, where the
    /// answer is the same every time.
    private func batch(for term: String,
                       using engine: DesktopFeedEngine,
                       citySlug: String) async -> [Listing] {
        let payload = await engine.load(query(for: term, citySlug: citySlug))
        var parsed = payload.enumerated().map { index, item in item.makeListing(cardIndex: index) }
        // Same fallback as everywhere else: a page served entirely client-side
        // renders cards with no embedded listing block behind them, and the
        // markup carries everything a card needs.
        if parsed.isEmpty {
            parsed = await engine.renderedCards().enumerated()
                .compactMap { index, card in DesktopCardParser.parse(card, cardIndex: index) }
        }

        // Ships-only cards are not what a local marketplace's home screen is
        // for. Only the markup path sets this badge, so it catches the tail
        // rather than everything — the query's delivery filter is what does the
        // real work when the user has one set.
        let kept = parsed.filter { $0.badgeText != "Ships" }
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
    ///
    /// Also where a listing found by two searches is dropped — first occurrence
    /// wins, and "first" is by seed order, so the result doesn't depend on which
    /// page finished loading first.
    static func interleave(_ buckets: [[Listing]]) -> [Listing] {
        var out: [Listing] = []
        var seen = Set<String>()
        let depth = buckets.map(\.count).max() ?? 0
        for index in 0..<depth {
            for bucket in buckets where index < bucket.count {
                let listing = bucket[index]
                guard seen.insert(listing.id).inserted else { continue }
                out.append(listing)
            }
        }
        return out
    }
}

extension Logger {
    static let discover = Logger(subsystem: "lol.frens.openmarket", category: "discover")
}
