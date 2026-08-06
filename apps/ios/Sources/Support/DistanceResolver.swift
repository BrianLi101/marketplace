import Foundation
import CoreLocation

/// Turns a listing's "Berkeley, CA" into "~6 mi away".
///
/// Facebook never gives a coordinate per listing, only a place name, so this
/// geocodes the *place* (not the listing) once and caches the result across
/// launches. Cities repeat constantly across listings, so a session's browsing
/// costs a handful of lookups. Distances are approximate by construction —
/// city centre to user — which the "~" is there to admit.
///
/// Geocoding and the user's location arrive independently and in either order,
/// so neither one gates the other: places are resolved whenever they're seen,
/// and a distance appears once both halves exist.
@MainActor
final class DistanceResolver: ObservableObject {
    static let shared = DistanceResolver()

    @Published private(set) var placeCoordinates: [String: [Double]] {
        didSet { UserDefaults.standard.set(placeCoordinates, forKey: Self.cacheKey) }
    }
    @Published private(set) var userLocation: CLLocation?

    private var queued: [String] = []
    private var known: Set<String> = []     // queued, resolved, or given up on
    private var isDraining = false
    private var failed: Set<String> = []
    private let geocoder = CLGeocoder()
    private static let cacheKey = "placeCoordinates"

    /// CLGeocoder handles one request at a time and throttles bursts, so
    /// lookups are queued and spaced rather than fired per visible card.
    private static let gapBetweenLookups = Duration.milliseconds(250)

    init() {
        placeCoordinates = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: [Double]] ?? [:]
    }

    func setUserLocation(_ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else { return }
        userLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// The geocoded centre of a place name, once resolved. This is a city or
    /// neighbourhood centroid, never the listing itself — Facebook only ever
    /// says "Location is approximate".
    func coordinate(for place: String?) -> CLLocationCoordinate2D? {
        guard let key = normalize(place),
              let pair = placeCoordinates[key], pair.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
    }

    /// Formatted distance, or nil until both the place and the user are known.
    func distanceText(for place: String?) -> String? {
        guard let key = normalize(place),
              let pair = placeCoordinates[key], pair.count == 2 else { return nil }
        return distanceText(to: CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1]))
    }

    /// Distance to a coordinate the listing itself supplied. Item pages publish
    /// an approximate point per listing, which is a much better anchor than the
    /// city centroid above — same formatting, so the two are interchangeable at
    /// the call site and the caller just passes the better one when it has it.
    func distanceText(to coordinate: CLLocationCoordinate2D) -> String? {
        guard let userLocation else { return nil }
        let metres = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: userLocation)
        let miles = metres / 1609.34
        if miles < 1 { return "under 1 mi" }
        return "~\(Int(miles.rounded())) mi"
    }

    /// Kilometres to a listing, preferring its own approximate point over the
    /// centroid of its city.
    ///
    /// Returns nil when the answer isn't known yet — the user has no fix, or
    /// the place hasn't been geocoded. Callers filtering on distance must treat
    /// that as "keep", never "hide": geocoding is asynchronous, and hiding on
    /// missing data makes listings vanish and reappear as the queue drains.
    func distanceKM(for place: String?, coordinate: CLLocationCoordinate2D? = nil) -> Double? {
        guard let userLocation else { return nil }
        let point: CLLocationCoordinate2D?
        if let coordinate {
            point = coordinate
        } else {
            point = self.coordinate(for: place)
        }
        guard let point else { return nil }
        let metres = CLLocation(latitude: point.latitude, longitude: point.longitude)
            .distance(from: userLocation)
        return metres / 1000
    }

    /// Safe to call from a card's `task` on every render — repeats and
    /// already-known places are no-ops. Deliberately does *not* require the
    /// user's location, so places seen before the GPS fix still get resolved.
    func resolve(place: String?) {
        guard let key = normalize(place),
              placeCoordinates[key] == nil,
              !known.contains(key) else { return }
        known.insert(key)
        queued.append(key)
        drain()
    }

    private func drain() {
        guard !isDraining else { return }
        isDraining = true
        Task {
            defer { isDraining = false }
            while !queued.isEmpty {
                let key = queued.removeFirst()
                if let placemarks = try? await geocoder.geocodeAddressString(key),
                   let location = placemarks.first?.location {
                    placeCoordinates[key] = [location.coordinate.latitude, location.coordinate.longitude]
                } else {
                    failed.insert(key)  // don't retry a name the geocoder can't place
                }
                try? await Task.sleep(for: Self.gapBetweenLookups)
            }
        }
    }

    private func normalize(_ place: String?) -> String? {
        guard let place else { return nil }
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
