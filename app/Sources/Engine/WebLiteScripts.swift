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
    // Listing photos are served from scontent-*.xx.fbcdn.net. Facebook's own
    // chrome (the wordmark, icons) is on static.xx.fbcdn.net/rsrc.php, so
    // matching "fbcdn" alone picks up the header logo and lets a card grow
    // outward until it swallows its neighbour.
    function __mpIsListingPhoto(img) {
      var src = img.getAttribute('src') || '';
      return src.indexOf('scontent') !== -1 && src.indexOf('rsrc.php') === -1;
    }
    function __mpListingImages(el) {
      var imgs = el.querySelectorAll('img'), n = 0;
      for (var i = 0; i < imgs.length; i++) {
        if (__mpIsListingPhoto(imgs[i])) n++;
      }
      return n;
    }
    // Containment is the wrong model for this markup: a listing's photo and its
    // text can live in sibling subtrees, so no single ancestor holds one whole
    // card without also holding the next. Document order is reliable instead —
    // every text node between one listing photo and the next belongs to that
    // listing. This walks the page once and buckets accordingly.
    function __mpCards() {
      var walker = document.createTreeWalker(
        document.body,
        NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT,
        null
      );
      var cards = [], current = null, node;
      while ((node = walker.nextNode())) {
        if (node.nodeType === 1 && node.tagName === 'IMG' && __mpIsListingPhoto(node)) {
          var action = node.closest ? node.closest('[data-action-id]') : null;
          current = {
            element: action || node.parentElement,
            imageURL: node.getAttribute('src'),
            actionId: action ? action.getAttribute('data-action-id') : null,
            texts: []
          };
          cards.push(current);
        } else if (node.nodeType === 3 && current) {
          var t = (node.textContent || '').trim();
          // Guard against the page furniture that trails the final card.
          if (t && t.length < 120) current.texts.push(t);
        }
      }
      return cards;
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
            var card = cards[i];
            out.push({
              index: i,
              actionId: card.actionId,
              imageURL: card.imageURL,
              texts: card.texts,
              fullText: card.texts.join(' | ').slice(0, 300)
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
          var el = cards[\(index)] ? cards[\(index)].element : null;
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
        // Detail pages phrase this as "Listed 3 days ago in Berkeley, CA";
        // keep only the place itself so it can be geocoded and shown plainly.
        locationText: (function(){
          var m = text.match(/[A-Z][A-Za-z .'-]+,\\s*[A-Z]{2}/);
          if (!m) return null;
          return m[0].replace(/^.*?\\bin\\s+/i, '').trim();
        })(),
        loginWall: /you must log in|log into facebook to continue/i.test(text),
        title: document.title
      });
    })()
    """
}
