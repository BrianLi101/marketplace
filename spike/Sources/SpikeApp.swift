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

    func runTests() async {
        // Safari on this same simulator DOES render listings and paginates past 15.
        // Diagnose why the webview didn't: dump DOM shape under the mobile UA.
        emit("=== DIAGNOSTIC: mobile UA, long wait ===")
        webView.customUserAgent = Self.mobileUA
        await load("https://www.facebook.com/marketplace/sanfrancisco/search?query=desk")
        for wait in [5, 10, 20] {
            try? await Task.sleep(for: .seconds(wait == 5 ? 5 : 5))
            emit("t+\(wait)s: \(await js(Self.domShapeJS))")
        }
        emit("--- where do item IDs live on mobile? ---")
        emit("ids: \(await js(Self.idHuntJS))")
        emit("fiber: \(await js(Self.fiberHuntJS))")

        emit("--- deep ID hunt ---")
        emit("deep: \(await js(Self.deepIDHuntJS))")
        emit("--- synthetic click test ---")
        emit("click: \(await js(Self.clickTestJS))")
        try? await Task.sleep(for: .seconds(3))
        emit("url after click: \(await js("window.location.href"))")

        let uaMatrix: [(String, String?)] = [
            ("desktop-safari", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 Safari/605.1.15"),
        ]

        var bestUA: (String, String?)?
        var bestCount = 0
        var bestFirstID: String?

        for (name, ua) in uaMatrix {
            emit("=== UA: \(name) ===")
            await clearCookies()
            webView.customUserAgent = ua
            await load("https://www.facebook.com/marketplace/sanfrancisco/search?query=desk")
            try? await Task.sleep(for: .seconds(6))

            var lastCount = 0
            var firstID: String?
            for round in 0..<5 {
                let probe = await js(Self.probeAndScrollJS)
                emit("[\(name)] round \(round): \(probe)")
                if firstID == nil { firstID = extract(probe, key: "firstId") }
                lastCount = Int(extract(probe, key: "count") ?? "0") ?? 0
                try? await Task.sleep(for: .seconds(3))
            }
            emit("[\(name)] final count: \(lastCount)")
            if lastCount > bestCount {
                bestCount = lastCount
                bestUA = (name, ua)
                bestFirstID = firstID
            }
        }

        if let (name, ua) = bestUA {
            emit("=== DETAIL via \(name) (count \(bestCount)) ===")
            webView.customUserAgent = ua
            if let id = bestFirstID {
                await load("https://www.facebook.com/marketplace/item/\(id)")
                try? await Task.sleep(for: .seconds(6))
                emit("detail: \(await js(Self.detailProbeJS))")
            }
            emit("=== FILTERS via \(name) ===")
            await load("https://www.facebook.com/marketplace/sanfrancisco/search?query=desk&minPrice=100&radius=10")
            try? await Task.sleep(for: .seconds(6))
            emit("filtered: \(await js(Self.filterProbeJS))")
        } else {
            emit("no UA variant produced any listings")
        }

        emit("=== DONE ===")
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

    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1"

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
