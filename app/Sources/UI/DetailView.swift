import SwiftUI

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
                mapBlock
                if didFail { unavailableNotice }
            }
            .padding(.horizontal)
            .padding(.bottom, 100)
        }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { primaryAction }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let url = current.itemURL {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    Button(role: .destructive) { store.hide(current) } label: {
                        Label("Hide this listing", systemImage: "eye.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            distances.resolve(place: listing.locationText)
            let enriched = await store.enrich(listing)
            distances.resolve(place: enriched.locationText ?? enriched.detail?.locationText)
            withAnimation(.easeOut(duration: 0.25)) {
                current = enriched
                didFail = enriched.detail == nil
                isEnriching = false
            }
        }
    }

    private var hero: some View {
        AsyncImage(url: current.thumbnailURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Color(.tertiarySystemFill)
            }
        }
        .frame(maxWidth: .infinity)
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
            if let location = current.locationText ?? detail?.locationText,
               distances.coordinate(for: location) == nil {
                HStack(spacing: 5) {
                    Text(location)
                    if let distance = distances.distanceText(for: location) {
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

    /// The map replaces the plain location line once a coordinate resolves.
    @ViewBuilder
    private var mapBlock: some View {
        if let place = current.locationText ?? detail?.locationText,
           let coordinate = distances.coordinate(for: place) {
            LocationMapCard(place: place,
                            coordinate: coordinate,
                            distanceText: distances.distanceText(for: place))
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
