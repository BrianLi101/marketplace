import SwiftUI

/// §5 — Settings has to carry real functionality. The keyword blocklist and
/// hidden-listings management are genuinely useful and also answer Apple's
/// minimum-functionality concern about thin webview wrappers.
struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var location: LocationProvider
    @Environment(\.dismiss) private var dismiss
    @State private var newKeyword = ""

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

                Section {
                    HStack {
                        TextField("Add a word to hide", text: $newKeyword)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit(addKeyword)
                        Button("Add", action: addKeyword)
                            .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(prefs.blockedKeywords, id: \.self) { word in
                        Text(word)
                    }
                    .onDelete { indexSet in
                        prefs.blockedKeywords.remove(atOffsets: indexSet)
                    }
                } header: {
                    Text("Hidden keywords")
                } footer: {
                    Text("Listings whose title matches any of these are never shown.")
                }

                Section("Hidden listings") {
                    LabeledContent("Hidden", value: "\(prefs.hiddenListingIDs.count)")
                    Button("Unhide all") { prefs.unhideAll() }
                        .disabled(prefs.hiddenListingIDs.isEmpty)
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

    private func addKeyword() {
        prefs.addKeyword(newKeyword)
        newKeyword = ""
    }
}
