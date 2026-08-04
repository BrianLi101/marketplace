# Marketplace (working title)

A native iOS app for browsing local Facebook Marketplace listings without
signing in. SwiftUI renders everything the user sees; a hidden `WKWebView` is
the data layer. Any action that needs an account — messaging, offers, saving on
Facebook — hands off to the Facebook app via a universal link.

- `app/` — the app (xcodegen: `xcodegen generate`, then build the `Marketplace` scheme)
- `spike/` — throwaway probe harness used to answer questions against the live site
- `docs/` — findings and decisions, listed at the bottom

---

## Which surface has what

Facebook serves two completely different sites depending on the user agent, and
they expose different data. This is the practical breakdown.

Legend: **yes** · **no** · **~** partial or conditional · **?** not yet verified

| | Mobile search | Mobile browse | Mobile item | Web search | Web browse | Web item |
|---|---|---|---|---|---|---|
| **Listing ID** | no | no | n/a | **yes** | **yes** | n/a |
| Title | ~ truncated | ~ truncated | yes | **yes** untruncated | yes | yes |
| Price | yes | yes | yes | yes | yes | yes |
| Was-price (strikethrough) | yes | yes | yes | yes | yes | yes |
| Badge ("Price drop") | yes | yes | — | ? | ? | — |
| City ("San Francisco, CA") | ~ variant-dependent | yes | yes | yes | yes | yes |
| **Approximate coordinates** | no | no | **yes** (map URL) | no | no | **yes** (JSON) |
| "Location is approximate" note | — | — | no | — | — | yes |
| Description | — | — | yes (labelled) | — | — | ~ present, unlabelled |
| Condition | — | — | ? | — | — | yes |
| Posted ("Listed 5 weeks ago") | — | — | yes | — | — | yes |
| Photos (full set) | — | — | yes (24) | — | — | yes (29) |
| **Seller name** | — | — | **yes** | — | — | **no** |
| Seller joined date | — | — | yes | — | — | no |
| Seller rating | — | — | ~ when present | — | — | no |
| Dimensions | — | — | yes | — | — | yes |
| Category breadcrumb | — | — | yes | — | — | yes |
| **Pagination past first batch** | **yes** (26→50→74→99) | **yes** | n/a | **no** (~16 cap) | **no** (~24 cap) | n/a |
| `radius` URL parameter honoured | **no** (stripped) | **no** (stripped) | n/a | yes | ? | n/a |
| Shipping listings mixed in | yes | yes | — | yes | yes | — |

Measured from a `WKWebView` on an iPhone 17 Pro simulator, logged out, between
2026-07-31 and 2026-08-04. "Web" means a desktop user agent — the desktop site
renders fine on iOS; the server keys purely off the UA string.

---

## The findings that shape the app

**Listing IDs exist only on the web surface.** Mobile is WebLite, a
server-driven UI where taps are opaque tokens resolved server-side, so the
client is never told which listing a card is — verified against every pattern
the web surface uses (hrefs, accessibility labels, `listing <id>` phrasing,
long numeric runs). The web surface puts the ID in the `href` *and* in an
aria-label that also carries title, price and city:

```html
<a aria-label="Anthurium Red Gunsal x Bess add, $38, San Francisco, CA, listing 1030250539438843"
   href="/marketplace/item/1030250539438843/?ref=search…">
```

**Item pages carry approximate coordinates — both surfaces, same value.** This
is the only place anything more precise than a city name appears:

- Web: embedded JSON — `"latitude":37.735290527344,"longitude":-122.39318847656`
- Mobile: the same pair inside a static map image URL —
  `static_map.php?…&center=37.735290527344%2C-122.39318847656&zoom=11`

Identical for the same listing on both surfaces, so it's the listing's
published approximate point rather than anything client-derived. It is
deliberately fuzzed — Facebook labels it "Location is approximate" — but it is
far better than a city centroid: for the sample listing it sits ~4.5 km from
the San Francisco centroid the app currently geocodes to.

Coordinates are **per item page only**. Feed cards never carry them, so
card-level distance still has to come from geocoding the city name.

**Seller identity is mobile-only.** The mobile item page shows a seller name,
join date, and rating where present; the web item page shows none of it.

**Depth and precision are on opposite surfaces.** Mobile paginates
indefinitely; web caps at ~16 results and doesn't paginate logged out. Web
honours the `radius` parameter; mobile strips it and falls back to 40 mi, which
means the app's radius control is currently decorative on the feed.

---

## Docs

| File | What's in it |
|---|---|
| `docs/status.md` | What's built and verified, and the open gaps |
| `docs/surface-strategy.md` | Mobile vs. web trade-off, options, and recommendation |
| `docs/mobile-location-radius-notes.md` | Why mobile's location and radius don't behave as the URL implies |
| `docs/feasibility-2026-07-31.md` | The original §9 feasibility answers and how the architecture got here |
