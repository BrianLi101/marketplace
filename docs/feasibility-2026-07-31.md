# §9 Feasibility Findings — 2026-07-31

Method: clean logged-out desktop browser profile (no Facebook cookies), plus
curl with mobile Safari UA. **Caveat: desktop viewport + desktop Chrome UA.**
Mobile-UA behavior (what a WKWebView in the app would actually get) is NOT yet
tested — see "Open" below.

## Answers to §9

| # | Question | Answer |
|---|---|---|
| 9.1 | Depth before wall | **15 listings per search query, hard stop.** ~24 for category browse pages. No CAPTCHA, no hard wall — the page simply never loads more. A dismissible "See more on Facebook" login modal appears on load and re-appears on scroll. |
| 9.2 | Pagination logged out | **No.** Scrolling past the first batch loads nothing. Infinite scroll is login-gated. |
| 9.3 | Detail pages | **Yes, nearly complete.** Title, price, condition, full description, dimensions, "Listed 5 weeks ago", approximate location, photos all render. **Seller name/info is login-gated.** Detail pages embed a "Today's picks" related-listings module — extractor must scope to the listing container or it will ingest junk cards. |
| 9.4 | Filter params | **Yes.** `query`, `minPrice`, `radius` all applied logged out (verified: all 15 results ≥ $100 with `minPrice=100`). **`radius` is in kilometers** — `radius=10` renders as "6 mi". |
| 9.5 | Inventory parity | Untested — requires a logged-in comparison (Brian). Largely moot given the 15-cap: logged out is a slice, not a mirror. |
| 9.6 | Across metros | Consistent: SF and Austin both behave identically (15-listing cap, same layout). |
| 9.7 | Data in initial HTML | **Yes, for real browser navigations.** Listing data (titles, prices) is embedded as JSON in script tags of the navigated document. JSON-first extraction from inside the webview is viable. BUT the same URL fetched via `fetch()` from the same origin *with the same cookies* returns a 583KB JS shell with zero listing data — Facebook gates the data payload on top-level document navigation. |
| 9.8 | Plain URLSession | **No.** Mobile-Safari-UA curl gets "This browser isn't supported" (bare headers) or a logo splash shell (full headers). Even in-browser `fetch()` with a valid session's cookies gets a dataless shell (see 9.7). Data delivery requires a real browser navigation. **WKWebView is the transport; drop the §9.8 direct-fetch branch.** |

## Other observations

- Card text concatenates strikethrough prices: `"$25$40Dimond bikeSan Marcos, TX"`.
  Price extraction must handle two adjacent currency tokens (current price
  first, original second) and "Free".
- The login modal is a plain dismissible overlay; listings are fully rendered
  behind it. The app's extractor doesn't need to dismiss it — data is in the
  DOM/JSON regardless — but its presence/absence is a useful login-wall signal.
- ~8 rapid navigations in one session drew no rate-limiting.

## The existential question (§9.1 criterion)

The spec says: "If it's ~20, the product doesn't exist in this form."
**Measured: 15.** As specced — infinite-scroll grid over deep inventory — the
logged-out thesis fails on desktop web.

## Addendum: WKWebView spike on iOS Simulator (same day)

Ran the real transport — `WKWebView`, `nonPersistent()` store, iPhone 17 Pro
simulator (`spike/` in this repo). UA matrix, cookies cleared between runs,
same search URL, 5 scroll rounds each:

| UA | Result |
|---|---|
| Stock WKWebView (`Mobile/15E148`, no Safari token) | **0 listings.** Skeleton cards that never fill, "Open app" push. Detail URLs redirect to the Marketplace landing page. |
| Full mobile Safari UA (`Version/18.7 … Safari/604.1`) | **0 listings.** Identical shell. |
| Desktop Safari UA | **15 listings** — identical behavior to the desktop-browser test: same first item ID, complete detail page (description, condition, listed-ago, JSON in script tags), filters apply (`minPrice` honored, `radius` in km), login modal present but dismissable-irrelevant (data is in the DOM regardless). No pagination past 15. |

