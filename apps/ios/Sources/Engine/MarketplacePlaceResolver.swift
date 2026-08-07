import Foundation
import CoreLocation
import WebKit
import os

extension Logger {
    static let place = Logger(subsystem: "com.brianli101.marketplace", category: "place")
}

/// Turns a coordinate into a place Facebook recognises, by asking Facebook.
///
/// Named for what it does and where the answer comes from: the resolution is
/// Facebook's, performed in its own picker (`GeoPickerScripts`). The app
/// supplies a coordinate and reads back a place — it never derives a slug
/// itself, which is the whole point. Both user journeys are the same call:
///
/// * **"Use my location"** — the device's CoreLocation fix.
/// * **"Browse another city"** — a coordinate from Apple's search completer
///   (`AppleMapsCitySearch`), so the user can pick anywhere at all rather than
///   from a list somebody curated.
///
/// Runs in its own throwaway webview on the **unauthed** store, so resolving a
/// place never touches the signed-in session, and nothing about it persists
/// beyond the `ResolvedPlace` returned.
@MainActor
final class MarketplacePlaceResolver: NSObject, WKNavigationDelegate {
    enum Failure: Error, Equatable {
        /// The header pill wasn't there, so the dialog was never opened.
        case noPill
        /// The dialog opened but the centring arrow wasn't in it.
        case noArrow
        /// The arrow was clicked but never called the shim.
        case notAsked
        /// Facebook resolved to nothing usable — no place segment in the URL.
        case unresolved
        /// It resolved, but a fresh load of the resulting URL didn't come back
        /// naming that place. The characteristic failure of this whole area:
        /// the results look fine and are for somewhere else.
        case notConfirmed(shown: String?)
    }

    private let webView: WKWebView
    private var navContinuation: CheckedContinuation<Void, Never>?

