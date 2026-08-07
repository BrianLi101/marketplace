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
                distanceSection
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
                        // Says it was checked, not just requested. A place that
                        // resolved and then quietly served somewhere else is
                        // never stored, so anything shown here is confirmed.
                        if let pill = place.verifiedPill {
                            Label("Confirmed on Facebook — \(pill)", systemImage: "checkmark.seal")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
                ForEach(Preferences.radiusOptions, id: \.self) { km in
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
