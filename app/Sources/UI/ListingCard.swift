import SwiftUI

struct ListingCard: View {
    let listing: Listing
    let namespace: Namespace.ID
    @EnvironmentObject private var distances: DistanceResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
            // §3.1 — price carries the heaviest weight in the cell.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(listing.priceText ?? "—")
                    .font(.headline)
                if let original = listing.originalPriceText {
                    Text(original)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .strikethrough()
                }
            }
            if let title = listing.title {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            // §3.1 — location and distance are the point of a *local* browser,
            // so they get their own line whenever the surface provides them.
            if let location = listing.locationText {
                HStack(spacing: 4) {
                    Text(location)
                        .lineLimit(1)
                    if let distance = distances.distanceText(for: location) {
                        Text("·").foregroundStyle(.tertiary)
                        Text(distance)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .task { distances.resolve(place: listing.locationText) }
    }

    private var thumbnail: some View {
        ZStack(alignment: .topLeading) {
            AsyncImage(url: listing.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Color(.tertiarySystemFill)
                        .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                default:
                    Color(.tertiarySystemFill)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .matchedGeometryEffect(id: listing.id, in: namespace)

            if let badge = listing.badgeText {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            }
        }
    }
}
