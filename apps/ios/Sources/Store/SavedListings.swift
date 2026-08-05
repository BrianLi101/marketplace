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

    @Published private(set) var ids: Set<String> = []

    private let defaults: UserDefaults
    private static let key = "savedListingIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        defaults.set(Array(ids), forKey: Self.key)
    }
}
