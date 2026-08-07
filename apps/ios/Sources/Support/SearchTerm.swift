import Foundation

/// Turns what a seller typed into something worth searching for.
///
/// People describe what they're selling; they don't phrase it as a query. "IKEA
/// Malm 6 drawer dresser, white, barely used, from a pet-free home" searched
/// literally finds nothing, because no other listing says that. What the
/// comparables have in common is the two or three words naming the *kind of
/// thing*, so that is what this keeps.
///
/// Not clever, and it doesn't need to be: dropping filler and keeping the first
/// few content words gets "ikea malm dresser white" out of a sentence about a
/// dresser, which is a searchable term. Measured against the on-device model
/// doing the same job, it produced the same query on the cases tried.
///
/// This was the model's first task, and it is the only one that survived it
/// being taken out — see `SellerToolsModel`. The term is shown in the transcript
/// either way, so a bad one is visible to the person best placed to notice.
enum SearchTerm {
    /// Words that describe the seller or the condition rather than the thing.
    /// Condition words go too: comparables are found by what an item *is*, and
    /// "used" or "like new" narrow the search without narrowing the market.
    private static let filler: Set<String> = [
        "a", "an", "the", "my", "our", "i", "im", "am", "is", "are", "was", "for",
        "sale", "selling", "sell", "with", "and", "in", "of", "very", "really",
        "great", "good", "nice", "condition", "used", "new", "barely", "hardly",
        "like", "excellent", "perfect", "mint", "some", "few", "little", "bit",
        "from", "home", "house", "smoke", "pet", "free", "no", "not", "it", "its",
    ]

    static func from(_ item: String) -> String {
        let words = item
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !filler.contains($0) }
        guard !words.isEmpty else {
            return item.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Four is enough to identify a thing and few enough that Facebook's
        // search still matches something. Longer queries return nothing at all
        // rather than fewer results.
        return words.prefix(4).joined(separator: " ")
    }
}
