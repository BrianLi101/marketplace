import Foundation

/// JavaScript for the desktop surface.
///
/// Desktop is a React app that ships the `MarketplaceSearch` GraphQL response
/// alongside its markup, so extraction here reads a *payload* rather than
/// scraping rendered text — which is what makes it worth the 15-result cap.
///
/// Written without backslashes wherever possible: these strings cross Swift and
/// JavaScript escaping, and a stray one has twice produced an opaque
/// "A JavaScript exception occurred" hiding an otherwise fine result. See
/// `tools/probe/README.md`.
enum DesktopScripts {

    /// Every card's payload object from a search page.
    ///
    /// Anchors on `"listing":{` inside the feed edges rather than searching for
    /// `creation_time` globally: item pages and the search page both contain
    /// payload objects belonging to *other* listings, and position in the
    /// document is not evidence of ownership.
    static let extractSearchPayload = """
    (function(){
      try {
        var html = document.documentElement.outerHTML;

        // The markup is JSON escaped inside attributes, so quotes arrive as
        // \\" and every pattern has to tolerate both forms. Normalising once is
        // far more reliable than escaping each pattern.
        var flat = html.split('\\\\"').join('"');

        // Slices past the *key* and then expects the colon, rather than
        // slicing past `"key":` and searching for one — the latter skips the
        // separator and then finds a colon inside the value, which returned
        // null for every field and made the whole extractor silently produce
        // zero listings against a page holding fifteen.
        // The colon must be adjacent, or a key appearing inside some other
        // string would match.
        // Reads a JSON string body starting at its opening quote, honouring
        // escapes. Scanning for the next bare quote instead would truncate any
        // value containing one -- and titles routinely do, because Facebook
        // stores dimensions as 10x7'9".
        function readString(s) {
          var out = '', i = 1;
          while (i < s.length) {
            var c = s.charAt(i);
            if (c === '\\\\') { out += c + s.charAt(i + 1); i += 2; continue; }
            if (c === '"') break;
            out += c;
            i++;
          }
          return out;
        }

        // These values are JSON string bodies, so they still carry \\uXXXX,
        // \\n and friends. Round-tripping through JSON.parse decodes the lot in
        // one step; without it a title renders literally as
        // "10x7\\u20199\\u201d Rug" instead of 10x7'9" Rug.
        function decode(s) {
          if (s === null || s === undefined) return null;
          try { return JSON.parse('"' + s + '"'); } catch (e) { return s; }
        }

        function field(block, key) {
          var needle = '"' + key + '"';
          var i = block.indexOf(needle);
          if (i === -1) return null;
          var rest = block.slice(i + needle.length);
          var colon = rest.indexOf(':');
          if (colon === -1 || colon > 3) return null;
          rest = rest.slice(colon + 1).replace(/^[ ]+/, '');
          if (rest.charAt(0) === '"') {
            return decode(readString(rest));
          }
          var stop = rest.search(/[,}\\]]/);
          var raw = (stop === -1 ? rest : rest.slice(0, stop)).trim();
          return raw.length ? raw : null;
        }

        function nested(block, container, key) {
          var i = block.indexOf('"' + container + '"');
          if (i === -1) return null;
          return field(block.slice(i, i + 600), key);
        }

        function deliveryTypes(block) {
          var i = block.indexOf('"delivery_types"');
          if (i === -1) return [];
          var open = block.indexOf('[', i);
          var close = block.indexOf(']', open);
          if (open === -1 || close === -1) return [];
          var inner = block.slice(open + 1, close);
          var out = [];
          inner.split(',').forEach(function(p){
            var t = p.replace(/["' ]/g, '').trim();
            if (t) out.push(t);
          });
          return out;
        }

        var out = [], from = 0, guard_ = 0;
        while (guard_++ < 200) {
          var start = flat.indexOf('"listing":{', from);
          if (start === -1) break;
          from = start + 11;
          // One card's object is comfortably inside this window; reading
          // further risks picking up the next card's fields.
          var block = flat.slice(start, start + 3000);

          var id = field(block, 'id');
          if (!id || !/^[0-9]{8,}$/.test(id)) continue;

          // `decode` already turned the JSON's escaped forward slashes back
          // into real ones, so the URI is usable as-is.
          var photo = nested(block, 'primary_listing_photo', 'uri');
          out.push({
            id: id,
            title: field(block, 'marketplace_listing_title'),
            creationTime: parseFloat(field(block, 'creation_time')) || null,
            priceAmount: nested(block, 'listing_price', 'amount'),
            priceFormatted: nested(block, 'listing_price', 'formatted_amount'),
            strikethroughFormatted: nested(block, 'strikethrough_price', 'formatted_amount'),
            photoURL: photo,
            photoID: nested(block, 'primary_listing_photo', 'id'),
            city: nested(block, 'reverse_geocode', 'city'),
            state: nested(block, 'reverse_geocode', 'state'),
            cityPageID: nested(block, 'city_page', 'id'),
            deliveryTypes: deliveryTypes(block),
            isSold: field(block, 'is_sold') === 'true',
            isLive: field(block, 'is_live') === 'true',
            categoryID: field(block, 'marketplace_listing_category_id'),
            createdWithSellerApp: field(block, 'created_with_seller_app') === 'true'
          });
        }

        // Cards rendered but absent from the payload — everything past the
        // first server-rendered page. Reported so callers can tell "no payload
        // for this card" from "extraction failed", which look identical
        // downstream and are not the same problem.
        var rendered = [], seen = {};
        var links = document.querySelectorAll('a[href*="/marketplace/item/"]');
        for (var i = 0; i < links.length; i++) {
          var h = links[i].getAttribute('href') || '';
          var k = h.indexOf('/marketplace/item/');
          if (k === -1) continue;
          var j = k + 18, rid = '';
          while (j < h.length) {
            var c = h.charAt(j);
            if (c >= '0' && c <= '9') { rid += c; j++; } else { break; }
          }
          if (rid.length > 7 && !seen[rid]) { seen[rid] = 1; rendered.push(rid); }
        }

        return JSON.stringify({
          listings: out,
          renderedIDs: rendered,
          renderedCount: rendered.length,
          payloadCount: out.length,
          loginWall: document.body.innerText.indexOf('You must log in') !== -1
        });
      } catch (e) {
        return JSON.stringify({ listings: [], renderedIDs: [], error: String(e.message) });
      }
    })()
    """

