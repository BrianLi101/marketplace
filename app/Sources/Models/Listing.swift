import Foundation

/// A card as it appears in the results grid.
///
/// The mobile surface exposes no listing id on the grid (see
/// docs/feasibility-2026-07-31.md), so identity comes from the photo FBID
/// embedded in the thumbnail CDN URL, with a title+price hash as fallback.
/// The canonical `itemURL` is resolved lazily, when the user opens the listing.
struct Listing: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var title: String?
    var priceText: String?      // kept as displayed: "Free", "$1,200", ranges
    var originalPriceText: String?
    var locationText: String?   // usually nil on mobile cards; detail fills it in
    var thumbnailURL: URL?
    var itemURL: URL?           // nil until resolved by tapping through
    var badgeText: String?      // "Price drop", "Sold", …
    var cardIndex: Int          // position in the DOM, used to re-find the card
    var detail: ListingDetail?
    var capturedAt: Date

    var isResolved: Bool { itemURL != nil }
}

struct ListingDetail: Codable, Equatable, Hashable {
    var description: String?
    var photoURLs: [URL] = []
    var postedText: String?
    var conditionText: String?
    var locationText: String?
    var sellerName: String?
}

extension Listing {
    /// Stable-enough identity for dedupe and the hidden-listings list.
    static func identity(thumbnailURL: URL?, title: String?, priceText: String?) -> String {
        if let fbid = thumbnailURL.flatMap(Self.photoFBID) { return "p:\(fbid)" }
        return "h:\((title ?? "") + "|" + (priceText ?? ""))".lowercased()
    }

    /// fbcdn filenames look like `729964685_1105285382678938_1161471387555069882_n.jpg`;
    /// the middle group is the photo's FBID and is stable for the listing.
    static func photoFBID(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_")
        guard parts.count >= 2 else { return nil }
        let candidate = String(parts[1])
        return candidate.allSatisfy(\.isNumber) && candidate.count >= 10 ? candidate : nil
    }
}