    override init() {
        let config = WKWebViewConfiguration.make(session: .unauthed)
        config.userContentController.addUserScript(
            WKUserScript(source: GeoPickerScripts.feeder,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900),
                            configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = Surface.desktop.userAgent
    }

    /// Hands Facebook a coordinate and reports back what it called the place.
    ///
    /// Deliberately sequential with real waits rather than a single injected
    /// script: every step here is a React re-render that has to land before the
    /// next selector exists, and the picker's own network round-trip sits in
    /// the middle of it.
    func resolve(_ coordinate: CLLocationCoordinate2D,
                 origin: ResolvedPlace.Origin) async -> Result<ResolvedPlace, Failure> {
        await navigate(to: URL(string: "https://www.facebook.com/marketplace/")!)
        try? await Task.sleep(for: .seconds(4))

        _ = await js(GeoPickerScripts.arm(latitude: coordinate.latitude,
                                          longitude: coordinate.longitude))

        guard await flag(GeoPickerScripts.openDialog, "opened") else {
            Logger.place.error("resolve: no location pill")
            return .failure(.noPill)
        }
        try? await Task.sleep(for: .seconds(2))

        let arrow = await js(GeoPickerScripts.clickArrow)
        guard arrow.contains("\"clicked\":true") else {
            Logger.place.error("resolve: no centring arrow")
            return .failure(.noArrow)
        }
        guard arrow.contains("\"called\":true") else {
            Logger.place.error("resolve: arrow did not ask for a position")
            return .failure(.notAsked)
        }
        // The picker reverse-geocodes over the network before the field
        // updates, and Apply before that lands commits the *old* place.
        try? await Task.sleep(for: .seconds(3))

        _ = await js(GeoPickerScripts.apply)
        try? await Task.sleep(for: .seconds(4))

        let result = await js(GeoPickerScripts.readResult)
        let url = value(in: result, key: "url").flatMap(URL.init(string:))
        let place = MarketplaceURLPlace.parse(url)
        guard let segment = place.segment, place.isExplicit else {
            Logger.place.error("resolve: unresolved — \(place.summaryDescription, privacy: .public)")
            return .failure(.unresolved)
        }
        // Facebook's own name for it, falling back to the segment so the user
        // always sees something rather than a blank chip.
        let name = value(in: result, key: "name") ?? segment.capitalized
        let browseURL = url?.absoluteString
        Logger.place.info("resolved \(coordinate.latitude, privacy: .public),\(coordinate.longitude, privacy: .public) -> \(name, privacy: .public) [\(segment, privacy: .public)]")

        // Applying is not the same as it having worked.
        return await confirm(ResolvedPlace(name: name, segment: segment,
                                           coordinate: coordinate, origin: origin,
                                           browseURL: browseURL))
    }

    /// Loads the resulting URL from scratch and checks that the page comes back
    /// naming the place we think we set.
    ///
    /// This is not belt-and-braces. A refused place doesn't error — Facebook
    /// rewrites the path and serves the IP-inferred city with a full, healthy
    /// result set (`docs/location.md` §3), so "it applied" and "it worked" are
    /// genuinely different claims and only one of them is worth storing.
    ///
    /// Deliberately a **fresh navigation** rather than reading the page still on
    /// screen. The post-Apply page was mutated client-side by React and would
    /// tell us what the picker believes; what matters is what the server does
    /// with this URL on a cold request, which is the request every later search
    /// will make.
    func confirm(_ place: ResolvedPlace) async -> Result<ResolvedPlace, Failure> {
        guard let target = place.browseURL.flatMap(URL.init(string:)) else {
            return .failure(.unresolved)
        }
        await navigate(to: target)
        // The pill renders after the payload — measured at up to ~2.5 s — so a
        // single read here would report "no pill" for a page that has one.
        var located = await readLocation()
        for _ in 0..<10 where located.pill == nil {
            try? await Task.sleep(for: .milliseconds(300))
            located = await readLocation()
        }
        Logger.place.info("confirm \(place.segment, privacy: .public): \(located.summary, privacy: .public)")

        guard located.wasAccepted else {
            return .failure(.notConfirmed(shown: located.pill?.placeName))
        }
        // Nil means "no pill to compare", which is not a failure — the page may
        // simply not have drawn one. A pill that names a *different* place is.
        if located.pillAgrees(withRequestedName: place.name) == false {
            return .failure(.notConfirmed(shown: located.pill?.placeName))
        }
        var confirmed = place
        confirmed.verifiedPill = located.pill?.rawPillText
        confirmed.verifiedAt = Date()
        return .success(confirmed)
    }

    /// Reads the URL's place and the rendered pill together, so a disagreement
    /// between them is visible rather than averaged away.
    private func readLocation() async -> DesktopPageLocation {
        let raw = await js(GeoPickerScripts.readResult)
        let url = value(in: raw, key: "url").flatMap(URL.init(string:))
        let pillText = value(in: raw, key: "pill")
        return DesktopPageLocation(urlPlace: MarketplaceURLPlace.parse(url),
                                   pill: pillText.map(DesktopLocationPill.init(rawPillText:)))
    }

    // MARK: - Plumbing

    private func flag(_ script: String, _ key: String) async -> Bool {
        await js(script).contains("\"\(key)\":true")
    }

    private func value(in json: String, key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object[key] as? String, !text.isEmpty else { return nil }
        return text
    }

    private func js(_ script: String) async -> String {
        let result = try? await webView.evaluateJavaScript(script)
        return (result as? String) ?? ""
    }

    private func navigate(to url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navContinuation = cont
            webView.load(URLRequest(url: url))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            navContinuation?.resume()
            navContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            navContinuation?.resume()
            navContinuation = nil
        }
    }
}

private extension MarketplaceURLPlace {
    /// For the log line, which needs a plain description of the refusal.
    var summaryDescription: String {
        switch self {
        case .citySlug(let s): "slug \(s)"
        case .placeID(let id): "place id \(id)"
        case .ipInferred: "IP-inferred (place refused)"
        case .refused: "refused"
        case .notAPlaceURL: "not a place URL"
        }
    }
}