    /// Every rendered card, scraped from the DOM rather than the payload.
    ///
    /// This is the tail: past the first server-rendered page there is no payload
    /// at all, so cards 16-onward can only be read this way. Desktop makes that
    /// tolerable — its `aria-label` carries title, price, city and the listing
    /// id in one string:
    ///
    ///     "Black L-Shaped Corner Desk with Monitor Shelf, $40, San Francisco, CA, listing 1054280080442808"
    ///
    /// so a markup-only card still yields everything a grid needs except the
    /// exact timestamp and delivery types. Classification stays in Swift.
    ///
    /// Must be called repeatedly while scrolling, never once at the end: the
    /// desktop feed virtualises, recycling cards out of the DOM as they leave
    /// the viewport, so a single read at the bottom returns the last window
    /// rather than the feed.
    static let extractRenderedCards = """
    (function(){
      try {
        var out = [], seen = {};
        var links = document.querySelectorAll('a[href*="/marketplace/item/"]');
        for (var i = 0; i < links.length; i++) {
          var a = links[i];
          var h = a.getAttribute('href') || '';
          var k = h.indexOf('/marketplace/item/');
          if (k === -1) continue;
          var j = k + 18, id = '';
          while (j < h.length) {
            var c = h.charAt(j);
            if (c >= '0' && c <= '9') { id += c; j++; } else { break; }
          }
          if (id.length < 8 || seen[id]) continue;
          seen[id] = 1;

          var img = a.querySelector('img');
          var src = img ? (img.getAttribute('src') || '') : '';
          if (src.indexOf('scontent') === -1) src = '';

          out.push({
            id: id,
            label: a.getAttribute('aria-label') || '',
            imageURL: src,
            text: (a.innerText || '').slice(0, 140)
          });
        }
        return JSON.stringify({ cards: out, count: out.length });
      } catch (e) {
        return JSON.stringify({ cards: [], count: 0, error: String(e.message) });
      }
    })()
    """

