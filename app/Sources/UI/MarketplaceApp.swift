import SwiftUI
import WebKit

@main
struct MarketplaceApp: App {
    @StateObject private var store = ListingStore()
    @StateObject private var prefs = Preferences.shared
    @StateObject private var location = LocationProvider()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(prefs)
                .environmentObject(location)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        ZStack {
            // §2.1 — the engines' webviews must be in the hierarchy or WebKit
            // throttles script execution and lazy content never arrives. They
            // sit behind the UI at effectively zero opacity.
            HiddenWebViewHost(webView: store.feed.webView)
            HiddenWebViewHost(webView: store.detail.webView)

            ResultsView()
        }
        .fullScreenCover(isPresented: .init(
            get: { !prefs.hasSeenFirstRun },
            set: { if !$0 { prefs.hasSeenFirstRun = true } }
        )) {
            FirstRunView { prefs.hasSeenFirstRun = true }
        }
    }
}

/// Attached, sized, and rendering — but invisible and non-interactive.
struct HiddenWebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.005
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
