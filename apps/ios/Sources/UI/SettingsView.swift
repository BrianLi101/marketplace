import SwiftUI

/// §5 — Settings has to carry real functionality, which also answers Apple's
/// minimum-functionality concern about thin webview wrappers.
struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var viewed: ViewedListings
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

                // "Search area" used to sit here — a default-radius picker and
                // a read-only location row. Both moved to the location sheet,
                // where the place and the distance are chosen together because
                // they read as one fact ("San Francisco · 10 mi"), and both are
                // one tap from the bar that displays them.
                //
                // The radius picker had also quietly become wrong: it offered
                // only the standard rungs, so a radius set by "Try 6 mi" on the
                // results screen couldn't be represented, and opening Settings
                // would show some other value as selected.

                Section("History") {
                    Button("Clear search history") { prefs.recentSearches = [] }
                        .disabled(prefs.recentSearches.isEmpty)
                    Button("Clear viewing history") { viewed.clear() }
                        .disabled(viewed.isEmpty)
                    Text("Viewing history is what \"Only new listings\" filters against, and what fills Recently viewed. It stays on this device — Facebook is never told which listings you opened.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
