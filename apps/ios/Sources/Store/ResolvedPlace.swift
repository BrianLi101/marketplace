import Foundation
import CoreLocation

/// A place Facebook itself chose, and the coordinate that produced it.
///
/// The app never invents a slug. Every slug it holds came back from Facebook's
/// own picker after being handed a coordinate, which is what makes it safe to
/// use: a slug Facebook returned is by construction one Facebook recognises,
/// where a slug we derived from a city name has roughly even odds
/// (`docs/location-targeting.md` §2 — five of twelve shipped slugs were not
/// real places, and `richmond` is in Virginia).
///
/// The coordinate is kept alongside it for two reasons: it identifies what was
/// asked for when the answer is surprising ("I asked for Berkeley and got
/// Oakland"), and it lets a stale resolution be repeated without making the
/// user search again.
struct ResolvedPlace: Codable, Equatable, Identifiable {
    /// What Facebook calls it — taken from the pill after resolution, e.g.
    /// "London", "Toronto", "San Francisco".
    var name: String
    /// The path segment Facebook put in the URL. A slug, or a numeric place id;
    /// both are things it handed us rather than things we guessed.
    var segment: String
    /// The coordinate that was fed to the picker to get this.
    var latitude: Double
    var longitude: Double
    /// Where the coordinate came from, which decides whether it can go stale.
    var origin: Origin
    var resolvedAt: Date

    /// The URL Facebook landed on once the place was applied, kept verbatim.
    ///
    /// Worth storing rather than rebuilding. Facebook chose this form —
    /// `/marketplace/toronto/?radius_in_km=65` — and reusing what it produced
    /// avoids re-deriving a URL from parts and getting the form subtly wrong.
    /// It is also the thing to re-check against: if a later load of this URL
    /// stops naming this place, the place has gone stale rather than the app
    /// having a bug somewhere else.
    var browseURL: String?

    /// The pill text seen on a **fresh load** of `browseURL`, e.g.
    /// "Toronto · 8 km", and when that check ran.
    ///
    /// Nil means never confirmed. That is different from confirmed-and-wrong,
    /// and the UI says so, because a silent refusal is this whole area's
    /// characteristic failure: Facebook serves a full, healthy-looking result
    /// set for a city nobody asked for.
    var verifiedPill: String?
    var verifiedAt: Date?

    var isVerified: Bool { verifiedAt != nil }

    var id: String { segment }

    enum Origin: String, Codable {
        /// The device's own fix. Goes stale when the user moves.
        case deviceFix
        /// A city the user searched for and picked. Stays true until they pick
        /// another one.
        case searchedCity
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(name: String, segment: String, coordinate: CLLocationCoordinate2D,
         origin: Origin, resolvedAt: Date = Date(),
         browseURL: String? = nil, verifiedPill: String? = nil, verifiedAt: Date? = nil) {
        self.name = name
        self.segment = segment
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.origin = origin
        self.resolvedAt = resolvedAt
        self.browseURL = browseURL
        self.verifiedPill = verifiedPill
        self.verifiedAt = verifiedAt
    }

    /// How far the device has drifted from where this was resolved. Only
    /// meaningful for `.deviceFix`; a searched city is wherever the user said.
    func metres(from location: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: location.latitude, longitude: location.longitude))
    }
}
