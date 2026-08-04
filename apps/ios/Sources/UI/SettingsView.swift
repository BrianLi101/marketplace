import SwiftUI

/// §5 — Settings has to carry real functionality, which also answers Apple's
/// minimum-functionality concern about thin webview wrappers.
struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var location: LocationProvider
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Search area") {
                    Picker("Default radius", selection: $prefs.radiusKM) {
                        ForEach(Preferences.radiusOptions, id: \.self) { km in
                            Text("\(SearchQuery.kilometresToMiles(km)) mi").tag(km)
                        }
                    }
                    LabeledContent("Location", value: prefs.locationName ?? "Not set")
                }

                Section("Recent searches") {
                    Button("Clear search history") { prefs.recentSearches = [] }
                        .disabled(prefs.recentSearches.isEmpty)
                }

                Section {
                    Text("This app browses public Marketplace listings without signing in. It never asks for, stores, or sees your Facebook password. Messaging a seller opens the Facebook app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
