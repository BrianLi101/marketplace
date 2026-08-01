import UIKit

/// §4 — universal links to the canonical web URL. iOS routes them to the
/// Facebook app when it's installed and to Safari when it isn't. The `fb://`
/// custom scheme is undocumented and fails silently, so it's never used.
enum Handoff {
    static func open(_ url: URL, kind: String, metrics: MetricsReporter = LocalMetrics.shared) {
        metrics.handoff(kind: kind)
        UIApplication.shared.open(url)
    }

    static func openMarketplace(metrics: MetricsReporter = LocalMetrics.shared) {
        guard let url = URL(string: "https://www.facebook.com/marketplace/") else { return }
        open(url, kind: "marketplace-root", metrics: metrics)
    }
}
