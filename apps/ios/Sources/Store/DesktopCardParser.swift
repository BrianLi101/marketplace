import Foundation

/// One rendered desktop card, before classification.
struct DesktopRawCard: Decodable {
    let id: String
    let label: String
    let imageURL: String
    let text: String
}

/// Turns a desktop card's `aria-label` into a listing.
///
/// The label is the whole reason the markup-only tail is usable. Desktop packs
/// title, price, an optional was-price, city and the listing id into one
/// string:
///
///     "Black L-Shaped Corner Desk with Monitor Shelf, $40, San Francisco, CA, listing 1054280080442808"
///     "Wooden writing desk with gray hutch, $50, reduced from $70, San Francisco, CA, listing 1624050395351390"
///     "Office desk, $80, , listing 2508057202946956"          <- shipping: city segment empty
///
/// Parsing is in Swift rather than JavaScript so the rules are testable outside
/// a webview (§6.2), and it works from the *end* backwards because the title is
/// the only field that can itself contain commas.
enum DesktopCardParser {

    static func parse(_ raw: DesktopRawCard, cardIndex: Int) -> Listing? {
        var segments = raw.label
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard segments.count >= 2 else { return nil }

        // Trailing "listing <id>" — present on every real card, and its absence
        // means this anchor is something else entirely.
        guard let last = segments.last, last.hasPrefix("listing ") else { return nil }
        segments.removeLast()

        // An empty city segment is a shipping listing: desktop leaves the slot
        // in place rather than omitting it, which is a cleaner signal than
        // guessing from the absence of a comma.
        var locationText: String?
        var shipsOnly = false
        if let city = segments.last {
            if city.isEmpty {
                shipsOnly = true
                segments.removeLast()
            } else if city.count == 2, city.uppercased() == city, segments.count >= 2 {
                // "San Francisco", "CA" split across two segments — rejoin.
                let state = segments.removeLast()
                let name = segments.removeLast()
                locationText = "\(name), \(state)"
            } else {
                locationText = segments.removeLast()
            }
        }

        // Optional "reduced from $70", then the current price.
        var originalPriceText: String?
        if let candidate = segments.last, candidate.hasPrefix("reduced from ") {
            originalPriceText = String(candidate.dropFirst("reduced from ".count))
            segments.removeLast()
        }

        // Case-insensitive on "free" because the surfaces disagree: a search
        // result's label says "Free", the browse feed's says "FREE". Matching
        // one spelling left the other unparsed, and a free listing then
        // rendered with an em dash for a price and the word FREE stuck on the
        // end of its title.
        var priceText: String?
        if let candidate = segments.last,
           candidate.hasPrefix("$") || candidate.caseInsensitiveCompare("free") == .orderedSame {
            priceText = candidate
            segments.removeLast()
        }

        // Whatever is left is the title, commas and all.
        let title = segments.joined(separator: ", ")
        guard !title.isEmpty else { return nil }

        let thumbnail = raw.imageURL.isEmpty ? nil : URL(string: raw.imageURL)

        return Listing(
            // Photo identity where possible, so a desktop card and a mobile
            // card for the same listing collide rather than duplicating
            // (docs/surface-strategy.md §5a). Falls back to the listing id,
            // which desktop always has and mobile never does.
            id: thumbnail.flatMap(Listing.photoFBID).map { "p:\($0)" } ?? "fb:\(raw.id)",
            title: title,
            priceText: priceText,
            originalPriceText: originalPriceText,
            locationText: locationText,
            conditionText: nil,
            thumbnailURL: thumbnail,
            itemURL: URL(string: "https://www.facebook.com/marketplace/item/\(raw.id)/"),
            badgeText: shipsOnly ? "Ships" : nil,
            cardIndex: cardIndex,
            detail: nil,
            capturedAt: Date()
        )
    }
}
