import Foundation

/// Matches a grid listing to a search result on the desktop surface.
///
/// The two surfaces describe the same listing differently: grid titles arrive
/// truncated ("Anthurium Red Gunsa"), while a desktop result card is one run of
/// text ("$38Anthurium Red GunsangSan Francisco, CA"). So matching is on a
/// normalised title *prefix* plus the price, and it refuses to guess — a wrong
/// item URL would send the user to someone else's listing, which is worse than
/// no link at all.
enum ItemMatcher {
    static func bestMatch(title: String?,
                          priceText: String?,
                          candidates: [DetailEngine.ItemCandidate]) -> String? {
        guard let title, !title.isEmpty else { return nil }
        let needle = normalize(title)
        guard needle.count >= 6 else { return nil }

        // Compare on a prefix: the grid's title is the truncated one.
        let prefix = String(needle.prefix(minimumPrefix))
        let priceNeedle = priceText.map(normalizePrice)

        var best: (id: String, score: Int)?
        for candidate in candidates {
            let haystack = normalize(candidate.text)
            guard haystack.contains(prefix) else { continue }

            var score = prefix.count
            // A matching price is strong corroboration when several listings
            // share a title, which is common for plants and furniture.
            if let priceNeedle, !priceNeedle.isEmpty,
               normalizePrice(candidate.text).contains(priceNeedle) {
                score += priceBonus
            }
            if best == nil || score > best!.score {
                best = (candidate.id, score)
            }
        }
        return best?.id
    }

    /// Enough characters that a match is meaningful, few enough that a
    /// truncated grid title still matches the full one.
    private static let minimumPrefix = 12
    private static let priceBonus = 20

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// "$1,200" and "$1200" should compare equal; "Free" survives as "free".
    static func normalizePrice(_ text: String) -> String {
        let lowered = text.lowercased()
        if lowered.contains("free") { return "free" }
        return lowered.filter { $0.isNumber }
    }
}
