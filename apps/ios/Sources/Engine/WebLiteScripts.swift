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
    /// A TreeWalker over SHOW_TEXT visits the contents of <script> and <style>
    /// too, which is how a page's JavaScript ended up rendered as a listing
    /// description. Everything that reads text nodes must go through this.
    private static let textGuard = """
    function __mpTextOf(node) {
      var parent = node.parentElement;
      if (!parent) return null;
      var tag = parent.tagName;
      if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE') return null;
      var t = (node.textContent || '').trim();
      return t || null;
    }
    """

    private static let cardFinder = """
    \(textGuard)
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
    // Every search card labels itself with far more than it renders:
    //   "Desk for sale - Used - Good - $75 in Oakland, CA"
    //   "Free Computer desk for sale - Used - Like New in El Sobrante, CA"
    // The label carries the *untruncated* title, the condition and the city,
    // none of which reach the rendered text on every layout. Read it off the
    // listing's own image rather than searching the container: a
    // `querySelector('[aria-label]')` can cross into a neighbouring card, and
    // the photo is unambiguously this listing's.
    function __mpCardLabel(img, action) {
      var alt = img.getAttribute('alt');
      if (alt && alt.length > 12) return alt;
      if (action) {
        var own = action.getAttribute('aria-label');
        if (own && own.length > 12) return own;
      }
      return null;
    }
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
            label: __mpCardLabel(node, action),
            texts: []
          };
          cards.push(current);
        } else if (node.nodeType === 3 && current) {
          var t = __mpTextOf(node);
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
              label: card.label,
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

    /// Detail pages are ordinary documents and much richer than the cards — but
    /// they also carry "Related searches" and "Today's picks" modules holding
    /// *other people's* listings. Everything below is scoped to stop at the
    /// first of those markers, so neither the photo strip nor the description
    /// can pick up a neighbouring listing's content.
    static var extractDetail: String {
        """
    (function(){
      \(textGuard)
      var STOP = /^(Related searches|Today's picks|Similar listings|More like this|Suggested|You may also like|See all|Sponsored)/i;

      // Walk in document order, gathering this listing's own gallery, and stop
      // dead at the first related-content heading.
      var photos = [], seenPhotoIDs = {};
      var walker = document.createTreeWalker(document.body,
        NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, null);
      var node, mainText = '';
      while ((node = walker.nextNode())) {
        if (node.nodeType === 3) {
          var t = __mpTextOf(node);
          if (!t) continue;
          if (STOP.test(t)) break;
          mainText += t + '\\n';
        } else if (node.tagName === 'IMG') {
          var src = node.getAttribute('src') || '';
          if (src.indexOf('scontent') === -1 || src.indexOf('rsrc.php') !== -1) continue;
          // Same photo appears at several sizes; key on the fbcdn photo id.
          var parts = src.split('/').pop().split('_');
          var key = parts.length > 1 ? parts[1] : src;
          if (seenPhotoIDs[key]) continue;
          seenPhotoIDs[key] = 1;
          photos.push(src);
        }
      }

      function after(label) {
        var re = new RegExp(label + "\\\\s*\\\\n+([^\\\\n]{1,120})", 'i');
        var m = mainText.match(re);
        return m ? m[1].trim() : null;
      }

      var listed = (mainText.match(/Listed\\s+[^\\n]{1,40}/i) || [])[0] || null;
      if (listed) listed = listed.replace(/\\s+in\\s+[A-Z][A-Za-z .'-]*(,\\s*[A-Z]{2})?\\s*$/, '').trim();

      // Description. Some pages label it, most don't — the seller's text just
      // follows the condition — so fall back to picking the longest line that
      // isn't the title, the price, a date, a place, or a piece of chrome.
      // Login prompts are prose, not chrome words, so the exact-match CHROME
      // list below never caught them — and being long sentences they won the
      // "longest line" fallback outright. A QR sign-in modal once rendered as
      // a listing's description. Matched as substrings, not whole lines.
      var LOGIN_NOISE = /scan the qr code|codes match|log ?in to facebook|log into facebook|you must log ?in|create new account|forgot password|continue with (google|apple|facebook)|keep me signed in|buy and sell in your community|browse or sell items|marketplace is a convenient/i;

      var description = after('Description');
      if (description && LOGIN_NOISE.test(description)) description = null;
      if (!description) {
        var CHROME = /^(Message|Save|Share|Details|Condition|Alert|More|See all|Log ?In|Sign ?Up|Marketplace|Home|Buying|Selling|Notifications|Inbox|Create new listing|Categories|Filters|Sort|Seller information|Send seller a message|Is this still available\\?)$/i;
        var pageTitle = document.title || '';
        var best = null;
        mainText.split('\\n').forEach(function(line){
          var t = line.trim();
          if (t.length < 15) return;
          if (CHROME.test(t)) return;
          if (LOGIN_NOISE.test(t)) return;                         // sign-in modal prose
          if (/^Listed\\b/i.test(t)) return;                       // "Listed 3 weeks ago…"
          if (/Location is approximate/i.test(t)) return;
          if (/^[A-Z][A-Za-z .'-]+,\\s*[A-Z]{2}$/.test(t)) return;  // a bare "Berkeley, CA"
          if (/^[$£€¥₹]/.test(t)) return;                          // price runs
          if (pageTitle.indexOf(t) !== -1) return;                 // the listing title
          if (!best || t.length > best.length) best = t;
        });
        description = best;
      }
      if (description) description = description.slice(0, 1500);

      var _p = location.pathname, _i = _p.indexOf('/item/');
      return JSON.stringify({
        itemId: _i === -1 ? null : _p.slice(_i + 6).split('/')[0],
        description: description || null,
        photoURLs: photos.slice(0, 12),
        postedText: listed,
        conditionText: after('Condition'),
        // Detail pages phrase this as "Listed 3 days ago in Berkeley, CA";
        // keep only the place itself so it can be geocoded and shown plainly.
        locationText: (function(){
          var m = mainText.match(/[A-Z][A-Za-z .'-]+,\\s*[A-Z]{2}/);
          if (!m) return null;
          return m[0].replace(/^.*?\\bin\\s+/i, '').trim();
        })(),
        // A sign-in modal often overlays a page whose real content is still in
        // the DOM behind it, so a login prompt alone isn't a wall — it's only a
        // wall if it also cost us the content. Reporting it otherwise would
        // throw away a listing we successfully read and trip the backoff.
        loginWall: LOGIN_NOISE.test(document.body.innerText || '')
                   && !description && photos.length === 0,
        title: document.title
      });
    })()
    """
    }
}
