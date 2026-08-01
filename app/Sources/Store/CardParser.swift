import Foundation

/// Turns WebLite's raw text runs into `Listing` values.
///
/// Cards carry no labels — just an image and a couple of text blocks — so
/// fields are identified by pattern rather than position, and every one of them
/// is optional (§2.2: a card missing a field still renders).
enum CardParser {
    /// Badges Facebook overlays on the thumbnail. They arrive mixed into the
    /// card text and would otherwise be mistaken for a title.
    static let knownBadges = ["price drop", "just listed", "sold", "pending", "sponsored", "free shipping"]

    static func parse(_ card: FeedEngine.RawCard, now: Date = Date()) -> Listing? {
        let runs = normalizedRuns(card)
        guard !runs.isEmpty else { return nil }

        let badge = runs.first { knownBadges.contains($0.lowercased()) }
        let remaining = runs.filter { $0 != badge }

        let priceRuns = remaining.filter(isPrice)
        let price = priceRuns.first
        // A struck-through original price follows the current one ("$25" "$40").
        let originalPrice = priceRuns.count > 1 ? priceRuns[1] : nil

        let title = remaining
            .filter { !isPrice($0) && !isLocation($0) }
            .max(by: { $0.count < $1.count })

        let location = remaining.first(where: isLocation)
        let thumbnail = card.imageURL.flatMap(URL.init(string:))

        // A card with neither a price nor a title is chrome, not a listing.
        guard price != nil || title != nil else { return nil }

        return Listing(
            id: Listing.identity(thumbnailURL: thumbnail, title: title, priceText: price),
            title: title,
            priceText: price,
            originalPriceText: originalPrice,
            locationText: location,
            thumbnailURL: thumbnail,
            itemURL: nil,
            badgeText: badge,
            cardIndex: card.index,
            detail: nil,
            capturedAt: now
        )
    }

    /// The h3 runs are reliable; `fullText` is the fallback when a card's text
    /// isn't split into headings at all.
    private static func normalizedRuns(_ card: FeedEngine.RawCard) -> [String] {
        let fromHeadings = card.texts
            .flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !fromHeadings.isEmpty { return fromHeadings }
        return card.fullText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// "Free", "$1,200", "£40", "€15", "Please contact" — all stay strings (§2.3).
    static func isPrice(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered == "free" { return true }
        guard text.count <= 24 else { return false }
        let symbols: Set<Character> = ["$", "£", "€", "¥", "₹", "₩"]
        return text.contains(where: symbols.contains) && text.contains(where: \.isNumber)
    }

    /// Mobile cards usually omit location, but when present it looks like
    /// "Berkeley, CA".
    static func isLocation(_ text: String) -> Bool {
        guard text.count <= 40, text.contains(",") else { return false }
        let parts = text.split(separator: ",")
        guard parts.count == 2 else { return false }
        let region = parts[1].trimmingCharacters(in: .whitespaces)
        return region.count <= 3 && region.allSatisfy { $0.isUppercase }
    }
}
