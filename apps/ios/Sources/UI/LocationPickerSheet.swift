import SwiftUI
import MapKit
import CoreLocation

/// Choose where to browse: here, or anywhere.
///
/// Replaces a hand-curated list of seven cities, which was never really a
/// feature — it was a workaround for the app having to guess slugs, and it
/// guessed wrong for five of the twelve it originally shipped.
///
/// Both routes end in the same place: a coordinate is handed to Facebook's own
/// picker and Facebook names the place (`MarketplacePlaceResolver`). Apple
/// answers "where is what the user typed", Facebook answers "what do you call
/// that", and the slug is valid because Facebook produced it.
struct LocationPickerSheet: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var location: LocationProvider
    @StateObject private var cities = AppleMapsCitySearch()
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var pending: Pending?
    @State private var failure: String?

    /// What we're waiting on, so the right row shows the spinner.
    private enum Pending: Equatable {
        case deviceFix
        case city(String)
    }

    var body: some View {
        NavigationStack {
            List {
                currentSection
                if !cities.suggestions.isEmpty { suggestionSection }
                if let failure { failureSection(failure) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search for a city")
            .onChange(of: query) { cities.search(query) }
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var currentSection: some View {
        Section {
            if let place = prefs.resolvedPlace {
                LocationMapCard(place: place.name, coordinate: place.coordinate,
                                precision: .city,
                                userLocation: location.coordinate)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                HStack {
                    Image(systemName: place.origin == .deviceFix ? "location.fill" : "mappin.and.ellipse")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name).font(.subheadline.weight(.semibold))
                        // The segment is worth showing. It is what actually
                        // goes in the URL, and seeing "Berkeley → oakland"
                        // explains a surprising result set immediately.
                        Text("Facebook calls this `\(place.segment)`")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                Task { await useDeviceLocation() }
            } label: {
                HStack {
                    Label("Use my current location", systemImage: "location")
                    Spacer()
                    if pending == .deviceFix { ProgressView().controlSize(.small) }
                }
            }
            .disabled(pending != nil)
        } header: {
            Text(prefs.resolvedPlace == nil ? "Location" : "Browsing")
        } footer: {
            Text("Your coordinate is sent to Facebook once, to name the place. "
                 + "Searches after that use the place name, not your position.")
        }
    }

    private var suggestionSection: some View {
        Section("Cities") {
            ForEach(cities.suggestions) { suggestion in
                Button {
                    Task { await use(suggestion) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if pending == .city(suggestion.display) {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(pending != nil)
            }
        }
    }

    private func failureSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Resolution

    private func useDeviceLocation() async {
        failure = nil
        pending = .deviceFix
        defer { pending = nil }
        guard let coordinate = await location.resolveOnce() else {
            failure = location.isDenied
                ? "Location is off for Marketplace. Turn it on in Settings."
                : "Couldn't get a location fix."
            return
        }
        await apply(coordinate, origin: .deviceFix)
    }

    private func use(_ suggestion: AppleMapsCitySearch.Suggestion) async {
        failure = nil
        pending = .city(suggestion.display)
        defer { pending = nil }
        guard let coordinate = await cities.coordinate(for: suggestion) else {
            failure = "Couldn't place \(suggestion.title) on the map."
            return
        }
        await apply(coordinate, origin: .searchedCity)
    }

    private func apply(_ coordinate: CLLocationCoordinate2D, origin: ResolvedPlace.Origin) async {
        let resolver = MarketplacePlaceResolver()
        switch await resolver.resolve(coordinate, origin: origin) {
        case .success(let place):
            prefs.setResolvedPlace(place)
            query = ""
            cities.clear()
        case .failure(let error):
            // Named rather than generic: each of these is a different thing
            // going wrong and the distinction is what makes a report useful.
            failure = switch error {
            case .noPill: "Facebook's location control wasn't on the page."
            case .noArrow: "Facebook's location dialog didn't offer the current-location button."
            case .notAsked: "Facebook didn't ask for a position."
            case .unresolved: "Facebook didn't recognise that place."
            }
        }
    }
}
