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
        webView.customUserAgent = Self.mobileUA
        let variants = [
            ("no-radius", "https://www.facebook.com/marketplace/sanfrancisco/search/?query=anthurium"),
            ("with-radius", "https://www.facebook.com/marketplace/sanfrancisco/search/?query=anthurium&radius=10"),
        ]
        for (name, url) in variants {
            await load(url)
            try? await Task.sleep(for: .seconds(16))
            emit("[\(name)] \(await js(Self.cityCountJS))")
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
