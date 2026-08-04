import Foundation
import SwiftUI

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
    private var seenIDs = Set<String>()

    init(feed: FeedEngine? = nil,
         detail: DetailEngine? = nil,
         prefs: Preferences = .shared,
         metrics: MetricsReporter = LocalMetrics.shared) {
        self.feed = feed ?? FeedEngine()
        self.detail = detail ?? DetailEngine()
        self.prefs = prefs
        self.metrics = metrics
    }

    var feedState: FeedEngine.LoadState { feed.state }
    var canLoadMore: Bool { feed.canLoadMore }

    // MARK: - Searching

    func run(_ query: SearchQuery) async {
        self.query = query
        isLoadingFirstPage = true
        listings = []
        seenIDs = []
        health = ParseHealth()

        await feed.load(query)
        await ingest(await feed.extractCards())
        isLoadingFirstPage = false
        await settle()
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
            guard !seenIDs.contains(listing.id) else {
                fillGaps(from: listing)
                continue
            }
            seenIDs.insert(listing.id)
            fresh.append(listing)
        }

        counts.rendered = listings.count + fresh.count
        health = counts
        metrics.parseHealth(counts)
        listings.append(contentsOf: fresh)
    }

    /// §6.2 — filtering happens in Swift, after extraction, so the page's own
    /// scripts stay undisturbed and the rules are unit-testable.
    private func shouldFilter(_ listing: Listing) -> Bool {
        listing.badgeText?.lowercased() == "sponsored"
    }

    // MARK: - Detail

    /// Resolves the canonical item URL, then loads the detail page. Both steps
    /// are lazy: nothing happens for listings the user never opens.
    func enrich(_ listing: Listing) async -> Listing {
        var updated = listing

        if updated.itemURL == nil {
            // Tapping the card in the hidden feed resolves the id client-side
            // and costs no page load at all. The desktop title search stays as
            // a fallback for cards the tap can't reach — it's slower, needs a
            // 6-character title, and can pick wrong among ties.
            var resolved = await feed.resolveItemURL(cardIndex: listing.cardIndex)
            if resolved == nil {
                resolved = await detail.resolveItemURL(for: listing, citySlug: prefs.locationSlug)
            }
            updated.itemURL = resolved
            apply(updated)
        }
        guard let url = updated.itemURL else { return updated }

        if let detailValue = await detail.loadDetail(id: updated.id, url: url) {
            updated.detail = detailValue
            // §3.2 — never replace text that's already correct; only fill gaps.
            if updated.locationText == nil { updated.locationText = detailValue.locationText }
            apply(updated)
        }
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
