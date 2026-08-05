import SwiftUI

/// §5 — Settings has to carry real functionality, which also answers Apple's
/// minimum-functionality concern about thin webview wrappers.
struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var location: LocationProvider
    @EnvironmentObject private var store: ListingStore
    @Environment(\.dismiss) private var dismiss
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Facebook account") {
                    LabeledContent("Status",
                                   value: store.session == .authed ? "Signed in" : "Browsing anonymously")
                    Button(store.session == .authed ? "Manage account" : "Sign in") {
                        showSignIn = true
                    }
                    Text(store.session == .authed
                         ? "Seller names and ratings are visible, and results keep loading past the first page."
                         : "Signing in adds seller names and ratings, and lets results load past the first ~15. Optional — everything else works without it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
                    Text("Signing in is optional and happens on Facebook's own page — this app never asks for, stores, or sees your password. Anonymous browsing uses a separate store that shares nothing with your account. Messaging a seller opens the Facebook app.")
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
            .sheet(isPresented: $showSignIn) {
                SignInView {
                    // The result set itself changes with the session, so drop
                    // anything cached under the old one and re-run.
                    Task {
                        store.setSession(await SessionState.isSignedIn() ? .authed : .unauthed)
                        await store.retry()
                    }
                }
            }
        }
    }
}
