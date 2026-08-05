# The GraphQL payload is already in the page

**Date:** 2026-08-05
**Method:** desktop pages inspected in a browser; both surfaces measured from a
`WKWebView` (`tools/probe`, `runPayloadTests`)
**Related:** `filter-parameters.md`, `surface-strategy.md`, `data-model.md`

The question was whether Facebook exposes a GraphQL API we could call for exact
posting times and better filtering. The useful answer turned out to be that we
don't need to call anything: **the desktop surface embeds the `MarketplaceSearch`
GraphQL response verbatim in the HTML it already serves us**, one structured
`listing` object per card.

The mobile surface embeds none of it.

---

## 1. Why not the API itself

| Route | Status |
|---|---|
| Public Marketplace API | Does not exist, and never has. Meta's incentive runs the other way — the whole product depends on keeping buyers and sellers inside Facebook. |
| Commerce Platform API | Limited alpha, approved *seller* partners only. Built for managing your own inventory, not for reading other people's listings. |
| Meta Content Library API | Real, and it does expose Marketplace listings with `SINCE`/`UNTIL` date filtering — but access is for approved researchers, running inside a Secure Research Environment or third-party cleanroom. Not a thing a consumer iOS app can ship against. |
| Internal `/api/graphql/` | Reachable, but each query needs a `doc_id` (a precompiled-query hash that rotates every few weeks) plus a session-bound `fb_dtsg` CSRF token, and logged-out calls get bounced to a login wall. Reported rate limits are ~30–60 requests/hour/IP. |

The internal endpoint is the only one that would work in principle, and it is a
maintenance treadmill: a rotating `doc_id` means the app breaks on Facebook's
schedule rather than ours. It is also a considerably more aggressive posture
than loading pages — this app's whole premise is that it browses the public site
the way a logged-out visitor does.

Reading the payload out of the page we already load gets the same fields with
none of that.

## 2. What each card carries

The desktop search page holds one of these per rendered card, inside
`MarketplaceSearchFeedStoriesEdge` → `node.listing`:

```json
{
  "id": "1054280080442808",
  "primary_listing_photo": { "image": {"uri": "https://scontent-…"},
                             "id": "928285686952534" },
  "creation_time": 1784161765,
  "listing_price": { "formatted_amount": "$40", "amount": "40.00" },
  "strikethrough_price": null,
  "location": { "reverse_geocode": {
      "city": "San Francisco", "state": "CA",
      "city_page": { "display_name": "San Francisco, California",
                     "id": "114952118516947" } } },
  "is_hidden": false, "is_live": true, "is_pending": false, "is_sold": false,
  "marketplace_listing_category_id": "1583634935226685",
  "marketplace_listing_title": "Black L-Shaped Corner Desk with Monitor Shelf",
  "created_with_seller_app": false,
  "marketplace_listing_seller": null,
  "delivery_types": ["IN_PERSON"]
}
```

Counted rather than sampled, on a 15-card page: `creation_time` ×15,
`marketplace_listing_title` ×15, `delivery_types` ×15, `is_sold` ×15,
`primary_listing_photo` ×15, `strikethrough_price` ×15,
`marketplace_listing_seller` ×15, `MarketplaceSearchFeedStoriesEdge` ×15. One
per card, no gaps.

Five of these are things the app currently does without, or works to derive:

- **`creation_time` is an exact unix timestamp.** This is the field that makes
  recency sorting possible at all. Cards render no date, and item pages only say
  "Listed 2 weeks ago" — the payload for that same listing says 20.3 days.
- **`primary_listing_photo.id` is the photo FBID** the app already parses out of
  the fbcdn filename to use as `Listing.id`. Here it is as a field, which
  removes the `h:<title>|<price>` fallback and its collision risk.
- **`delivery_types` is the local-vs-shipping signal**, structured. See §4.
- **`city_page.id` is a place id**, free with every card — the open question in
  `mobile-location-radius-notes.md` §8 about cities with no vanity slug.
- **`is_sold` / `is_live` / `is_pending`** give a sold check for saved listings.

**No coordinates.** `latitude` appears 6 times on a 15-card page, so it is not
per-card; the finest location a card carries is still its city. Per-listing
coordinates remain item-page-only.

## 3. Verification

The rule from `probe-checklist.md` §6 applies with force here, because item
pages carry ~20 *other* listings' `creation_time` values in their "Today's
picks" rail — the same trap that made the coordinate extractor read a
neighbour's location. A timestamp found in the markup is not automatically this
listing's.

Two checks:

1. **Structural, on item pages.** The listing's own `creation_time` is the one
   followed by `location_text`; the picks' are followed by
   `primary_listing_photo`. On a sample item page that discriminator matched
   **exactly once** against 20 picks, and the value it returned (27.3 hours)
   agreed with the page's own "Listed a day ago".
2. **Cross-surface, on search pages.** Card `1054280080442808` carried
   `creation_time: 1784161765` in the search payload. Opening that listing's own
   item page and reading its own timestamp gave **the same value**, against a
   rendered "Listed 2 weeks ago".

So the search payload's per-card timestamps are the listings' real creation
times, not an artefact of proximity in the markup.

## 4. `delivery_types`, measured both ways

| Page | Values seen |
|---|---|
| default search (15 cards) | `IN_PERSON`, `IN_PERSON,DOOR_PICKUP`, `IN_PERSON,PUBLIC_MEETUP` — no shipping token anywhere |
| `deliveryMethod=shipping` (24 cards) | `SHIPPING_ONSITE` in **24 of 24**, alone on 5 and combined with local options on 19 |

