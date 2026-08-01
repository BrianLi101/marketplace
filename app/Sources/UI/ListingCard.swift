import SwiftUI

struct ListingCard: View {
    let listing: Listing
    let namespace: Namespace.ID

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
            if let location = listing.locationText {
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
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
