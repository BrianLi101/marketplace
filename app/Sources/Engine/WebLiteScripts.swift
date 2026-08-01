import Foundation

/// JavaScript injected into the results and detail pages.
///
/// Facebook's mobile surface is WebLite — a server-driven UI where cards are
/// `data-mcomponent` containers keyed by an opaque `data-action-id`. There are
/// no listing anchors and no ids anywhere in the DOM, so:
///   • cards are found structurally (a container holding an fbcdn image and an h3),
///   • the scripts return *raw* text runs and let Swift classify them (§6 keeps
///     interpretation testable outside a webview),
///   • the canonical item URL is resolved by clicking a card and catching the
///     navigation, which the feed cancels (see FeedEngine).
enum WebLiteScripts {

    /// Shared card-finding logic. Innermost container that holds both an image
    /// and a text block is the card; anything that contains another such
    /// container is a grid, not a card.
    /// Card markup differs between surfaces — search results wrap text in `h3`,
    /// category pages don't — so the only reliable signal is structural: an
    /// actionable container holding a listing photo, innermost first.
    private static let cardFinder = """
    function __mpCards() {
      var all = Array.prototype.slice.call(document.querySelectorAll('div[data-action-id]'));
      var candidates = all.filter(function(el){
        var img = el.querySelector('img');
        return img && (img.getAttribute('src') || '').indexOf('fbcdn') !== -1;
      });
      return candidates.filter(function(el){
        return !candidates.some(function(other){ return other !== el && el.contains(other); });
      });
    }
    function __mpTexts(el) {
      var out = [], walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), n;
      while ((n = walker.nextNode())) {
        var t = (n.textContent || '').trim();
        if (t) out.push(t);
      }
      return out;
    }
    """

    /// Returns every card on the page as raw fields. Classification happens in Swift.
    static var extract: String {
        """
        (function(){
          \(cardFinder)
          var cards = __mpCards();
          var out = [];
          for (var i = 0; i < cards.length; i++) {
            var el = cards[i];
            var img = el.querySelector('img');
            var texts = __mpTexts(el);
            var full = (el.innerText || '').trim();
            out.push({
              index: i,
              actionId: el.getAttribute('data-action-id'),
              imageURL: img ? img.getAttribute('src') : null,
              texts: texts,
              fullText: full.slice(0, 300)
            });
          }
          return JSON.stringify({
            cards: out,
            docHeight: document.body.scrollHeight,
            loginWall: /you must log in|log into facebook to continue/i.test(document.body.innerText || ''),
            url: window.location.href
          });
        })()
        """
    }

    /// Taps the card at `index`. The resulting navigation carries the item id;
    /// the feed's navigation delegate captures and cancels it.
    ///
    /// WebLite binds its handlers differently across surfaces — a synthetic
    /// mouse sequence navigates on search results but does nothing on category
    /// pages — and the binding is server-driven, so it can change without
    /// notice. Rather than depend on one gesture, send touch, mouse, and a
    /// native `click()`: the first one the page listens for wins, and the
    /// others are inert. Callers must still tolerate no navigation at all.
    static func click(index: Int) -> String {
        """
        (function(){
          \(cardFinder)
          var cards = __mpCards();
          var el = cards[\(index)];
          if (!el) return 'missing';
          var r = el.getBoundingClientRect();
          var cx = r.left + r.width / 2, cy = r.top + r.height / 2;

          function touch() {
            return new Touch({identifier: 1, target: el, clientX: cx, clientY: cy,
                              pageX: cx, pageY: cy, radiusX: 11, radiusY: 11, force: 1});
          }
          try {
            el.dispatchEvent(new TouchEvent('touchstart', {bubbles:true, cancelable:true, composed:true,
              touches:[touch()], targetTouches:[touch()], changedTouches:[touch()]}));
            el.dispatchEvent(new TouchEvent('touchend', {bubbles:true, cancelable:true, composed:true,
              touches:[], targetTouches:[], changedTouches:[touch()]}));
          } catch (e) {}

          var mouseOpts = {bubbles:true, cancelable:true, composed:true, clientX:cx, clientY:cy};
          ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){
            try { el.dispatchEvent(new MouseEvent(t, mouseOpts)); } catch(e) {}
          });

          try { if (typeof el.click === 'function') el.click(); } catch (e) {}
          return 'tapped';
        })()
        """
    }

    static let pageMetrics = """
    (function(){
      return JSON.stringify({
        docHeight: document.body.scrollHeight,
        scrollY: Math.round(window.scrollY)
      });
    })()
    """

    /// Detail pages are ordinary documents and much richer than the cards.
    static let extractDetail = """
    (function(){
      var text = document.body.innerText || '';
      function after(label) {
        var re = new RegExp(label + "\\\\s*\\\\n+([^\\\\n]{1,120})", 'i');
        var m = text.match(re);
        return m ? m[1].trim() : null;
      }
      var photos = [];
      var imgs = document.querySelectorAll('img');
      for (var i = 0; i < imgs.length; i++) {
        var s = imgs[i].getAttribute('src') || '';
        if (s.indexOf('fbcdn') !== -1 && s.indexOf('/p32x32/') === -1 && photos.indexOf(s) === -1) photos.push(s);
      }
      var listed = (text.match(/Listed\\s+[^\\n]{1,40}/i) || [])[0] || null;
      // Description: the longest paragraph that isn't chrome.
      var blocks = text.split(/\\n{2,}/).map(function(b){ return b.trim(); })
        .filter(function(b){ return b.length > 40 && !/^(Log In|Marketplace|Related searches|Today's picks)/i.test(b); });
      blocks.sort(function(a,b){ return b.length - a.length; });
      return JSON.stringify({
        description: blocks[0] || null,
        photoURLs: photos.slice(0, 12),
        postedText: listed,
        conditionText: after('Condition'),
        locationText: (text.match(/[A-Z][A-Za-z .'-]+,\\s*[A-Z]{2}/) || [])[0] || null,
        loginWall: /you must log in|log into facebook to continue/i.test(text),
        title: document.title
      });
    })()
    """
}
