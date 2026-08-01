import SwiftUI

struct ResultsView: View {
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var location: LocationProvider

    @State private var searchText = ""
    @State private var selected: Listing?
    @State private var showSettings = false
    @State private var showRadiusPicker = false
    @Namespace private var heroNamespace

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    pillRow
                    content
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Marketplace")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search local listings")
            .onSubmit(of: .search) { Task { await search(searchText) } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { radiusButton }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .confirmationDialog("Search radius", isPresented: $showRadiusPicker, titleVisibility: .visible) {
                ForEach(Preferences.radiusOptions, id: \.self) { km in
                    Button("\(SearchQuery.kilometresToMiles(km)) mi") {
                        prefs.radiusKM = km
                        Task { await rerunCurrentQuery() }
                    }
                }
            }
            .navigationDestination(item: $selected) { listing in
                DetailView(listing: listing, namespace: heroNamespace)
            }
        }
    }

    // MARK: - Pieces

    /// §3.1 — the radius is the product's whole thesis, so it's always visible
    /// and one tap from changing, never buried in settings.
    private var radiusButton: some View {
        Button { showRadiusPicker = true } label: {
            Label("\(SearchQuery.kilometresToMiles(prefs.radiusKM)) mi", systemImage: "location.circle")
                .font(.subheadline.weight(.medium))
        }
    }

    /// Recent searches, or suggested categories on first launch so the row is
    /// never a blank strip.
    private var pillRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if prefs.recentSearches.isEmpty {
                    ForEach(Preferences.suggestedCategories, id: \.self) { name in
                        pill(name, systemImage: "square.grid.2x2") {
                            Task { await browse(category: name) }
                        }
                    }
                } else {
                    ForEach(prefs.recentSearches, id: \.self) { term in
                        pill(term, systemImage: "clock.arrow.circlepath") {
                            searchText = term
                            Task { await search(term) }
                        }
                        .contextMenu {
                            Button(role: .destructive) { prefs.removeSearch(term) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func pill(_ text: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: systemImage)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

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
                EmptyStatePrompt()
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        StaggeredGrid(items: store.listings, columns: 2, spacing: 12) { listing in
            ListingCard(listing: listing, namespace: heroNamespace)
                .onTapGesture { selected = listing }
                .contextMenu {
                    Button(role: .destructive) { store.hide(listing) } label: {
                        Label("Hide this listing", systemImage: "eye.slash")
                    }
                }
                .task { await store.loadMoreIfNeeded(currentItem: listing) }
        }
        .padding(.horizontal, 12)
        .overlay(alignment: .bottom) {
            if store.isLoadingMore {
                ProgressView().padding()
            }
        }
    }

    // MARK: - Actions

    private func search(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        prefs.recordSearch(trimmed)
        await store.run(makeQuery(.search(trimmed)))
    }

    private func browse(category: String) async {
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
            Task { await location.resolveOnce() }
        }
        return SearchQuery(
            kind: kind,
            radiusKM: prefs.radiusKM,
            citySlug: prefs.locationSlug ?? "sanfrancisco",
            coordinate: location.coordinate
        )
    }
}

struct EmptyStatePrompt: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Search for something nearby")
                .font(.headline)
            Text("Or pick a category above.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
