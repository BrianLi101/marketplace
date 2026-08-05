import SwiftUI
import MapKit

/// An approximate-area map for a listing.
///
/// Facebook labels every location "Location is approximate", so this draws a
/// radius rather than a pin: a pin would imply a precision that doesn't exist
/// and would point at an address the seller never shared. Non-interactive on
/// purpose — it's orientation, not navigation.
///
/// The circle's size is not decoration. It says which of two very different
/// things the centre is, and the two are kilometres apart.
struct LocationMapCard: View {
    /// Not rendered — the place is named under the title, where it stays put
    /// whether or not this card can draw. Kept for the accessibility label.
    let place: String
    let coordinate: CLLocationCoordinate2D
    let precision: Precision

    /// Where the centre came from — and therefore how much of the map around it
    /// the listing could actually be in.
    enum Precision {
        /// Facebook's own published point for this listing, off the item page.
        /// Fuzzed, but tied to the listing: a sample sat ~4.5 km from the San
        /// Francisco centroid the city fallback would have used.
        case listing
        /// A geocoded centroid of the place name, the only thing available
        /// before the item page loads. The listing is somewhere in the city,
        /// which is a far weaker claim and has to look like one.
        case city

        /// Radius of the drawn circle, in metres.
        ///
        /// A city centroid previously drew the same 1.2 km circle as a real
        /// point, which asserted the listing was near downtown — usually false.
        /// Facebook's own fuzz isn't published, so `listing` uses a
        /// neighbourhood-sized half mile: wide enough not to overclaim, tight
        /// enough to be worth showing.
        var radius: CLLocationDistance {
            switch self {
            case .listing: 800
            case .city: 6_000
            }
        }

        /// Frames the circle at roughly two-thirds of the map's width, so the
        /// zoom follows the claim instead of being fixed at city scale.
        var span: CLLocationDistance { radius * 3 }

        var caption: String {
            switch self {
            case .listing: "Approximate area"
            case .city: "City only"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Map(initialPosition: .region(region), interactionModes: []) {
                MapCircle(center: coordinate, radius: precision.radius)
                    .foregroundStyle(.tint.opacity(0.18))
                    .stroke(.tint.opacity(0.55), lineWidth: 1)
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("\(precision.caption) around \(place)")

            Text(precision.caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        // The map is re-centred when the item page's coordinate lands, which is
        // after the first frame. `initialPosition` is read once, so the view has
        // to be rebuilt rather than updated.
        .id("\(coordinate.latitude),\(coordinate.longitude)")
    }

    private var region: MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate,
                           latitudinalMeters: precision.span,
                           longitudinalMeters: precision.span)
    }
}
