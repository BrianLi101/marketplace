# Build status — 2026-07-31

App lives in `app/` (xcodegen; `xcodegen generate` then build the `Marketplace`
scheme). Throwaway probe harness in `spike/`. Feasibility record in
`feasibility-2026-07-31.md`.

## Working, verified on an iPhone 17 Pro simulator

- **Category feeds** — 49 DOM cards → 48 parsed, with title, price, badge,
  **city**, and **approximate distance**.
- **Search feeds** — 27 cards → 26 parsed (title, price, badge; no location,
  see below).
- **Progressive detail preview** (§3.2) — pushes on the next frame with the
  grid's data, hero image shared via `matchedGeometryEffect`, skeletons for
  what's still loading. Never blocks on the network.
- **Pagination** — driven by stepping the hidden webview's native scroll view,
  the only method that works (§ below).
- **Radius pinning, keyword blocklist, hidden listings, recent-search pills,
  first-run, settings, request pacing with backoff, parse-health metrics.**

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

### Item URLs don't resolve (affects handoff precision and detail enrichment)

Listing ids exist nowhere in the mobile DOM. The plan was to tap a card in the
hidden webview and capture the navigation it triggers — this **worked in the
standalone spike** (resolved to `/marketplace/item/1901499511237727/`) but does
**not** fire from inside the app, on either surface, after trying mouse events,
touch events, `el.click()`, an interactive webview, and full opacity. WebLite
dispatches taps server-side, so the difference is likely in how the action is
bound rather than in the events themselves.

Consequence: "Message Seller" falls back to a Marketplace **search for the
listing's title** (`Handoff.openSearch`), which lands the user on or beside the
item, and the detail page keeps the preview without enrichment. Everything
degrades quietly, per §3.2.

Worth trying next: capture the outbound request WebLite makes when a real
finger taps a card (compare against the synthetic path), or drive a real
`UIWindow` hit-test rather than DOM events.

### Search cards often carry no location — a server-side layout lottery

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

## Notes for testing

- The iOS 26 floating search bar doesn't take focus from synthetic taps; seed
  `recentSearches` via `simctl spawn <udid> defaults write` and tap a pill.
- Set a location first, or distances stay blank:
  `xcrun simctl location <udid> set 37.7749,-122.4194`.
- Sustained probing does trigger Facebook's login wall — the app's backoff
  (§7.3) is not theoretical.
