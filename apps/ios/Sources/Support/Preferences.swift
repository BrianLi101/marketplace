import Foundation
import Combine

/// §3.1 recent pills, §5 settings, §6 content filtering. All small and
/// non-sensitive, so UserDefaults is the right store.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let recentSearches = "recentSearches"
        static let radiusKM = "radiusKM"
        static let hasSeenFirstRun = "hasSeenFirstRun"
        static let locationName = "locationName"
        static let locationSlug = "locationSlug"
        static let lastQueryKind = "lastQueryKind"
        static let lastQueryValue = "lastQueryValue"
        static let sortBy = "sortBy"
        static let deliveryMethod = "deliveryMethod"
        static let minPrice = "minPrice"
        static let maxPrice = "maxPrice"
        static let conditions = "itemConditions"
        static let hideViewed = "hideViewed"
    }

    private let defaults: UserDefaults

    @Published var recentSearches: [String] { didSet { defaults.set(recentSearches, forKey: Key.recentSearches) } }
    @Published var radiusKM: Int { didSet { defaults.set(radiusKM, forKey: Key.radiusKM) } }
    @Published var hasSeenFirstRun: Bool { didSet { defaults.set(hasSeenFirstRun, forKey: Key.hasSeenFirstRun) } }
    /// Human-readable place name for the UI ("San Francisco, CA").
    @Published var locationName: String? { didSet { defaults.set(locationName, forKey: Key.locationName) } }
    /// Facebook's city slug used in the search path ("sanfrancisco").
    @Published var locationSlug: String? { didSet { defaults.set(locationSlug, forKey: Key.locationSlug) } }
    /// The last thing the user looked at, so reopening the app lands them back
    /// there instead of on an empty screen.
    @Published private(set) var lastQueryKind: String? { didSet { defaults.set(lastQueryKind, forKey: Key.lastQueryKind) } }
    @Published private(set) var lastQueryValue: String? { didSet { defaults.set(lastQueryValue, forKey: Key.lastQueryValue) } }

    /// Both are applied server-side by Facebook, so changing either means
    /// re-running the search rather than re-sorting what's on screen.
    @Published var sort: SearchQuery.Sort { didSet { defaults.set(sort.rawValue, forKey: Key.sortBy) } }
    /// Defaults to local pickup: this is a local-browsing app, and shipping
    /// listings are the main thing that makes a result set stop being local.
    /// `local_pick_up` returned 15 results with 0 shipping against a default
    /// page where shipping was mixed in throughout.
    @Published var delivery: SearchQuery.Delivery { didSet { defaults.set(delivery.rawValue, forKey: Key.deliveryMethod) } }

    /// Nil means unbounded on that end. Stored as -1 rather than absent so a
    /// cleared bound is distinguishable from never having set one.
    @Published var minPrice: Int? { didSet { defaults.set(minPrice ?? -1, forKey: Key.minPrice) } }
    @Published var maxPrice: Int? { didSet { defaults.set(maxPrice ?? -1, forKey: Key.maxPrice) } }

    /// Comma-joined raw values, which is also the shape Facebook's own
    /// `itemCondition` parameter takes.
    @Published var conditions: [SearchQuery.Condition] {
        didSet { defaults.set(conditions.map(\.rawValue).joined(separator: ","), forKey: Key.conditions) }
    }

    /// Hide listings the user has already opened (`ViewedListings`).
    ///
    /// Unlike everything above it, this one is ours: it is applied on device,
    /// against a record Facebook doesn't keep, and there is no parameter that
    /// would ask for it. Off by default — it is a way to re-scan a search you
    /// have already been through, not the normal way to browse.
    @Published var hideViewed: Bool { didSet { defaults.set(hideViewed, forKey: Key.hideViewed) } }

    static let maxRecentSearches = 12

    /// Kilometres, chosen so each one is a round number of *miles* — the unit
    /// the UI shows and the one people think in. 16 km is 10 mi, 32 is 20, and
    /// so on. The old ladder was round in kilometres and consequently showed
    /// "6 mi" and "62 mi".
    static let radiusOptions = [2, 3, 8, 16, 32, 64, 161]   // 1, 2, 5, 10, 20, 40, 100 mi

    /// 10 miles. An opinionated default for a local-browsing app: far enough to
    /// find things, close enough that collecting them is still plausible.
    static let defaultRadiusKM = 16

    static let suggestedCategories = ["Furniture", "Electronics", "Free Stuff", "Bikes", "Tools"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentSearches = defaults.stringArray(forKey: Key.recentSearches) ?? []
        // Snap to the nearest rung. The ladder changed from round kilometres to
        // round miles, so a value stored under the old one — 20, say — matches
        // no option and would leave the distance control showing nothing
        // selected.
        let storedRadius = defaults.object(forKey: Key.radiusKM) as? Int ?? Self.defaultRadiusKM
        radiusKM = Self.radiusOptions.contains(storedRadius)
            ? storedRadius
            : Self.radiusOptions.min(by: { abs($0 - storedRadius) < abs($1 - storedRadius) })
                ?? Self.defaultRadiusKM
        hasSeenFirstRun = defaults.bool(forKey: Key.hasSeenFirstRun)
        locationName = defaults.string(forKey: Key.locationName)
        // Drop a stored slug that is no longer offered. Five of the cities this
        // app used to list are not places Facebook recognises, and a rejected
        // slug doesn't fail — it silently serves the IP-inferred city
        // (`docs/location-targeting.md` §1). Removing them from the picker left
        // anyone who had one selected still sending it on every search, with
        // the sheet now showing a *different* city than the one being queried.
        let storedSlug = defaults.string(forKey: Key.locationSlug)
        if let storedSlug, MarketplaceCity.named(storedSlug) == nil {
            locationSlug = nil
            locationName = nil
        } else {
            locationSlug = storedSlug
        }
        lastQueryKind = defaults.string(forKey: Key.lastQueryKind)
        lastQueryValue = defaults.string(forKey: Key.lastQueryValue)
        sort = defaults.string(forKey: Key.sortBy)
            .flatMap(SearchQuery.Sort.init(rawValue:)) ?? .bestMatch
        delivery = defaults.string(forKey: Key.deliveryMethod)
            .flatMap(SearchQuery.Delivery.init(rawValue:)) ?? .localPickup
        let storedMin = defaults.object(forKey: Key.minPrice) as? Int ?? -1
        let storedMax = defaults.object(forKey: Key.maxPrice) as? Int ?? -1
        minPrice = storedMin >= 0 ? storedMin : nil
        maxPrice = storedMax >= 0 ? storedMax : nil
        conditions = (defaults.string(forKey: Key.conditions) ?? "")
            .split(separator: ",")
            .compactMap { SearchQuery.Condition(rawValue: String($0)) }
        hideViewed = defaults.bool(forKey: Key.hideViewed)
    }

    /// Back to the app's opinionated defaults, not to "no filters at all" —
    /// local pickup and a 10-mile radius are the product's position on what a
    /// local marketplace browser should show, so Reset restores them rather
    /// than clearing them.
    func resetFilters() {
        sort = .bestMatch
        delivery = .localPickup
        radiusKM = Self.defaultRadiusKM
        minPrice = nil
        maxPrice = nil
        conditions = []
        hideViewed = false
    }

    /// Whether anything differs from those defaults — drives the dot on the
    /// Filters button.
    var hasNonDefaultFilters: Bool {
        sort != .bestMatch
            || delivery != .localPickup
            || radiusKM != Self.defaultRadiusKM
            || minPrice != nil
            || maxPrice != nil
            || !conditions.isEmpty
            || hideViewed
    }

    /// Remembers what to reopen on. Categories are remembered too — browsing
    /// "Free Stuff" is just as much "where I was" as typing a search.
    func recordLastQuery(_ kind: SearchQuery.Kind) {
        switch kind {
        case .search(let term):
            lastQueryKind = "search"
            lastQueryValue = term
        case .category(let name):
            lastQueryKind = "category"
            lastQueryValue = name
        }
    }

    var lastQuery: SearchQuery.Kind? {
        guard let lastQueryValue, !lastQueryValue.isEmpty else { return nil }
        switch lastQueryKind {
        case "search": return .search(lastQueryValue)
        case "category": return .category(lastQueryValue)
        default: return nil
        }
    }

    func clearLastQuery() {
        lastQueryKind = nil
        lastQueryValue = nil
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

}
