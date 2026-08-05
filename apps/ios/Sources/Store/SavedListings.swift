import Foundation
import SwiftUI

/// The listings the user deliberately kept.
///
/// Keyed on `Listing.id`, which is the photo FBID pulled out of the thumbnail
/// CDN URL (`Listing.identity`). That key is the reason a save made on the
/// detail screen shows up on the search grid without either side coordinating:
/// both already identify a listing the same way, and the id survives the card
/// being re-parsed from a fresh DOM on a later search.
///
/// Small, non-sensitive, and user data rather than cache — so it lives in
/// UserDefaults, and unlike `ListingCache` nothing here is ever evicted.
@MainActor
final class SavedListings: ObservableObject {
    static let shared = SavedListings()

    /// Ordered, most recently saved first — this is the home screen's running
    /// order, and a `Set` would reshuffle it on every launch.
    @Published private(set) var ids: [String] = []

    /// Membership is checked once per card on every grid render, so it doesn't
    /// go through the array.
    private var index: Set<String> = []

    private let defaults: UserDefaults
    private static let key = "savedListingIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = defaults.stringArray(forKey: Self.key) ?? []
        index = Set(ids)
    }

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: String) -> Bool { index.contains(id) }

    func toggle(_ id: String) {
        if index.contains(id) {
            index.remove(id)
            ids.removeAll { $0 == id }
        } else {
            index.insert(id)
            ids.insert(id, at: 0)
        }
        defaults.set(ids, forKey: Self.key)
    }
}
