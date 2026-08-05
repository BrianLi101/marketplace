import SwiftUI
import CoreLocation

/// §3.2 — the progressive preview. The transition never waits on the network:
/// everything the grid already knows renders on the first frame, and detail
/// fades in behind it.
struct DetailView: View {
    let listing: Listing
    let namespace: Namespace.ID

    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var distances: DistanceResolver
    @State private var current: Listing
    @State private var didFail = false
    @State private var isEnriching = true

    init(listing: Listing, namespace: Namespace.ID) {
        self.listing = listing
        self.namespace = namespace
        _current = State(initialValue: listing)
    }

    private var detail: ListingDetail? { current.detail }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                priceBlock
                photoStrip
                descriptionBlock
                factsBlock
                sellerBlock
                mapBlock
                if didFail { unavailableNotice }
            }
            .padding(.horizontal)
            .padding(.bottom, 100)
        }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { primaryAction }
        .toolbar {
            // Sharing was the only other entry in what used to be an overflow
            // menu, so it goes straight in the toolbar rather than behind one.
            if let url = current.itemURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .task {
            distances.resolve(place: listing.locationText)
            // Words land seconds before the gallery, so they're shown the
            // moment they exist rather than waiting on the photos. The strip
            // keeps its own placeholders until the second stage arrives.
            let enriched = await store.enrich(listing) { staged in
                withAnimation(.easeOut(duration: 0.2)) {
                    current = staged
                    isEnriching = false
                }
            }
            distances.resolve(place: enriched.locationText ?? enriched.detail?.locationText)
            withAnimation(.easeOut(duration: 0.25)) {
                current = enriched
                didFail = enriched.detail == nil
                isEnriching = false
            }
        }
    }

    /// A **reserved** square, not a box that grows to whatever the photo turns
    /// out to be.
    ///
    /// This used to be a bare `AsyncImage` with no height: the placeholder is a
    /// `Color`, which has no intrinsic size and collapses to nothing, and then
    /// the decoded image expanded the frame to its full aspect height. For a
    /// listing that was prefetched, everything below the hero is already laid
    /// out on the first frame — so that expansion shoved the entire page down a
    /// beat after it appeared. Cold listings hid it, because their content
    /// arrived seconds later, once the hero had already settled.
    ///
    /// The photo is fitted rather than cropped, so an unusually tall or wide
    /// one letterboxes instead of losing its edges.
    private var hero: some View {
        Color(.tertiarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: current.thumbnailURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .matchedGeometryEffect(id: current.id, in: namespace)
    }

    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(current.priceText ?? "—").font(.title2.weight(.semibold))
                if let original = current.originalPriceText {
                    Text(original).font(.subheadline).foregroundStyle(.secondary).strikethrough()
                }
            }
            if let title = current.title {
                Text(title).font(.title3)
            }
            // Unconditional. This used to be hidden once the map could render,
            // which meant a line appearing and then vanishing under the title
            // as a geocode or an item coordinate landed — a second, smaller
            // version of the hero's jump. The map card no longer repeats the
            // place, so there's nothing to de-duplicate against.
            if let location = placeName {
                HStack(spacing: 5) {
                    Text(location)
                    if let distance = bestDistanceText {
                        Text("·").foregroundStyle(.tertiary)
                        Text(distance)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// One real thumbnail plus placeholders, filling in left to right.
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let photos = detail?.photoURLs, !photos.isEmpty {
                    ForEach(photos, id: \.self) { url in
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color(.tertiarySystemFill)
                            }
                        }
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                } else {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.tertiarySystemFill))
                            .frame(width: 96, height: 96)
                    }
                }
            }
        }
    }

    /// Reserves height so the fade-in doesn't shove the page around. Shows the
    /// seller's own words only — the heading is dropped entirely when there's
    /// nothing to put under it, rather than leaving a bare label.
    @ViewBuilder
    private var descriptionBlock: some View {
        if let description = detail?.description, !description.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Description").font(.headline)
                Text(description)
                    .font(.body)
                    .textSelection(.enabled)
            }
        } else if isEnriching {
            VStack(alignment: .leading, spacing: 8) {
                Text("Description").font(.headline)
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.tertiarySystemFill))
                        .frame(height: 13)
                }
            }
            .frame(minHeight: 90, alignment: .top)
        }
    }

    /// Seller identity comes only from the mobile item page. A rating is
    /// optional even there — plenty of sellers have never been rated — so the
    /// stars appear only when there is a real score behind them.
    @ViewBuilder
    private var sellerBlock: some View {
        if let name = detail?.sellerName {
            VStack(alignment: .leading, spacing: 4) {
                Text("Seller").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(name).font(.body.weight(.medium))
                    if let rating = detail?.sellerRating {
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { star in
                                Image(systemName: Double(star) <= rating.rounded()
                                      ? "star.fill" : "star")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            Text(String(format: "%.1f", rating)).font(.caption)
                            if let count = detail?.sellerRatingCount {
                                Text("(\(count))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Rated \(String(format: "%.1f", rating)) out of 5"
                            + (detail?.sellerRatingCount.map { " from \($0) ratings" } ?? ""))
                    }
                }
                if let joined = detail?.sellerJoined {
                    Text(joined).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var factsBlock: some View {
        // The card label already carried the condition, so it can render on the
        // first frame instead of waiting for the detail page to load.
        let condition = current.conditionText ?? detail?.conditionText
        let rows = [
            condition.map { ("Condition", $0) },
            detail?.postedText.map { ("Posted", $0) }
        ].compactMap { $0 }

        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    HStack {
                        Text(row.0).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.1)
                    }
                    .font(.subheadline)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var placeName: String? { current.locationText ?? detail?.locationText }

    /// Two sources, in order of how much they actually know.
    ///
    /// The listing's own coordinate comes off the item page and doesn't exist
    /// until enrichment lands, so the city centroid carries the first frame and
    /// is replaced in place when the real point arrives.
    private var mapPoint: (CLLocationCoordinate2D, LocationMapCard.Precision)? {
        if let latitude = detail?.latitude, let longitude = detail?.longitude {
            return (CLLocationCoordinate2D(latitude: latitude, longitude: longitude), .listing)
        }
        if let coordinate = distances.coordinate(for: placeName) {
            return (coordinate, .city)
        }
        return nil
    }

    /// Measured from the listing's own point when we have it, falling back to
    /// the geocoded city centroid otherwise.
    private var bestDistanceText: String? {
        if let (coordinate, precision) = mapPoint, precision == .listing {
            return distances.distanceText(to: coordinate)
        }
        return distances.distanceText(for: placeName)
    }

    @ViewBuilder
    private var mapBlock: some View {
        if let place = placeName, let (coordinate, precision) = mapPoint {
            LocationMapCard(place: place, coordinate: coordinate, precision: precision)
        }
    }

    /// §3.2 — a quiet inline row, never a dialog. The preview above it still
    /// has the price, title, location and photo, which is most of what anyone
    /// needs to decide.
    private var unavailableNotice: some View {
        InlineNotice(
            text: current.itemURL == nil
                ? "Couldn't match this listing on Facebook."
                : "Full details unavailable.",
            actionTitle: viewOnFacebookTitle,
            action: openInFacebook
        )
    }

    /// The button says what it does. It deep-links to this listing's own
    /// Marketplace page when the id resolved, and says so when it couldn't —
    /// rather than promising "Message Seller" and landing somewhere generic.
    private var viewOnFacebookTitle: String {
        current.itemURL != nil ? "View on Facebook" : "Search on Facebook"
    }

    /// §4 — every route out is a link. When the canonical URL never resolved,
    /// fall back to a Marketplace search for the title rather than a dead end.
    private func openInFacebook() {
        if let url = current.itemURL {
            Handoff.open(url, kind: "view-listing")
        } else {
            Handoff.openSearch(for: current, citySlug: prefs.locationSlug)
        }
    }

    /// §4 — every action is a link-out, never an in-app flow.
    private var primaryAction: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: openInFacebook) {
                Label(viewOnFacebookTitle, systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .background(.bar)
    }
}
