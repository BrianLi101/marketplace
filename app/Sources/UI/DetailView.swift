import SwiftUI

/// §3.2 — the progressive preview. The transition never waits on the network:
/// everything the grid already knows renders on the first frame, and detail
/// fades in behind it.
struct DetailView: View {
    let listing: Listing
    let namespace: Namespace.ID

    @EnvironmentObject private var store: ListingStore
    @State private var current: Listing
    @State private var didFail = false

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
            let enriched = await store.enrich(listing)
            withAnimation(.easeOut(duration: 0.25)) {
                current = enriched
                didFail = enriched.detail == nil
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
            if let location = current.locationText ?? detail?.locationText {
                Text(location).font(.subheadline).foregroundStyle(.secondary)
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

    /// Reserves height so the fade-in doesn't shove the page around.
    private var descriptionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details").font(.headline)
            if let description = detail?.description {
                Text(description).font(.body)
            } else if !didFail {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.tertiarySystemFill))
                        .frame(height: 13)
                }
            }
        }
        .frame(minHeight: 90, alignment: .top)
    }

    @ViewBuilder
    private var factsBlock: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 6) {
                if let condition = detail.conditionText { fact("Condition", condition) }
                if let posted = detail.postedText { fact("Posted", posted) }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline)
        }
    }

    private var unavailableNotice: some View {
        InlineNotice(text: "Full details unavailable.", actionTitle: "Open in Facebook") {
            if let url = current.itemURL { Handoff.open(url, kind: "detail-fallback") }
            else { Handoff.openMarketplace() }
        }
    }

    /// §4 — every action is a link-out, never an in-app flow.
    private var primaryAction: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                if let url = current.itemURL { Handoff.open(url, kind: "message-seller") }
                else { Handoff.openMarketplace() }
            } label: {
                Label("Message Seller on Facebook", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .background(.bar)
    }
}
