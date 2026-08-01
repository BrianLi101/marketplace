import SwiftUI
import WebKit

@main
struct MarketplaceApp: App {
    @StateObject private var store = ListingStore()
    @StateObject private var prefs = Preferences.shared
    @StateObject private var location = LocationProvider()
    @StateObject private var distances = DistanceResolver.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(prefs)
                .environmentObject(location)
                .environmentObject(distances)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        ZStack {
            ResultsView()

            // §2.1 — the engines' webviews must be in the hierarchy or WebKit
            // throttles them. But *covering* them isn't good enough either:
            // behind an opaque view, WebKit takes a reduced rendering path and
            // parts of each card (notably the location line) never render at
            // all. So they're laid out at full size and pushed outside the
            // visible area, where WebKit still treats them as live.
            HiddenWebViewHost(webView: store.feed.webView)
                .offset(x: 3000)
            HiddenWebViewHost(webView: store.detail.webView)
                .offset(x: 3000)
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
        // Fully live — normal opacity, interaction and scrolling all enabled —
        // because WebLite's rendering and tap handling both degrade when the
        // view is treated as inert. It stays invisible by sitting behind the
        // opaque results UI rather than by being dimmed or disabled.
        webView.isUserInteractionEnabled = true
        webView.alpha = 1
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
