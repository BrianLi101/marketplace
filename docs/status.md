# Build status — 2026-07-31

App lives in `apps/ios/` (xcodegen; `xcodegen generate` then build the
`Marketplace` scheme). Probe harness in `tools/probe/`, with its own README. Feasibility record in
`feasibility-2026-07-31.md`. Which Facebook surface to route through, and why —
including the desktop login modal — is analysed in `surface-strategy.md`.
How the mobile site handles location, radius and result quality (and why the
radius control is currently decorative) is in `mobile-location-radius-notes.md`.

## Working, verified on an iPhone 17 Pro simulator

- **Category feeds** — 49 DOM cards → 48 parsed, with title, price, badge,
  **city**, and **approximate distance**.
- **Search feeds** — 27 cards → 26 parsed, with **untruncated title**, price,
  badge, **city**, **distance**, and **condition**, all read from each card's
  `aria-label` rather than its rendered text (see below).
- **Progressive detail preview** (§3.2) — pushes on the next frame with the
  grid's data, hero image shared via `matchedGeometryEffect`, skeletons for
  what's still loading. Never blocks on the network. Enrichment then fills in
  the real description, condition, photo strip, and location + distance
  (measured 4.7s and 7.6s for two listings).
- **Deep linking** — "View on Facebook" opens the listing's own
  `/marketplace/item/{id}` page. Verified against a live listing.
- **Detail content is scoped to the listing.** Detail pages carry "Related
  searches" and "Today's picks" modules full of *other people's* listings; the
  extractor walks in document order and stops at the first such heading, so the
  photo strip and description can't pick them up. Text nodes inside
  `<script>`/`<style>` are excluded — a TreeWalker over `SHOW_TEXT` visits them,
  which briefly rendered a page's JavaScript as a listing description.
- **Approximate-area map** — an Apple Maps card with a radius circle around the
  geocoded place, not a pin: Facebook says "Location is approximate" and a pin
  would imply precision the seller never shared.
- **Session restore** — the last search or category is persisted and re-run on
  launch, so reopening lands where the user left off rather than on an empty
  screen.
- **Pagination** — driven by stepping the hidden webview's native scroll view,
  the only method that works (§ below).
- **Radius pinning, recent-search pills, first-run, settings, request pacing
  with backoff, parse-health metrics.** Sponsored cards are filtered out; the
  keyword blocklist and per-listing hiding were removed on 2026-08-04.

## The three findings the implementation is built around

1. **Mobile UA only.** Desktop caps at 15 results with no pagination; the stock
   WKWebView UA gets a dataless shell.
2. **Pagination responds only to the native scroll view.** `window.scrollTo`
   and synthesized `TouchEvent`s leave the page frozen; stepping
   `scrollView.contentOffset` loads the next ~25 listings.
3. **Cards are found structurally**, as an actionable container holding an
   fbcdn image. Search pages wrap card text in `h3`; category pages don't, so
   any markup-shaped selector breaks on one surface or the other.

## Known gaps

### Item URLs — solved, via the desktop surface

Listing ids exist nowhere in the mobile DOM, and synthetic taps never fired
WebLite's server-side action from inside the app (mouse events, touch events,
`el.click()`, interactive webview, full opacity — all no-ops, though the same
code worked in the standalone spike).

Resolved by going around it. The **desktop** surface still exposes real
`a[href*="/marketplace/item/{id}"]` anchors, so `DetailEngine` searches that
surface for the listing's own title and matches the result back by title prefix
and price (`ItemMatcher`). Grid titles arrive truncated, so matching is on a
normalised prefix, and it refuses to guess — a wrong id would open someone
else's listing, which is worse than no link.

Cost is one page load per listing the user actually opens, on top of the detail
page load that §3.2 already requires. Verified end to end: tapping a card
resolves the id, loads the real description, condition and photos, and "View on
Facebook" deep-links to that exact item page.

### Search cards often carry no location — SOLVED 2026-08-04

**We were reading the wrong thing.** Every mobile search card carries an
`aria-label` holding the untruncated title, the condition, the price and the
city — 27 of 27 cards, on both layouts. The extractor reads rendered text,
which on one layout omits the city. Nothing about the webview context was ever
at fault.

```
Desk for sale - Used - Good - $75 in Oakland, CA
Free Computer desk for sale - Used - Like New in El Sobrante, CA
```

Two shapes: priced listings put the price between the condition and `in`; free
listings prefix `Free ` and drop the price segment. Parsing both covers every
card that is a listing.

The layout difference is real but no longer load-bearing, and it is not random:
requesting a place that differs from the IP-inferred one gets the layout with
per-card cities, requesting the place you already appear to be in does not.
Eight search observations, no exceptions. The elimination work below stands as
a record of what was ruled out, but the premise — that the app was being denied
data — was wrong.

<details>
<summary>Original diagnosis, kept for the record</summary>

Category feeds render a city per card and the app shows city + distance there.
Search is inconsistent, and the cause is **not** in our code:

Facebook serves at least two mobile layouts for the *same* search URL:

| | header | cards | text nodes | city nodes |
|---|---|---|---|---|
| Variant A | "Results" + a Distance chip | price, title | 141 | 1 (page header only) |
| Variant B | "Search results for X near Y" + "40 mi", Filters, Sort | price, title, **city** | 128 | 26 (one per card) |

The standalone spike reliably gets B; the app reliably gets A, with an
identical URL, identical mobile user agent, and a fresh `nonPersistent` store
in both. Ruled out by direct experiment: the `radius` parameter, the
`latitude`/`longitude` parameters (both now removed as unnecessary), extraction
timing (re-read to ~25s), card-root selection (containment *and* document-order
bucketing), viewport size (402×778 in both), `isScrollEnabled`, webview opacity,
occlusion vs. offscreen positioning, and hit-testability.

What that leaves is something about the app's WebKit context that biases the
bucket — plausibly the process pool, two webviews in one process, or a
cookie/bucketing decision made on the very first navigation of a session.

Next step, and the cheap one: have the app instantiate a *single* webview
exactly as the spike does (no shared pool, no second engine, default
configuration) and see if the variant flips. If it does, bisect the
configuration from there. Failing that, detect the variant at runtime — the
header text and city-node count identify it unambiguously — and reload once
into a fresh data store to reroll.

Meanwhile the parse-health metric already reports `failing=location`, which is
exactly the early warning §8 was specified for; it is working as intended.

</details>

## Notes for testing

- The iOS 26 floating search bar doesn't take focus from synthetic taps; seed
  `recentSearches` via `simctl spawn <udid> defaults write` and tap a pill.
- Set a location first, or distances stay blank:
  `xcrun simctl location <udid> set 37.7749,-122.4194`.
- Sustained probing does trigger Facebook's login wall — the app's backoff
  (§7.3) is not theoretical.
