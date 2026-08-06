import SwiftUI
import CoreLocation

struct ResultsView: View {
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var location: LocationProvider
    @EnvironmentObject private var distances: DistanceResolver
    @EnvironmentObject private var saved: SavedListings

    @State private var searchText = ""
    @State private var selected: Listing?
    @State private var showSettings = false

    @State private var showSignIn = false
    @Namespace private var heroNamespace

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Always present, including on the saved-items home. With
                    // no search running these set the defaults the next one
                    // will use — `rerunCurrentQuery` is a no-op without a
                    // query — so the bar is where you configure a search as
                    // well as where you adjust one.
                    FilterBar { Task { await rerunCurrentQuery() } }
                    Divider()
                    content
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Marketplace")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search local listings")
            .searchSuggestions { SearchSuggestions() }
            .onSubmit(of: .search) { Task { await search(searchText) } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showSignIn) {
                SignInView {
                    // A signed-in query returns a different result set, not
                    // merely a longer one, so this re-runs rather than
                    // appending to what's already on screen.
                    Task {
                        store.setSession(await SessionState.isSignedIn() ? .authed : .unauthed)
                        await store.retry()
                    }
                }
            }
            .navigationDestination(item: $selected) { listing in
                DetailView(listing: listing, namespace: heroNamespace)
            }
            // The fix can land long after a search starts; hand it straight to
            // the distance resolver whenever it does.
            .onChange(of: location.coordinate?.latitude) {
                distances.setUserLocation(location.coordinate)
            }
            // Emptying the search bar goes home, to the saved list.
            .onChange(of: searchText) { _, text in
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.clearQuery()
                }
            }
            .task {
                distances.setUserLocation(location.coordinate)
            }
        }
    }

    // MARK: - Pieces

    // §3.1 — the radius used to live in the toolbar, on the thesis that it is
    // the product's whole point and should never be buried. It still isn't:
    // it moved into `FilterBar` alongside the filters it belongs with, where
    // it can also say the thing the toolbar button couldn't — that distance is
    // applied on this device, because Facebook won't.

    // Recent searches and suggested categories used to sit in a pill row above
    // the results, where they cost a strip of vertical space on every screen —
    // including the ones where nobody is looking for them. They now appear
    // inside the search field, which is where someone is when they want them.

    @ViewBuilder
    private var content: some View {
        switch store.feedState {
        case .loginWall:
            LoginWallCard { Task { await store.retry() } }
                .padding()
        case .failed(let message):
            InlineNotice(text: message, actionTitle: "Try again") { Task { await store.retry() } }
                .padding()
        default:
            if store.isLoadingFirstPage {
                SkeletonGrid()
            } else if store.listings.isEmpty && store.query != nil {
                InlineNotice(text: "Nothing found nearby. Try a wider radius.", actionTitle: nil, action: nil)
                    .padding()
            } else if store.query == nil {
                savedHome
            } else {
                grid
            }
        }
    }

    /// With an empty search bar, the home screen is what the user kept.
    ///
    /// Entirely local — every card here comes out of the profile store, which
    /// is exactly why it can render with no network at all. Saving writes the
    /// card at the moment it's saved, so there is no such thing as a saved
    /// listing with nothing behind it.
    @ViewBuilder
    private var savedHome: some View {
        let items = store.savedListings(saved.ids)
        if items.isEmpty {
            EmptyStatePrompt(hasSavedNothing: saved.isEmpty)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Saved")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 12)
                StaggeredGrid(items: items, columns: 2, spacing: 12) { listing in
                    ListingCard(listing: listing, namespace: heroNamespace)
                        .onTapGesture { selected = listing }
                }
                .padding(.horizontal, 12)
            }
            .padding(.top, 4)
        }
    }

    /// The grid, after the one filter Facebook won't apply for us.
    ///
    /// Distance is enforced here because no surface honours `radius` — the chip
    /// changes and the results don't (`docs/filter-parameters.md` §3). Listings
    /// whose distance isn't known yet are **kept**, not hidden: geocoding is
    /// asynchronous, and filtering on missing data would make cards disappear
    /// and come back as the queue drains.
    private var visibleListings: [Listing] {
        guard prefs.radiusKM > 0 else { return store.listings }
        return store.listings.filter { listing in
            let coordinate = listing.detail.flatMap { detail -> CLLocationCoordinate2D? in
                guard let latitude = detail.latitude, let longitude = detail.longitude else { return nil }
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            guard let km = distances.distanceKM(for: listing.locationText, coordinate: coordinate)
            else { return true }
            return km <= Double(prefs.radiusKM)
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            let items = visibleListings
            StaggeredGrid(items: items, columns: 2, spacing: 12) { listing in
                ListingCard(listing: listing, namespace: heroNamespace)
                    .onTapGesture { selected = listing }
                    .task { await store.loadMoreIfNeeded(currentItem: listing) }
            }
            .padding(.horizontal, 12)
            .overlay(alignment: .bottom) {
                if store.isLoadingMore {
                    ProgressView().padding()
                }
            }

            // Distance is filtered here rather than by Facebook, so listings
            // disappear with no explanation unless one is given. That matters
            // most with "Newest first", which genuinely does return results
            // 60-90 mi out — a search can go from fifteen cards to one, and
            // without this it just looks broken.
            let hidden = store.listings.count - items.count
            if hidden > 0 {
                distanceNotice(hidden: hidden, showingNothing: items.isEmpty)
            }

            if store.session == .unauthed, !items.isEmpty {
                endOfResultsSignIn
            }
        }
    }

    private func distanceNotice(hidden: Int, showingNothing: Bool) -> some View {
        VStack(spacing: 8) {
            Text(showingNothing
                 ? "Nothing within \(SearchQuery.kilometresToMiles(prefs.radiusKM)) mi"
                 : "\(hidden) more further than \(SearchQuery.kilometresToMiles(prefs.radiusKM)) mi")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Show any distance") { prefs.radiusKM = 0 }
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, showingNothing ? 40 : 24)
    }

    /// The bottom of an anonymous result set really is the bottom — Facebook
    /// serves about fifteen listings to a signed-out session and then blocks
    /// scrolling behind an overlay that can be dismissed exactly once.
    ///
    /// The offer alone carries it; explaining the cap out loud only draws
    /// attention to the ceiling.
    private var endOfResultsSignIn: some View {
        VStack(spacing: 12) {
            Text("Log in to keep scrolling, and to see who's selling.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { showSignIn = true } label: {
                Text("Log in to Facebook")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    // MARK: - Actions

    private func search(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        prefs.recordSearch(trimmed)
        prefs.recordLastQuery(.search(trimmed))
        await store.run(makeQuery(.search(trimmed)))
    }

    /// Currently unreachable: the category pills that called it are gone, and
    /// the suggestions run categories as ordinary searches. Kept because
    /// `SearchQuery.Kind.category` still builds a valid URL — but note that
    /// category *paths* have never been through the desktop payload extractor,
    /// which is verified only against `/search/`. Anything reviving this should
    /// check the payload parses there first.
    private func browse(category: String) async {
        prefs.recordLastQuery(.category(category))
        await store.run(makeQuery(.category(category)))
    }

    private func rerunCurrentQuery() async {
        guard let existing = store.query else { return }
        await store.run(makeQuery(existing.kind))
    }

    /// Location is an enhancement, never a gate: searching uses whatever
    /// coordinate is already cached and asks for a fresh one in the background,
    /// so a slow or refused fix can't stall the results.
    private func makeQuery(_ kind: SearchQuery.Kind) -> SearchQuery {
        if location.coordinate == nil {
            Task {
                let coordinate = await location.resolveOnce()
                distances.setUserLocation(coordinate)
            }
        } else {
            distances.setUserLocation(location.coordinate)
        }
        return SearchQuery(
            kind: kind,
            // Sent for shape only — no surface filters on it. The real distance
            // filter is `visibleListings`.
            radiusKM: prefs.radiusKM == 0 ? 40 : prefs.radiusKM,
            citySlug: prefs.locationSlug ?? "sanfrancisco",
            coordinate: location.coordinate,
            sort: prefs.sort,
            delivery: prefs.delivery
        )
    }
}

/// What the search field offers while it has focus: what you looked for
/// before, or somewhere to start if you never have.
///
/// Uses `.searchCompletion` rather than buttons. A button has to call
/// `dismissSearch()`, which *clears the field* — so the term the user just
/// picked vanished from the search bar, and the empty value tripped the
/// "emptied the field, go home" handler on its way past. A completion puts the
/// term in the field and submits it, which is the behaviour wanted here.
///
/// Categories run as searches for the same reason anything else does: the
/// desktop payload is only verified on `/search/` paths, and a category path
/// is a different page shape that has never been through this extractor.
private struct SearchSuggestions: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        if !prefs.recentSearches.isEmpty {
            Section("Recent") {
                ForEach(prefs.recentSearches, id: \.self) { term in
                    Label(term, systemImage: "clock.arrow.circlepath")
                        .searchCompletion(term)
                }
            }
        }
        Section(prefs.recentSearches.isEmpty ? "Try" : "Categories") {
            ForEach(Preferences.suggestedCategories, id: \.self) { name in
                Label(name, systemImage: "square.grid.2x2")
                    .searchCompletion(name)
            }
        }
    }
}

struct EmptyStatePrompt: View {
    /// Distinguishes "you haven't saved anything yet" from "search for
    /// something" — the home screen is the saved list now, so an empty one
    /// should say what would fill it.
    var hasSavedNothing = true

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: hasSavedNothing ? "bookmark" : "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(hasSavedNothing ? "Nothing saved yet" : "Search for something nearby")
                .font(.headline)
            Text(hasSavedNothing
                 ? "Search for something, then tap the bookmark to keep it here."
                 : "Or pick a category above.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 80)
    }
}

/// §3.3 — no login form, ever. Just an honest explanation and a way out.
struct LoginWallCard: View {
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Facebook is limiting anonymous browsing right now.")
                .font(.headline)
            Text("You can keep browsing in a moment, or open Marketplace in the Facebook app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Try again", action: retry)
                    .buttonStyle(.bordered)
                Button("Open Facebook") { Handoff.openMarketplace() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct InlineNotice: View {
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.subheadline)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
