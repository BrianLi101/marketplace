import Foundation
import SwiftUI
import os

extension Logger {
    static let store = Logger(subsystem: "com.brianli101.marketplace", category: "store")
}

/// Owns what the grid shows: dedupe, filtering, paging, and the parse-health
/// counters that back §8's telemetry and the debug parity report.
@MainActor
final class ListingStore: ObservableObject {
    @Published private(set) var listings: [Listing] = []
    @Published private(set) var isLoadingFirstPage = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var health = ParseHealth()
    @Published var query: SearchQuery?

    let feed: FeedEngine
    let detail: DetailEngine
    private let prefs: Preferences
    private let metrics: MetricsReporter
    private let cache: ListingCache
    private var seenIDs = Set<String>()
    /// True while the grid is showing last session's cards. They render on the
    /// first frame, but their `cardIndex` refers to a DOM that no longer
    /// exists, so nothing may tap through them until live cards replace them.
    private(set) var isShowingCachedResults = false

    init(feed: FeedEngine? = nil,
         detail: DetailEngine? = nil,
         prefs: Preferences = .shared,
         metrics: MetricsReporter = LocalMetrics.shared,
         cache: ListingCache = .shared) {
        self.feed = feed ?? FeedEngine()
        self.detail = detail ?? DetailEngine()
        self.prefs = prefs
        self.metrics = metrics
        self.cache = cache
    }

    var feedState: FeedEngine.LoadState { feed.state }
    var canLoadMore: Bool { feed.canLoadMore }

    // MARK: - Searching

    func run(_ query: SearchQuery) async {
        self.query = query
        listings = []
        seenIDs = []
        health = ParseHealth()
        cancelPrefetch()

        // Last session's cards for this exact query, on the first frame. The
        // live load underneath takes 5.13s to produce anything; there is no
        // reason to show a skeleton for it when we know what was there.
        if let cached = cache.results(for: query) {
            listings = cached
            seenIDs = Set(cached.map(\.id))
            isShowingCachedResults = true
            isLoadingFirstPage = false
            Logger.store.info("restored \(cached.count) cards from cache")
        } else {
            isLoadingFirstPage = true
        }

        await feed.load(query)
        await ingest(await feed.extractCards())
        isLoadingFirstPage = false
        // Runs alongside `settle()`; both serialize on the feed webview's gate.
        startPrefetch()
        await settle()
        cache.saveResults(listings, for: query)
    }

    /// WebLite paints cards before it finishes filling them — an image, price
    /// and title arrive first, and the location line lands a beat later. So
    /// re-read the DOM a few times and merge in whatever showed up. Costs
    /// nothing: extraction is JavaScript against a page already loaded.
    private func settle() async {
        for delay in Self.settleDelays {
            try? await Task.sleep(for: delay)
            guard !listings.isEmpty else { return }
            await ingest(await feed.extractCards())
        }
    }

    /// Cumulative ~25s. WebLite fills a card's location line well after its
    /// photo, price and title are painted — later than feels reasonable, but
    /// re-reading is free, and stopping early is why locations went missing.
    private static let settleDelays: [Duration] = [
        .milliseconds(1200), .seconds(2), .seconds(4), .seconds(6), .seconds(6), .seconds(6)
    ]

    /// §3.1 — triggered when the user is a few rows from the end, never
    /// speculatively. One batch at a time (§7.3: one page ahead, maximum).
    func loadMoreIfNeeded(currentItem: Listing) async {
        guard !isLoadingMore, feed.canLoadMore,
              let index = listings.firstIndex(of: currentItem),
              index >= listings.count - 6 else { return }
        await loadMore()
    }

    func loadMore() async {
        guard !isLoadingMore, feed.canLoadMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if await feed.loadNextBatch() {
            await ingest(await feed.extractCards())
            try? await Task.sleep(for: .seconds(2))
            await ingest(await feed.extractCards())   // let the new batch finish filling in
        }
    }