`SHIPPING_ONSITE` is therefore the reliable marker, and it is finer than the
"card has no city line" heuristic in `mobile-location-radius-notes.md` §4: it
separates *ships only* (5 cards) from *ships or collect in person* (19), which
are different things for a local-browsing app.

`created_with_seller_app` is also per-card and is a plausible business /
drop-shipper signal, but every card on the pages measured was `false`, so it is
untested as a discriminator.

## 5. The catch: mobile has none of it

Both mobile pages, measured from the same `WKWebView` that produced the desktop
numbers above:

| | mobile search | mobile item | desktop search |
|---|---|---|---|
| rendered listing photos | 26 | 20 | 15 |
| `creation_time` | **0** | **0** | 15 |
| `marketplace_listing_title` | **0** | **0** | 15 |
| `delivery_types` | **0** | **0** | 15 |
| `is_sold` | **0** | **0** | 15 |
| `MarketplaceSearchFeedStoriesEdge` | **0** | **0** | 15 |

Zero occurrences of every key, on a page rendering 26 listings. The desktop
column is the positive control from the same run — the probe works, and the
mobile result is a real absence rather than a selector problem.

This is consistent with what WebLite is: a server-driven UI that ships rendered
components, not a React app rehydrating from a GraphQL response. It also
explains the earlier finding that mobile item pages have no embedded JSON to
fall back on for condition.

## 5a. Why the payload is absent, and how far that's actually established

The short version: **the two surfaces put the renderer in different places, and
the payload is only needed where the renderer is.**

Desktop is a React app that re-renders from data on the client — clicking a
filter rewrites the result grid via `history.pushState` with no page load, which
is only possible if the client holds the data that produced the grid. So the
GraphQL response ships alongside the markup. That is what the 124 script tags
and 68 KB per listing are.

WebLite is the opposite arrangement: the server runs the query, binds the
results into a component tree, renders it, and ships only the rendered output.
The client is a thin runtime that displays components and posts an action token
back when one is tapped. It never re-renders from data because it never holds
data.

Measured support, rather than inference:

| | mobile | desktop |
|---|---|---|
| bytes of HTML per rendered listing | ~7,000 | ~68,000 |
| `<script>` tags | 25 | 124 |

And the decisive tell is not the size but the **missing identifiers**. Mobile
carries no listing id anywhere — checked previously against every pattern the
desktop surface uses, including React internals. A payload merely trimmed for
bandwidth would keep ids; they are 16 bytes and nearly everything depends on
them. Their total absence is the signature of a client that was never meant to
reason about listings at all, which is exactly why card taps are opaque
`data-action-id` tokens the server resolves.

So the absence looks like an architectural consequence rather than an
anti-scraping measure. WebLite exists to serve low-bandwidth devices, and a 10×
reduction per listing is the point of it. The scraping-resistance is a side
effect.

**Caveat on this section:** the architecture description is an inference from
observed behaviour, not from anything Meta documents. The measurements above are
real; the causal story is the most economical explanation of them.

## 5b. Unresolved: what transport pagination uses

Worth recording as a genuine dead end rather than quietly dropping.

Scrolling the mobile feed paginates 26 → 50 → 74 listings, growing the markup
from 181 KB to 297 KB. Three things were established about that new content:

- It is **not preloaded.** Snapshotting the initial markup and searching it for
  the later listings found 0 of 48 photo ids and 4 of 48 titles (those four
  being short generic strings like "Black small desk"). Positive control: 26 of
  26 photo ids and 25 of 26 titles for the *first* batch were found.
- It carries **no payload keys** — `creation_time` stays at 0 across all
  297 KB.
- It arrives over the network, yet **neither instrument can see the request.**
  A `fetch`/`XMLHttpRequest` recorder injected at `.atDocumentStart` — before
  any page script runs — captured **0 requests**. Resource Timing, which records
  requests whatever API issued them, shows 83 entries: 75 images, 4 CSS, and 4
  `/ajax/weblite_*_logging/` telemetry beacons of ~380 bytes each. No content
  request in either.

Something is either clearing the Resource Timing buffer (WebLite demonstrably
harvests it — `weblite_resources_timing_logging` is one of the four beacons) or
using a transport neither instrument observes. Not chased further because it
does not change any decision: whatever the transport, the bytes arriving on
mobile contain none of the structured data.

## 6. What this changes

The surface trade-off in `filter-parameters.md` §5 stands, but the desktop side
is worth much more than it looked:

- Desktop: 15–24 results, no pagination — but every one **fully structured**,
  with an exact timestamp, a numeric price, delivery types, sold state, a place
  id, and the photo id.
- Mobile: paginates indefinitely and carries seller identity — but everything
  must be scraped from rendered text, and there is no date at any depth.

For the plan of filtering by location and then sorting ourselves, the desktop
payload is the enrichment source, and it removes the blocker recorded in the
README's to-do list: sorting by recency no longer needs an item-page fetch per
listing, because the search response already dates every card.

## 7. Open questions

- Does the payload survive on the desktop *category browse* path, or only on
  search?
- `marketplace_listing_seller` is present as a key on every card but was `null`
  throughout. When is it populated? If it ever carries a seller id, the
  duplicate-coordinates business heuristic in `data-model.md` gets much cheaper.
- Is there a `cursor` that would paginate the desktop payload? The edges carry
  `"cursor": null` logged out, which is consistent with the observed hard cap.
- Does `created_with_seller_app` ever come back `true`, and does it correlate
  with the drop-shipper listings we want to filter?
- What transport does mobile pagination actually use (§5b)? Answering it would
  need a proxy or `WKURLSchemeHandler`-level interception rather than anything
  reachable from inside the page.
