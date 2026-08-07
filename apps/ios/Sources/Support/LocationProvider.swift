import Foundation
import CoreLocation

/// §6 radius pinning needs a coordinate. When-in-use, requested on first
/// search, cached afterwards — never continuous tracking (§7.3 has no
/// background activity of any kind).
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case idle, requesting, resolved(String), denied, failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        // A kilometre was enough when this only had to pick a city for radius
        // pinning. It isn't any more: the same fix is now the origin of a
        // per-listing distance quoted to a tenth of a mile and of a walking
        // time quoted to the minute, and a kilometre of slack is twenty minutes
        // on foot. Still a single on-demand fix, so the cost is one slightly
        // longer wait rather than any ongoing draw.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
        [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus)
    }

    /// Never asked. A prompt here can still summon the system dialog, so it's
    /// worth offering one.
    var isUndecided: Bool { manager.authorizationStatus == .notDetermined }

    /// Asked and refused, or refused on the user's behalf by a restriction.
    /// The system dialog will not appear again, so the only honest offer is a
    /// trip to Settings.
    var isDenied: Bool {
        [.denied, .restricted].contains(manager.authorizationStatus)
    }

    /// Resolves once and caches. Returns nil if the user declines or the fix
    /// doesn't arrive — searching still works, it just falls back to the
    /// stored city slug, so this must never block indefinitely.
    func resolveOnce(timeout: Duration = .seconds(6)) async -> CLLocationCoordinate2D? {
        if let coordinate { return coordinate }
        guard manager.authorizationStatus != .denied, manager.authorizationStatus != .restricted else {
            state = .denied
            return nil
        }
        guard continuation == nil else { return nil }   // a request is already in flight
        state = .requesting

        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, let pending = self.continuation else { return }
            self.continuation = nil
            if self.state == .requesting { self.state = .failed }
            pending.resume(returning: nil)
        }

        return await withCheckedContinuation { cont in
            continuation = cont
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
        }
    }

    private func finish(_ coord: CLLocationCoordinate2D?) {
        continuation?.resume(returning: coord)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            case .denied, .restricted: state = .denied; finish(nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            coordinate = loc.coordinate
            await reverseGeocode(loc)
            finish(loc.coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            state = .failed
            finish(nil)
        }
    }

    private func reverseGeocode(_ location: CLLocation) async {
        let places = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let place = places?.first, let city = place.locality else {
            state = .resolved("Your area")
            return
        }
        let name = [city, place.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        state = .resolved(name)
        let prefs = Preferences.shared
        prefs.locationName = name
        prefs.locationSlug = city.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
    }
}