    func retry() async {
        guard let query else { return }
        await run(query)
    }

    // MARK: - Ingestion

    /// Extraction returns every card in the DOM each time, so this is
    /// idempotent: known ids are skipped and only genuinely new cards append.
    private func ingest(_ raw: [FeedEngine.RawCard]) async {
        // The first live cards replace the restored ones outright rather than
        // merging into them. Merging would keep last session's `cardIndex`,
        // which now points at a different card — or at nothing — and a tap
        // would open the wrong listing. Detail already fetched isn't lost: it
        // comes back out of the profile cache below.
        //
        // The replacement is one assignment at the end, never a clear followed
        // by a refill. `listings` is `@Published` and the grid renders "Nothing
        // found nearby" on an empty array — so emptying it, even for an instant,
        // tears down the grid and pops any listing the user has open.
        let isReplacingCached = isShowingCachedResults && !raw.isEmpty
        // Worked out on a copy, so a replacement that turns out to yield nothing
        // (every card filtered, say) leaves the restored grid exactly as it was
        // rather than half-dismantling it.
        var seen = isReplacingCached ? Set<String>() : seenIDs

        var counts = ParseHealth()
        counts.domCards = raw.count

        var fresh: [Listing] = []
        for card in raw {
            guard let listing = CardParser.parse(card) else { continue }
            counts.extracted += 1
            counts.fieldCounts["title", default: 0] += listing.title != nil ? 1 : 0
            counts.fieldCounts["price", default: 0] += listing.priceText != nil ? 1 : 0
            counts.fieldCounts["thumbnail", default: 0] += listing.thumbnailURL != nil ? 1 : 0
            counts.fieldCounts["location", default: 0] += listing.locationText != nil ? 1 : 0

            guard !shouldFilter(listing) else {
                counts.dropped += 1
                continue
            }
            guard !seen.contains(listing.id) else {
                fillGaps(from: listing)
                continue
            }
            seen.insert(listing.id)
            // A card we've fully read before arrives already complete, so its
            // detail screen opens with everything on the first frame.
            var seeded = listing
            if let cached = cache.profile(for: listing.id) {
                seeded.detail = cached.detail
                seeded.itemURL = cached.itemURL
                if seeded.locationText == nil { seeded.locationText = cached.detail.locationText }
            }
            fresh.append(seeded)
        }

        if isReplacingCached {
            guard !fresh.isEmpty else { return }   // keep the restored grid
            isShowingCachedResults = false
            counts.rendered = fresh.count
            listings = fresh                       // one assignment, never empty
        } else {
            counts.rendered = listings.count + fresh.count
            listings.append(contentsOf: fresh)
        }
        seenIDs = seen
        health = counts
        metrics.parseHealth(counts)
    }

    /// §6.2 — filtering happens in Swift, after extraction, so the page's own
    /// scripts stay undisturbed and the rules are unit-testable.
    private func shouldFilter(_ listing: Listing) -> Bool {
        listing.badgeText?.lowercased() == "sponsored"
    }

    // MARK: - Detail

    // MARK: - Prefetch

    /// How many of the top cards to warm before they're tapped.
    ///
    /// Each one costs a real item-page fetch against Facebook, so this trades
    /// login-wall headroom for latency.
    ///
    /// Eight rather than three because the profile store makes repeat launches
    /// nearly free: anything already cached is skipped, so a second run of the
    /// same search only pays for cards it has never read.
    static let prefetchDepth = 8

    private var prefetchTask: Task<Void, Never>?
    /// The card currently being opened, as its own task. Unstructured, so
    /// cancelling the loop above stops it *scheduling more work* without
    /// killing the fetch already in progress — which is what lets a tap on
    /// this card ride along instead of starting the same work over.
    private var inFlight: (cardIndex: Int, task: Task<FeedEngine.ItemHarvest?, Never>)?

