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
    }

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
            guard !seenIDs.contains(listing.id) else { continue }
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
        if prefs.hiddenListingIDs.contains(listing.id) { return true }
        if listing.badgeText?.lowercased() == "sponsored" { return true }
        let haystack = [listing.title, listing.priceText]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return prefs.blockedKeywords.contains { !$0.isEmpty && haystack.contains($0) }
    }

    // MARK: - Detail

    /// Resolves the canonical URL (by clicking the card in the hidden feed) and
    /// then loads the detail page. Both steps are lazy: nothing happens for
    /// listings the user never opens.
    func enrich(_ listing: Listing) async -> Listing {
        var updated = listing

        if updated.itemURL == nil {
            updated.itemURL = await feed.resolveItemURL(cardIndex: listing.cardIndex)
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

    private func apply(_ listing: Listing) {
        guard let index = listings.firstIndex(where: { $0.id == listing.id }) else { return }
        listings[index] = listing
    }

    func hide(_ listing: Listing) {
        prefs.hide(listing.id)
        listings.removeAll { $0.id == listing.id }
    }
}