    /// The desktop search page's **location pill**, the one under the filter
    /// row reading "San Francisco, California · Within 5 mi".
    ///
    /// Returns the strings only — `DesktopLocationPill` does the parsing in
    /// Swift, where it is readable and testable, as with every other extractor
    /// here.
    ///
    /// Two selectors, in order of how much they can be trusted. The
    /// `aria-label` is the real target: it is written for a screen reader, so
    /// it spells out `Location:` and `Within 5 mi` in full even when the visible
    /// pill has been abbreviated to fit. Rendered text is the fallback, for a
    /// layout or a locale where that label is absent.
    ///
    /// `candidates` is reported for the same reason the card probes report
    /// their sample: a pill parsed from the wrong element produces a perfectly
    /// plausible place name, and the count is what makes that visible
    /// (`docs/probe-checklist.md` §2).
    static let extractLocationPill = """
    (function(){
      function clean(s) { return (s || '').replace(/\\s+/g, ' ').trim(); }

      var labelled = document.querySelectorAll('[aria-label]');
      var candidates = [];
      var best = null, source = null;

      for (var i = 0; i < labelled.length; i++) {
        var label = clean(labelled[i].getAttribute('aria-label'));
        // "Location: San Francisco, California, Within 5 mi"
        if (/^Location\\b/i.test(label)) {
          candidates.push(label.slice(0, 80));
          if (!best) { best = label; source = 'aria-label'; }
        }
      }

      if (!best) {
        // Fall back to anything clickable whose text reads like a place and a
        // distance: "San Francisco, California · Within 5 mi", "Toronto · 5 mi".
        var buttons = document.querySelectorAll('[role="button"], button');
        for (var j = 0; j < buttons.length; j++) {
          var text = clean(buttons[j].innerText);
          if (text && text.length < 60 && /\\d+\\s*(mi|km)\\b/i.test(text)) {
            candidates.push(text.slice(0, 80));
            if (!best) { best = text; source = 'text'; }
          }
        }
      }

      return JSON.stringify({
        pill: best,
        source: source,
        candidates: candidates.slice(0, 4),
        href: location.href
      });
    })()
    """

