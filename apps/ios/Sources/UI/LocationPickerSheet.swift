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

    /// Typing takes the screen over.
    ///
    /// The suggestions used to be a third section, below the map and the
    /// distance pills — so results for what you had just typed appeared off the
    /// bottom of the screen and had to be scrolled to. A search field whose
    /// results aren't where you are looking isn't a search field.
    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    suggestionSection
                } else {
                    currentSection
                    distanceSection
                }
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
                // Just the name.
                //
                // This used to also print the URL segment and a "confirmed on
                // Facebook" badge. Both were really notes to ourselves: the
                // segment is an implementation detail, and the badge reassured
                // the reader about something that is now an invariant — an
                // unconfirmed place is never stored at all, so anything on this
                // screen has already been checked. Saying so added a line
                // without adding a fact.
                HStack {
                    Image(systemName: place.isUserLocation ? "location.fill" : "mappin.and.ellipse")
                        .foregroundStyle(.tint)
                    Text(place.name)
                        .font(.subheadline.weight(.semibold))
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

    /// Distance lives here rather than in the filter sheet.
    ///
    /// "San Francisco · 10 mi" is one thought — where, and how far — and the
    /// bar states it as one readout, so the control that changes it should be
    /// one screen too. Splitting them meant tapping the location pill to change
    /// the place, then a different sheet to change the radius, for a phrase the
    /// user reads as a single fact.
    private var distanceSection: some View {
        Section {
            WrapLayout(spacing: 8) {
                ForEach(distanceOptions, id: \.self) { km in
                    distancePill("\(SearchQuery.kilometresToMiles(km)) mi", isOn: prefs.radiusKM == km) {
                        prefs.radiusKM = km
                    }
                }
                distancePill("Any", isOn: prefs.radiusKM == 0) { prefs.radiusKM = 0 }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Distance")
        } footer: {
            // Worth repeating here: this one is ours, and it is the reason a
            // result set can look emptier than the place suggests.
            Text("Applied on this device — Facebook ignores distance in a search.")
        }
    }

    /// The standard rungs, plus wherever the user actually is.
    ///
    /// "Try 15 mi" on the results screen sets a radius the ladder doesn't
    /// contain, and a picker that couldn't show it would present every pill
    /// unselected — reading as "no distance set" for a search that is very
    /// much filtered. Inserting the current value keeps the control honest,
    /// and it disappears again the moment a rung is chosen.
    private var distanceOptions: [Int] {
        let options = Preferences.radiusOptions
        guard prefs.radiusKM > 0, !options.contains(prefs.radiusKM) else { return options }
        return (options + [prefs.radiusKM]).sorted()
    }

    private func distancePill(_ text: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(isOn ? Color.accentColor : Color(.secondarySystemBackground)))
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var suggestionSection: some View {
        Section("Cities") {
            // Now that this is the only thing on screen while typing, it has to
            // account for having nothing to show — an empty section would read
            // as the field being broken.
            if cities.suggestions.isEmpty {
                Text(cities.isSearching ? "Searching…" : "No places found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
                ? "Location is off for Open Market. Turn it on in Settings."
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
            case .paced: "Too many requests just now. Try again shortly."
            case .notConfirmed(let shown):
                if let shown {
                    "Facebook set the location but then served \(shown) instead. Not saved."
                } else {
                    "Couldn't confirm the location took effect. Not saved."
                }
            }
        }
    }
}
