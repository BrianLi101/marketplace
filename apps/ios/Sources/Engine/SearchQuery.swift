import Foundation
import CoreLocation

/// §6.1 — pin the radius by rewriting query params rather than driving
/// Facebook's own filter UI, which changes shape constantly.
struct SearchQuery: Equatable {
    enum Kind: Equatable {
        case search(String)
        case category(String)
    }

    var kind: Kind
    var radiusKM: Int
    var citySlug: String
    var coordinate: CLLocationCoordinate2D?

    static func == (lhs: SearchQuery, rhs: SearchQuery) -> Bool {
        lhs.kind == rhs.kind && lhs.radiusKM == rhs.radiusKM && lhs.citySlug == rhs.citySlug
            && lhs.coordinate?.latitude == rhs.coordinate?.latitude
            && lhs.coordinate?.longitude == rhs.coordinate?.longitude
    }

    var displayName: String {
        switch kind {
        case .search(let term): return term
        case .category(let name): return name
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.facebook.com"

        var items: [URLQueryItem] = []
        switch kind {
        case .search(let term):
            components.path = "/marketplace/\(citySlug)/search/"
            items.append(URLQueryItem(name: "query", value: term))
        case .category(let name):
            components.path = "/marketplace/\(citySlug)/\(Self.categorySlug(name))/"
        }

        // Kilometres, despite the UI showing miles — but this does not filter
        // anything. Mobile strips the parameter outright, and desktop only
        // updates its own chip: `radius=8` and `radius=161` return the same 15
        // listings, and a "Within 5 mi" search still comes back with results
        // 60 mi out. Kept because it costs nothing and is the shape Facebook
        // expects; radius has to be enforced client-side against the
        // per-listing coordinates. See docs/filter-parameters.md §3.
        items.append(URLQueryItem(name: "radius", value: String(radiusKM)))

        // No latitude/longitude: the city slug already anchors the search, and
        // the user's coordinate is only needed locally, to compute distances.
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    static func categorySlug(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "")
    }

    static func kilometresToMiles(_ km: Int) -> Int {
        Int((Double(km) * 0.621371).rounded())
    }
}
