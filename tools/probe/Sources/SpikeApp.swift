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
            Text("swipe the web area during the 60s window")
                .font(.caption2).padding(2)
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
        .onAppear { controller.start() }
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
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func emit(_ s: String) {
        log.append(s)
        NSLog("SPIKE| %@", s)
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await runTests() }
    }

    // MARK: - Test sequence

    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 Safari/605.1.15"

    /// Three questions the tap finding depends on: does it repeat, is the
    /// mobile item page extractable, and does history.back() put the feed back?
    func runTests() async {
        webView.customUserAgent = Self.mobileUA
        await load("https://www.facebook.com/marketplace/sanfrancisco/search/?query=desk")
        try? await Task.sleep(for: .seconds(15))

        for idx in [0, 1] {
            emit("BEFORE[\(idx)] \(await js(Self.feedStateJS))")
            emit("TAP[\(idx)] \(await js(Self.tapCard(index: idx)))")
            try? await Task.sleep(for: .seconds(6))
            emit("ITEM[\(idx)] \(await js(Self.mobileItemDumpJS))")

            _ = await js("(function(){ history.back(); return 'back'; })()")
            try? await Task.sleep(for: .seconds(6))
            emit("BACK[\(idx)] \(await js(Self.feedStateJS))")
        }

        emit("=== TAPFLOW COMPLETE ===")
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

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
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

    static let filterProbeJS = """
    (function(){
      var links = Array.prototype.slice.call(document.querySelectorAll('a[href*="/marketplace/item/"]'));
      var prices = [];
      links.forEach(function(a){ var m = a.textContent.match(/\\$([\\d,]+)/); if (m) prices.push(parseInt(m[1].replace(',',''))); });
      var radiusLine = (document.body.innerText.match(/·\\s*\\d+\\s*(mi|km)/) || [null])[0];
      return JSON.stringify({ cards: links.length, prices: prices, radiusLine: radiusLine });
    })()
    """
}