    /// An item page's own fields, in the shape `RawDetail` already decodes.
    ///
    /// The discriminator is the whole design. Item pages carry ~20 other
    /// listings' payload objects in the "Today's picks" rail, and every field
    /// here is read from the object whose id matches the page's own — never the
    /// nearest match in the document.
    static func extractDetail(expectedID: String) -> String {
        """
        (function(){
          try {
            var html = document.documentElement.outerHTML;
            var flat = html.split('\\\\"').join('"');
            var body = document.body.innerText || '';

            function firstMatch(re) {
              var m = body.match(re);
              return m ? m[0] : null;
            }

            // The listing's own coordinates: the pair inside the object that
            // also carries its location text, not the first pair in the page.
            var lat = null, lng = null;
            var anchor = flat.indexOf('"location_text"');
            if (anchor !== -1) {
              var around = flat.slice(Math.max(0, anchor - 2500), anchor + 500);
              var lm = around.match(/"latitude":(-?[0-9]+[.][0-9]+)/);
              var gm = around.match(/"longitude":(-?[0-9]+[.][0-9]+)/);
              if (lm) lat = lm[1];
              if (gm) lng = gm[1];
            }

            // Only this listing's photos.
            //
            // Every image in the "Today's picks" rail sits inside an
            // `a[href*="/marketplace/item/"]` pointing at *another* listing,
            // while the listing's own gallery is not wrapped in an item link at
            // all. Measured on a sample page: 25 scontent images, 20 of them
            // inside such an anchor and belonging to other sellers, 5 outside
            // and carrying `alt="Product photo of <this title>"`.
            //
            // Taking them all is how a mirror's gallery ended up showing a tool
            // chest — the same neighbour-contamination trap as the coordinates
            // and the condition, in a new place.
            // The payload's own gallery, which is the reliable half.
            //
            // `listing_photos` appears exactly **once** per item page — against
            // twenty `primary_listing_photo` objects belonging to the picks
            // rail — so it needs no discriminator: it is the page's own listing
            // by construction, and it is the only photo source that does not
            // depend on anything having rendered.
            //
            // That independence is the point. A **sold** listing's page draws no
            // gallery at all at desktop width: measured on three sold item
            // pages at 1280px, zero `alt="Product photo of ..."` images against
            // three on the same pages at a narrower viewport, and against two
            // to three on any listing still for sale. The DOM scrape below
            // therefore returned nothing for exactly the listings the Seller
            // tab's sold strip opens, and the detail screen spent the full
            // eight-second photo timeout finding it out.
            var photos = [];
            var pk = flat.indexOf('"listing_photos"');
            if (pk !== -1) {
              // Bounded at the next typename boundary so this can't run on into
              // a neighbour's object if the array is ever absent or empty.
              var pblock = flat.slice(pk, pk + 20000);
              var pend = pblock.indexOf('"__isMarketplace');
              if (pend > 0) pblock = pblock.slice(0, pend);
              // Deliberately a plain capture with the unescaping done after,
              // rather than a regex that tries to match escaped slashes. The
              // payload writes URLs as `https:\\/\\/scontent...`, and matching
              // that shape through a Swift multiline string, a JS string and a
              // regex is three layers of backslash nobody should have to read.
              var pre = /"uri":"([^"]+)"/g, pm;
              while ((pm = pre.exec(pblock)) !== null) {
                var uri = pm[1].split('\\\\/').join('/');
                if (uri.indexOf('scontent') === -1) continue;
                if (photos.indexOf(uri) === -1) photos.push(uri);
              }
            }

            // Then the rendered gallery, for anything the payload didn't carry.
            //
            // Every image in the "Today's picks" rail sits inside an
            // `a[href*="/marketplace/item/"]` pointing at *another* listing,
            // while the listing's own gallery is not wrapped in an item link at
            // all. Measured on a sample page: 25 scontent images, 20 of them
            // inside such an anchor and belonging to other sellers, 5 outside
            // and carrying `alt="Product photo of <this title>"`.
            //
            // Taking them all is how a mirror's gallery ended up showing a tool
            // chest — the same neighbour-contamination trap as the coordinates
            // and the condition, in a new place.
            //
            // Deduped against the payload by the fbcdn filename's photo id, not
            // by URL: the same photo is served at several sizes with different
            // query strings, so a URL comparison would show it twice.
            function photoKey(u) {
              var f = u.split('?')[0].split('/').pop().split('.')[0].split('_');
              return f.length >= 2 ? f[1] : u;
            }
            var seenKeys = {};
            for (var pi = 0; pi < photos.length; pi++) seenKeys[photoKey(photos[pi])] = 1;

            var imgs = document.querySelectorAll('img[src*="scontent"]');
            for (var i = 0; i < imgs.length; i++) {
              var img = imgs[i];
              var src = img.getAttribute('src') || '';
              if (src.indexOf('rsrc.php') !== -1) continue;
              if (img.closest && img.closest('a[href*="/marketplace/item/"]')) continue;
              var key = photoKey(src);
              if (seenKeys[key]) continue;
              seenKeys[key] = 1;
              photos.push(src);
            }

            // Seller identity only exists for a signed-in session. The rating
            // renders as "(N)" beside star glyphs rather than "N ratings" --
            // matching the latter is how an earlier survey concluded, wrongly,
            // that ratings were unavailable everywhere.
            var sellerName = null, ratingCount = null, ratingScore = null, joined = null;
            var section = null;
            var candidates = document.querySelectorAll('div, span');
            for (var s = 0; s < candidates.length; s++) {
              var t = (candidates[s].innerText || '').trim();
              if (t.indexOf('Seller information') === 0 && t.length > 20 && t.length < 400) {
                section = t; break;
              }
            }
            if (section) {
              var lines = section.split(String.fromCharCode(10));
              for (var L = 0; L < lines.length; L++) {
                var line = lines[L].trim();
                if (!line || line === 'Seller information' || line === 'Seller details') continue;
                if (line.indexOf('Joined Facebook') === 0) { joined = line; continue; }
                if (line.indexOf('Highly rated') === 0) continue;
                var paren = line.match(/^[(]([0-9]+)[)]$/);
                if (paren) { ratingCount = paren[1]; continue; }
                if (!sellerName) sellerName = line;
              }
            }
            var starLabel = null;
            var labelled = document.querySelectorAll('[aria-label]');
            for (var a = 0; a < labelled.length && !starLabel; a++) {
              var lab = labelled[a].getAttribute('aria-label') || '';
              if (lab.indexOf('out of 5') !== -1) starLabel = lab;
            }
            if (starLabel) {
              var sm = starLabel.match(/([0-9]+([.][0-9]+)?) out of 5/);
              if (sm) ratingScore = sm[1];
            }

            // Description comes from the payload rather than rendered text,
            // because the rendered block is unlabelled on this surface and
            // sits adjacent to the Today's-picks rail. `redacted_description`
            // is the listing's own, and it is the field the own-listing
            // discriminator (`location_text` alongside it) identifies.
            // Same JSON-escape handling as the search payload: read the string
            // body honouring escapes, then decode it in one pass. Matching a
            // bare-quote pattern here would both truncate at the first
            // apostrophe-as-escape and leave \\uXXXX sequences rendering
            // literally in the description.
            var description = null;
            var dk = flat.indexOf('"redacted_description"');
            if (dk !== -1) {
              var dblock = flat.slice(dk, dk + 6000);
              var tk = dblock.indexOf('"text"');
              if (tk !== -1) {
                var after = dblock.slice(tk + 6);
                var dcolon = after.indexOf(':');
                if (dcolon !== -1 && dcolon <= 3) {
                  var body = after.slice(dcolon + 1).replace(/^[ ]+/, '');
                  if (body.charAt(0) === '"') {
                    var raw = '', di = 1;
                    while (di < body.length) {
                      var dc = body.charAt(di);
                      if (dc === '\\\\') { raw += dc + body.charAt(di + 1); di += 2; continue; }
                      if (dc === '"') break;
                      raw += dc;
                      di++;
                    }
                    try { description = JSON.parse('"' + raw + '"'); }
                    catch (e) { description = raw; }
                  }
                }
              }
            }

            // Sold and pending, from the listing's own object.
            //
            // Anchored on `"location_text"` — the same discriminator the
            // coordinates above use, and for the same reason. A sold item page
            // carries twenty-one `is_sold` values: one true for this listing
            // and twenty false ones belonging to the picks rail. Counting
            // occurrences, or taking the first, would report a neighbour's
            // availability as this listing's. Verified both ways: the anchor
            // returns exactly one value, `true` on a sold page and `false` on a
            // listing still for sale.
            var isSold = null, isPending = null;
            if (anchor !== -1) {
              var avail = flat.slice(Math.max(0, anchor - 4000), anchor + 4000);
              var sm2 = avail.match(/"is_sold":(true|false)/);
              var pm2 = avail.match(/"is_pending":(true|false)/);
              if (sm2) isSold = sm2[1] === 'true';
              if (pm2) isPending = pm2[1] === 'true';
            }

            // "Condition" and its value render as adjacent lines in Details.
            var conditionText = null;
            var cm = body.match(/Condition[^]{0,3}(New|Used - Like New|Used - Good|Used - Fair)/i);
            if (cm) conditionText = cm[1];

            var pathID = null;
            var path = location.pathname;
            var pk = path.indexOf('/marketplace/item/');
            if (pk !== -1) {
              var pj = pk + 18, pid = '';
              while (pj < path.length) {
                var pc = path.charAt(pj);
                if (pc >= '0' && pc <= '9') { pid += pc; pj++; } else { break; }
              }
              pathID = pid.length ? pid : null;
            }

            return JSON.stringify({
              itemId: pathID,
              expected: '\(expectedID)',
              sellerName: sellerName,
              sellerJoined: joined,
              sellerRatingText: ratingScore,
              sellerRatingCount: ratingCount,
              description: description,
              photoURLs: photos,
              postedText: firstMatch(/Listed [^]{0,40}/),
              conditionText: conditionText,
              locationText: firstMatch(/[A-Z][A-Za-z .'-]+, [A-Z]{2}/),
              latitude: lat,
              longitude: lng,
              isSold: isSold,
              isPending: isPending,
              profileLinks: document.querySelectorAll('a[href*="/marketplace/profile/"]').length,
              loginWall: body.indexOf('You must log in') !== -1
            });
          } catch (e) {
            return JSON.stringify({ error: String(e.message), photoURLs: [], isSold: null, isPending: null, loginWall: false });
          }
        })()
        """
    }
}