    /// Warms the top cards by opening them exactly the way a tap does, then
    /// caching the result. Serial by necessity — there is one feed webview and
    /// each open parks it on an item page for a couple of seconds.
    func startPrefetch(count: Int = ListingStore.prefetchDepth) {
        cancelPrefetch()
        let targets = Array(listings.prefix(count))
        guard !targets.isEmpty else { return }

        prefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let began = Date()
            var warmed = 0
            var skipped = 0
            for listing in targets {
                if Task.isCancelled { break }
                // Already on disk from an earlier session. Revalidation is the
                // tap's job — spending a fetch here would burn the traffic
                // budget on something the user may never open.
                if self.cache.profile(for: listing.id) != nil {
                    skipped += 1
                    continue
                }

                let cardStart = Date()
                let task = Task { @MainActor [weak self] in
                    await self?.feed.openItem(cardIndex: listing.cardIndex, onPartial: { _ in }) ?? nil
                }
                self.inFlight = (listing.cardIndex, task)
                let harvest = await task.value
                if self.inFlight?.cardIndex == listing.cardIndex { self.inFlight = nil }

                guard let harvest else { continue }
                self.record(Self.merging(listing, harvest))
                warmed += 1
                Logger.store.info("prefetch card \(listing.cardIndex) warm in \(String(format: "%.2f", Date().timeIntervalSince(cardStart)))s")
            }
            Logger.store.info("prefetch: \(warmed) warmed, \(skipped) already cached, of \(targets.count) in \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
            if let query = self.query { self.cache.saveResults(self.listings, for: query) }
        }
    }

    func cancelPrefetch() {
        prefetchTask?.cancel()
        inFlight?.task.cancel()
        inFlight = nil
        prefetchTask = nil
    }

