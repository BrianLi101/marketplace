import SwiftUI
import MapKit

/// An approximate-area map for a listing.
///
/// Facebook deliberately publishes only a place name and labels it "Location is
/// approximate", so this draws a radius around the geocoded centre rather than
/// a pin: a pin would imply a precision that doesn't exist and would point at a
/// specific address the seller never shared. Non-interactive on purpose — it's
/// orientation, not navigation.
struct LocationMapCard: View {
    let place: String
    let coordinate: CLLocationCoordinate2D
    let distanceText: String?

    private static let approximateRadius: CLLocationDistance = 1_200

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Map(initialPosition: .region(region), interactionModes: []) {
                MapCircle(center: coordinate, radius: Self.approximateRadius)
                    .foregroundStyle(.tint.opacity(0.18))
                    .stroke(.tint.opacity(0.55), lineWidth: 1)
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)

            HStack(spacing: 4) {
                Text(place)
                if let distanceText {
                    Text("·").foregroundStyle(.tertiary)
                    Text(distanceText)
                }
                Spacer()
                Text("Approximate")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var region: MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate,
                           latitudinalMeters: Self.approximateRadius * 5,
                           longitudinalMeters: Self.approximateRadius * 5)
    }
}
