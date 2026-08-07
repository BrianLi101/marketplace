import Foundation
import CoreLocation

/// The lattice Facebook snaps published listing coordinates to.
///
/// Facebook never states how much it fuzzes a listing's location — the item
/// page says only "Location is approximate", and every number the page *does*
/// show ("Within 40 mi", "San Francisco · 40 mi") is the viewer's own search
/// radius, not anything about the listing. So the size of the drawn area was,
/// until this was measured, a guess.
///
/// It doesn't have to be. The published coordinates are quantised, and the
/// lattice is recoverable from a sample of them.
///
/// **Measured 2026-08-06** over 56 cached item pages (46 distinct points,
/// Bay Area, logged out):
///
/// - every latitude sits on a `360/2^16°` lattice
/// - every longitude sits on a `360/2^15°` lattice — twice as coarse
/// - worst residual `4.6e-10°`, i.e. ~0.05 mm, so this is exact snapping and
///   not a coincidence of rounding
/// - five different listings share one identical point, which is what snapping
///   to a grid this size looks like in a dense city
///
/// A published point therefore means "somewhere in this cell", and the cell is
/// wider than it is tall. The map draws the circle that circumscribes it
/// rather than the cell itself — Facebook shows an area around its own
/// listings, and matching that shape is worth more to someone comparing the
/// two screens than the extra fidelity of a rectangle. `worstCaseError` is the
/// radius that makes the circle contain the whole cell.
///
/// The lattice is a *lower* bound on the fuzz: it is possible Facebook also
/// jitters a point before snapping it, and no amount of sampling from outside
/// can rule that out. What can be said is that the true location is never
/// nearer to the published point than this.
enum FacebookCoordinateGrid {
    /// 0.0054931640625° — about 611 m of latitude, everywhere.
    static let latitudeStep = 360.0 / 65_536

    /// 0.010986328125° — about 966 m of longitude at San Francisco's latitude,
    /// narrowing towards the poles.
    static let longitudeStep = 360.0 / 32_768

    /// The cell's size on the ground, which depends on latitude east-west.
    static func cellSize(at latitude: CLLocationDegrees) -> (northSouth: CLLocationDistance,
                                                             eastWest: CLLocationDistance) {
        let metresPerDegree = 111_320.0
        return (latitudeStep * metresPerDegree,
                longitudeStep * metresPerDegree * cos(latitude * .pi / 180))
    }

    /// How far a listing can be from its published point: the half-diagonal of
    /// the cell, ~572 m in San Francisco.
    static func worstCaseError(at latitude: CLLocationDegrees) -> CLLocationDistance {
        let size = cellSize(at: latitude)
        return hypot(size.northSouth / 2, size.eastWest / 2)
    }
}