    /// Opens a listing, in three steps:
    ///
    ///  1. The caller has already painted the card's own fields — price, title,
    ///     photo, city, condition — so the screen is never empty.
    ///  2. If we've fully read this listing before, that profile paints now,
    ///     from disk, on the first frame.
    ///  3. Either way we refetch it live. A cached profile is a head start, not
    ///     an answer: price drops and sold status are exactly the things that
    ///     change while a listing sits in a cache, and they're the things
    ///     someone opening a listing most needs to be right.
    ///
    /// `onStage` therefore fires up to three times. Every stage is built from
    /// the original card rather than accumulated, so a late partial can't
    /// interleave with an earlier one into a state neither of them described.
    func enrich(_ listing: Listing, onStage: @MainActor (Listing) -> Void = { _ in }) async -> Listing {
        let started = Date()
        var best = listing

        // A prefetch may be holding the feed webview. If it is fetching *this*
        // card, ride along — cancelling would throw away work already most of
        // the way to the answer. Stop the loop queueing more, but let it land.
        if let inFlight, inFlight.cardIndex == listing.cardIndex {
            prefetchTask?.cancel()
            if let harvest = await inFlight.task.value {
                self.inFlight = nil
                best = Self.merging(listing, harvest)
                record(best)
                onStage(best)
                Logger.store.info("tap -> joined in-flight prefetch in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                return best
            }
            self.inFlight = nil
        } else {
            // The user's tap outranks a guess about the user's tap.
            cancelPrefetch()
        }

        // Step 2 — the local profile store.
        if let cached = cache.profile(for: listing.id) {
            best.detail = cached.detail
            best.itemURL = best.itemURL ?? cached.itemURL
            if best.locationText == nil { best.locationText = cached.detail.locationText }
            apply(best)
            onStage(best)
            Logger.store.info("tap -> cache in \(String(format: "%.3f", Date().timeIntervalSince(started)))s (age \(Int(Date().timeIntervalSince(cached.fetchedAt)))s)")
        }

        // Step 3 — revalidate live, always.
        if let fresh = await fetchLive(best, startedAt: started, onStage: onStage) {
            best = fresh
        }
        return best
    }

    /// The live read, by whichever route can actually reach this listing.
    ///
    /// Tapping the card is faster and is what an ordinary open uses. But it
    /// needs a `cardIndex` that matches the DOM, which a restored card does not
    /// have — and it occupies the feed webview. When the canonical URL is
    /// already known, loading it directly sidesteps both problems, which is
    /// exactly the case for anything we've cached.
    private func fetchLive(_ listing: Listing,
                           startedAt started: Date,
                           onStage: @MainActor (Listing) -> Void) async -> Listing? {
        if let url = listing.itemURL {
            guard let detailValue = await detail.loadDetail(id: listing.id, url: url) else { return nil }
            var updated = listing
            updated.detail = detailValue
            if updated.locationText == nil { updated.locationText = detailValue.locationText }
            record(updated)
            onStage(updated)
            Logger.store.info("tap -> revalidated in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            return updated
        }

        // No URL yet, and the card index is only meaningful against live cards.
        guard !isShowingCachedResults else { return nil }

        if let harvest = await feed.openItem(cardIndex: listing.cardIndex,
                                             onPartial: { partial in
                                                 Logger.store.info("tap -> text in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                                                 onStage(Self.merging(listing, partial))
                                             }) {
            let updated = Self.merging(listing, harvest)
            metrics.detailLatency(seconds: Date().timeIntervalSince(started), succeeded: true)
            Logger.store.info("tap -> complete in \(String(format: "%.2f", Date().timeIntervalSince(started)))s (harvested in place)")
            record(updated)
            onStage(updated)
            return updated
        }

        // The tap didn't land. Fall back to searching the desktop surface for
        // the title and loading the item page separately — slower, needs a
        // 6-character title, and can pick wrong among ties, which is why it is
        // no longer the path anyone takes on purpose.
        var updated = listing
        updated.itemURL = await detail.resolveItemURL(for: listing, citySlug: prefs.locationSlug)
        guard let url = updated.itemURL else { return nil }
        guard let detailValue = await detail.loadDetail(id: updated.id, url: url) else { return nil }
        updated.detail = detailValue
        if updated.locationText == nil { updated.locationText = detailValue.locationText }
        record(updated)
        onStage(updated)
        return updated
    }

    /// Writes a fully-read listing to both the grid and the profile store.
    private func record(_ listing: Listing) {
        guard let detailValue = listing.detail else { return }
        cache.store(detailValue, itemURL: listing.itemURL, for: listing.id)
        apply(listing)
    }

    /// Folds a harvest onto the card the user tapped. Built from the original
    /// listing every time rather than accumulated, so a partial stage and the
    /// final one can't interleave into something neither of them said.
    private static func merging(_ listing: Listing, _ harvest: FeedEngine.ItemHarvest) -> Listing {
        var updated = listing
        updated.itemURL = harvest.url
        updated.detail = harvest.detail.listingDetail
        if updated.locationText == nil { updated.locationText = harvest.detail.locationText }
        return updated
    }

    /// §3.2's rule applied to the grid: never replace text that's already
    /// correct, only fill in what was missing when the card was first read.
    private func fillGaps(from parsed: Listing) {
        guard let index = listings.firstIndex(where: { $0.id == parsed.id }) else { return }
        var existing = listings[index]
        var changed = false

        if existing.locationText == nil, parsed.locationText != nil {
            existing.locationText = parsed.locationText
            changed = true
        }
        if existing.title == nil, parsed.title != nil {
            existing.title = parsed.title
            changed = true
        }
        if existing.badgeText == nil, parsed.badgeText != nil {
            existing.badgeText = parsed.badgeText
            changed = true
        }
        if existing.originalPriceText == nil, parsed.originalPriceText != nil {
            existing.originalPriceText = parsed.originalPriceText
            changed = true
        }
        if changed { listings[index] = existing }
    }

    private func apply(_ listing: Listing) {
        guard let index = listings.firstIndex(where: { $0.id == listing.id }) else { return }
        listings[index] = listing
    }
}
