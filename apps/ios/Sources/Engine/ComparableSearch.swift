import Foundation
import WebKit
import os

extension Logger {
    static let seller = Logger(subsystem: "com.brianli101.marketplace", category: "seller")
}

/// One listing being used as evidence about price.
struct MarketComp: Identifiable, Equatable {
    var listing: Listing
    /// Whole dollars, parsed from the displayed price. Nil when the card had no
    /// readable price at all.
    var price: Int?
    /// Seller-marked, so it means "no longer for sale", not "sold for this".
    var isSold: Bool
    var postedAt: Date?

    var id: String { listing.id }

    init(payload: PayloadListing, cardIndex: Int) {
        listing = payload.makeListing(cardIndex: cardIndex)
        price = PriceGuide.parse(payload.priceFormatted)
        isSold = payload.isSold == true
        postedAt = payload.postedAt

        // The numeric field is not used (see `PriceGuide.parse`), but a
        // disagreement with the text is worth knowing about, and this is the
        // one place both are in hand. Costs nothing and turns an assumption
        // about Facebook's units into a measurement the first time anyone
        // sells something.
        if let price, let amount = payload.price {
            let numeric = NSDecimalNumber(decimal: amount).intValue
            if numeric != price {
                Logger.seller.info("price fields disagree: formatted \(price, privacy: .public) vs amount \(numeric, privacy: .public)")
            }
        }
    }

    init(listing: Listing) {
        self.listing = listing
        price = PriceGuide.parse(listing.priceText)
        isSold = listing.badgeText?.lowercased() == "sold"
        postedAt = nil
    }
}

/// Runs the market search behind the seller tab.
///
/// **Its own engine, deliberately.** Sharing the browse tab's `DesktopFeedEngine`
/// would mean drafting a listing navigated the results the user was reading out
/// from under them — same webview, same DOM — and `loadMore` would then be
/// paging a search nobody asked for. A second engine costs one more idle
/// webview and keeps the two tabs independent.
///
/// It does *not* cost extra request budget: `RequestPacer` is a shared actor,
/// so this engine's loads count against the same session cap and obey the same
/// backoff as every other request the app makes.
///
/// **One page load per draft, and no item pages.** Comparables are read from
/// the search results only — title, price, photo, city. Opening fifteen item
/// pages to price a dresser is exactly the automation-shaped traffic the app
/// removed everywhere else (`docs/decision-desktop-primary.md`). If the user
/// taps a comparable, that opens it, because a person asked.
@MainActor
final class ComparableSearch {
    enum Failure: Error, Equatable {
        /// Facebook wants a session before it will show anything.
        case loginWall
        /// The search ran and returned nothing to compare against.
        case nothingFound
        /// The load failed, or the pacer refused it. Carries the engine's own
        /// message, which already distinguishes the two.
        case engine(String)
    }

    private let engine: DesktopFeedEngine

    /// Has to be in the view hierarchy for WebKit to render it — see
    /// `RootView`. Same constraint as the browse engines.
    var webView: WKWebView { engine.webView }

    init(engine: DesktopFeedEngine? = nil) {
        self.engine = engine ?? DesktopFeedEngine()
    }

    /// The first page of results for a term, as evidence.
    ///
    /// Filters are the app's own rather than the browse tab's, and that is a
    /// correctness point, not tidiness: someone browsing with "over $100" set
    /// would otherwise get a price guide computed from a corpus that excludes
    /// everything cheap, and it would read as the market rather than as their
    /// filter. Local pickup stays on — a private seller with a dresser is
    /// competing with other people's dressers in the same city, not with
    /// shipped ones.
    func comparables(to term: String,
                     citySlug: String,
                     radiusKM: Int,
                     limit: Int = 15) async -> Result<[MarketComp], Failure> {
        let query = SearchQuery(
            kind: .search(term),
            // Sent for shape only; no surface honours it (`SearchQuery.url`).
            radiusKM: radiusKM == 0 ? 40 : radiusKM,
            citySlug: citySlug,
            coordinate: nil,
            sort: .bestMatch,
            delivery: .localPickup
        )

        let payload = await engine.load(query)
        if case .loginWall = engine.state { return .failure(.loginWall) }

        var comps = payload.prefix(limit).enumerated().map { index, item in
            MarketComp(payload: item, cardIndex: index)
        }

        // The payload is absent often enough to plan for — a page served
        // entirely client-side renders cards with no embedded listing block at
        // all. The markup carries titles and prices, which is all this needs.
        if comps.isEmpty {
            comps = await engine.renderedCards().enumerated()
                .compactMap { index, card in DesktopCardParser.parse(card, cardIndex: index) }
                .prefix(limit)
                .map(MarketComp.init(listing:))
        }

        guard !comps.isEmpty else {
            if case .failed(let message) = engine.state { return .failure(.engine(message)) }
            return .failure(.nothingFound)
        }
        Logger.seller.info("comps for \(term, privacy: .public): \(comps.count, privacy: .public)")
        return .success(comps)
    }
}
