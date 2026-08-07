import Foundation

/// The place named in a Marketplace **URL** — the path segment, nothing else.
///
/// Source: `URL.pathComponents`, so this works on any URL from either surface,
/// including one read back off a webview after Facebook has rewritten it. It
/// says nothing about what the page rendered; for that, read the pill the
/// desktop page draws (`DesktopLocationPill`).
///
/// Reading this back is not bookkeeping — it is the only way to know whether the
/// place we asked for was accepted. Facebook does not reject an unknown place:
/// it rewrites the path to `/marketplace/category/search/` and serves the
/// IP-inferred city's listings, which look completely healthy
/// (`docs/location-targeting.md` §2). Five of the twelve cities this app used to
/// offer failed in exactly that way, silently.
enum MarketplaceURLPlace: Equatable {
    /// A vanity alias in the path: `/marketplace/sanfrancisco/search/`. Exists
    /// for roughly half the cities tried, and resolves in a *global* namespace —
    /// `richmond` is served as Richmond, Virginia.
    case citySlug(String)
    /// A numeric city page id: `/marketplace/107929532567815/search/`. Always
    /// honoured, and every desktop search payload carries one per card at
    /// `location.reverse_geocode.city_page.id`.
    case placeID(String)
    /// No place segment, so Facebook resolves one from the IP address.
    case ipInferred
    /// **The requested place was refused.** Facebook rewrote it to
    /// `/marketplace/category/search/`; the listings belong to whatever city it
    /// inferred instead.
    case refused
    /// Not a place-bearing URL — an item page, a profile, `about:blank`.
    case notAPlaceURL

    /// True when this URL returns listings for a *specific* place rather than
    /// for wherever the request appeared to come from.
    var isExplicit: Bool {
        switch self {
        case .citySlug, .placeID: return true
        case .ipInferred, .refused, .notAPlaceURL: return false
        }
    }

    /// The segment exactly as written, for logging and for comparing a response
    /// against the request that produced it.
    var segment: String? {
        switch self {
        case .citySlug(let value), .placeID(let value): return value
        case .ipInferred, .refused, .notAPlaceURL: return nil
        }
    }

    /// Segments that follow `/marketplace/` but are not places. `category` is
    /// deliberately absent — it is the refusal signature, not a place.
    private static let reservedSegments: Set<String> = [
        "item", "you", "profile", "notifications", "saved", "selling",
        "create", "inbox", "learn_more", "collection"
    ]

    /// Reads the place segment out of any Marketplace URL.
    ///
    /// Tolerant of both the search and browse forms — `/<place>/search/` and
    /// `/<place>/<category>/` — because the place is always the first segment
    /// after `marketplace`, whatever follows it.
    static func parse(_ url: URL?) -> MarketplaceURLPlace {
        guard let url,
              let host = url.host, host.contains("facebook.com") else { return .notAPlaceURL }

        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let marketplaceIndex = parts.firstIndex(of: "marketplace") else { return .notAPlaceURL }

        let placeIndex = marketplaceIndex + 1
        guard placeIndex < parts.count else { return .ipInferred }   // bare /marketplace/

        let place = parts[placeIndex]
        switch place {
        case "search":
            return .ipInferred                  // /marketplace/search/ — IP decides
        case "category":
            return .refused                     // the rewrite Facebook performs on a miss
        case _ where reservedSegments.contains(place):
            return .notAPlaceURL
        case _ where isPlaceID(place):
            return .placeID(place)
        default:
            return .citySlug(place)
        }
    }

    /// Observed city page ids are 15 digits (`114952118516947`). The bar sits at
    /// 8 so a shorter id still reads as an id, while a numeric-looking slug —
    /// a ZIP like `94110`, which Facebook rejects anyway — does not.
    private static func isPlaceID(_ segment: String) -> Bool {
        segment.count >= 8 && segment.allSatisfy(\.isNumber)
    }
}
