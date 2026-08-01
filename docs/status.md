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

### Search cards carry no location

Verified directly: on the mobile search surface the only city string on the
entire page is the header's, and `sortBy=distance` adds no per-card distance.
Category pages do include location. Distance therefore appears on category
feeds and detail pages, not on search results.

Options if this matters more than pagination: use the desktop surface for
search (has location per card, but 15 results and no infinite scroll), or
enrich per-card location from detail pages (one request per card — violates
§7.3 and shouldn't be done).

## Notes for testing

- The iOS 26 floating search bar doesn't take focus from synthetic taps; seed
  `recentSearches` via `simctl spawn <udid> defaults write` and tap a pill.
- Set a location first, or distances stay blank:
  `xcrun simctl location <udid> set 37.7749,-122.4194`.
- Sustained probing does trigger Facebook's login wall — the app's backoff
  (§7.3) is not theoretical.
