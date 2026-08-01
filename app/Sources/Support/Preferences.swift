import Foundation
import Combine

/// §3.1 recent pills, §5 settings, §6 content filtering. All small and
/// non-sensitive, so UserDefaults is the right store.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let recentSearches = "recentSearches"
        static let blockedKeywords = "blockedKeywords"
        static let hiddenListings = "hiddenListings"
        static let radiusKM = "radiusKM"
        static let hasSeenFirstRun = "hasSeenFirstRun"
        static let locationName = "locationName"
        static let locationSlug = "locationSlug"
    }

    private let defaults: UserDefaults

    @Published var recentSearches: [String] { didSet { defaults.set(recentSearches, forKey: Key.recentSearches) } }
    @Published var blockedKeywords: [String] { didSet { defaults.set(blockedKeywords, forKey: Key.blockedKeywords) } }
    @Published var hiddenListingIDs: Set<String> { didSet { defaults.set(Array(hiddenListingIDs), forKey: Key.hiddenListings) } }
    @Published var radiusKM: Int { didSet { defaults.set(radiusKM, forKey: Key.radiusKM) } }
    @Published var hasSeenFirstRun: Bool { didSet { defaults.set(hasSeenFirstRun, forKey: Key.hasSeenFirstRun) } }
    /// Human-readable place name for the UI ("San Francisco, CA").
    @Published var locationName: String? { didSet { defaults.set(locationName, forKey: Key.locationName) } }
    /// Facebook's city slug used in the search path ("sanfrancisco").
    @Published var locationSlug: String? { didSet { defaults.set(locationSlug, forKey: Key.locationSlug) } }

    static let maxRecentSearches = 12
    static let radiusOptions = [2, 5, 10, 20, 40, 65, 100, 250]  // km; Facebook's own ladder
    static let suggestedCategories = ["Furniture", "Electronics", "Free Stuff", "Bikes", "Tools"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentSearches = defaults.stringArray(forKey: Key.recentSearches) ?? []
        blockedKeywords = defaults.stringArray(forKey: Key.blockedKeywords) ?? []
        hiddenListingIDs = Set(defaults.stringArray(forKey: Key.hiddenListings) ?? [])
        radiusKM = defaults.object(forKey: Key.radiusKM) as? Int ?? 10
        hasSeenFirstRun = defaults.bool(forKey: Key.hasSeenFirstRun)
        locationName = defaults.string(forKey: Key.locationName)
        locationSlug = defaults.string(forKey: Key.locationSlug)
    }

    func recordSearch(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        next.insert(trimmed, at: 0)
        recentSearches = Array(next.prefix(Self.maxRecentSearches))
    }

    func removeSearch(_ term: String) {
        recentSearches.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
    }

    func hide(_ id: String) { hiddenListingIDs.insert(id) }
    func unhideAll() { hiddenListingIDs.removeAll() }

    func addKeyword(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !blockedKeywords.contains(trimmed) else { return }
        blockedKeywords.append(trimmed)
    }
}
