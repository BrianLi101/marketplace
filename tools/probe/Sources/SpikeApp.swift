import SwiftUI
import WebKit

@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var controller = SpikeController()

    var body: some View {
        VStack(spacing: 0) {
            WebViewRepresentable(webView: controller.webView)
                .frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                Button("Open login") { controller.openLogin() }
                    .buttonStyle(.borderedProminent)
                Button("Check session") { controller.checkSession() }
                Button("Run tests") { controller.startLoggedInTests() }
                    .disabled(!controller.looksSignedIn)
                Button("Timing") { controller.startTimingTests() }
                    .disabled(!controller.looksSignedIn)
                Button("Seller") { controller.startSellerSurvey() }
                    .disabled(!controller.looksSignedIn)
                Button("Route") { controller.startRouteComparison() }
                    .disabled(!controller.looksSignedIn)
                Button("Rated") { controller.startRatedRouteTest() }
                    .disabled(!controller.looksSignedIn)
                // Ungated: how location is resolved is worth knowing in both
                // states, and a signed-in account may carry its own saved city.
                Button("Location") { controller.startLocationTests() }
                Button("Slugs") { controller.startSlugSurvey() }
                Button("Picker") { controller.startPickerProbe() }
                Button("Persist") { controller.startPersistenceProbe() }
                Button("GeoFeed") { controller.startGeoFeedProbe() }
            }
            .font(.caption)
            .padding(.vertical, 4)
            Text(controller.sessionState)
                .font(.caption2)
                .foregroundStyle(controller.looksSignedIn ? .green : .secondary)
                .padding(.bottom, 2)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(controller.log.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 180)
                .background(Color(white: 0.95))
                .onChange(of: controller.log.count) {
                    proxy.scrollTo(controller.log.count - 1, anchor: .bottom)
                }
            }
        }
        .onAppear { controller.checkSession() }
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class SpikeController: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var log: [String] = []
    let webView: WKWebView
    private var navContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    override init() {
        let config = WKWebViewConfiguration()
        // Persistent, unlike everywhere else in this project: a signed-in
        // session has to survive relaunches or every probe run would need the
        // password typed again. This is the harness, not the app — the app's
        // engines still use .nonPersistent().
        config.websiteDataStore = .default()
        // Patching fetch/XHR from evaluateJavaScript after first paint is not a
        // real measurement: the page's own bundle has already run and may hold
        // a reference to the originals, so "nothing was captured" is
        // indistinguishable from "the hook was bypassed". Injecting at document
        // start puts the recorder in place before any page script exists.
        config.userContentController.addUserScript(
            WKUserScript(source: Self.wireRecorderJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        // WebSocket frames appear in no Resource Timing entry and go through
        // neither fetch nor XHR, which is exactly why §5b came back empty on
        // both instruments. Wrap the constructor before any page script runs.
        config.userContentController.addUserScript(
            WKUserScript(source: Self.socketRecorderJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        // Does Facebook ever *ask* the browser where it is? If it does, the
        // app can answer with the user's real fix and get exact targeting for
        // free. Same reasoning as the two above: hook before any page script
        // exists, or "never called" is indistinguishable from "called before
        // we were watching".
        config.userContentController.addUserScript(
            WKUserScript(source: Self.geoRecorderJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        // §5a said the picker's centring arrow accepts any coordinate — in a
        // desktop browser. The app runs `WKWebView`, which has never supported
        // the Geolocation API properly, so the question here isn't "will the
        // user grant permission" but "does the API even exist to be called".
        // This sidesteps both: it *replaces* the API with one that answers with
        // whatever `__geoFeed` holds, so the web view needs no location
        // permission of its own and Facebook can only ever receive a
        // coordinate the app chose to give it.
        config.userContentController.addUserScript(
            WKUserScript(source: Self.geoFeederJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func emit(_ s: String) {
        log.append(s)
        NSLog("SPIKE| %@", s)
    }

    @Published var sessionState = "not checked"
    @Published var looksSignedIn = false

    func start() {
        guard !started else { return }
        started = true
        Task { await runTests() }
    }

    // MARK: - Signed-in session

    /// Opens Facebook's own login page for the user to sign in by hand.
    ///
    /// Deliberately the real page in a visible webview: nothing in this project
    /// collects a password, and nothing here should either. Loads under the
    /// mobile user agent because the desktop login form is unusable on a phone
    /// screen — the cookie jar is shared, so tests can switch to the desktop
    /// agent afterwards.
    func openLogin() {
        Task {
            webView.customUserAgent = Self.mobileUA
            await load("https://www.facebook.com/login/")
            emit("login page loaded — sign in in the webview above, then tap 'Check session'")
        }
    }

    /// `c_user` is the account id cookie; its presence is the cheapest reliable
    /// signal that a session exists.
    func checkSession() {
        Task {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let facebook = cookies.filter { $0.domain.contains("facebook.com") }
            let hasUser = facebook.contains { $0.name == "c_user" }
            let hasSession = facebook.contains { $0.name == "xs" }
            looksSignedIn = hasUser && hasSession
            sessionState = looksSignedIn
                ? "signed in — \(facebook.count) fb cookies, c_user + xs present"
                : "signed out — \(facebook.count) fb cookies, c_user=\(hasUser) xs=\(hasSession)"
            emit("SESSION \(sessionState)")
        }
    }

    func startLoggedInTests() {
        Task { await runLoggedInTests() }
    }

    func startTimingTests() {
        Task {
            webView.customUserAgent = Self.desktopUA
            await runTimingTests()
        }
    }

    func startRouteComparison() {
        Task { await runRouteComparison() }
    }

    func startLocationTests() {
        Task { await runLocationTests() }
    }

    func startSlugSurvey() {
        Task { await runSlugSurvey() }
    }

    func startPickerProbe() {
        Task { await runPickerProbe() }
    }

    func startPersistenceProbe() {
        Task { await runPersistenceProbe() }
    }

    /// Run **after** driving the picker by hand. Does the place it set survive?
    ///
    /// This decides how the app would use the picker. If the choice is session
    /// state, the app sets a location once in a hidden webview and every later
    /// search inherits it — no ids, no slugs, no URL construction. If it isn't,
    /// the picker is only useful as a *resolver*: drive it once, learn the place
    /// id, and address that id by URL forever after.
    ///
    /// Cookies persist across relaunch here (`.default()` store), so a fresh
    /// launch is a fair test of the session rather than of the page.
    func runPersistenceProbe() async {
        webView.customUserAgent = Self.desktopUA

        // No place segment at all: whatever comes back is what the session
        // believes, not what the URL asked for.
        await load("https://www.facebook.com/marketplace/search/?query=desk")
        try? await Task.sleep(for: .seconds(9))
        emit("PERSIST[no_place] \(await js(Self.slugVerdictJS))")
        emit("PERSIST[ids] \(await js(Self.placeIDHarvestJS))")

        // And the app's own form of URL, to see whether a place segment still
        // overrides a session location.
        await load("https://www.facebook.com/marketplace/sanfrancisco/search/?query=desk")
        try? await Task.sleep(for: .seconds(9))
        emit("PERSIST[slug_sf] \(await js(Self.slugVerdictJS))")

        emit("=== PERSISTPROBE COMPLETE ===")
    }

    /// Can the user pick a place the app has never seen — Toronto, from San
    /// Francisco?
    ///
    /// Harvesting ids from search payloads (`location-targeting.md` §6) only
    /// ever learns places the user already got listings from, so it cannot
    /// answer that. Three candidate mechanisms, cheapest first:
    ///
    ///  1. **A ZIP or postcode as the path segment.** If Facebook resolves one,
    ///     arbitrary location is a text field and nothing else.
    ///  2. **Slugs for major cities.** Known to work for metros; the question is
    ///     only whether that extends past the US.
    ///  3. **Facebook's own location picker**, driven in a webview. It accepts
    ///     city, ZIP and neighbourhood, and resolves them server-side — so if it
    ///     can be driven, it is a general place resolver we don't have to build,
    ///     and whatever it navigates to tells us the id it chose.
    ///
    /// Synthetic clicks do work on this site (`filter-parameters.md` §4
    /// correction), so the picker is worth trying rather than assuming.
    /// Does §5a's coordinate route survive in `WKWebView`?
    ///
    /// Three things could differ from the desktop browser it was measured in:
    /// the API may not exist at all (WKWebView has never really shipped
    /// Geolocation), Facebook may feature-detect and hide the arrow, and the
    /// resolution may be done somewhere that behaves differently for a
    /// logged-out mobile-ish session.
    ///
    /// Feeds **London** — which is neither the IP city (San Francisco) nor
    /// whatever the persistent store is already set to from an earlier probe
    /// run. A result of "London" therefore can't be the IP talking, and can't
    /// be leftover state either. The first run of this probe fed Toronto and
    /// the web view was *already* on Toronto from the picker probe, which
    /// would have made a failure look like a pass.
    func runGeoFeedProbe() async {
        webView.customUserAgent = Self.desktopUA

        await load("https://www.facebook.com/marketplace/")
        try? await Task.sleep(for: .seconds(9))

        // Positive control first: prove the shim is installed and reachable,
        // or "Facebook never called it" and "we never hooked it" look alike.
        emit("GEOFEED[control] \(await js("""
        (function(){
          window.__geoFeed = { lat: 51.5074, lon: -0.1278 };   // London
          var before = window.__geoFedCalls;
          var got = null;
          navigator.geolocation.getCurrentPosition(function(p){ got = p.coords.latitude; });
          return JSON.stringify({ hooked: !!window.__geoFedHooked,
                                  geoWasMissing: window.__geoWasMissing,
                                  sawOwnCall: window.__geoFedCalls > before,
                                  startedAt: (document.body.innerText.match(/\\n([A-Za-z ]+)\\s*·\\s*\\d+\\s*(mi|km)/) || [])[1] || null });
        })()
        """))")

        emit("GEOFEED[open] \(await js(Self.openLocationDialogJS))")
        try? await Task.sleep(for: .seconds(4))

        emit("GEOFEED[arrow] \(await js(Self.clickGeoArrowJS))")
        try? await Task.sleep(for: .seconds(5))
        emit("GEOFEED[field] \(await js(Self.pickerFieldJS))")

        emit("GEOFEED[apply] \(await js(Self.applyLocationJS))")
        try? await Task.sleep(for: .seconds(9))
        emit("GEOFEED[result] \(await js(Self.resultCitiesJS))")

        emit("=== GEOFEEDPROBE COMPLETE ===")
    }

    func startGeoFeedProbe() { Task { await runGeoFeedProbe() } }

    func runPickerProbe() async {
        webView.customUserAgent = Self.desktopUA
        let query = "?query=desk"

        // 1 and 2 — entry forms that need no interaction at all.
        for place in ["94110", "94103", "toronto", "vancouver", "london", "m5v"] {
            await load("https://www.facebook.com/marketplace/\(place)/search/\(query)")
            try? await Task.sleep(for: .seconds(8))
            emit("ENTRY[\(place)] \(await js(Self.slugVerdictJS))")
        }

        // 3 — the picker itself.
        await load("https://www.facebook.com/marketplace/sanfrancisco/search/\(query)")
        try? await Task.sleep(for: .seconds(9))
        emit("PICKER[candidates] \(await js(Self.pickerCandidatesJS))")

        emit("PICKER[open] \(await js(Self.clickPickerJS))")
        try? await Task.sleep(for: .seconds(4))
        emit("PICKER[dialog] \(await js(Self.dialogDumpJS))")

        emit("PICKER[type] \(await js(Self.typeTorontoJS))")
        try? await Task.sleep(for: .seconds(4))
        emit("PICKER[options] \(await js(Self.dialogDumpJS))")

        emit("=== PICKERPROBE COMPLETE ===")
    }

    /// Two follow-ups to `runLocationTests`, which established that a *valid*
    /// slug relocates the results and an invalid one silently rewrites to
    /// `/marketplace/category/search/` and serves the IP-inferred city.
    ///
    ///  1. **How often does naive slugification miss?** `sandiego` worked and
    ///     `santarosa` and `walnutcreek` did not, which suggests aliases exist
    ///     for metros and not for everywhere else. If the miss rate is high,
    ///     "lowercase the city and strip spaces" cannot be the only mechanism.
    ///  2. **Is a place id harvested from a page's own payload usable as a path
    ///     segment?** Every card carries its city's `city_page.id`, so if a
    ///     harvested id works, the app can learn ids for the places its users
    ///     actually see, and never has to guess a slug for them.
    func runSlugSurvey() async {
        webView.customUserAgent = Self.desktopUA
        let query = "?query=desk"

        // Exactly the list the app ships in `MarketplaceCity.common`. The
        // general survey found `berkeley` rejected, which would mean the
        // shipped picker has entries that silently return the wrong city.
        let slugs = ["sanfrancisco", "oakland", "berkeley", "sanjose", "dalycity",
                     "paloalto", "fremont", "marin", "la", "nyc", "seattle", "chicago"]

        for slug in slugs {
            await load("https://www.facebook.com/marketplace/\(slug)/search/\(query)")
            try? await Task.sleep(for: .seconds(8))
            emit("SLUG[\(slug)] \(await js(Self.slugVerdictJS))")
        }

        // Harvest ids from a page whose results span several cities, then try
        // the one place we have never addressed by slug.
        await load("https://www.facebook.com/marketplace/107929532567815/search/\(query)")
        try? await Task.sleep(for: .seconds(9))
        let pairs = await js(Self.placeIDHarvestJS)
        emit("HARVEST \(pairs)")

        if let id = firstHarvestedID(pairs, excluding: "San Francisco") {
            await load("https://www.facebook.com/marketplace/\(id.1)/search/\(query)")
            try? await Task.sleep(for: .seconds(9))
            emit("HARVESTED_ID[\(id.0) = \(id.1)] \(await js(Self.slugVerdictJS))")
        } else {
            emit("HARVESTED_ID none usable")
        }

        emit("=== SLUGPROBE COMPLETE ===")
    }

    /// First `city -> place id` pair that isn't the city we searched from, so
    /// the follow-up load is a real relocation rather than a no-op.
    func firstHarvestedID(_ json: String, excluding: String) -> (String, String)? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return obj.sorted { $0.key < $1.key }.first { !$0.key.hasPrefix(excluding) }
            .map { ($0.key, $0.value) }
    }

    /// Can the app point Facebook at wherever the user actually is?
    ///
    /// What is already settled, both on **mobile** (`mobile-location-radius-notes.md`
    /// §7): city slugs relocate the result set, place ids work, and
    /// `latitude`/`longitude` are discarded in favour of the IP-inferred place.
    /// None of it was measured on **desktop**, which is now the app's primary
    /// search surface, and three questions matter for dropping the curated city
    /// list:
    ///
    ///  1. Does desktop honour `latitude`/`longitude`? If it does, a coordinate
    ///     goes straight into the URL and there is nothing else to build.
    ///  2. Does an *arbitrary* slug work — one nobody has hand-checked — and
    ///     what does a wrong slug do? A silent fall back to the IP-inferred
    ///     place is the dangerous answer: results that look fine and are for
    ///     the wrong city.
    ///  3. Does the page ask for `navigator.geolocation`? That would be live
    ///     location in the truest sense.
    ///
    /// Every case reports the **cities of the returned cards**, not the header.
    /// Radius was recorded as working for weeks on the strength of a chip that
    /// updated while the listings didn't (`filter-parameters.md` §3).
    func runLocationTests() async {
        let query = "?query=desk"
        func desktop(_ path: String, _ extra: String = "") -> String {
            "https://www.facebook.com/marketplace/\(path)search/\(query)\(extra)"
        }

        // San Diego is the target throughout: ~500 mi from the simulator's
        // IP-inferred San Francisco, so "did it move" needs no judgement call.
        let sanDiego = "&latitude=32.7157&longitude=-117.1611"

        let cases: [(String, String)] = [
            ("d_slug_sf",         desktop("sanfrancisco/")),
            ("d_slug_sanjose",    desktop("sanjose/")),            // positive control: cities must move
            ("d_no_place",        desktop("")),                    // IP baseline
            ("d_latlong_only",    desktop("", sanDiego)),          // Q1
            ("d_latlong_vs_slug", desktop("sanfrancisco/", sanDiego)),
            ("d_slug_sandiego",   desktop("sandiego/")),           // Q2 — arbitrary slug
            ("d_slug_santarosa",  desktop("santarosa/")),
            ("d_slug_walnutcreek", desktop("walnutcreek/")),       // two words, no vanity alias?
            ("d_slug_garbage",    desktop("notarealplacexyz/")),   // Q2 — the failure mode
            ("d_placeid_ssf",     desktop("107929532567815/"))     // known-good place id
        ]

        webView.customUserAgent = Self.desktopUA
        for (name, url) in cases {
            await load(url)
            try? await Task.sleep(for: .seconds(9))
            emit("LOC[\(name)] \(await js(Self.locationProbeJS))")
        }

        // Q3, and the control that says the geolocation hook works at all. A
        // page that never asked is indistinguishable from a hook that never
        // installed until the harness calls the API on itself and sees it.
        emit("LOC[geo_control_desktop] \(await js(Self.geoControlJS))")

        webView.customUserAgent = Self.mobileUA
        await load("https://www.facebook.com/marketplace/sanfrancisco/search/\(query)")
        try? await Task.sleep(for: .seconds(9))
        emit("LOC[m_slug_sf] \(await js(Self.locationProbeJS))")
        emit("LOC[geo_control_mobile] \(await js(Self.geoControlJS))")

        emit("=== LOCPROBE COMPLETE ===")
    }

    /// Does reaching an item page by clicking a card give the same data as
    /// loading its URL directly?
    ///
    /// Desktop Marketplace is a single-page app: a click is a client-side
    /// route change that renders a view, while a URL load is a fresh server
    /// render. There is no reason those must produce the same DOM, and a
    /// reported difference in seller information says they don't.
    ///
    /// Structure: a known-rated listing loaded directly first, as a positive
    /// control that the detector can see a rating at all — the previous survey
    /// searched for "246 ratings" while the page renders "(246)", so its
    /// zero-for-six may have been the selector rather than the sellers. Then
    /// the same listing reached both ways, so the comparison is self-controlled.
    func runRouteComparison() async {
        webView.customUserAgent = Self.desktopUA

        await load("https://www.facebook.com/marketplace/item/1532699951339768/")
        try? await Task.sleep(for: .seconds(9))
        emit("ROUTE[control_direct] \(await js(Self.sellerSectionJS))")

        let search = "https://www.facebook.com/marketplace/sanfrancisco/search/?query=desk"
        await load(search)
        try? await Task.sleep(for: .seconds(9))

        // A rating can only go missing on a route if the seller has one, so a
        // single unrated listing proves nothing either way. Walk several cards
        // through both routes and compare per listing.
        let idsRaw = await js(Self.cardIDListJS)
        let ids = Self.decodeIDs(idsRaw).prefix(6)
        emit("ROUTE[candidates] \(ids.joined(separator: ","))")

        for (index, id) in ids.enumerated() {
            // Route A — back to the search, then click that card in place.
            await load(search)
            try? await Task.sleep(for: .seconds(8))
            _ = await js(Self.clickCardAt(index: index))
            try? await Task.sleep(for: .seconds(9))
            emit("ROUTE[A:\(id)] \(await js(Self.sellerSectionJS))")

            // Route B — the same listing by direct URL load.
            await load("https://www.facebook.com/marketplace/item/\(id)/")
            try? await Task.sleep(for: .seconds(9))
            emit("ROUTE[B:\(id)] \(await js(Self.sellerSectionJS))")
        }

        emit("=== ROUTEPROBE COMPLETE ===")
    }

    static func decodeIDs(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    func startRatedRouteTest() {
        Task { await runRatedRouteTest() }
    }

    /// The route comparison found the two views differ, but every seller it
    /// sampled was unrated — so it could not tell whether the click route
    /// *drops* a rating or those sellers simply had none.
    ///
    /// Fixes that by finding a positive first: direct-load candidates until one
    /// with a rating turns up, then reach that same listing by clicking. Plant
    /// listings are the hunting ground because the known-rated seller in hand
    /// (246 ratings) sells anthuriums.
    func runRatedRouteTest() async {
        webView.customUserAgent = Self.desktopUA
        let search = "https://www.facebook.com/marketplace/sanfrancisco/search/?query=anthurium"

        await load(search)
        try? await Task.sleep(for: .seconds(9))
        let ids = Self.decodeIDs(await js(Self.cardIDListJS))
        emit("RATED[candidates] \(ids.count) cards")

        var ratedIndex: Int?
        var ratedID: String?
        for (index, id) in ids.prefix(10).enumerated() {
            await load("https://www.facebook.com/marketplace/item/\(id)/")
            try? await Task.sleep(for: .seconds(7))
            let report = await js(Self.sellerSectionJS)
            let isRated = report.contains("\"highlyRated\":true") || !report.contains("\"starLabels\":[]")
            emit("RATED[scan\(index):\(id)] rated=\(isRated) \(report.prefix(190))")
            if isRated, ratedIndex == nil {
                ratedIndex = index
                ratedID = id
            }
        }

        guard let ratedIndex, let ratedID else {
            emit("RATED[none] no rated seller among the candidates — route effect on ratings still unproven")
            return
        }

        // Same listing, reached by clicking its card in the search results.
        await load(search)
        try? await Task.sleep(for: .seconds(9))
        _ = await js(Self.clickCardAt(index: ratedIndex))
        try? await Task.sleep(for: .seconds(9))
        emit("RATED[clicked:\(ratedID)] \(await js(Self.sellerSectionJS))")

        await load("https://www.facebook.com/marketplace/item/\(ratedID)/")
        try? await Task.sleep(for: .seconds(8))
        emit("RATED[direct:\(ratedID)] \(await js(Self.sellerSectionJS))")

        // Seller data survives both routes, but the modal carries roughly 40%
        // of the body text. Name what is actually missing, because a field
        // that silently disappears on one route is how an extractor starts
        // returning nulls for no visible reason.
        await load(search)
        try? await Task.sleep(for: .seconds(9))
        _ = await js(Self.clickCardAt(index: ratedIndex))
        try? await Task.sleep(for: .seconds(9))
        let clickedText = await js(Self.bodyTextJS)

        await load("https://www.facebook.com/marketplace/item/\(ratedID)/")
        try? await Task.sleep(for: .seconds(8))
        let directText = await js(Self.bodyTextJS)

        let clickedLines = Set(Self.lines(clickedText))
        let directLines = Self.lines(directText)
        let onlyDirect = directLines.filter { !clickedLines.contains($0) }
        emit("RATED[onlyOnDirect \(onlyDirect.count) lines] \(onlyDirect.prefix(14).joined(separator: " · ").prefix(600))")

        let directSet = Set(directLines)
        let onlyClicked = Array(clickedLines).filter { !directSet.contains($0) }
        emit("RATED[onlyOnClicked \(onlyClicked.count) lines] \(onlyClicked.prefix(10).joined(separator: " · ").prefix(400))")

        emit("=== RATEDROUTE COMPLETE ===")
    }

    static func lines(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else { return [] }
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 2 }
    }

    func startSellerSurvey() {
        Task {
            webView.customUserAgent = Self.desktopUA
            // One listing showed a seller name and join date but no rating, so
            // "ratings and stars" is so far an assumption. Spread across
            // several sellers before anything in the UI depends on it.
            let ids = ["1054280080442808", "3576979889123241", "1244917550907745",
                       "1797842328020434", "1624050395351390", "1318664736543676"]
            // Ratings came back null on every desktop page, which has two very
            // different explanations: desktop doesn't render them, or these
            // sellers have none. Mobile is known to show ratings "when
            // present", so running the same listings on both agents tells the
            // two apart — a rating on mobile and not desktop is a surface gap;
            // absent on both means these sellers simply aren't rated.
            for id in ids {
                webView.customUserAgent = Self.desktopUA
                await load("https://www.facebook.com/marketplace/item/\(id)/")
                try? await Task.sleep(for: .seconds(7))
                emit("SELLER[d:\(id)] \(await js(Self.sellerFieldsJS))")

                webView.customUserAgent = Self.mobileUA
                await load("https://www.facebook.com/marketplace/item/\(id)/")
                try? await Task.sleep(for: .seconds(7))
                emit("SELLER[m:\(id)] \(await js(Self.sellerFieldsJS))")
            }
            emit("=== SELLERSURVEY COMPLETE ===")
        }
    }

    // MARK: - Test sequence

    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 Safari/605.1.15"

    /// Do the desktop filter parameters do anything on mobile?
    ///
    /// Desktop's own filter UI produces these names (read off `location.href`
    /// while driving the real controls, 2026-08-04):
    ///
    ///   sortBy=best_match|creation_time_descend|distance_ascend|price_ascend|price_descend
    ///   deliveryMethod=local_pick_up|shipping
    ///   daysSinceListed=1|7|30
    ///   availability=in stock|out of stock
    ///   itemCondition=new,used_like_new,used_good,used_fair   (comma list)
    ///   radius=<km>            ("5 miles" produced radius=8)
    ///   minPrice / maxPrice    (names untested — desktop's inputs wouldn't drive)
    ///
    /// The checklist rule that matters here (§6): a parameter that survives
    /// normalisation is not a parameter that works. Every case therefore
    /// reports the *result set*, not just the URL, and the assertions are
    /// chosen so the answer is unambiguous from the cards alone —
    /// `price_ascend` must come back monotonic, `shipping` must lose its city
    /// lines, `radius` must shrink the city set.
    func runTests() async {
        await runEndlessScrollTest()
    }

    /// The four questions that can only be answered with a session, in order of
    /// how much they'd change the plan.
    ///
    /// Q2 is the one that decides whether an all-desktop app is worth building:
    /// logged out, cards 16–39 arrive with no embedded payload, so if that
    /// holds when signed in then infinite scroll yields unlimited *markup*
    /// cards and structured data still stops at ~15 — which is roughly what
    /// mobile already gives, without putting an account at risk.
    func runLoggedInTests() async {
        emit("=== LOGGED-IN BATTERY START ===")
        let base = "https://www.facebook.com/marketplace/sanfrancisco/search/?query=desk"

        webView.customUserAgent = Self.desktopUA
        await load(base)
        try? await Task.sleep(for: .seconds(10))
        emit("LI[q0_firstPage] \(await js(Self.desktopPayloadCoverageJS))")

        // Q1: does it scroll past the logged-out ceiling of 39?
        // Q2: does the payload keep pace with the cards?
        let scrollView = webView.scrollView
        var previous = 0
        for round in 1...10 {
            for _ in 0..<6 {
                let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                guard maxY > 10 else { break }
                let next = min(scrollView.contentOffset.y + scrollView.bounds.height * 0.85, maxY)
                scrollView.setContentOffset(CGPoint(x: 0, y: next), animated: false)
                try? await Task.sleep(for: .milliseconds(1100))
            }
            let report = await js(Self.desktopPayloadCoverageJS)
            emit("LI[q1_scroll\(round)] \(report)")
            let cards = Self.cardsIn(report)
            if cards == previous, round >= 2 {
                emit("LI[q1_stalled] \(cards) cards after \(round) rounds")
                break
            }
            previous = cards
        }

        // Q3: radius is decorative logged out. Does a session change that?
        for km in [8, 161] {
            await load(base + "&radius=\(km)")
            try? await Task.sleep(for: .seconds(9))
            emit("LI[q3_radius\(km)] \(await js(Self.radiusSpreadJS))")
        }

        // Q4: desktop item pages carry no seller fields logged out.
        await load("https://www.facebook.com/marketplace/item/1054280080442808/")
        try? await Task.sleep(for: .seconds(9))
        emit("LI[q4_item] \(await js(Self.sellerFieldsJS))")

        await runTimingTests()

        emit("=== LOGGED-IN BATTERY COMPLETE ===")
    }

    /// When does an item page's *data* become readable, relative to when the
    /// page finishes loading?
    ///
    /// If the payload lands well before `didFinish`, the app never has to wait
    /// for the page — it can extract as soon as the JSON is in the document and
    /// abandon the rest of the load. That is the difference between a detail
    /// screen that fills in at first byte and one that waits on images and
    /// third-party chrome.
    ///
    /// Polls at 25 ms through the whole load rather than sampling afterwards,
    /// because the question is precisely about the interval.
    func runTimingTests() async {
        let items = [
            "1054280080442808",
            "1624050395351390",
            "1318664736543676"
        ]

        for id in items {
            // Belt and braces alongside the id guard in the probe: start from a
            // blank document so there is no stale item page to mistake for the
            // one being timed.
            await load("about:blank")
            try? await Task.sleep(for: .milliseconds(400))

            let clock = ContinuousClock()
            let start = clock.now
            var finishAt: Duration?
            onDidFinish = { [weak self] in
                guard self != nil, finishAt == nil else { return }
                finishAt = clock.now - start
            }

            webView.load(URLRequest(url: URL(string: "https://www.facebook.com/marketplace/item/\(id)/")!))

            var payloadAt: Duration?
            var renderedAt: Duration?
            let deadline = start + .seconds(25)
            while clock.now < deadline {
                let probe = await js(Self.timingProbe(expectedID: id))
                if payloadAt == nil, probe.contains("\"payload\":true") {
                    payloadAt = clock.now - start
                }
                if renderedAt == nil, probe.contains("\"rendered\":true") {
                    renderedAt = clock.now - start
                }
                if payloadAt != nil, renderedAt != nil, finishAt != nil { break }
                try? await Task.sleep(for: .milliseconds(25))
            }

            func ms(_ d: Duration?) -> String {
                guard let d else { return "n/a" }
                return String(format: "%.2fs", Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18)
            }
            emit("TIMING[\(id)] payload=\(ms(payloadAt)) rendered=\(ms(renderedAt)) didFinish=\(ms(finishAt))")
            onDidFinish = nil
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Can desktop be scrolled indefinitely by re-dismissing the overlay?
    ///
    /// The previous run concluded "no" from four rounds that added nothing —
    /// but it never checked whether those rounds' dismissals *worked*. If the
    /// overlay stops offering a Close affordance, a silent no-op is
    /// indistinguishable from exhausted results, which is the same mistake as
    /// scrolling a 0-height viewport.
    ///
    /// So every round asserts its own precondition: the dismissal is logged,
    /// and the unlock is confirmed by the document growing past the ~600 px
    /// locked height before any scrolling is counted.
    func runEndlessScrollTest() async {
        webView.customUserAgent = Self.desktopUA
        await load("https://www.facebook.com/marketplace/sanfrancisco/search/?query=desk")
        try? await Task.sleep(for: .seconds(10))

        let scrollView = webView.scrollView
        var previousCards = 0

        for round in 1...8 {
            let dismissal = await js(Self.dismissOverlayJS)
            try? await Task.sleep(for: .milliseconds(900))
            let unlocked = await js(Self.lockStateJS)

            // Scroll only while the page is actually scrollable.
            for _ in 0..<8 {
                let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                guard maxY > 10 else { break }
                let next = min(scrollView.contentOffset.y + scrollView.bounds.height * 0.85, maxY)
                scrollView.setContentOffset(CGPoint(x: 0, y: next), animated: false)
                try? await Task.sleep(for: .milliseconds(1100))
            }

            let after = await js(Self.desktopPayloadCoverageJS)
            let cards = Self.cardsIn(after)
            emit("ENDLESS[r\(round)] dismiss=\(dismissal) | unlocked=\(unlocked) | after=\(after)")

            if cards == previousCards, round >= 3 {
                emit("ENDLESS[stalled] \(cards) cards, no growth this round")
                break
            }
            previousCards = cards
        }

        // The second overlay exposes no Close affordance. Before calling that a
        // hard stop, exhaust the other ways a modal can be dismissed — an
        // unlabelled X, Escape, or a backdrop click. "My selector found nothing"
        // is not the same as "nothing is there".
        emit("ENDLESS[modalAnatomy] \(await js(Self.modalAnatomyJS))")
        emit("ENDLESS[escape] \(await js(Self.pressEscapeJS))")
        try? await Task.sleep(for: .milliseconds(900))
        emit("ENDLESS[afterEscape] \(await js(Self.lockStateJS))")
        emit("ENDLESS[backdrop] \(await js(Self.clickBackdropJS))")
        try? await Task.sleep(for: .milliseconds(900))
        emit("ENDLESS[afterBackdrop] \(await js(Self.lockStateJS))")

        emit("=== ENDLESSPROBE COMPLETE ===")
    }

    /// Two things are conflated in "desktop is one page": the result cap, and
    /// the login modal. This separates them.
    ///
    /// The earlier attempt at this ran in a browser pane whose viewport was
    /// 0x0, so nothing could lazy-load and "no new cards after six scrolls"
    /// measured nothing. A real `WKWebView` with a real viewport is the only
    /// honest instrument, and it is also what the app uses.
    ///
    /// Recorded per step: card count, whether a dialog is up, and whether the
    /// listings are still in the DOM behind it — an overlay that leaves the
    /// cards extractable is a very different constraint from a wall that
    /// replaces them.
    func runDesktopScrollTests() async {
        webView.customUserAgent = Self.desktopUA
        await load("https://www.facebook.com/marketplace/sanfrancisco/search/?query=desk")
        try? await Task.sleep(for: .seconds(10))

        emit("DSCROLL[step0] \(await js(Self.desktopWallJS))")

        let scrollView = webView.scrollView
        var lastCards = -1
        var stableRounds = 0

        for step in 1...24 {
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let next = min(scrollView.contentOffset.y + scrollView.bounds.height * 0.85, maxY)
            scrollView.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            try? await Task.sleep(for: .milliseconds(1100))

            let report = await js(Self.desktopWallJS)
            // Only log transitions and every fourth step, to keep the run readable.
            let cards = Self.cardsIn(report)
            if cards != lastCards || step % 4 == 0 {
                emit("DSCROLL[step\(step)] \(report)")
            }
            if cards == lastCards { stableRounds += 1 } else { stableRounds = 0 }
            lastCards = cards
            if report.contains("\"hardWall\":true") {
                emit("DSCROLL[walled at step \(step)]")
                break
            }
            // Bottom reached and nothing new for a while: it is a cap, not a wall.
            if stableRounds >= 8, next >= maxY - 1 {
                emit("DSCROLL[settled at step \(step)] no growth in \(stableRounds) rounds at bottom")
                break
            }
        }

        // The overlay is up from load and pins the document at ~600px, so the
        // question is not "how much scrolling triggers it" but "does removing
        // it unlock anything". Two escalating attempts, because they answer
        // different things: dismissing it tests the product's own affordance,
        // and forcing the scroll lock off separates "the gate stops us" from
        // "there is nothing more to fetch".
        emit("DSCROLL[dismiss] \(await js(Self.dismissOverlayJS))")
        try? await Task.sleep(for: .seconds(2))
        emit("DSCROLL[afterDismiss] \(await js(Self.desktopWallJS))")

        for _ in 0..<6 {
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let next = min(scrollView.contentOffset.y + scrollView.bounds.height * 0.85, maxY)
            scrollView.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            try? await Task.sleep(for: .milliseconds(1100))
        }
        emit("DSCROLL[scrolledAfterDismiss] \(await js(Self.desktopWallJS))")

        // The overlay comes back on scroll, so the real question is whether a
        // dismiss-scroll loop keeps paying out, and whether the cards it adds
        // carry the embedded payload or are just markup. `creationTimes`
        // against `cards` answers the second: if the count stops tracking the
        // card count, desktop pagination buys reach but not structured data.
        for round in 1...5 {
            _ = await js(Self.dismissOverlayJS)
            try? await Task.sleep(for: .milliseconds(600))
            for _ in 0..<5 {
                let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                let next = min(scrollView.contentOffset.y + scrollView.bounds.height * 0.85, maxY)
                scrollView.setContentOffset(CGPoint(x: 0, y: next), animated: false)
                try? await Task.sleep(for: .milliseconds(1100))
            }
            emit("DSCROLL[loop\(round)] \(await js(Self.desktopPayloadCoverageJS))")
        }

        emit("=== DSCROLLPROBE COMPLETE ===")
    }

    static func cardsIn(_ json: String) -> Int {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = obj["cards"] as? Int else { return -1 }
        return n
    }

    /// Does WebLite really ship canonical item URLs over a WebSocket before the
    /// cards reach the DOM?
    ///
    /// If so it settles §5b — WebSocket frames appear in no Resource Timing
    /// entry and go through neither `fetch` nor XHR, which is exactly why both
    /// earlier instruments came back empty — and it means the per-card tap that
    /// currently costs ~1.9s per listing is avoidable.
    ///
    /// Presence of ids in a frame is the cheap half. The half that decides
    /// whether this is usable is **ordering**: an id list that cannot be
    /// aligned to cards is a list of ids for unknown listings, which is worse
    /// than useless because a mis-mapping opens someone else's listing.
    func runSocketTests() async {
        webView.customUserAgent = Self.mobileUA
        await load("https://www.facebook.com/marketplace/sanfrancisco/search/?query=desk")
        try? await Task.sleep(for: .seconds(12))

        emit("SOCKET[search] \(await js(Self.socketReportJS))")
        let idList = await js(Self.socketIDListJS)
        emit("SOCKET[ids] \(idList.prefix(400))")

        // Alignment check: tap a card, see which recorded id it actually was.
        for index in [1, 2] {
            emit("SOCKET[tap\(index)] \(await js(Self.tapCard(index: index)))")
            try? await Task.sleep(for: .seconds(5))
            emit("SOCKET[landed\(index)] \(await js(Self.landedIDJS))")
            _ = await js("(function(){ history.back(); return 'back'; })()")
            try? await Task.sleep(for: .seconds(6))
        }

        // Does pagination bring more ids down the same channel?
        let scrollView = webView.scrollView
        for _ in 0..<6 {
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let next = min(scrollView.contentOffset.y + scrollView.bounds.height * 0.9, maxY)
            scrollView.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            try? await Task.sleep(for: .milliseconds(900))
        }
        try? await Task.sleep(for: .seconds(3))
        emit("SOCKET[paginated] \(await js(Self.socketReportJS))")

        emit("=== SOCKETPROBE COMPLETE ===")
    }

    /// Does a photo id actually bridge the two surfaces?
    ///
    /// The app keys a listing on the middle segment of its fbcdn filename, and
    /// the desktop payload carries a `primary_listing_photo.id`. Whether either
    /// of those joins mobile to desktop decides if `ItemMatcher`'s fuzzy title
    /// matching can be deleted or has to stay. Same query, same session, both
    /// user agents; join on title and compare.
    func runSeamTests() async {
        let url = "https://www.facebook.com/marketplace/sanfrancisco/search/?query=desk"

        webView.customUserAgent = Self.mobileUA
        await load(url)
        try? await Task.sleep(for: .seconds(10))
        let mobileRaw = await js(Self.photoKeyJS)

        webView.customUserAgent = Self.desktopUA
        await load(url)
        try? await Task.sleep(for: .seconds(10))
        let desktopRaw = await js(Self.photoKeyJS)
        emit("SEAM[payload_vs_filename] \(await js(Self.payloadPhotoIDJS))")

        // NSLog truncates around 1 kB, so the row sets are joined here rather
        // than shipped out and reassembled.
        let mobile = Self.decodeRows(mobileRaw)
        let desktop = Self.decodeRows(desktopRaw)
        let shared = mobile.keys.filter { desktop[$0] != nil }
        let agreeing = shared.filter { mobile[$0] == desktop[$0] }

        emit("SEAM[counts] mobile=\(mobile.count) desktop=\(desktop.count) sharedTitles=\(shared.count) samePhotoKey=\(agreeing.count)")
        for title in shared.prefix(6) {
            let verdict = mobile[title] == desktop[title] ? "MATCH" : "DIFFER"
            emit("SEAM[row] \(verdict) '\(title.prefix(30))' m=\(mobile[title] ?? "-") d=\(desktop[title] ?? "-")")
        }

        emit("=== SEAMPROBE COMPLETE ===")
    }

    /// `{"rows":[{"t":title,"k":photoSegment}]}` -> `[title: photoSegment]`
    static func decodeRows(_ json: String) -> [String: String] {
        struct Row: Decodable { let t: String; let k: String }
        struct Payload: Decodable { let rows: [Row] }
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else { return [:] }
        var out: [String: String] = [:]
        for row in decoded.rows {
            let key = row.t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.count > 6 else { continue }
            out[key] = row.k
        }
        return out
    }

    /// Mobile's *initial* page carries no GraphQL payload. But mobile is the
    /// surface that paginates, and pagination has to fetch something. If what
    /// comes back over the wire is JSON, the structured data is reachable on
    /// the surface with depth after all, and the whole trade-off changes.
    ///
    /// Installs a fetch/XHR recorder *after* first paint, then scrolls the real
    /// scroll view the way `FeedEngine.loadNextBatch` does, and reports the
    /// content type and shape of everything the page pulled.
    func runWireTests() async {
        webView.customUserAgent = Self.mobileUA
        await load("https://www.facebook.com/marketplace/sanfrancisco/search/?query=desk")
        try? await Task.sleep(for: .seconds(10))

        // The recorder is already in place from document start, so this window
        // covers the initial load too.
        emit("WIRE[initial] \(await js(Self.wireReportJS))")
        emit("WIRE[before] \(await js(Self.cardCountJS))")

        // If pagination uses no network at all, the obvious remaining
        // explanation is that the listings were in the first response all
        // along and scrolling only materialises them. Snapshot the markup now
        // so it can be searched for listings that have not appeared yet.
        _ = await js("(function(){ window.__snap = document.documentElement.outerHTML; return window.__snap.length; })()")

        // Same gesture the app uses to paginate: real scroll offsets, paced.
        let scrollView = webView.scrollView
        for step in 0..<10 {
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let next = min(scrollView.contentOffset.y + scrollView.bounds.height * 0.9, maxY)
            scrollView.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            try? await Task.sleep(for: .milliseconds(900))
            if step == 4 { emit("WIRE[mid] \(await js(Self.cardCountJS))") }
        }

        try? await Task.sleep(for: .seconds(3))
        emit("WIRE[after] \(await js(Self.cardCountJS))")
        emit("WIRE[captured] \(await js(Self.wireReportJS))")
        emit("WIRE[preloaded] \(await js(Self.preloadCheckJS))")
        emit("WIRE[resources] \(await js(Self.resourceTimingJS))")

        emit("=== WIREPROBE COMPLETE ===")
    }

    /// The desktop search page embeds the `MarketplaceSearch` GraphQL response
    /// verbatim — one `listing` object per card carrying `creation_time` as a
    /// unix timestamp, a numeric price, `delivery_types`, `is_sold`, the city's
    /// place id, and the photo id the app already uses as its identity key.
    ///
    /// If mobile embeds the same payload, everything the app wants is available
    /// on the surface that also paginates, and no filter parameters are needed
    /// — the sorting and filtering can all happen in Swift. That is the whole
    /// question here.
    func runPayloadTests() async {
        let search = "https://www.facebook.com/marketplace/sanfrancisco/search/?query=desk"
        let item = "https://www.facebook.com/marketplace/item/4588862774666491/"

        webView.customUserAgent = Self.mobileUA
        await load(search)
        try? await Task.sleep(for: .seconds(10))
        emit("PAYLOAD[mobile_search] \(await js(Self.payloadProbeJS))")

        await load(item)
        try? await Task.sleep(for: .seconds(10))
        emit("PAYLOAD[mobile_item] \(await js(Self.payloadProbeJS))")

        webView.customUserAgent = Self.desktopUA
        await load(search)
        try? await Task.sleep(for: .seconds(10))
        emit("PAYLOAD[desktop_search] \(await js(Self.payloadProbeJS))")

        emit("=== PAYLOADPROBE COMPLETE ===")
    }

    func runFilterMatrix() async {
        webView.customUserAgent = Self.mobileUA

        let base = "https://www.facebook.com/marketplace/sanfrancisco/search/?query=desk"
        let cases: [(String, String)] = [
            ("baseline",        base),
            ("sort_newest",     base + "&sortBy=creation_time_descend"),
            ("sort_price_asc",  base + "&sortBy=price_ascend"),
            ("sort_price_desc", base + "&sortBy=price_descend"),
            ("sort_distance",   base + "&sortBy=distance_ascend"),
            ("deliv_local",     base + "&deliveryMethod=local_pick_up"),
            ("deliv_shipping",  base + "&deliveryMethod=shipping"),
            ("days_1",          base + "&daysSinceListed=1"),
            ("radius_8",        base + "&radius=8"),
            ("price_100_200",   base + "&minPrice=100&maxPrice=200"),
            ("cond_new",        base + "&itemCondition=new"),
            ("city_sanjose",    "https://www.facebook.com/marketplace/sanjose/search/?query=desk"),
        ]

        for (name, url) in cases {
            await load(url)
            try? await Task.sleep(for: .seconds(9))
            emit("FILTER[\(name)] \(await js(Self.filterProbeJS))")
        }

        emit("=== FILTERPROBE COMPLETE ===")
    }

    /// Mobile discards every filter parameter (above). Two ways round it are
    /// still open, and both are cheap to test:
    ///
    /// 1. **Session carry-over.** Mobile already treats *location* as session
    ///    state rather than URL state. If filters are stored the same way, then
    ///    applying one on the desktop surface — which does honour the
    ///    parameters — and then switching the user agent inside the same
    ///    webview should leave the filter in force. Same cookie jar, so the
    ///    server sees one continuous session.
    /// 2. **The mobile filter UI.** If mobile renders its own controls, what
    ///    are they — links carrying a URL we could construct, or opaque
    ///    WebLite actions?
    ///
    /// `price_ascend` is the probe filter throughout: monotonic prices are
    /// unambiguous evidence in a way that "the cards look different" is not.
    func runCarryOverTests() async {
        let mobileSearch = "https://www.facebook.com/marketplace/sanfrancisco/search/?query=desk"
        let desktopFiltered = mobileSearch + "&sortBy=price_ascend&deliveryMethod=local_pick_up&radius=8"

        // Control: mobile, no filter ever applied in this session.
        webView.customUserAgent = Self.mobileUA
        await load(mobileSearch)
        try? await Task.sleep(for: .seconds(9))
        emit("CARRY[control] \(await js(Self.filterProbeJS))")

        // Apply the filter where it demonstrably works.
        webView.customUserAgent = Self.desktopUA
        await load(desktopFiltered)
        try? await Task.sleep(for: .seconds(9))
        emit("CARRY[desktop_applied] \(await js(Self.desktopFilterProbeJS))")

        // Same webview, same cookies, mobile UA, and a URL carrying no filter.
        webView.customUserAgent = Self.mobileUA
        await load(mobileSearch)
        try? await Task.sleep(for: .seconds(9))
        emit("CARRY[mobile_after] \(await js(Self.filterProbeJS))")

        // What does mobile offer in its own UI?
        emit("MOBILEUI \(await js(Self.mobileFilterUIJS))")

        emit("=== CARRYPROBE COMPLETE ===")
    }

    func extractStrings(_ json: String, key: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj[key] as? [String] else { return [] }
        return v
    }

    func clearCookies() async {
        let store = webView.configuration.websiteDataStore
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    // MARK: - Plumbing

    func currentUA() async -> String {
        (try? await webView.evaluateJavaScript("navigator.userAgent") as? String) ?? "?"
    }

    func load(_ url: String) async {
        emit("loading \(url)")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navContinuation = cont
            webView.load(URLRequest(url: URL(string: url)!))
        }
    }

    /// Set to observe `didFinish` without blocking on it — the timing test
    /// needs to keep polling *through* the load rather than wait for its end.
    var onDidFinish: (@MainActor () -> Void)?

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.onDidFinish?()
            navContinuation?.resume()
            navContinuation = nil
        }
    }

    /// The decisive instrument: if a tap fires WebLite's action as a real
    /// navigation, it shows up here even if it would later be cancelled.
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        NSLog("SPIKE| NAVACTION type=%ld %@",
              navigationAction.navigationType.rawValue,
              navigationAction.request.url?.absoluteString ?? "nil")
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            emit("nav failed: \(error.localizedDescription)")
            navContinuation?.resume()
            navContinuation = nil
        }
    }

    func js(_ script: String) async -> String {
        do {
            let result = try await webView.evaluateJavaScript(script)
            return (result as? String) ?? String(describing: result)
        } catch {
            return "JS error: \(error.localizedDescription)"
        }
    }

    func extract(_ json: String, key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj[key] else { return nil }
        return "\(v)"
    }

    // MARK: - Injected probes

    /// What text does each mobile card actually contain?
    static let cardTextsJS = """
    (function(){
      var all = Array.prototype.slice.call(document.querySelectorAll('div[data-action-id]'));
      var cands = all.filter(function(el){
        var i = el.querySelector('img');
        return i && (i.getAttribute('src')||'').indexOf('fbcdn') !== -1;
      });
      var cards = cands.filter(function(el){
        return !cands.some(function(o){ return o !== el && el.contains(o); });
      });
      var body = document.body.innerText || '';
      return JSON.stringify({
        count: cards.length,
        first3: cards.slice(1, 4).map(function(el){ return (el.innerText||'').replace(/\\n/g, ' | ').slice(0, 90); }),
        pageCities: (body.match(/[A-Z][A-Za-z .'-]+,\\s*[A-Z]{2}\\b/g) || []).slice(0, 6)
      });
    })()
    """

    /// Desktop cards use real item anchors and include location text.
    static let desktopCardsJS = """
    (function(){
      var links = Array.prototype.slice.call(document.querySelectorAll('a[href*="/marketplace/item/"]'));
      var out = links.slice(0, 5).map(function(a){
        var m = a.href.match(/marketplace\\/item\\/(\\d+)/);
        return {id: m ? m[1] : null, text: (a.textContent||'').slice(0, 90)};
      });
      return JSON.stringify({count: links.length, sample: out});
    })()
    """

    /// Count city-shaped text nodes in the whole document, not via innerText.
    static let cityCountJS = """
    (function(){
      var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), n;
      var cities = [], all = 0;
      while ((n = w.nextNode())) {
        var t = (n.textContent || '').trim();
        if (!t) continue;
        all++;
        if (/^[A-Z][A-Za-z .'-]+,\\s*[A-Z]{2}$/.test(t)) cities.push(t);
      }
      return JSON.stringify({textNodes: all, cityNodes: cities.length, sample: cities.slice(0, 3)});
    })()
    """

    /// Titles the mobile feed shows, in order.
    static let mobileTitlesJS = """
    (function(){
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, null);
      var cards = [], cur = null, n;
      while ((n = walker.nextNode())) {
        if (n.nodeType === 1 && n.tagName === 'IMG') {
          var s = n.getAttribute('src') || '';
          if (s.indexOf('scontent') === -1) continue;
          cur = []; cards.push(cur);
        } else if (n.nodeType === 3 && cur) {
          var p = n.parentElement;
          if (!p || p.tagName === 'SCRIPT' || p.tagName === 'STYLE') continue;
          var t = (n.textContent || '').trim();
          if (t && t.length < 120) cur.push(t);
        }
      }
      return JSON.stringify({count: cards.length, titles: cards.map(function(c){ return c.join('|').slice(0,60); }).slice(0,30)});
    })()
    """

    /// Item ids the desktop surface exposes for the same query.
    static let desktopIDsJS = """
    (function(){
      var links = Array.prototype.slice.call(document.querySelectorAll('a[href*="/marketplace/item/"]'));
      var seen = {}, out = [];
      links.forEach(function(a){
        var m = (a.getAttribute('href')||'').match(/marketplace\\/item\\/(\\d+)/);
        if (!m || seen[m[1]]) return;
        seen[m[1]] = 1;
        out.push(m[1] + ' :: ' + (a.textContent||'').trim().slice(0,55));
      });
      return JSON.stringify({count: out.length, items: out});
    })()
    """

    /// Are the ids real HTML attributes in the rendered DOM, or only in JS state?
    static let markupProofJS = """
    (function(){
      var links = Array.prototype.slice.call(document.querySelectorAll('a[href*="/marketplace/item/"]'));
      if (!links.length) return JSON.stringify({anchors: 0});
      var a = links[0];
      var html = a.outerHTML;
      // Strip the inner content so the anchor's own attributes are visible.
      var openTag = html.slice(0, html.indexOf('>') + 1);
      return JSON.stringify({
        anchors: links.length,
        tagName: a.tagName,
        hrefAttribute: a.getAttribute('href').slice(0, 90),
        openTag: openTag.slice(0, 260),
        idInStaticMarkup: document.documentElement.outerHTML.indexOf(
          (a.getAttribute('href').match(/item\\/(\\d+)/) || [])[1] || 'zzz') !== -1,
        renderedSize: Math.round(a.getBoundingClientRect().width) + 'x' + Math.round(a.getBoundingClientRect().height),
        ua: navigator.userAgent.slice(0, 45)
      });
    })()
    """

    /// Does the mobile surface carry listing ids anywhere the desktop one does?
    /// Checks the desktop patterns explicitly: item hrefs, "listing <id>" in an
    /// accessibility label, and any long numeric run — anywhere in the document.
    static let mobileIDHuntJS = """
    (function(){
      var html = document.documentElement.outerHTML;

      // 1. item hrefs
      var hrefs = {};
      (html.match(/marketplace\\/item\\/(\\d+)/g) || []).forEach(function(h){ hrefs[h] = 1; });

      // 2. every aria-label / alt / title on the page, and any that name a listing
      var labelled = [], listingLabels = [];
      Array.prototype.slice.call(document.querySelectorAll('[aria-label],[alt],[title]')).forEach(function(el){
        ['aria-label','alt','title'].forEach(function(k){
          var v = el.getAttribute(k);
          if (!v) return;
          labelled.push(k + '=' + v.slice(0, 70));
          if (/listing\\s*\\d{8,}/i.test(v)) listingLabels.push(v.slice(0, 90));
        });
      });

      // 3. "listing <id>" anywhere in the markup at all
      var listingPhrases = (html.match(/listing\\s*\\d{8,}/gi) || []).slice(0, 3);

      // 4. long numeric runs vs how many cards are on screen
      var longNums = {};
      (html.match(/\\b\\d{13,17}\\b/g) || []).forEach(function(n){ longNums[n] = 1; });
      var photos = Array.prototype.slice.call(document.querySelectorAll('img')).filter(function(i){
        return (i.getAttribute('src') || '').indexOf('scontent') !== -1;
      });

      return JSON.stringify({
        cardsOnPage: photos.length,
        itemHrefs: Object.keys(hrefs).length,
        anchorsTotal: document.querySelectorAll('a').length,
        labelledElements: labelled.length,
        labelSamples: labelled.slice(0, 6),
        listingLabels: listingLabels.length,
        listingPhrases: listingPhrases,
        distinctLongNumbers: Object.keys(longNums).length,
        ua: navigator.userAgent.slice(0, 40)
      });
    })()
    """

    /// What fields does an item page actually expose, and is there anything
    /// more precise than a city name (a map tile, coordinates, a neighbourhood)?
    static let fieldDumpJS = """
    (function(){
      var body = document.body.innerText || '';
      var html = document.documentElement.outerHTML;

      var photos = Array.prototype.slice.call(document.querySelectorAll('img')).filter(function(i){
        return (i.getAttribute('src') || '').indexOf('scontent') !== -1;
      });

      // Any map imagery? Static map tiles usually carry coordinates in the URL.
      var mapImgs = Array.prototype.slice.call(document.querySelectorAll('img')).filter(function(i){
        var s = (i.getAttribute('src') || '').toLowerCase();
        return s.indexOf('map') !== -1 || s.indexOf('tile') !== -1 || s.indexOf('static') !== -1 && s.indexOf('lat') !== -1;
      }).map(function(i){ return (i.getAttribute('src') || '').slice(0, 140); });

      // Coordinate-shaped pairs anywhere in the markup.
      var coordPairs = (html.match(/-?\\d{1,3}\\.\\d{4,},\\s*-?\\d{1,3}\\.\\d{4,}/g) || []).slice(0, 4);
      var latKeys = (html.match(/"(latitude|longitude|lat|lng)":\\s*-?\\d+\\.\\d+/g) || []).slice(0, 6);

      // Seller block
      var sellerHeading = /Seller information|Seller details|About the seller/i.test(body);
      var rating = (body.match(/\\d\\.\\d\\s*\\(\\d+\\)|Rating:\\s*\\d\\.\\d/) || [])[0] || null;
      var joined = (body.match(/Joined Facebook[^\\n]{0,30}/i) || [])[0] || null;

      function has(re) { return re.test(body); }
      return JSON.stringify({
        ua: navigator.userAgent.indexOf('iPhone') !== -1 ? 'mobile' : 'desktop',
        title: (document.title || '').slice(0, 50),
        price: (body.match(/\\$[\\d,]+/) || [])[0] || null,
        condition: (body.match(/Condition\\s*\\n*([^\\n]{1,30})/i) || [])[1] || null,
        hasDescription: has(/Description/i),
        photos: photos.length,
        posted: (body.match(/Listed[^\\n]{0,40}/i) || [])[0] || null,
        cityText: (body.match(/[A-Z][A-Za-z .'-]+,\\s*[A-Z]{2}/) || [])[0] || null,
        approximateNote: has(/Location is approximate/i),
        sellerHeading: sellerHeading,
        sellerRating: rating,
        sellerJoined: joined,
        mapImages: mapImgs.length,
        mapImageSample: mapImgs[0] || null,
        coordPairs: coordPairs,
        latLngKeys: latKeys,
        shipping: (body.match(/Ships (for|to)[^\\n]{0,20}/i) || [])[0] || null,
        dimensions: has(/Estimated \\(WxDxH\\)/i),
        category: (body.match(/Marketplace\\s*›?\\s*([A-Za-z &]{3,30})/) || [])[1] || null,
        loginWall: has(/you must log in|log into facebook to continue/i)
      });
    })()
    """

    /// Every card's aria-label, not a sample: how many carry one, and how many
    /// parse as "<title> for sale - <condition> - <price> in <city>, <ST>"?
    static let ariaCoverageJS = """
    (function(){
      var all = Array.prototype.slice.call(document.querySelectorAll('div[data-action-id]'));
      var cands = all.filter(function(el){
        var i = el.querySelector('img');
        return i && (i.getAttribute('src')||'').indexOf('fbcdn') !== -1;
      });
      var cards = cands.filter(function(el){
        return !cands.some(function(o){ return o !== el && el.contains(o); });
      });

      function labelOf(el){
        var a = el.getAttribute('aria-label');
        if (a) return a;
        var q = el.querySelector('[aria-label]');
        if (q) return q.getAttribute('aria-label');
        var img = el.querySelector('img[alt]');
        return img ? img.getAttribute('alt') : null;
      }

      var RE = /^(.+?) for sale\\s*[-\\u2013]\\s*(.+?)\\s*[-\\u2013]\\s*(\\$[\\d,]+|Free)\\s+in\\s+(.+?),\\s*([A-Z]{2})$/i;
      var withLabel = 0, parsed = 0, failures = [], cities = 0, conds = {};

      cards.forEach(function(el){
        var l = labelOf(el);
        if (!l) return;
        withLabel++;
        var m = l.match(RE);
        if (m) {
          parsed++;
          if (m[4]) cities++;
          conds[m[2]] = (conds[m[2]] || 0) + 1;
        } else if (failures.length < 4) {
          failures.push(l.slice(0, 80));
        }
      });

      return JSON.stringify({
        cards: cards.length,
        withAriaLabel: withLabel,
        parsedFully: parsed,
        cityFromLabel: cities,
        conditions: Object.keys(conds).map(function(k){ return k + ' x' + conds[k]; }).slice(0, 6),
        parseFailures: failures
      });
    })()
    """

    /// What does a card actually carry? Variant A shows a Distance chip in its
    /// header, so it may render distance per card where B renders a city — in
    /// which case the location data was never missing, only differently spelled.
    static let cardContentJS = """
    (function(){
      var all = Array.prototype.slice.call(document.querySelectorAll('div[data-action-id]'));
      var cands = all.filter(function(el){
        var i = el.querySelector('img');
        return i && (i.getAttribute('src')||'').indexOf('fbcdn') !== -1;
      });
      var cards = cands.filter(function(el){
        return !cands.some(function(o){ return o !== el && el.contains(o); });
      });

      var body = document.body.innerText || '';
      var DIST = /\\d+(\\.\\d+)?\\s*(mi|km|miles|kilometers)\\b|\\bnearby\\b|\\baway\\b/gi;

      return JSON.stringify({
        cards: cards.length,
        sample: cards.slice(1, 5).map(function(el){
          return (el.innerText || '').replace(/\\n/g, ' | ').slice(0, 88);
        }),
        distanceOnPage: (body.match(DIST) || []).slice(0, 6),
        cardsWithDistance: cards.filter(function(el){
          return DIST.test(el.innerText || '');
        }).length,
        ariaSample: cards.slice(1, 4).map(function(el){
          var a = el.getAttribute('aria-label');
          if (!a) { var q = el.querySelector('[aria-label]'); a = q && q.getAttribute('aria-label'); }
          return (a || '(none)').slice(0, 76);
        })
      });
    })()
    """

    /// Which search layout did this URL get? status.md's discriminators are the
    /// header wording and the count of city-shaped text nodes: variant A has one
    /// (the page header), variant B has one per card.
    static let variantProbeJS = """
    (function(){
      var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), n;
      var cityNodes = 0, cities = {};
      while ((n = w.nextNode()) !== null) {
        var p = n.parentElement;
        if (!p || p.tagName === 'SCRIPT' || p.tagName === 'STYLE') continue;
        var t = (n.textContent || '').trim();
        if (/^[A-Z][A-Za-z .'-]+,\\s*[A-Z]{2}$/.test(t)) {
          cityNodes++; cities[t] = (cities[t] || 0) + 1;
        }
      }

      var all = Array.prototype.slice.call(document.querySelectorAll('div[data-action-id]'));
      var cands = all.filter(function(el){
        var i = el.querySelector('img');
        return i && (i.getAttribute('src')||'').indexOf('fbcdn') !== -1;
      });
      var cards = cands.filter(function(el){
        return !cands.some(function(o){ return o !== el && el.contains(o); });
      });

      var body = document.body.innerText || '';
      var top = Object.keys(cities).sort(function(a,b){ return cities[b]-cities[a]; })
                      .slice(0, 4).map(function(k){ return k + ' x' + cities[k]; });

      return JSON.stringify({
        variant: cityNodes > 3 ? 'B (per-card cities)' : 'A (header only)',
        cityNodes: cityNodes,
        cards: cards.length,
        radiusChip: (body.match(/\\b\\d+\\s*mi\\b/) || [null])[0],
        header: body.slice(0, 72).replace(/\\n/g, ' '),
        topCities: top,
        finalURL: location.href.slice(0, 92)
      });
    })()
    """

    /// The condition string is in the HTML but not the rendered DOM. What is
    /// it attached to — this listing's JSON, or a related listing's?
    static let conditionContextJS = """
    (function(){
      var html = document.documentElement.outerHTML;
      var id = (location.pathname.match(/item\\/(\\d+)/) || [])[1] || null;

      var re = /Used\\s*[\\u2013\\u2014-]\\s*(?:Like New|Good|Fair)/gi, m, hits = [];
      while ((m = re.exec(html)) !== null && hits.length < 4) {
        hits.push({
          v: m[0],
          at: m.index,
          before: html.slice(Math.max(0, m.index - 120), m.index).replace(/\\s+/g, ' ').slice(-110)
        });
      }

      // Where does this listing's own id sit, for distance comparison?
      var idPos = [];
      if (id) {
        var r2 = new RegExp(id, 'g'), m2;
        while ((m2 = r2.exec(html)) !== null && idPos.length < 8) idPos.push(m2.index);
      }

      // Does any <script> carry it, and does that script also name this id?
      var inScript = 0, inScriptWithId = 0;
      Array.prototype.slice.call(document.querySelectorAll('script')).forEach(function(s){
        var t = s.textContent || '';
        if (!/Used\\s*[\\u2013\\u2014-]\\s*(?:Like New|Good|Fair)/i.test(t)) return;
        inScript++;
        if (id && t.indexOf(id) !== -1) inScriptWithId++;
      });

      return JSON.stringify({
        title: (document.title || '').slice(0, 30),
        id: id,
        idPositions: idPos,
        hits: hits,
        scriptsWithCondition: inScript,
        scriptsWithConditionAndId: inScriptWithId
      });
    })()
    """

    /// When `innerText` shows no condition, is the text nevertheless in the
    /// DOM — hidden, collapsed, or behind a "More" disclosure? That decides
    /// whether mobile can serve condition at all, or only sometimes.
    static let hiddenConditionProbeJS = """
    (function(){
      var html = document.documentElement.outerHTML;
      var body = document.body.innerText || '';
      var VAL = /Used\\s*[\\u2013\\u2014-]\\s*(?:Like New|Good|Fair)|\\bBrand New\\b/i;

      // Leaf elements whose text is exactly the label or a condition value.
      var hits = [];
      Array.prototype.slice.call(document.querySelectorAll('*')).forEach(function(el){
        if (el.children.length) return;
        var t = (el.textContent || '').trim();
        if (!/^Condition$/i.test(t) && !VAL.test(t)) return;
        if (t.length > 26) return;
        var cs = window.getComputedStyle(el);
        var r = el.getBoundingClientRect();
        hits.push(t + ' [' + cs.display + '/' + cs.visibility + '/h' + Math.round(r.height) + ']');
      });

      // Disclosure affordances that might be hiding a details block.
      var more = [];
      Array.prototype.slice.call(document.querySelectorAll('[role="button"],div[data-action-id],a')).forEach(function(el){
        var t = (el.innerText || '').trim();
        if (t && t.length < 22 && /\\b(more|see|show|detail)/i.test(t)) more.push(t);
      });

      return JSON.stringify({
        title: (document.title || '').slice(0, 32),
        innerTextHasLabel: /\\bCondition\\b/i.test(body),
        htmlHasLabel: /Condition/i.test(html),
        htmlHasValue: VAL.test(html),
        htmlValueSamples: (html.match(/Used\\s*[\\u2013\\u2014-]\\s*(?:Like New|Good|Fair)/gi) || []).slice(0, 3),
        domHits: hits.slice(0, 6),
        moreControls: Object.keys(more.reduce(function(a,s){ a[s]=1; return a; },{})).slice(0, 6),
        breadcrumb: /Marketplace\\s*\\u203a/.test(body),
        htmlLen: html.length
      });
    })()
    """

    /// Condition on an item page — label, value, and enough surrounding
    /// structure to tell "absent" from "phrased differently".
    static let conditionProbeJS = """
    (function(){
      var body = document.body.innerText || '';

      // The label, and whatever follows it.
      var m = body.match(/\\bCondition\\b[\\s\\S]{0,40}/i);
      var afterLabel = m ? m[0].replace(/\\n+/g, ' / ').trim() : null;

      // The values themselves, independent of any label — mobile may render
      // the value with different (or no) surrounding chrome.
      var vals = (body.match(/Used\\s*[\\u2013\\u2014-]\\s*(Like New|Good|Fair)|\\bNew\\b|\\bRefurbished\\b/gi) || []);
      var uniq = Object.keys(vals.reduce(function(a,s){ a[s.trim()] = 1; return a; }, {}));

      // Short standalone lines: what labels does this surface actually use?
      var lines = body.split('\\n').map(function(s){ return s.trim(); })
                      .filter(function(s){ return s.length > 0 && s.length < 30; });

      return JSON.stringify({
        surface: navigator.userAgent.indexOf('iPhone') !== -1 ? 'mobile' : 'web',
        title: (document.title || '').slice(0, 38),
        conditionLabel: !!m,
        afterLabel: afterLabel,
        valuesFound: uniq.slice(0, 4),
        detailsLabel: /\\bDetails\\b/i.test(body),
        seller: (body.match(/Joined Facebook[^\\n]{0,24}/i) || [])[0] || null,
        shortLines: lines.slice(0, 26),
        bodyLen: body.length,
        loginWall: /you must log in|log in to continue|Log In to Facebook/i.test(body)
      });
    })()
    """

    /// One search page, reduced to the things a filter would visibly change:
    /// the URL Facebook settled on, its own location/radius chip, and the
    /// ordered list of price + city per card.
    ///
    /// Prices come off the `aria-label` rather than the rendered text because
    /// the label is the only place a free listing is distinguishable from an
    /// unpriced one, and because it carries the city on both search layouts.
    static let filterProbeJS = """
    (function(){
      try {
        function isPhoto(img) {
          var src = img.getAttribute('src') || '';
          return src.indexOf('scontent') !== -1 && src.indexOf('rsrc.php') === -1;
        }
        function labelOf(img) {
          var alt = img.getAttribute('alt');
          if (alt && alt.length > 12) return alt;
          var action = img.closest ? img.closest('[data-action-id]') : null;
          if (action) {
            var own = action.getAttribute('aria-label');
            if (own && own.length > 12) return own;
          }
          return null;
        }
        // "Desk for sale - Used - Good - $75 in Oakland, CA" -> 75
        // Free listings carry no price segment at all and score 0.
        function priceOf(label) {
          var i = label.indexOf('$');
          if (i === -1) return (label.indexOf('Free ') === 0) ? 0 : null;
          var n = '';
          for (var k = i + 1; k < label.length; k++) {
            var c = label.charAt(k);
            if (c >= '0' && c <= '9') { n += c; }
            else if (c === ',') { continue; }
            else { break; }
          }
          return n.length ? parseInt(n, 10) : null;
        }
        function cityOf(label) {
          var i = label.lastIndexOf(' in ');
          return i === -1 ? null : label.slice(i + 4);
        }

        var imgs = Array.prototype.slice.call(document.querySelectorAll('img'));
        var labels = [];
        for (var i = 0; i < imgs.length; i++) {
          if (!isPhoto(imgs[i])) continue;
          var l = labelOf(imgs[i]);
          if (l) labels.push(l);
        }

        var prices = [], cities = [];
        for (var j = 0; j < labels.length; j++) {
          prices.push(priceOf(labels[j]));
          var c = cityOf(labels[j]);
          if (c) cities.push(c);
        }

        // Monotonicity over the priced cards only: a null is an unparsed
        // label, not evidence of disorder.
        function sortedRuns(arr, ascending) {
          var vals = arr.filter(function(v){ return v !== null; });
          var bad = 0;
          for (var k = 1; k < vals.length; k++) {
            if (ascending ? (vals[k] < vals[k-1]) : (vals[k] > vals[k-1])) bad++;
          }
          return vals.length + ':' + bad;
        }

        var body = document.body.innerText || '';
        var chip = (body.match(/[A-Za-z .'-]+ . [0-9]+ mi/) || [])[0] || null;

        var uniqueCities = {};
        for (var m = 0; m < cities.length; m++) { uniqueCities[cities[m]] = 1; }

        return JSON.stringify({
          href: location.href,
          chip: chip,
          cards: labels.length,
          prices: prices.slice(0, 14),
          ascViolations: sortedRuns(prices, true),
          descViolations: sortedRuns(prices, false),
          cities: Object.keys(uniqueCities),
          cityLines: cities.length,
          shipMentions: (body.match(/Ships /g) || []).length,
          first3: labels.slice(0, 3),
          loginWall: /you must log in|log in to continue/i.test(body)
        });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// What filter controls, if any, does the mobile surface render — and are
    /// they navigable (an href we could construct ourselves) or opaque WebLite
    /// actions (which would need a visible webview and a real user tap)?
    static let mobileFilterUIJS = """
    (function(){
      try {
        var body = document.body.innerText || '';
        var words = ['Filter', 'Sort', 'Radius', 'Distance', 'Delivery', 'Condition',
                     'Price', 'Date listed', 'Availability', 'mi', 'Location'];
        var present = [];
        for (var i = 0; i < words.length; i++) {
          if (body.indexOf(words[i]) !== -1) present.push(words[i]);
        }

        // Anything clickable whose label looks like a filter control.
        var controls = [];
        var nodes = document.querySelectorAll('[data-action-id], a, button, [role=button]');
        for (var j = 0; j < nodes.length; j++) {
          var el = nodes[j];
          var t = ((el.innerText || el.getAttribute('aria-label') || '')).trim();
          if (!t || t.length > 40) continue;
          var hit = false;
          for (var k = 0; k < words.length; k++) {
            if (t.indexOf(words[k]) !== -1) { hit = true; break; }
          }
          if (!hit) continue;
          controls.push({
            tag: el.tagName,
            text: t,
            href: el.getAttribute('href'),
            actionId: el.getAttribute('data-action-id') ? 'yes' : null
          });
        }

        // Do any hrefs on this page carry filter parameters we could reuse?
        var params = [];
        var links = document.querySelectorAll('a[href]');
        for (var m = 0; m < links.length; m++) {
          var h = links[m].getAttribute('href') || '';
          if (h.indexOf('sortBy') !== -1 || h.indexOf('deliveryMethod') !== -1 ||
              h.indexOf('radius') !== -1 || h.indexOf('daysSinceListed') !== -1) {
            params.push(h.slice(0, 160));
          }
        }

        return JSON.stringify({
          wordsInBody: present,
          controls: controls.slice(0, 20),
          controlCount: controls.length,
          filterHrefs: params.slice(0, 6),
          headLines: body.split(String.fromCharCode(10)).slice(0, 12)
        });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Is the GraphQL payload embedded in this page, and how much of it?
    ///
    /// Counts rather than samples: one `creation_time` proves nothing (item
    /// pages carry ~20 belonging to "Today's picks"), but a count matching the
    /// card count means every card has one.
    static let payloadProbeJS = """
    (function(){
      try {
        var html = document.documentElement.outerHTML;
        function count(re) { return (html.match(re) || []).length; }

        // Escaping differs between the raw attribute text and rendered JSON,
        // so match the bare key and let the count speak.
        var keys = ['creation_time', 'marketplace_listing_title', 'delivery_types',
                    'reverse_geocode', 'is_sold', 'listing_price',
                    'primary_listing_photo', 'strikethrough_price',
                    'marketplace_listing_seller', 'location_vanity_or_id',
                    'MarketplaceSearchFeedStoriesEdge', 'redacted_description'];
        var counts = {};
        for (var i = 0; i < keys.length; i++) {
          counts[keys[i]] = count(new RegExp(keys[i], 'g'));
        }

        // A listing's own creation_time on an item page is the one followed by
        // location_text; the picks' are followed by primary_listing_photo.
        var ownStamp = html.match(/creation_time.{0,3}:(\\d{10}),.{0,3}"?location_text/);
        var anyStamps = (html.match(/creation_time.{0,3}:(\\d{10})/g) || []).length;

        var photos = 0;
        var imgs = document.querySelectorAll('img');
        for (var j = 0; j < imgs.length; j++) {
          var s = imgs[j].getAttribute('src') || '';
          if (s.indexOf('scontent') !== -1 && s.indexOf('rsrc.php') === -1) photos++;
        }

        return JSON.stringify({
          href: location.href,
          htmlLen: html.length,
          scriptTags: document.querySelectorAll('script').length,
          renderedPhotos: photos,
          stampsTotal: anyStamps,
          ownStamp: ownStamp ? ownStamp[1] : null,
          counts: counts
        });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Wraps `fetch` and `XMLHttpRequest` so every response the page pulls is
    /// recorded with its content type and whether it contains the payload keys
    /// the desktop surface ships.
    static let wireRecorderJS = """
    (function(){
      try {
        if (window.__cap) return 'already installed';
        window.__cap = [];
        function note(url, ct, body) {
          var t = body || '';
          window.__cap.push({
            url: String(url).slice(0, 180),
            ct: String(ct || '').slice(0, 60),
            len: t.length,
            creation: t.indexOf('creation_time') !== -1,
            title: t.indexOf('marketplace_listing_title') !== -1,
            graphqlish: t.indexOf('__typename') !== -1,
            htmlish: t.indexOf('data-mcomponent') !== -1 || t.indexOf('<div') !== -1,
            head: t.slice(0, 160)
          });
        }

        var origFetch = window.fetch;
        window.fetch = function(){
          var a0 = arguments[0];
          var url = (a0 && a0.url) ? a0.url : String(a0);
          var p = origFetch.apply(this, arguments);
          try {
            p.then(function(res){
              try {
                var ct = res.headers ? res.headers.get('content-type') : '';
                res.clone().text().then(function(t){ note(url, ct, t); },
                                       function(){ note(url, ct, ''); });
              } catch (e) {}
            }, function(){});
          } catch (e) {}
          return p;
        };

        var oOpen = XMLHttpRequest.prototype.open;
        var oSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(m, u){
          this.__capURL = u;
          return oOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function(){
          var x = this;
          x.addEventListener('load', function(){
            var t = '';
            try { t = x.responseText || ''; } catch (e) {}
            var ct = '';
            try { ct = x.getResponseHeader('content-type') || ''; } catch (e) {}
            note(x.__capURL, ct, t);
          });
          return oSend.apply(this, arguments);
        };

        return 'installed';
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    static let wireReportJS = """
    (function(){
      try {
        var cap = window.__cap || [];
        var withPayload = 0, jsonish = 0, htmlish = 0, bytes = 0;
        for (var i = 0; i < cap.length; i++) {
          if (cap[i].creation || cap[i].title) withPayload++;
          if (cap[i].graphqlish) jsonish++;
          if (cap[i].htmlish) htmlish++;
          bytes += cap[i].len;
        }
        // Biggest responses first — a pagination batch is large, telemetry is not.
        var big = cap.slice().sort(function(a, b){ return b.len - a.len; }).slice(0, 6);
        return JSON.stringify({
          recorderInstalled: !!window.__cap,
          requests: cap.length,
          totalBytes: bytes,
          anyWithPayloadKeys: withPayload,
          anyWithTypename: jsonish,
          anyHtmlShaped: htmlish,
          biggest: big
        });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Were the listings that appeared during pagination already in the first
    /// response? Each fbcdn filename carries a photo id unique to its listing,
    /// so searching the snapshot for it answers this without ambiguity.
    static let preloadCheckJS = """
    (function(){
      try {
        var snap = window.__snap || '';
        var ids = [], titles = [];
        var imgs = document.querySelectorAll('img');
        for (var i = 0; i < imgs.length; i++) {
          var s = imgs[i].getAttribute('src') || '';
          if (s.indexOf('scontent') === -1 || s.indexOf('rsrc.php') !== -1) continue;
          // .../<hash>_<photoid>_<hash>_n.jpg -- the middle segment is the id
          var file = s.split('/').pop().split('?')[0];
          var parts = file.split('_');
          ids.push(parts.length > 1 ? parts[1] : file);
          // A signed photo URL can be reassembled from parts, so its id is weak
          // evidence. The title is plain text and survives any encoding.
          var alt = imgs[i].getAttribute('alt') || '';
          var action = imgs[i].closest ? imgs[i].closest('[data-action-id]') : null;
          if (!alt && action) alt = action.getAttribute('aria-label') || '';
          var cut = alt.indexOf(' for sale');
          titles.push(cut > 8 ? alt.slice(0, cut) : alt.slice(0, 30));
        }
        function inSnap(list) {
          var hit = 0;
          for (var j = 0; j < list.length; j++) {
            if (list[j] && list[j].length > 6 && snap.indexOf(list[j]) !== -1) hit++;
          }
          return hit;
        }
        var earlyIds = ids.slice(0, 26), lateIds = ids.slice(26);
        var earlyT = titles.slice(0, 26), lateT = titles.slice(26);
        return JSON.stringify({
          snapshotLen: snap.length,
          firstBatch: earlyIds.length,
          firstBatchPhotoIdInSnapshot: inSnap(earlyIds),
          firstBatchTitleInSnapshot: inSnap(earlyT),
          laterBatches: lateIds.length,
          laterPhotoIdInSnapshot: inSnap(lateIds),
          laterTitleInSnapshot: inSnap(lateT),
          sampleLateTitles: lateT.slice(0, 4)
        });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Hooking `fetch` and `XMLHttpRequest` only finds requests made through
    /// those two APIs. Resource Timing records every request the page made
    /// whatever issued it, and tags each with an `initiatorType` — so this
    /// answers "what transport" without having to guess which API to wrap.
    static let resourceTimingJS = """
    (function(){
      try {
        var all = performance.getEntriesByType('resource');
        var byType = {};
        var docLike = [];
        for (var i = 0; i < all.length; i++) {
          var e = all[i];
          var t = e.initiatorType || 'unknown';
          byType[t] = (byType[t] || 0) + 1;
          // Anything that isn't an image or a static asset is a candidate for
          // carrying listing content.
          var n = e.name || '';
          var isImage = n.indexOf('scontent') !== -1 || n.indexOf('.jpg') !== -1 ||
                        n.indexOf('.png') !== -1 || n.indexOf('.webp') !== -1;
          if (!isImage && n.indexOf('facebook.com') !== -1) {
            docLike.push({
              type: t,
              size: Math.round(e.transferSize || 0),
              name: n.replace('https://www.facebook.com', '').slice(0, 150)
            });
          }
        }
        docLike.sort(function(a, b){ return b.size - a.size; });
        return JSON.stringify({
          totalResources: all.length,
          byInitiatorType: byType,
          facebookNonImage: docLike.slice(0, 10)
        });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Every listing photo on the page as (title, fbcdn middle segment), which
    /// is the key `Listing.id` is built from.
    static let photoKeyJS = """
    (function(){
      try {
        var out = [];
        var imgs = document.querySelectorAll('img');
        for (var i = 0; i < imgs.length; i++) {
          var s = imgs[i].getAttribute('src') || '';
          if (s.indexOf('scontent') === -1 || s.indexOf('rsrc.php') !== -1) continue;
          var file = s.split('/').pop().split('?')[0];
          var parts = file.split('_');
          var label = imgs[i].getAttribute('alt') || '';
          if (!label) {
            var a = imgs[i].closest ? imgs[i].closest('[aria-label]') : null;
            if (a) label = a.getAttribute('aria-label') || '';
          }
          // Normalise both surfaces to a bare title: mobile labels read
          // "<title> for sale - ...", desktop's read "<title>, $40, City, ...".
          var t = label;
          var cut = t.indexOf(' for sale');
          if (cut > 0) t = t.slice(0, cut);
          else { cut = t.indexOf(', $'); if (cut > 0) t = t.slice(0, cut); }
          out.push({ t: t.slice(0, 46), k: parts.length > 1 ? parts[1] : file });
        }
        return JSON.stringify({ n: out.length, rows: out.slice(0, 30) });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// The desktop payload's own photo id, next to the filename it ships, so
    /// the two can be compared directly.
    static let payloadPhotoIDJS = """
    (function(){
      try {
        // Walk it with indexOf rather than a regex: the markup is escaped JSON
        // inside an attribute, so quote handling in a pattern is a trap.
        var html = document.documentElement.outerHTML;
        var out = [], from = 0;
        for (var n = 0; n < 6; n++) {
          var anchor = html.indexOf('primary_listing_photo', from);
          if (anchor === -1) break;
          from = anchor + 20;
          var block = html.slice(anchor, anchor + 900);
          var u = block.indexOf('scontent');
          if (u === -1) continue;
          var tail = block.slice(u);
          var stop = tail.search(/[?"\\\\]/);
          var uri = stop === -1 ? tail : tail.slice(0, stop);
          var file = uri.split('/').pop();
          var parts = file.split('_');
          // the object's own photo id trails the image object
          var idm = block.slice(u).match(/id.{0,3}:.{0,3}"(\\d{8,})"/);
          out.push({
            filenameSegment: parts.length > 1 ? parts[1] : file,
            payloadPhotoId: idm ? idm[1] : null
          });
        }
        return JSON.stringify({ pairs: out });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Records every WebSocket frame, decoding binary ones as UTF-8, and pulls
    /// any `marketplace/item/<id>` route out of them.
    ///
    /// No regex anywhere: this string crosses Swift and JavaScript escaping,
    /// and a stray backslash there has twice produced an opaque
    /// "A JavaScript exception occurred" (see the probe README).
    static let socketRecorderJS = """
    (function(){
      try {
        if (window.__ws) return;
        window.__ws = { opened: [], frames: [], ids: [], seen: {}, samples: [] };
        var Orig = window.WebSocket;
        if (!Orig) return;

        function pullIds(text) {
          var needle = 'marketplace/item/';
          var from = 0, found = [];
          while (true) {
            var i = text.indexOf(needle, from);
            if (i === -1) break;
            var j = i + needle.length, id = '';
            while (j < text.length) {
              var c = text.charAt(j);
              if (c >= '0' && c <= '9') { id += c; j++; } else { break; }
            }
            if (id.length > 6) found.push(id);
            from = i + needle.length;
          }
          return found;
        }

        function absorb(text, kind) {
          var ids = pullIds(text);
          window.__ws.frames.push({ kind: kind, len: text.length, ids: ids.length });
          for (var i = 0; i < ids.length; i++) {
            if (!window.__ws.seen[ids[i]]) {
              window.__ws.seen[ids[i]] = 1;
              window.__ws.ids.push(ids[i]);
            }
          }
          if (window.__ws.samples.length < 2 && ids.length > 0) {
            window.__ws.samples.push(text.slice(0, 200));
          }
        }

        function handle(data) {
          try {
            if (typeof data === 'string') { absorb(data, 'text'); return; }
            if (data instanceof ArrayBuffer) {
              absorb(new TextDecoder('utf-8', { fatal: false }).decode(data), 'binary');
              return;
            }
            if (data && typeof data.arrayBuffer === 'function') {
              data.arrayBuffer().then(function(buf){
                absorb(new TextDecoder('utf-8', { fatal: false }).decode(buf), 'blob');
              });
              return;
            }
            window.__ws.frames.push({ kind: 'unknown', len: 0, ids: 0 });
          } catch (e) {}
        }

        function Wrapped(url, protocols) {
          var sock = (protocols === undefined) ? new Orig(url) : new Orig(url, protocols);
          window.__ws.opened.push(String(url).slice(0, 140));
          try { sock.binaryType = 'arraybuffer'; } catch (e) {}
          sock.addEventListener('message', function(ev){ handle(ev.data); });
          return sock;
        }
        Wrapped.prototype = Orig.prototype;
        Wrapped.OPEN = Orig.OPEN; Wrapped.CLOSED = Orig.CLOSED;
        Wrapped.CONNECTING = Orig.CONNECTING; Wrapped.CLOSING = Orig.CLOSING;
        window.WebSocket = Wrapped;
      } catch (e) {}
    })()
    """

    static let socketReportJS = """
    (function(){
      try {
        var w = window.__ws || { opened: [], frames: [], ids: [], samples: [] };
        var photos = 0;
        var imgs = document.querySelectorAll('img');
        for (var i = 0; i < imgs.length; i++) {
          var s = imgs[i].getAttribute('src') || '';
          if (s.indexOf('scontent') !== -1 && s.indexOf('rsrc.php') === -1) photos++;
        }
        var withIds = [];
        for (var j = 0; j < w.frames.length; j++) {
          if (w.frames[j].ids > 0) withIds.push(w.frames[j]);
        }
        return JSON.stringify({
          sockets: w.opened.length,
          socketURLs: w.opened.slice(0, 3),
          frames: w.frames.length,
          framesCarryingIds: withIds.length,
          biggestIdFrames: withIds.sort(function(a,b){ return b.len - a.len; }).slice(0, 4),
          uniqueItemIds: w.ids.length,
          renderedCards: photos,
          firstIds: w.ids.slice(0, 3)
        });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    static let socketIDListJS = """
    (function(){
      var w = window.__ws || { ids: [] };
      return JSON.stringify({ n: w.ids.length, ids: w.ids.slice(0, 12) });
    })()
    """

    /// After a tap: which listing did we land on, and where does its id sit in
    /// the order the socket delivered them?
    static let landedIDJS = """
    (function(){
      try {
        var href = location.href;
        var needle = 'marketplace/item/';
        var i = href.indexOf(needle), id = '';
        if (i !== -1) {
          var j = i + needle.length;
          while (j < href.length) {
            var c = href.charAt(j);
            if (c >= '0' && c <= '9') { id += c; j++; } else { break; }
          }
        }
        var w = window.__ws || { ids: [] };
        var pos = -1;
        for (var k = 0; k < w.ids.length; k++) {
          if (w.ids[k] === id) { pos = k; break; }
        }
        return JSON.stringify({ landedOn: id || null, indexInSocketList: pos,
                                socketListSize: w.ids.length });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Desktop card count plus the state of any login prompt, distinguishing a
    /// dismissible overlay (cards still extractable behind it) from a wall.
    static let desktopWallJS = """
    (function(){
      try {
        var body = document.body.innerText || '';
        var cards = document.querySelectorAll('a[href*="/marketplace/item/"]').length;
        var dialogs = document.querySelectorAll('[role="dialog"]');
        var visibleDialog = null;
        for (var i = 0; i < dialogs.length; i++) {
          var r = dialogs[i].getBoundingClientRect();
          if (r.height > 40 && r.width > 40) {
            visibleDialog = (dialogs[i].innerText || '').slice(0, 40).replace(/[\\r\\n]+/g, ' ');
            break;
          }
        }
        // A wall replaces the results; an overlay sits on top of them.
        var hardWall = (cards === 0) ||
          body.indexOf('You must log in to continue') !== -1 ||
          body.indexOf('Log in to continue') !== -1;
        return JSON.stringify({
          cards: cards,
          creationTimes: (document.documentElement.outerHTML.match(/creation_time/g) || []).length,
          dialog: visibleDialog,
          hardWall: hardWall,
          scrollY: Math.round(window.scrollY || 0),
          docHeight: document.documentElement.scrollHeight
        });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Click the overlay's own Close affordance, the way a user would.
    static let dismissOverlayJS = """
    (function(){
      try {
        var dialogs = document.querySelectorAll('[role="dialog"]');
        for (var i = 0; i < dialogs.length; i++) {
          var buttons = dialogs[i].querySelectorAll('[aria-label], [role="button"]');
          for (var j = 0; j < buttons.length; j++) {
            var label = (buttons[j].getAttribute('aria-label') || buttons[j].innerText || '').trim();
            if (label === 'Close' || label === 'Not now' || label === 'Dismiss') {
              buttons[j].click();
              return 'clicked: ' + label;
            }
          }
        }
        return 'no close affordance found';
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Strip the scroll lock outright. This is not something the app would do —
    /// it is here to tell the two explanations apart. If the page still will
    /// not grow with the lock removed, the 15-result cap is the server's, not
    /// the overlay's.
    static let forceScrollUnlockJS = """
    (function(){
      try {
        var removed = [];
        var nodes = [document.documentElement, document.body];
        for (var i = 0; i < nodes.length; i++) {
          var s = getComputedStyle(nodes[i]);
          if (s.overflow === 'hidden' || s.overflowY === 'hidden' || s.position === 'fixed') {
            removed.push(nodes[i].tagName + ':' + s.overflowY + '/' + s.position);
            nodes[i].style.setProperty('overflow', 'auto', 'important');
            nodes[i].style.setProperty('position', 'static', 'important');
            nodes[i].style.setProperty('height', 'auto', 'important');
          }
        }
        var dialogs = document.querySelectorAll('[role="dialog"]');
        for (var k = 0; k < dialogs.length; k++) {
          if (dialogs[k].parentNode) dialogs[k].parentNode.removeChild(dialogs[k]);
        }
        return JSON.stringify({ unlocked: removed, dialogsRemoved: dialogs.length,
                                docHeight: document.documentElement.scrollHeight });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Does the payload keep pace with the cards as desktop paginates?
    ///
    /// Counting keys is not enough — the question is whether *these specific*
    /// rendered listings have one, so this checks each visible card's id
    /// against the markup that holds the payload objects.
    static let desktopPayloadCoverageJS = """
    (function(){
      try {
        var html = document.documentElement.outerHTML;
        var links = document.querySelectorAll('a[href*="/marketplace/item/"]');
        var ids = {}, order = [];
        for (var i = 0; i < links.length; i++) {
          var h = links[i].getAttribute('href') || '';
          var k = h.indexOf('/marketplace/item/');
          if (k === -1) continue;
          var j = k + 18, id = '';
          while (j < h.length) {
            var c = h.charAt(j);
            if (c >= '0' && c <= '9') { id += c; j++; } else { break; }
          }
          if (id.length > 6 && !ids[id]) { ids[id] = 1; order.push(id); }
        }
        // A card has payload if its id appears next to a creation_time.
        var covered = 0;
        for (var m = 0; m < order.length; m++) {
          var p = html.indexOf('"' + order[m] + '"');
          if (p === -1) continue;
          var window_ = html.slice(Math.max(0, p - 200), p + 1200);
          if (window_.indexOf('creation_time') !== -1) covered++;
        }
        var dialogs = document.querySelectorAll('[role="dialog"]');
        return JSON.stringify({
          cards: links.length,
          uniqueIds: order.length,
          idsWithPayload: covered,
          creationTimeKeys: (html.match(/creation_time/g) || []).length,
          dialogUp: dialogs.length > 0,
          docHeight: document.documentElement.scrollHeight
        });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Is the page currently scrollable, and what is holding it if not? The
    /// locked state is ~600px against an unlocked ~2340px, so the height alone
    /// distinguishes them.
    static let lockStateJS = """
    (function(){
      try {
        var dialogs = document.querySelectorAll('[role="dialog"]');
        var labels = [];
        for (var i = 0; i < dialogs.length; i++) {
          var r = dialogs[i].getBoundingClientRect();
          if (r.height > 40) {
            var buttons = dialogs[i].querySelectorAll('[aria-label]');
            var affordances = [];
            for (var j = 0; j < buttons.length && affordances.length < 4; j++) {
              var l = buttons[j].getAttribute('aria-label');
              if (l) affordances.push(l);
            }
            labels.push({ text: (dialogs[i].innerText || '').slice(0, 28).replace(/[\\r\\n]+/g, ' '),
                          affordances: affordances });
          }
        }
        var bodyStyle = getComputedStyle(document.body);
        return JSON.stringify({
          docHeight: document.documentElement.scrollHeight,
          scrollable: document.documentElement.scrollHeight > 900,
          bodyOverflow: bodyStyle.overflowY,
          bodyPosition: bodyStyle.position,
          visibleDialogs: labels
        });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Everything clickable inside the blocking modal, labelled or not.
    static let modalAnatomyJS = """
    (function(){
      try {
        var out = [];
        var dialogs = document.querySelectorAll('[role="dialog"]');
        for (var i = 0; i < dialogs.length; i++) {
          var r = dialogs[i].getBoundingClientRect();
          if (r.height < 40) continue;
          var els = dialogs[i].querySelectorAll('[role="button"], button, a, svg, i, [tabindex]');
          for (var j = 0; j < els.length && out.length < 18; j++) {
            var e = els[j];
            var box = e.getBoundingClientRect();
            out.push({
              tag: e.tagName,
              role: e.getAttribute('role'),
              label: e.getAttribute('aria-label'),
              text: (e.innerText || '').slice(0, 22).replace(/[\\r\\n]+/g, ' '),
              w: Math.round(box.width), h: Math.round(box.height)
            });
          }
        }
        return JSON.stringify({ controls: out });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    static let pressEscapeJS = """
    (function(){
      try {
        var opts = { key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true, cancelable: true };
        [document, document.body].forEach(function(t){
          t.dispatchEvent(new KeyboardEvent('keydown', opts));
          t.dispatchEvent(new KeyboardEvent('keyup', opts));
        });
        return 'escape dispatched';
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Click just outside the modal, where a backdrop would be.
    static let clickBackdropJS = """
    (function(){
      try {
        var dialogs = document.querySelectorAll('[role="dialog"]');
        var target = null;
        for (var i = 0; i < dialogs.length; i++) {
          if (dialogs[i].getBoundingClientRect().height > 40) { target = dialogs[i]; break; }
        }
        if (!target) return 'no modal';
        var r = target.getBoundingClientRect();
        var x = Math.max(4, r.left / 2), y = Math.max(4, r.top / 2);
        var under = document.elementFromPoint(x, y);
        if (!under) return 'nothing at backdrop point';
        ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(k){
          under.dispatchEvent(new MouseEvent(k, { bubbles: true, cancelable: true, clientX: x, clientY: y }));
        });
        return 'clicked backdrop: ' + under.tagName;
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Radius bites or it doesn't: the chip is not evidence, the spread of
    /// cities in the results is.
    static let radiusSpreadJS = """
    (function(){
      try {
        var links = document.querySelectorAll('a[href*="/marketplace/item/"]');
        var cities = {}, ids = [];
        for (var i = 0; i < links.length; i++) {
          var label = links[i].getAttribute('aria-label') || '';
          var m = label.match(/, ([A-Za-z .'-]+, [A-Z]{2}), listing/);
          if (m) cities[m[1]] = (cities[m[1]] || 0) + 1;
          var h = links[i].getAttribute('href') || '';
          var k = h.indexOf('/marketplace/item/');
          if (k !== -1) {
            var j = k + 18, id = '';
            while (j < h.length) {
              var c = h.charAt(j);
              if (c >= '0' && c <= '9') { id += c; j++; } else { break; }
            }
            if (id) ids.push(id);
          }
        }
        var chip = null;
        var btns = document.querySelectorAll('div[role="button"]');
        for (var n = 0; n < btns.length; n++) {
          var t = (btns[n].innerText || '').trim();
          if (t.indexOf('Within') !== -1) { chip = t.replace(/[\\r\\n]+/g, ' '); break; }
        }
        return JSON.stringify({ chip: chip, cards: links.length,
                                cities: cities, firstIds: ids.slice(0, 5) });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Seller fields are the one thing desktop item pages lack logged out.
    static let sellerFieldsJS = """
    (function(){
      try {
        var body = document.body.innerText || '';
        var html = document.documentElement.outerHTML;
        return JSON.stringify({
          joined: (body.match(/Joined Facebook[^]{0,24}/i) || [])[0] || null,
          rating: (body.match(/[0-9]+ ratings?/i) || [])[0] || null,
          ratingAlt: (body.match(/[0-9](\\.[0-9])? out of 5|[0-9]+ review/i) || [])[0] || null,
          starIcons: document.querySelectorAll('[aria-label*="star" i], [aria-label*="rating" i]').length,
          sellerHeading: /Seller information/i.test(body),
          profileLinks: document.querySelectorAll('a[href*="/marketplace/profile/"]').length,
          sellerKeyCount: (html.match(/marketplace_listing_seller/g) || []).length,
          latitude: (html.match(/"latitude":(-?[0-9]+\\.[0-9]+)/) || [])[1] || null,
          listed: (body.match(/Listed[^]{0,34}/) || [])[0] || null,
          photos: document.querySelectorAll('img[src*="scontent"]').length
        });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    /// Two independent readiness signals for one item page.
    ///
    /// `payload` uses the own-listing discriminator — a `creation_time`
    /// followed by `location_text` — rather than any `creation_time`, because
    /// the "Today's picks" rail carries ~20 belonging to other sellers and
    /// would report ready far too early.
    /// Takes the expected listing id, because `webView.load()` leaves the
    /// previous document in place until the new one commits — and the previous
    /// document is another item page carrying the same marker keys. Without
    /// this guard the first poll reports ready at ~0 ms every time, which is
    /// how the first run produced a 0.01 s "result".
    static func timingProbe(expectedID: String) -> String {
        """
        (function(){
          try {
            var html = document.documentElement.outerHTML;
            var body = document.body ? (document.body.innerText || '') : '';
            var fresh = location.href.indexOf('\(expectedID)') !== -1;
            var own = html.indexOf('location_text') !== -1 &&
                      html.indexOf('creation_time') !== -1;
            return JSON.stringify({
              fresh: fresh,
              payload: fresh && own,
              rendered: fresh && body.indexOf('Listed') !== -1 && body.length > 200,
              htmlLen: html.length,
              bodyLen: body.length
            });
          } catch (e) { return JSON.stringify({ payload: false, rendered: false }); }
        })()
        """
    }

    /// Dumps the Seller information block verbatim instead of pattern-matching
    /// for a phrasing. The last survey looked for "N ratings" while the page
    /// renders "(N)" beside star glyphs, so it reported no ratings anywhere —
    /// reading the section and looking at it is the fix.
    static let sellerSectionJS = """
    (function(){
      try {
        var body = document.body.innerText || '';
        var section = null;
        var all = document.querySelectorAll('div, section, span, h2, h3');
        for (var i = 0; i < all.length; i++) {
          var t = (all[i].innerText || '').trim();
          if (t.indexOf('Seller information') === 0 && t.length > 20 && t.length < 400) {
            section = t;
            break;
          }
        }
        var starLabels = [];
        var labelled = document.querySelectorAll('[aria-label]');
        for (var j = 0; j < labelled.length && starLabels.length < 5; j++) {
          var l = labelled[j].getAttribute('aria-label') || '';
          if (/star|rating|rated/i.test(l)) starLabels.push(l.slice(0, 50));
        }
        return JSON.stringify({
          href: location.href.slice(0, 90),
          sellerSection: section ? section.replace(/[\\r\\n]+/g, ' | ').slice(0, 180) : null,
          hasSellerHeading: body.indexOf('Seller information') !== -1,
          sellerDetailsLink: body.indexOf('Seller details') !== -1,
          highlyRated: body.indexOf('Highly rated') !== -1,
          parenCount: (body.match(/\\((\\d+)\\)/) || [])[1] || null,
          joined: (body.match(/Joined Facebook in \\d{4}/) || [])[0] || null,
          starLabels: starLabels,
          profileLinks: document.querySelectorAll('a[href*="/marketplace/profile/"]').length,
          listed: (body.match(/Listed [^|]{0,34}/) || [])[0] || null,
          // The full page renders the Marketplace sidebar; the click route
          // appears to open a lightbox instead. Recording the layout as well
          // as the fields, since layout is the likely cause of any difference.
          hasSidebar: body.indexOf('Browse all') !== -1 || body.indexOf('Create new listing') !== -1,
          hasCloseButton: document.querySelectorAll('[aria-label="Close"]').length,
          bodyLen: body.length
        });
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    static let firstCardIDJS = """
    (function(){
      var a = document.querySelector('a[href*="/marketplace/item/"]');
      if (!a) return 'none';
      var h = a.getAttribute('href') || '';
      var k = h.indexOf('/marketplace/item/');
      var j = k + 18, id = '';
      while (j < h.length) {
        var c = h.charAt(j);
        if (c >= '0' && c <= '9') { id += c; j++; } else { break; }
      }
      return id;
    })()
    """

    static let bodyTextJS = """
    (function(){
      return JSON.stringify({ text: (document.body.innerText || '').slice(0, 6000) });
    })()
    """

    static let cardIDListJS = """
    (function(){
      var out = [], seen = {};
      var links = document.querySelectorAll('a[href*="/marketplace/item/"]');
      for (var i = 0; i < links.length; i++) {
        var h = links[i].getAttribute('href') || '';
        var k = h.indexOf('/marketplace/item/');
        if (k === -1) continue;
        var j = k + 18, id = '';
        while (j < h.length) {
          var c = h.charAt(j);
          if (c >= '0' && c <= '9') { id += c; j++; } else { break; }
        }
        if (id.length > 8 && !seen[id]) { seen[id] = 1; out.push(id); }
      }
      return JSON.stringify(out);
    })()
    """

    static func clickCardAt(index: Int) -> String {
        """
        (function(){
          try {
            var links = document.querySelectorAll('a[href*="/marketplace/item/"]');
            var a = links[\(index)];
            if (!a) return 'no card at \(index)';
            a.scrollIntoView({ block: 'center' });
            var r = a.getBoundingClientRect();
            var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
            ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(k){
              a.dispatchEvent(new MouseEvent(k, { bubbles: true, cancelable: true,
                                                  composed: true, clientX: cx, clientY: cy }));
            });
            return 'clicked';
          } catch (e) { return 'ERR ' + String(e.message); }
        })()
        """
    }

    static let clickFirstCardJS = """
    (function(){
      try {
        var a = document.querySelector('a[href*="/marketplace/item/"]');
        if (!a) return 'no card';
        a.scrollIntoView({ block: 'center' });
        var r = a.getBoundingClientRect();
        var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(k){
          a.dispatchEvent(new MouseEvent(k, { bubbles: true, cancelable: true,
                                              composed: true, clientX: cx, clientY: cy }));
        });
        return 'clicked ' + (a.getAttribute('aria-label') || '').slice(0, 40);
      } catch (e) { return 'ERR ' + String(e.message); }
    })()
    """

    static let cardCountJS = """
    (function(){
      var imgs = document.querySelectorAll('img'), n = 0;
      for (var i = 0; i < imgs.length; i++) {
        var s = imgs[i].getAttribute('src') || '';
        if (s.indexOf('scontent') !== -1 && s.indexOf('rsrc.php') === -1) n++;
      }
      var html = document.documentElement.outerHTML;
      return JSON.stringify({
        photos: n,
        docHeight: document.body.scrollHeight,
        htmlLen: html.length,
        creationTimes: (html.match(/creation_time/g) || []).length
      });
    })()
    """

    static let feedStateJS = """
    (function(){
      \(strictCardFinder)
      var cards = mpCards();
      return JSON.stringify({
        cards: cards.length,
        firstLabel: cards.length ? (cards[0].img.getAttribute('alt') || '(none)').slice(0, 52) : null,
        url: location.href.slice(0, 72)
      });
    })()
    """

    static func tapCard(index: Int) -> String {
        """
        (function(){
          \(strictCardFinder)
          var cards = mpCards();
          var c = cards[\(index)];
          if (!c) return 'no-card-at-index';
          c.el.scrollIntoView({block: 'center'});
          var r = c.el.getBoundingClientRect();
          var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
          ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(k){
            c.el.dispatchEvent(new MouseEvent(k, {bubbles:true, cancelable:true, composed:true, clientX:cx, clientY:cy}));
          });
          return 'tapped: ' + (c.img.getAttribute('alt') || '').slice(0, 46);
        })()
        """
    }

    /// Everything the app's extractDetail needs, read off a mobile item page.
    /// Deliberately free of backslashes: this string crosses Python, Swift and
    /// JS, and the previous version's regexes did not survive the trip.
    static let mobileItemDumpJS = """
    (function(){
     try {
      var body = (document.body && document.body.innerText) || '';
      var NL = String.fromCharCode(10);
      var lines = body.split(NL).map(function(s){ return s.trim(); })
                      .filter(function(s){ return s.length > 0; });

      function after(label) {
        for (var i = 0; i < lines.length - 1; i++) {
          if (lines[i].toLowerCase() === label.toLowerCase()) return lines[i + 1].slice(0, 56);
        }
        return null;
      }

      var seen = {}, photos = 0, imgs = document.querySelectorAll('img');
      for (var j = 0; j < imgs.length; j++) {
        var src = imgs[j].getAttribute('src') || '';
        if (src.indexOf('scontent') === -1 || src.indexOf('rsrc.php') !== -1) continue;
        var parts = src.split('/').pop().split('_');
        var key = parts.length > 1 ? parts[1] : src;
        if (seen[key]) continue;
        seen[key] = 1; photos++;
      }

      var html = document.documentElement.outerHTML;
      var coords = null, mi = html.indexOf('static_map');
      if (mi !== -1) {
        var chunk = html.slice(mi, mi + 220), ci = chunk.indexOf('center=');
        if (ci !== -1) coords = chunk.slice(ci + 7, ci + 44);
      }

      var seller = null, joined = null;
      for (var m = 0; m < lines.length; m++) {
        if (lines[m].indexOf('Joined Facebook') === 0) {
          joined = lines[m];
          if (m > 0) seller = lines[m - 1];
        }
      }

      var path = location.pathname, ix = path.indexOf('/item/');
      return JSON.stringify({
        itemId: ix === -1 ? null : path.slice(ix + 6).split('/')[0],
        title: (document.title || '').slice(0, 30),
        description: after('Description'),
        condition: after('Condition'),
        photos: photos,
        seller: seller,
        joined: joined,
        coords: coords,
        stopMarker: body.indexOf("Today's picks") !== -1 || body.indexOf('Related searches') !== -1,
        loginNoise: body.toLowerCase().indexOf('scan the qr code') !== -1
      });
     } catch (e) {
       return JSON.stringify({error: String(e && e.message ? e.message : e).slice(0, 110),
                              url: location.href.slice(0, 60)});
     }
    })()
    """

    // MARK: - Tap probe

    /// The app's card finder, exactly: a listing photo is on scontent and is
    /// not Facebook's own chrome from rsrc.php. Under a bare `fbcdn` match the
    /// wordmark becomes cards[0] and every "tap worked" result is really the
    /// logo navigating home.
    private static let strictCardFinder = """
    function mpIsListingPhoto(img) {
      var s = img.getAttribute('src') || '';
      return s.indexOf('scontent') !== -1 && s.indexOf('rsrc.php') === -1;
    }
    function mpCards() {
      var out = [], imgs = document.querySelectorAll('img');
      for (var i = 0; i < imgs.length; i++) {
        if (!mpIsListingPhoto(imgs[i])) continue;
        var action = imgs[i].closest ? imgs[i].closest('[data-action-id]') : null;
        out.push({el: action || imgs[i].parentElement, img: imgs[i]});
      }
      return out;
    }
    function mpTarget() {
      var cards = mpCards();
      if (!cards.length) return null;
      var c = cards[0];
      var r = c.el.getBoundingClientRect();
      // Scroll it into view: a card below the fold has no hit-testable point.
      if (r.top < 0 || r.bottom > window.innerHeight) {
        c.el.scrollIntoView({block: 'center'});
        r = c.el.getBoundingClientRect();
      }
      return {el: c.el, img: c.img, rect: r,
              cx: r.left + r.width / 2, cy: r.top + r.height / 2};
    }
    """

    /// What are we about to tap? Rule 2 of the probe checklist: echo the sample.
    static let strictCardsJS = """
    (function(){
      \(strictCardFinder)
      var cards = mpCards();
      var t = mpTarget();
      if (!t) return JSON.stringify({cards: 0});
      var atPoint = document.elementFromPoint(t.cx, t.cy);
      var chain = [], p = atPoint, d = 0;
      while (p && d < 6) {
        chain.push(p.tagName.toLowerCase()
          + (p.getAttribute('role') ? '[role=' + p.getAttribute('role') + ']' : '')
          + (p.hasAttribute('data-action-id') ? '[action-id]' : '')
          + (p.tagName === 'A' ? '(href=' + (p.getAttribute('href') || '') .slice(0, 40) + ')' : ''));
        p = p.parentElement; d++;
      }
      return JSON.stringify({
        cards: cards.length,
        tappingText: (t.el.innerText || '').replace(/\\n/g, ' | ').slice(0, 70),
        tappingLabel: (t.img.getAttribute('alt') || '(none)').slice(0, 70),
        rect: Math.round(t.rect.width) + 'x' + Math.round(t.rect.height)
              + ' @' + Math.round(t.cx) + ',' + Math.round(t.cy),
        elementAtPoint: chain,
        sameAsCardRoot: atPoint === t.el || t.el.contains(atPoint),
        actionId: (t.el.getAttribute('data-action-id') || '(none)').slice(0, 40),
        url: location.href.slice(0, 80)
      });
    })()
    """

    /// WebLite may route client-side, in which case the navigation delegate
    /// never fires. Catch every other exit too.
    static let navHookJS = """
    (function(){
      if (window.__mpNav) return JSON.stringify({already: true});
      window.__mpNav = [];
      var ps = history.pushState, rs = history.replaceState;
      history.pushState = function(){ window.__mpNav.push('pushState ' + arguments[2]); return ps.apply(history, arguments); };
      history.replaceState = function(){ window.__mpNav.push('replaceState ' + arguments[2]); return rs.apply(history, arguments); };
      var op = window.open;
      window.open = function(u){ window.__mpNav.push('window.open ' + u); return op.apply(window, arguments); };
      window.addEventListener('beforeunload', function(){ window.__mpNav.push('beforeunload'); });
      window.addEventListener('popstate', function(){ window.__mpNav.push('popstate ' + location.href); });
      // Did anything at all handle the gesture?
      ['click','pointerdown','touchstart'].forEach(function(type){
        document.addEventListener(type, function(e){
          window.__mpNav.push('saw ' + type + ' on ' + e.target.tagName);
        }, true);
      });
      return JSON.stringify({installed: true});
    })()
    """

    static let navStateJS = """
    (function(){
      return JSON.stringify({
        url: location.href.slice(0, 90),
        title: (document.title || '').slice(0, 40),
        events: (window.__mpNav || []).slice(0, 8)
      });
    })()
    """

    /// Four ways to deliver the gesture. The fourth is the one the earlier
    /// round never tried: dispatch to whatever `elementFromPoint` reports,
    /// which is what a real finger would actually hit, rather than to the card
    /// container we happen to have a reference to.
    static let tapAttempts: [(String, String)] = [
        ("mouse-on-card", """
        (function(){
          \(strictCardFinder)
          var t = mpTarget(); if (!t) return 'no-card';
          window.__mpNav = window.__mpNav || [];
          ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(k){
            t.el.dispatchEvent(new MouseEvent(k, {bubbles:true, cancelable:true, composed:true, clientX:t.cx, clientY:t.cy}));
          });
          return 'sent';
        })()
        """),
        ("touch-on-card", """
        (function(){
          \(strictCardFinder)
          var t = mpTarget(); if (!t) return 'no-card';
          function T(){ return new Touch({identifier:1, target:t.el, clientX:t.cx, clientY:t.cy,
                                          pageX:t.cx, pageY:t.cy, radiusX:11, radiusY:11, force:1}); }
          try {
            t.el.dispatchEvent(new TouchEvent('touchstart', {bubbles:true, cancelable:true, composed:true,
              touches:[T()], targetTouches:[T()], changedTouches:[T()]}));
            t.el.dispatchEvent(new TouchEvent('touchend', {bubbles:true, cancelable:true, composed:true,
              touches:[], targetTouches:[], changedTouches:[T()]}));
          } catch (e) { return 'touch-err:' + e.message; }
          return 'sent';
        })()
        """),
        ("native-click-on-card", """
        (function(){
          \(strictCardFinder)
          var t = mpTarget(); if (!t) return 'no-card';
          if (typeof t.el.click !== 'function') return 'no-click-method';
          t.el.click();
          return 'sent';
        })()
        """),
        ("full-gesture-at-point", """
        (function(){
          \(strictCardFinder)
          var t = mpTarget(); if (!t) return 'no-card';
          var target = document.elementFromPoint(t.cx, t.cy) || t.el;
          function T(){ return new Touch({identifier:1, target:target, clientX:t.cx, clientY:t.cy,
                                          pageX:t.cx, pageY:t.cy, radiusX:11, radiusY:11, force:1}); }
          try {
            target.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, cancelable:true, composed:true,
              clientX:t.cx, clientY:t.cy, pointerType:'touch', isPrimary:true}));
            target.dispatchEvent(new TouchEvent('touchstart', {bubbles:true, cancelable:true, composed:true,
              touches:[T()], targetTouches:[T()], changedTouches:[T()]}));
            target.dispatchEvent(new TouchEvent('touchend', {bubbles:true, cancelable:true, composed:true,
              touches:[], targetTouches:[], changedTouches:[T()]}));
            target.dispatchEvent(new PointerEvent('pointerup', {bubbles:true, cancelable:true, composed:true,
              clientX:t.cx, clientY:t.cy, pointerType:'touch', isPrimary:true}));
            ['mousedown','mouseup','click'].forEach(function(k){
              target.dispatchEvent(new MouseEvent(k, {bubbles:true, cancelable:true, composed:true, clientX:t.cx, clientY:t.cy}));
            });
          } catch (e) { return 'err:' + e.message; }
          return 'sent to ' + target.tagName;
        })()
        """)
    ]

    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1"

    /// Shared preamble: locate the first listing card the same way the app does.
    private static let cardPreamble = """
    var all = Array.prototype.slice.call(document.querySelectorAll('div[data-action-id]'));
    var cands = all.filter(function(el){
      var i = el.querySelector('img');
      return i && (i.getAttribute('src')||'').indexOf('fbcdn') !== -1;
    });
    var cards = cands.filter(function(el){
      return !cands.some(function(o){ return o !== el && el.contains(o); });
    });
    var el = cards[0];
    if (!el) return 'no-card';
    var r = el.getBoundingClientRect();
    var cx = r.left + r.width/2, cy = r.top + r.height/2;
    """

    static let tapStrategies: [(String, String)] = [
        ("mouse", """
        (function(){
          \(cardPreamble)
          ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){
            el.dispatchEvent(new MouseEvent(t, {bubbles:true, cancelable:true, composed:true, clientX:cx, clientY:cy}));
          });
          return 'mouse-sent';
        })()
        """),
        ("touch", """
        (function(){
          \(cardPreamble)
          function T(){ return new Touch({identifier:1, target:el, clientX:cx, clientY:cy, pageX:cx, pageY:cy, radiusX:11, radiusY:11, force:1}); }
          el.dispatchEvent(new TouchEvent('touchstart', {bubbles:true, cancelable:true, composed:true, touches:[T()], targetTouches:[T()], changedTouches:[T()]}));
          el.dispatchEvent(new TouchEvent('touchend', {bubbles:true, cancelable:true, composed:true, touches:[], targetTouches:[], changedTouches:[T()]}));
          return 'touch-sent';
        })()
        """),
        ("touch+mouse", """
        (function(){
          \(cardPreamble)
          function T(){ return new Touch({identifier:1, target:el, clientX:cx, clientY:cy, pageX:cx, pageY:cy, radiusX:11, radiusY:11, force:1}); }
          el.dispatchEvent(new TouchEvent('touchstart', {bubbles:true, cancelable:true, composed:true, touches:[T()], targetTouches:[T()], changedTouches:[T()]}));
          el.dispatchEvent(new TouchEvent('touchend', {bubbles:true, cancelable:true, composed:true, touches:[], targetTouches:[], changedTouches:[T()]}));
          ['mousedown','mouseup','click'].forEach(function(t){
            el.dispatchEvent(new MouseEvent(t, {bubbles:true, cancelable:true, composed:true, clientX:cx, clientY:cy}));
          });
          return 'touch+mouse-sent';
        })()
        """),
        ("nativeClick", """
        (function(){
          \(cardPreamble)
          if (typeof el.click === 'function') { el.click(); return 'native-click'; }
          return 'no-click-method';
        })()
        """)
    ]

    /// What is actually in the DOM? Don't assume the desktop href pattern.
    static let domShapeJS = """
    (function(){
      var anchors = Array.prototype.slice.call(document.querySelectorAll('a'));
      var patterns = {};
      anchors.forEach(function(a){
        var p = (a.getAttribute('href') || '').split('?')[0].replace(/\\d{6,}/g, '{id}');
        if (p) patterns[p] = (patterns[p] || 0) + 1;
      });
      var top = Object.keys(patterns).sort(function(x,y){ return patterns[y]-patterns[x]; }).slice(0,6)
        .map(function(k){ return k + ' x' + patterns[k]; });
      var imgs = Array.prototype.slice.call(document.querySelectorAll('img')).filter(function(i){ return i.naturalWidth > 100; });
      var body = document.body.innerText;
      return JSON.stringify({
        itemHrefs: document.querySelectorAll('a[href*="/marketplace/item/"]').length,
        anchors: anchors.length,
        topPatterns: top,
        bigImages: imgs.length,
        priceMatches: (body.match(/\\$\\d+|FREE/g) || []).length,
        docH: document.body.scrollHeight,
        bodyLen: body.length,
        bodyHead: body.slice(0, 120).replace(/\\n/g, ' ')
      });
    })()
    """

    /// Mobile cards aren't anchors. Find any surface carrying a listing id.
    static let idHuntJS = """
    (function(){
      var out = {};
      // 1. ids anywhere in raw HTML
      var html = document.documentElement.outerHTML;
      out.htmlItemRefs = (html.match(/marketplace\\/item\\/(\\d+)/g) || []).length;
      out.htmlItemUnique = Object.keys((html.match(/marketplace\\/item\\/(\\d+)/g) || [])
        .reduce(function(a,s){ a[s]=1; return a; }, {})).length;
      // 2. ids in script tags (embedded JSON)
      var sids = {};
      Array.prototype.slice.call(document.querySelectorAll('script')).forEach(function(s){
        (s.textContent.match(/"(?:story_)?id":"(\\d{10,})"/g) || []).forEach(function(m){ sids[m] = 1; });
      });
      out.scriptIdMatches = Object.keys(sids).length;
      // 3. data-* attributes on elements
      var attrs = {};
      Array.prototype.slice.call(document.querySelectorAll('[data-testid],[data-id],[id]')).forEach(function(e){
        ['data-testid','data-id','id'].forEach(function(k){
          var v = e.getAttribute(k);
          if (v) attrs[k + '=' + v.replace(/\\d{6,}/g,'{id}')] = (attrs[k + '=' + v.replace(/\\d{6,}/g,'{id}')] || 0) + 1;
        });
      });
      out.topAttrs = Object.keys(attrs).sort(function(x,y){ return attrs[y]-attrs[x]; }).slice(0,8)
        .map(function(k){ return k + ' x' + attrs[k]; });
      // 4. what element wraps a price? walk up from a price text node
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      var priceNode = null, n;
      while ((n = walker.nextNode())) { if (/^\\s*\\$\\d/.test(n.textContent)) { priceNode = n; break; } }
      if (priceNode) {
        var chain = [], el = priceNode.parentElement, depth = 0;
        while (el && depth < 8) {
          chain.push(el.tagName.toLowerCase() + (el.getAttribute('role') ? '[role=' + el.getAttribute('role') + ']' : '') + (el.tagName === 'A' ? '(href=' + el.getAttribute('href') + ')' : ''));
          el = el.parentElement; depth++;
        }
        out.priceAncestry = chain;
      }
      return JSON.stringify(out);
    })()
    """

    /// IDs aren't in the DOM. Are they in React internals attached to card elements?
    static let fiberHuntJS = """
    (function(){
      // find the card root: walk up from a price text node until the subtree also has an image
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      var priceNode = null, n;
      while ((n = walker.nextNode())) { if (/^\\s*\\$\\d/.test(n.textContent)) { priceNode = n; break; } }
      if (!priceNode) return JSON.stringify({error: 'no price node'});
      var card = priceNode.parentElement, depth = 0;
      while (card && depth < 10 && !card.querySelector('img')) { card = card.parentElement; depth++; }
      if (!card) return JSON.stringify({error: 'no card root'});

      var out = {cardTag: card.tagName, cardDepth: depth, cardText: card.innerText.slice(0,60).replace(/\\n/g,' ')};
      var internalKeys = Object.keys(card).filter(function(k){ return k.indexOf('__react') === 0 || k.indexOf('__') === 0; });
      out.internalKeys = internalKeys;

      // scan fiber/props objects for a long numeric id
      function scanForId(obj, depthLimit) {
        var seen = new Set(), found = [];
        (function walk(o, d) {
          if (!o || d > depthLimit || typeof o !== 'object' || seen.has(o)) return;
          seen.add(o);
          for (var k in o) {
            var v;
            try { v = o[k]; } catch (e) { continue; }
            if (typeof v === 'string' && /^\\d{10,}$/.test(v)) found.push(k + '=' + v);
            else if (typeof v === 'object') walk(v, d + 1);
            if (found.length > 6) return;
          }
        })(obj, 0);
        return found;
      }
      internalKeys.forEach(function(k){
        try { out['scan_' + k] = scanForId(card[k], 6); } catch (e) { out['scan_' + k] = 'err'; }
      });

      // does the card respond to click by changing location?
      out.clickable = !!(card.onclick || card.getAttribute('role') || card.closest('[role="button"]'));
      out.roleAncestor = card.closest('[role]') ? card.closest('[role]').getAttribute('role') : null;
      return JSON.stringify(out);
    })()
    """

    /// Exhaustive: every attribute, every React key, every long number anywhere.
    static let deepIDHuntJS = """
    (function(){
      var out = {};
      function cardRoot() {
        var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), n, p = null;
        while ((n = w.nextNode())) { if (/^\\s*\\$\\d/.test(n.textContent)) { p = n; break; } }
        if (!p) return null;
        var el = p.parentElement, d = 0;
        while (el && d < 12 && !el.querySelector('img')) { el = el.parentElement; d++; }
        return el;
      }
      var card = cardRoot();
      if (!card) return JSON.stringify({error:'no card'});

      // every attribute on card + 6 ancestors + all descendants
      var attrNames = {};
      function collect(el){
        if (!el || !el.attributes) return;
        for (var i=0;i<el.attributes.length;i++){
          var a = el.attributes[i];
          attrNames[a.name] = (attrNames[a.name]||0)+1;
          if (/^\\d{10,}$/.test(a.value)) attrNames['HIT:'+a.name+'='+a.value] = 1;
        }
      }
      var el = card;
      for (var i=0;i<6 && el;i++){ collect(el); el = el.parentElement; }
      Array.prototype.slice.call(card.querySelectorAll('*')).forEach(collect);
      out.attrNames = Object.keys(attrNames).slice(0,25);

      // react keys document-wide
      var reactKeyCount = 0, sampleKeys = [];
      var all = document.querySelectorAll('div');
      for (var j=0;j<Math.min(all.length, 400);j++){
        var ks = Object.keys(all[j]).filter(function(k){ return k.indexOf('__react') === 0; });
        if (ks.length) { reactKeyCount++; if (sampleKeys.length < 3) sampleKeys = ks; }
      }
      out.reactElements = reactKeyCount;
      out.reactSampleKeys = sampleKeys;

      // any 13-17 digit number anywhere in the document HTML
      var html = document.documentElement.outerHTML;
      var longNums = html.match(/\\b\\d{13,17}\\b/g) || [];
      var uniq = Object.keys(longNums.reduce(function(a,s){a[s]=1;return a;},{}));
      out.longNumberCount = uniq.length;
      out.longNumberSample = uniq.slice(0,5);

      // image URLs: do they carry the listing id?
      var img = card.querySelector('img');
      out.imgSrcSample = img ? img.src.slice(0, 160) : null;

      // global JS objects that might hold the store
      out.globals = Object.keys(window).filter(function(k){
        return /require|__d|RelayStore|__RELAY|ServerJS|Bootloader/i.test(k);
      }).slice(0, 12);
      return JSON.stringify(out);
    })()
    """

    /// If IDs aren't in the DOM, does tapping a card navigate to a URL containing one?
    static let clickTestJS = """
    (function(){
      var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), n, p = null;
      while ((n = w.nextNode())) { if (/^\\s*\\$\\d/.test(n.textContent)) { p = n; break; } }
      if (!p) return JSON.stringify({error:'no price node'});
      var el = p.parentElement, d = 0;
      while (el && d < 12 && !el.querySelector('img')) { el = el.parentElement; d++; }
      if (!el) return JSON.stringify({error:'no card'});
      var before = window.location.href;
      var r = el.getBoundingClientRect();
      var opts = {bubbles:true, cancelable:true, clientX: r.left + r.width/2, clientY: r.top + r.height/2};
      ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){
        try { el.dispatchEvent(new MouseEvent(t, opts)); } catch(e) {}
      });
      return JSON.stringify({dispatched:true, urlBefore: before, urlImmediatelyAfter: window.location.href, cardText: el.innerText.slice(0,50).replace(/\\n/g,' ')});
    })()
    """

    /// Search cards show price + title but no location, while category cards do
    /// show it. Is the location hiding in an attribute, an ancestor, or behind a
    /// distance sort?
    static let locationHuntJS = """
    (function(){
      var all = Array.prototype.slice.call(document.querySelectorAll('div[data-action-id]'));
      var cands = all.filter(function(el){
        var i = el.querySelector('img');
        return i && (i.getAttribute('src')||'').indexOf('fbcdn') !== -1;
      });
      var cards = cands.filter(function(el){
        return !cands.some(function(o){ return o !== el && el.contains(o); });
      });
      var el = cards[0];
      if (!el) return JSON.stringify({error:'no card'});

      var body = document.body.innerText || '';
      // Any "City, ST" or distance strings anywhere on the page?
      var cityMatches = (body.match(/[A-Z][A-Za-z .'-]+,\\s*[A-Z]{2}\\b/g) || []).slice(0, 5);
      var distMatches = (body.match(/\\d+(\\.\\d+)?\\s*(mi|km|miles)\\b/gi) || []).slice(0, 5);

      // Everything the card itself carries, including a11y labels.
      var labels = [];
      Array.prototype.slice.call(el.querySelectorAll('[aria-label],[alt],[title]')).forEach(function(n){
        ['aria-label','alt','title'].forEach(function(k){
          var v = n.getAttribute(k);
          if (v) labels.push(k + '=' + v.slice(0, 80));
        });
      });
      if (el.getAttribute('aria-label')) labels.push('self aria-label=' + el.getAttribute('aria-label').slice(0,80));

      // Does a wider ancestor include location text the innermost card drops?
      var chain = [], p = el, d = 0;
      while (p && d < 4) {
        chain.push({depth: d, len: (p.innerText||'').length, text: (p.innerText||'').replace(/\\n/g,' | ').slice(0, 120)});
        p = p.parentElement; d++;
      }
      return JSON.stringify({
        cardCount: cards.length,
        cardText: (el.innerText||'').replace(/\\n/g,' | ').slice(0,100),
        labels: labels.slice(0, 6),
        ancestors: chain,
        pageCities: cityMatches,
        pageDistances: distMatches
      });
    })()
    """

    /// Dump the shape of one card + the grid container so selectors can be designed.
    static let cardStructureJS = """
    (function(){
      function priceEl(){
        var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), n;
        while ((n = w.nextNode())) { if (/^\\s*\\$\\d/.test(n.textContent)) return n.parentElement; }
        return null;
      }
      var pe = priceEl();
      if (!pe) return JSON.stringify({error:'no price'});
      var card = pe, d = 0;
      while (card && d < 12 && !card.querySelector('img')) { card = card.parentElement; d++; }
      var grid = card ? card.parentElement : null;

      function summarize(el, depth, maxDepth) {
        if (!el || depth > maxDepth) return null;
        var attrs = {};
        for (var i=0;i<el.attributes.length;i++){
          var a = el.attributes[i];
          if (a.name.indexOf('data-') === 0 || a.name === 'role' || a.name === 'href' || a.name === 'src')
            attrs[a.name] = a.value.length > 60 ? a.value.slice(0,60)+'…' : a.value;
        }
        var own = '';
        for (var j=0;j<el.childNodes.length;j++)
          if (el.childNodes[j].nodeType === 3) own += el.childNodes[j].textContent;
        var kids = [];
        for (var k=0;k<el.children.length && k<6;k++)
          kids.push(summarize(el.children[k], depth+1, maxDepth));
        return {tag: el.tagName.toLowerCase(), attrs: attrs, text: own.trim().slice(0,40) || undefined,
                kids: kids.filter(Boolean).length ? kids : undefined};
      }

      return JSON.stringify({
        cardDepthFromPrice: d,
        siblingCards: grid ? grid.children.length : 0,
        gridAttrs: grid ? summarize(grid, 0, 0) : null,
        card: summarize(card, 0, 4),
        scrollables: Array.prototype.slice.call(document.querySelectorAll('[data-scrollable]')).map(function(e){
          return {tag: e.tagName.toLowerCase(), sh: e.scrollHeight, ch: e.clientHeight, val: e.getAttribute('data-scrollable')};
        }).slice(0,4)
      });
    })()
    """

    /// Programmatic scroll doesn't paginate. Does a synthesized touch sequence?
    static let touchScrollJS = """
    (function(){
      var target = document.querySelector('[data-scrollable]') ||
                   Array.prototype.slice.call(document.querySelectorAll('div'))
                     .filter(function(d){ return d.scrollHeight > d.clientHeight + 200; })
                     .sort(function(a,b){ return b.scrollHeight - a.scrollHeight; })[0] ||
                   document.body;
      function T(el, x, y, id){
        return new Touch({identifier: id || 1, target: el, clientX: x, clientY: y,
                          pageX: x, pageY: y, screenX: x, screenY: y, radiusX: 11, radiusY: 11, force: 1});
      }
      function fire(el, type, touches){
        try {
          el.dispatchEvent(new TouchEvent(type, {bubbles:true, cancelable:true, composed:true,
            touches: touches, targetTouches: touches, changedTouches: touches}));
          return true;
        } catch(e) { return 'err:' + e.message; }
      }
      var h = window.innerHeight || 800, x = Math.round((window.innerWidth||400) / 2);
      var startY = Math.round(h * 0.8), endY = Math.round(h * 0.2);
      var r1 = fire(target, 'touchstart', [T(target, x, startY)]);
      var steps = 8, ok = true;
      for (var i = 1; i <= steps; i++) {
        var y = Math.round(startY + (endY - startY) * (i / steps));
        if (fire(target, 'touchmove', [T(target, x, y)]) !== true) ok = false;
      }
      var r3 = fire(target, 'touchend', []);
      // also nudge native scroll in case the page relies on it after gesture
      window.scrollTo(0, document.body.scrollHeight);
      if (target.scrollTop !== undefined) target.scrollTop = target.scrollHeight;
      return JSON.stringify({target: target.tagName + (target.getAttribute('data-scrollable') ? '[scrollable]' : ''),
                             start: r1, moves: ok, end: r3});
    })()
    """

    static let paginationProbeJS = """
    (function(){
      var body = document.body.innerText;
      return JSON.stringify({
        prices: (body.match(/\\$[\\d,]+|FREE/g) || []).length,
        bigImages: Array.prototype.slice.call(document.querySelectorAll('img')).filter(function(i){ return i.naturalWidth > 100; }).length,
        docH: document.body.scrollHeight,
        scrollY: Math.round(window.scrollY)
      });
    })()
    """

    static let scrollJS = """
    (function(){
      window.scrollTo(0, document.body.scrollHeight);
      var best = null;
      Array.prototype.slice.call(document.querySelectorAll('div')).forEach(function(d){
        if (d.scrollHeight > d.clientHeight + 200 && (!best || d.scrollHeight > best.scrollHeight)) best = d;
      });
      if (best) best.scrollTop = best.scrollHeight;
      return 'ok';
    })()
    """

    static let probeAndScrollJS = """
    (function(){
      var links = Array.prototype.slice.call(document.querySelectorAll('a[href*="/marketplace/item/"]'));
      var ids = {}; var first = null;
      links.forEach(function(a){ var m = a.href.match(/marketplace\\/item\\/(\\d+)/); if (m) { ids[m[1]] = 1; if (!first) first = m[1]; } });
      window.scrollTo(0, document.body.scrollHeight);
      var best = null;
      Array.prototype.slice.call(document.querySelectorAll('div')).forEach(function(d){
        if (d.scrollHeight > d.clientHeight + 200) { if (!best || d.scrollHeight > best.scrollHeight) best = d; }
      });
      if (best) best.scrollTop = best.scrollHeight;
      var body = document.body.innerText;
      return JSON.stringify({
        count: Object.keys(ids).length,
        firstId: first,
        modal: body.indexOf('See more on Facebook') !== -1,
        loginWall: body.indexOf('You must log in') !== -1,
        docH: Math.max(document.body.scrollHeight, best ? best.scrollHeight : 0),
        title: document.title.slice(0, 50)
      });
    })()
    """

    static let detailProbeJS = """
    (function(){
      var body = document.body.innerText;
      var imgs = Array.prototype.slice.call(document.querySelectorAll('img')).filter(function(i){
        return i.src.indexOf('scontent') !== -1 && i.naturalWidth > 100;
      });
      var inScripts = false;
      var scripts = document.querySelectorAll('script');
      for (var i = 0; i < scripts.length; i++) {
        if (scripts[i].textContent.indexOf('marketplace_listing_title') !== -1) { inScripts = true; break; }
      }
      return JSON.stringify({
        hasPrice: /\\$\\d+/.test(body),
        hasCondition: body.indexOf('Condition') !== -1,
        hasDescriptionSection: body.indexOf('Description') !== -1 || body.indexOf('Details') !== -1,
        hasListedAgo: /Listed .* ago/.test(body),
        photoCount: imgs.length,
        jsonInScripts: inScripts,
        loginWall: body.indexOf('You must log in') !== -1,
        title: document.title.slice(0, 50)
      });
    })()
    """

    /// Records every request the page makes for the device's position.
    /// Replaces `navigator.geolocation` with one that answers from
    /// `window.__geoFeed`, set from Swift before the arrow is clicked.
    ///
    /// Defines the object outright when WKWebView doesn't provide one, so the
    /// page's feature detection sees a working API either way.
    static let geoFeederJS = """
    (function(){
      if (window.__geoFedHooked) return;
      window.__geoFedHooked = true;
      window.__geoFeed = null;
      window.__geoFedCalls = 0;
      function position() {
        return {
          coords: {
            latitude: window.__geoFeed.lat, longitude: window.__geoFeed.lon,
            accuracy: 20, altitude: null, altitudeAccuracy: null,
            heading: null, speed: null
          },
          timestamp: Date.now()
        };
      }
      function getCurrentPosition(ok, err) {
        window.__geoFedCalls++;
        if (!window.__geoFeed) { if (err) err({ code: 2, message: 'no fix set' }); return; }
        setTimeout(function(){ ok(position()); }, 0);
      }
      function watchPosition(ok, err) { getCurrentPosition(ok, err); return 1; }
      var impl = { getCurrentPosition: getCurrentPosition,
                   watchPosition: watchPosition,
                   clearWatch: function(){} };
      var g = navigator.geolocation;
      if (!g) {
        window.__geoWasMissing = true;
        Object.defineProperty(navigator, 'geolocation', { value: impl, configurable: true });
      } else {
        window.__geoWasMissing = false;
        Object.defineProperty(g, 'getCurrentPosition', { value: getCurrentPosition, writable: true, configurable: true });
        Object.defineProperty(g, 'watchPosition', { value: watchPosition, writable: true, configurable: true });
      }
    })();
    """

    /// Opens the location dialog from the header pill.
    static let openLocationDialogJS = """
    (function(){
      // Units follow the place, not the viewer — a Canadian location renders
      // "Toronto · 8 km". Matching only "mi" made a working pill invisible.
      var btn = Array.prototype.slice.call(document.querySelectorAll('div[role="button"]'))
        .filter(function(e){ var t = (e.textContent||'').trim();
                             return /·\\s*\\d+\\s*(mi|km)/i.test(t) && t.length < 80; })[0];
      if (!btn) {
        var all = Array.prototype.slice.call(document.querySelectorAll('div[role="button"]'))
          .map(function(e){ return (e.textContent||'').trim().slice(0,40); })
          .filter(function(t){ return t.length > 2; }).slice(0, 10);
        return JSON.stringify({ opened: false, reason: 'pill not found', sawButtons: all });
      }
      btn.click();
      return JSON.stringify({ opened: true, pill: btn.textContent.trim() });
    })()
    """

    /// Clicks the centring arrow after arming the feed. Reports whether the
    /// control existed at all, which is the first thing that could differ
    /// between a desktop browser and WKWebView.
    static let clickGeoArrowJS = """
    (function(){
      var arrow = document.querySelector('[aria-label="Marketplace geolocation picker"]');
      if (!arrow) return JSON.stringify({ clicked: false, reason: 'arrow absent',
                                          geoMissing: window.__geoWasMissing });
      var before = window.__geoFedCalls;
      arrow.click();
      return JSON.stringify({ clicked: true, callsBefore: before,
                              callsAfter: window.__geoFedCalls,
                              geoMissing: window.__geoWasMissing });
    })()
    """

    /// What the dialog resolved the coordinate to, before Apply.
    static let pickerFieldJS = """
    (function(){
      var labels = Array.prototype.slice.call(document.querySelectorAll('label,div'))
        .filter(function(e){ return /^Location/.test((e.textContent||'').trim()); });
      var inputs = Array.prototype.slice.call(document.querySelectorAll('input'))
        .map(function(i){ return { value: i.value, placeholder: i.placeholder, label: i.getAttribute('aria-label') }; })
        .filter(function(i){ return i.value || i.placeholder; });
      var field = labels.length ? labels[labels.length-1].textContent.trim().slice(0, 80) : null;
      return JSON.stringify({ field: field, inputs: inputs.slice(0, 4), url: location.href });
    })()
    """

    /// Applies the resolved place and reports what actually changed — the URL
    /// is the thing the app would have to persist.
    static let applyLocationJS = """
    (function(){
      var apply = document.querySelector('[aria-label="Apply"]');
      if (!apply) return JSON.stringify({ applied: false, reason: 'no Apply' });
      apply.click();
      return JSON.stringify({ applied: true });
    })()
    """

    /// Where the listings ended up, read off the cards rather than the header.
    static let resultCitiesJS = """
    (function(){
      var cities = {};
      Array.prototype.slice.call(document.querySelectorAll('a[href*="/marketplace/item/"]'))
        .forEach(function(a){
          var m = (a.getAttribute('aria-label') || a.textContent || '').match(/([A-Za-z .'-]+,\\s*[A-Z]{2})\\b/);
          if (m) cities[m[1]] = (cities[m[1]] || 0) + 1;
        });
      return JSON.stringify({ url: location.href, cities: cities });
    })()
    """

    static let geoRecorderJS = """
    (function(){
      if (window.__geoHooked) return;
      window.__geoHooked = true;
      window.__geoCalls = [];
      try {
        var g = navigator.geolocation;
        if (!g) { window.__geoCalls.push({ kind: 'unavailable' }); return; }
        var get = g.getCurrentPosition.bind(g);
        g.getCurrentPosition = function(ok, err, opts) {
          window.__geoCalls.push({ kind: 'get', opts: JSON.stringify(opts || {}) });
          return get(ok, err, opts);
        };
        var watch = g.watchPosition.bind(g);
        g.watchPosition = function(ok, err, opts) {
          window.__geoCalls.push({ kind: 'watch', opts: JSON.stringify(opts || {}) });
          return watch(ok, err, opts);
        };
      } catch (e) {
        window.__geoCalls.push({ kind: 'hook-failed', error: String(e) });
      }
    })();
    """

    /// Proves the hook above can see a call, by making one. Without this, "the
    /// page never asked" and "the recorder never installed" look identical.
    static let geoControlJS = """
    (function(){
      var before = (window.__geoCalls || []).length;
      try {
        navigator.geolocation.getCurrentPosition(function(){}, function(){});
      } catch (e) {
        return JSON.stringify({ hooked: !!window.__geoHooked, error: String(e) });
      }
      var after = (window.__geoCalls || []).length;
      return JSON.stringify({
        hooked: !!window.__geoHooked,
        pageCalls: before,
        sawOwnCall: after > before,
        calls: (window.__geoCalls || []).slice(0, 4)
      });
    })()
    """

    /// Where did the *listings* come from — not where does the header claim.
    ///
    /// Cities are read off card aria-labels, whose last three comma segments
    /// are `<city>, <ST>, listing <id>`. Echoes a whole sample label so a
    /// mis-parse is visible rather than silent (checklist §2), and reports
    /// `location.href` after load so a normalised or redirected URL can't be
    /// mistaken for the one that was requested (§5).
    static let locationProbeJS = """
    (function(){
      var html = document.documentElement.outerHTML;
      var labels = [];
      var anchors = document.querySelectorAll('a[href*="/marketplace/item/"]');
      for (var i = 0; i < anchors.length; i++) {
        var l = anchors[i].getAttribute('aria-label');
        if (l) labels.push(l);
      }
      // Mobile has no item anchors — its cards label themselves instead.
      if (labels.length === 0) {
        var labelled = document.querySelectorAll('[aria-label*=" in "]');
        for (var j = 0; j < labelled.length; j++) labels.push(labelled[j].getAttribute('aria-label'));
      }
      var counts = {};
      labels.forEach(function(s){
        var parts = s.split(', ');
        var city = null;
        if (parts.length >= 3 && /^[A-Z]{2}$/.test(parts[parts.length - 2])) {
          city = parts[parts.length - 3] + ', ' + parts[parts.length - 2];
        } else {
          var m = s.match(/ in ([^,]+, [A-Z]{2})/);
          if (m) city = m[1];
        }
        if (city) counts[city] = (counts[city] || 0) + 1;
      });
      var ids = [], seen = {};
      var echoes = html.match(/marketplace\\/(\\d{8,})\\//g) || [];
      echoes.forEach(function(e){ if (!seen[e]) { seen[e] = 1; ids.push(e); } });
      var rg = [], re = /"reverse_geocode":\\{[^}]*\\}[^}]*\\}/g, m2;
      while ((m2 = re.exec(html)) !== null && rg.length < 2) rg.push(m2[0].slice(0, 220));
      var near = (document.body.innerText.match(/[^\\n]*\\bnear\\b[^\\n]*/) || [''])[0];
      return JSON.stringify({
        href: location.href.slice(0, 150),
        cards: labels.length,
        cities: counts,
        sample: labels[0] ? labels[0].slice(0, 100) : null,
        near: near.slice(0, 110),
        idEchoes: ids.slice(0, 4),
        reverseGeocode: rg,
        pageGeoCalls: (window.__geoCalls || []).length,
        loginWall: html.indexOf('You must log in') !== -1,
        title: document.title.slice(0, 60)
      });
    })()
    """

    /// Did the place in the path survive, and where did the listings come from?
    ///
    /// `accepted` is the whole test: Facebook rewrites an unrecognised place to
    /// `/marketplace/category/search/` rather than erroring, so the pathname is
    /// the only thing that separates "your city" from "the city your IP is in".
    static let slugVerdictJS = """
    (function(){
      var labels = [], anchors = document.querySelectorAll('a[href*="/marketplace/item/"]');
      for (var i = 0; i < anchors.length; i++) {
        var l = anchors[i].getAttribute('aria-label');
        if (l) labels.push(l);
      }
      var counts = {};
      labels.forEach(function(s){
        var p = s.split(', ');
        if (p.length >= 3 && /^[A-Z]{2}$/.test(p[p.length - 2])) {
          var c = p[p.length - 3] + ', ' + p[p.length - 2];
          counts[c] = (counts[c] || 0) + 1;
        }
      });
      var top = Object.keys(counts).sort(function(a, b){ return counts[b] - counts[a]; });
      return JSON.stringify({
        accepted: location.pathname.indexOf('/category/') === -1,
        path: location.pathname,
        cards: labels.length,
        top: top.slice(0, 3).map(function(c){ return c + ' x' + counts[c]; })
      });
    })()
    """

    /// What on a search page looks like it opens the location control.
    static let pickerCandidatesJS = """
    (function(){
      var out = [], els = document.querySelectorAll('[role="button"], button, [role="link"]');
      for (var i = 0; i < els.length && out.length < 20; i++) {
        var e = els[i];
        var text = (e.innerText || '').trim().replace(/\\s+/g, ' ');
        var label = e.getAttribute('aria-label') || '';
        if (/San Francisco|Location|Within|\\d+\\s*mi\\b/i.test(text + ' ' + label)) {
          out.push({ tag: e.tagName, label: label.slice(0, 50), text: text.slice(0, 50) });
        }
      }
      return JSON.stringify({ total: els.length, candidates: out });
    })()
    """

    /// Clicks whatever looks most like the location control, and says what it
    /// clicked — a click on the wrong element is the classic way to record a
    /// false negative here (checklist §2).
    static let clickPickerJS = """
    (function(){
      var els = document.querySelectorAll('[role="button"], button, [role="link"]');
      for (var i = 0; i < els.length; i++) {
        var e = els[i];
        var text = (e.innerText || '').trim().replace(/\\s+/g, ' ');
        var label = e.getAttribute('aria-label') || '';
        if (/San Francisco|Location/i.test(text + ' ' + label)) {
          e.click();
          return JSON.stringify({ clicked: true, label: label.slice(0, 60), text: text.slice(0, 60) });
        }
      }
      return JSON.stringify({ clicked: false });
    })()
    """

    /// Whatever dialog is now open: its text, its inputs, and any listbox rows.
    static let dialogDumpJS = """
    (function(){
      var dialogs = document.querySelectorAll('[role="dialog"]');
      if (!dialogs.length) {
        return JSON.stringify({ dialogs: 0, url: location.href.slice(0, 110),
                                bodyHint: (document.body.innerText || '').slice(0, 160) });
      }
      var d = dialogs[dialogs.length - 1];
      var inputs = [];
      d.querySelectorAll('input').forEach(function(i){
        inputs.push({ type: i.type, label: (i.getAttribute('aria-label') || i.placeholder || '').slice(0, 50), value: i.value.slice(0, 40) });
      });
      var options = [];
      d.querySelectorAll('[role="option"], li, [role="menuitem"]').forEach(function(o){
        var t = (o.innerText || '').trim().replace(/\\s+/g, ' ');
        if (t && options.length < 8) options.push(t.slice(0, 60));
      });
      return JSON.stringify({
        dialogs: dialogs.length,
        text: (d.innerText || '').replace(/\\s+/g, ' ').slice(0, 220),
        inputs: inputs,
        options: options,
        url: location.href.slice(0, 110)
      });
    })()
    """

    /// React ignores a plain `input.value = x`; the native setter plus a
    /// bubbling `input` event is what its onChange actually listens for.
    static let typeTorontoJS = """
    (function(){
      var dialogs = document.querySelectorAll('[role="dialog"]');
      var scope = dialogs.length ? dialogs[dialogs.length - 1] : document;
      var input = scope.querySelector('input[type="text"], input:not([type])');
      if (!input) return JSON.stringify({ typed: false, reason: 'no input' });
      var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
      input.focus();
      setter.call(input, 'Toronto');
      input.dispatchEvent(new Event('input', { bubbles: true }));
      return JSON.stringify({ typed: true, label: (input.getAttribute('aria-label') || input.placeholder || '').slice(0, 50) });
    })()
    """

    /// Every card names its city *and* that city's Facebook place id, so one
    /// search yields addressable ids for everywhere it returned.
    static let placeIDHarvestJS = """
    (function(){
      var html = document.documentElement.outerHTML;
      var re = /"reverse_geocode":\\{"city":"([^"]+)","state":"([^"]+)","city_page":\\{"display_name":"[^"]*","id":"(\\d+)"\\}\\}/g;
      var out = {}, m;
      while ((m = re.exec(html)) !== null) out[m[1] + ', ' + m[2]] = m[3];
      return JSON.stringify(out);
    })()
    """

    /// Desktop-only: keys off item anchors, which mobile doesn't have.
    static let desktopFilterProbeJS = """
    (function(){
      var links = Array.prototype.slice.call(document.querySelectorAll('a[href*="/marketplace/item/"]'));
      var prices = [];
      links.forEach(function(a){ var m = a.textContent.match(/\\$([\\d,]+)/); if (m) prices.push(parseInt(m[1].replace(',',''))); });
      var radiusLine = (document.body.innerText.match(/·\\s*\\d+\\s*(mi|km)/) || [null])[0];
      return JSON.stringify({ cards: links.length, prices: prices, radiusLine: radiusLine });
    })()
    """
}