### CORRECTION — the mobile result above was a selector artifact

The "0 listings on mobile UA" reading was **wrong**, and the conclusion drawn
from it was wrong. Mobile web renders listings in the WKWebView perfectly well
(27 images, 26 prices, titles and locations all present). The extractor counted
zero because **the mobile site has no `<a href="/marketplace/item/{id}">`
anchors at all** — 4 anchors on the entire page. The spec's "most stable
selector available" (§2.2) does not exist in the mobile DOM.

**And mobile paginates.** Under real touch swipes (programmatic
`scrollTo` does *not* trigger it — this matters for §3.1 infinite scroll):

```
listings:  26 → 50 → 74 → 99 …    docHeight: 4219 → 7471 → 10724 → 13976
```

Batches of ~24-25, no cap encountered. **§9.1 and §9.2 are answered YES on
mobile** — deep browsing and pagination both survive logged out. The 15-listing
ceiling is a *desktop-web* artifact only.

### What the mobile page actually is

Not React. It's Facebook's **WebLite** server-driven UI (`WebLiteBootloader`,
`data-mcomponent`, `data-action-id`, `data-screen-id`). Consequences:

- No React fiber props to read (`internalKeys: []`, zero React elements found).
- **Listing IDs appear nowhere in the DOM** — not in HTML, script tags,
  or any `data-*` attribute. Taps are server-driven actions keyed by opaque
  `data-action-id`.
- A **synthetic click on a card does resolve the ID**: dispatching a
  pointer/mouse sequence navigated the webview to
  `https://www.facebook.com/marketplace/item/1901499511237727/?ref=search`.
  The URL does not change synchronously — it resolves on the following tick.

### Revised architecture (supersedes §2.1, §2.2 transport and selector guidance)

| Path | Listings | Pagination | IDs | Detail |
|---|---|---|---|---|
| Desktop UA | 15, hard cap | none | in `href`, free | rich |
| **Mobile UA (WebLite)** | **unbounded** | **yes, touch-driven** | not in DOM; resolved by click | rich (via item URL) |

Mobile is the right transport. The ID problem is smaller than it looks:

1. **Grid cells don't need IDs.** Title, price, location, and thumbnail all
   extract from the mcomponent DOM without one.
2. **Stable identity for dedupe / hidden-listings (§6) comes from the
   thumbnail CDN URL**, which embeds a photo FBID
   (`…_1105285382678938_…jpg`). Good enough as a card key.
3. **The ID is resolved lazily, on tap — at zero extra cost.** When the user
   opens a listing, the app synthetically clicks that card in the hidden
   webview. The resulting navigation *is* the detail-page load §3.2 already
   requires, and its URL yields the canonical item link for handoff (§4). One
   navigation, for a listing the user actually opened — exactly §7.3's pacing
   rule. Nothing speculative.

**Open risk:** §3.1's infinite scroll must be driven by real touch events in
the offscreen webview, since programmatic scrolling doesn't trigger loading.
Synthesizing touch in a non-visible `WKWebView` needs a spike of its own and is
the main technical unknown remaining.

## Verdict

**The product thesis holds.** Logged-out mobile web gives deep, paginating,
richly-detailed local inventory from a WKWebView on iOS. The §9.1 kill
criterion is not met — that reading came from testing the wrong surface.

## Still open

1. **Driving touch-based infinite scroll in an offscreen webview** — the one
   real technical unknown. Programmatic scroll does not paginate.
2. Whether WebLite's DOM is stable enough to parse cards positionally
   (`data-mcomponent` structure, price/title/location by position).
3. Whether filter params (`minPrice`, `radius`, sort) apply on the *mobile*
   surface — confirmed on desktop only.
4. §9.5 logged-in inventory comparison; cellular vs. wifi on real hardware.
