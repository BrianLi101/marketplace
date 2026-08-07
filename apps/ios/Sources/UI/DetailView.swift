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
    @EnvironmentObject private var saved: SavedListings
    @EnvironmentObject private var viewed: ViewedListings
    @State private var current: Listing
    @State private var didFail = false
    @State private var isEnriching = true
    @State private var showSignIn = false

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
            ToolbarItem(placement: .topBarTrailing) { saveButton }
            // Sharing was the only other entry in what used to be an overflow
            // menu, so it goes straight in the toolbar rather than behind one.
            if let url = current.itemURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .task {
            // Opening a listing is what "seen" means — this is the only place
            // it's recorded, so every route in counts and none can miss it.
            // Before enrichment rather than after: a listing whose detail fetch
            // fails was still deliberately opened, and a slow one shouldn't be
            // forgotten because the user backed out while it loaded.
            viewed.record(listing.id)
            // And the card itself, for the same reason `saveButton` does it —
            // the recently-viewed strip draws from the profile store, so
            // something has to be there whether or not the fetch below lands.
            // Never destructive: `store` keeps any detail already held.
            store.remember(listing)

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
        .sheet(isPresented: $showSignIn) {
            SignInView {
                // Signing in doesn't retroactively fill this listing in — the
                // seller fields were never fetched, because Facebook didn't
                // render them to an anonymous session. So re-open it against
                // the new session rather than just closing the sheet.
                Task { await refetchAfterSignIn() }
            }
        }
    }

    /// Re-reads this listing now that a session exists.
    ///
    /// Deliberately bypasses the profile cache: the stored record is real, it
    /// simply predates the session and has *unknown* seller fields rather than
    /// absent ones (`CachedProfile.sellerFieldsAreKnown`). Re-fetching is the
    /// only way to learn them.
    private func refetchAfterSignIn() async {
        store.setSession(await SessionState.isSignedIn() ? .authed : .unauthed)
        guard store.session == .authed else { return }
        isEnriching = true
        let refreshed = await store.enrich(current)
        withAnimation(.easeOut(duration: 0.25)) {
            current = refreshed
            isEnriching = false
        }
    }

    /// Keyed on the listing id — the photo FBID — so the grid reflects a save
    /// the moment it happens, with no separate plumbing between the screens.
    private var saveButton: some View {
        let isSaved = saved.contains(current.id)
        return Button {
            // Record before flagging, so the saved-items screen always has a
            // card to draw even when this fires before enrichment lands.
            store.remember(current)
            withAnimation(.snappy(duration: 0.2)) { saved.toggle(current.id) }
        } label: {
            Label(isSaved ? "Saved" : "Save",
                  systemImage: isSaved ? "bookmark.fill" : "bookmark")
        }
        .accessibilityLabel(isSaved ? "Saved. Tap to remove." : "Save listing")
    }

    /// Every image on this screen has a **fixed height**: the hero below, and
    /// the 96pt squares in the photo strip. Nothing is sized by the photo that
    /// lands in it, so the page can't reflow when one decodes.
    ///
    /// That reflow was the bug. The hero was a bare `AsyncImage` with no height
    /// — its placeholder is a `Color`, which has no intrinsic size and
    /// collapses to nothing — so the decoded image expanded the frame to its
    /// full aspect height and shoved the whole page down. It showed up on
    /// prefetched listings because everything below is already laid out on the
    /// first frame; cold ones hid it behind their own loading.
    private static let heroHeight: CGFloat = 360

    /// Filled and cropped rather than fitted, which is what a fixed height
    /// wants: a portrait photo letterboxed into a fixed box is mostly
    /// background. It also matches `ListingCard`, which fills at a fixed 180 —
    /// so `matchedGeometryEffect` now animates fill to fill instead of
    /// distorting fill into fit. The strip below shows every photo uncropped.
    private var hero: some View {
        Color(.tertiarySystemFill)
            .frame(maxWidth: .infinity)
            .frame(height: Self.heroHeight)
            .overlay {
                AsyncImage(url: current.thumbnailURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
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

    private static let thumbSize: CGFloat = 96

    /// One real thumbnail plus placeholders, filling in left to right. Same
    /// shape as `hero`: a fixed box that the photo is laid into, never a box
    /// that takes its size from the photo. The strip's own height is therefore
    /// identical whether it holds placeholders or twelve loaded images.
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let photos = detail?.photoURLs, !photos.isEmpty {
                    ForEach(photos, id: \.self) { url in
                        thumbBox {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                }
                            }
                        }
                    }
                } else {
                    ForEach(0..<3, id: \.self) { _ in
                        thumbBox { EmptyView() }
                    }
                }
            }
        }
        .frame(height: Self.thumbSize)
    }

    private func thumbBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Color(.tertiarySystemFill)
            .frame(width: Self.thumbSize, height: Self.thumbSize)
            .overlay { content() }
            .clipShape(RoundedRectangle(cornerRadius: 10))
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

    /// Facebook only renders seller identity to a signed-in session, so when
    /// browsing anonymously this section is *unknown* rather than empty.
    ///
    /// Saying so is more honest than showing nothing — a blank space reads as
    /// "this seller has no name or rating", which is exactly the wrong
    /// conclusion, and it's the one place where signing in has an obvious,
    /// concrete payoff to point at.
    @ViewBuilder
    private var sellerSignInPrompt: some View {
        Button {
            showSignIn = true
        } label: {
            // Icon aligned to the first line of text rather than to the centre
            // of the whole block: centring floats it into the gap between the
            // title and the subtitle whenever the title wraps.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.body)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Log in to see seller details")
                        .font(.subheadline.weight(.semibold))
                    Text("Name, rating, and how long they've been on Facebook.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        // No horizontal padding here: the enclosing VStack already applies it,
        // and adding a second inset made this card visibly narrower than the
        // description and map it sits between.
    }

    /// Seller identity requires a signed-in desktop session. A rating is
    /// optional even then — plenty of sellers have never been rated — so the
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
            .padding(.top, 4)
        } else if store.session == .unauthed, !isEnriching {
            // Only once enrichment has settled: offering this while the fetch
            // is still running would flash a "log in" prompt at a signed-in
            // user a moment before their seller details arrived.
            sellerSignInPrompt
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
    ///
    /// Shares `DistanceResolver.bestDistanceText` with the grid rather than
    /// deciding for itself: this screen and the card that opened it disagreeing
    /// about how far away something is would be a bug the user could see.
    private var bestDistanceText: String? {
        distances.bestDistanceText(for: current)
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
