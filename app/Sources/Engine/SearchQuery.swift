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

        // Facebook's radius parameter is kilometres, despite the UI showing miles.
        items.append(URLQueryItem(name: "radius", value: String(radiusKM)))
        if let coordinate {
            items.append(URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)))
            items.append(URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)))
        }
        components.queryItems = items
        return components.url!
    }

    static func categorySlug(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "")
    }

    static func kilometresToMiles(_ km: Int) -> Int {
        Int((Double(km) * 0.621371).rounded())
    }
}
