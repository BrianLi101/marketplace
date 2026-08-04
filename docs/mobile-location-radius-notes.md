# Location, radius, and result quality on the mobile surface

**Date:** 2026-08-04
**Sources:** hands-on browsing (Brian) + webview probes from the simulator
**Related:** `surface-strategy.md`, `feasibility-2026-07-31.md`

Notes on how the mobile site actually handles location and radius, and why its
results are looser than the URL suggests. This matters because the app drives
everything by URL, and on this surface the URL is not where location lives.

---

## 1. Location is session state, not URL state

**Observed in normal use:** while browsing the mobile site the URL stays at
`facebook.com/marketplace`. Location isn't expressible there — you set it
physically in the UI, and afterwards the site shows listings near you. The
location you picked persists as session state rather than being carried in the
address.

**Measured, and worth stating precisely,** because there's a nuance the two
observations only look like they disagree on:

| Path | Location in URL? |
|---|---|
| `/marketplace/{place}/search/?query=desk` | **Yes.** Header rendered "Search results for 'desk' near South San Francisco, California" |
| `/marketplace/{place-id}/` (browse) | **Partly.** The path segment survives and the header read "South San Francisco", but it's a landing point only |
| Anything after in-app navigation | **No.** Falls back to the bare URL with location held server-side |

So a place ID *works as an entry point* — that part is usable — but the site
treats location as session state from then on. Search paths are the reliable
way to pin a location; the browse/home feed is not.

## 2. Radius is UI-only, and the URL parameters are discarded

**Observed:** you can set a radius, but only by doing it manually in the
interface.

**Measured:** loading `?radius_in_km=16` (and `?radius_in_km=16&radius=16`) on
mobile produced, after load:

```
https://www.facebook.com/marketplace/sanfrancisco/        ← parameter gone
https://www.facebook.com/marketplace/107929532567815/     ← both gone
```

with Facebook's own chip still reading **40 mi** — not the ~10 mi that 16 km
implies. The mobile surface normalises the URL and falls back to its default
radius.

The desktop surface *did* honour `radius` when tested earlier ("· 6 mi" for
`radius=10`), so this is mobile-specific.

**Consequence for the app: the radius control is currently decorative on the
feed.** We send `radius=<km>`, mobile discards it, and every search is really
40 mi. This was never verified end-to-end on mobile — it was confirmed on
desktop and the assumption carried over.

## 3. The feed is not tightly local, even with a location set

**Observed:** with a location set you still get "Popular listings" and
"Today's picks" — modules that aren't necessarily near you and don't adhere
well to the radius.

**Corroborated by probe.** A browse load for South San Francisco returned
cities including **Pittsburg (~35 mi), Vallejo (~40 mi), and Hayward**, none of
which are meaningfully "near South San Francisco". The header for that same
page read "Popular listings · South San Francisco · 40 mi".

The browse/home feed is a recommendation surface first and a local one second.
Search results are noticeably tighter, which is another argument for treating
search — not browse — as the app's primary path.

## 4. Shipping listings pollute the results

**Observed:** some listings are shipping items, shown as "Ships for $X". These
aren't what a local-browsing app should surface.

**Corroborated:** the first card of the South San Francisco browse probe was
`$65 Two-Piece Pink and Gray… Ships for $9.81`, with no city line. Desktop
shows the same class of listing as "Ships to you".

Useful property: these cards carry a **shipping phrase where a city would
otherwise be**, so they're identifiable without extra requests. Candidate
signals, in rough order of reliability:

- text matching `Ships for $…` or `Ships to you`
- absence of any `City, ST` line on a card that otherwise parsed cleanly

## 5. What this implies

1. **Radius has to be enforced locally.** The parameter is ignored, so the only
   honest radius is one applied in Swift against the distances we already
   compute per card (§6 puts filtering there anyway). We can narrow below
   Facebook's 40 mi, never widen — acceptable, since 40 mi is generous.
2. **Prefer search paths over browse.** Search carries location in the URL and
   returns tighter, more local results. Browse is a recommendations feed whose
   locality is advisory.
3. **Filter shipping listings**, or at minimum mark them, since "local
   marketplace browser" and "ships from three states away" are different
   products. Worth deciding whether to drop them outright or badge them.
4. **Place IDs remain the right way to target a location** (see
   `surface-strategy.md` §"how they're doing it") — they just can't be relied
   on to persist through in-app navigation.

## 6. Per-listing coordinates (added 2026-08-04)

Item pages — and only item pages — publish an approximate coordinate for the
listing. Both surfaces carry the same value:

- **Web:** embedded JSON, `"latitude":37.735290527344,"longitude":-122.39318847656`
- **Mobile:** the same pair in a static map image URL,
  `static_map.php?…&center=37.735290527344%2C-122.39318847656&zoom=11`

Identical across surfaces for the same listing, so it is Facebook's published
approximate point, not anything derived on the client. It's deliberately
imprecise ("Location is approximate"), but materially better than a city
centroid: the sample listing sits ~4.5 km from the San Francisco centroid the
app currently geocodes to.

This does **not** solve feed-level distance — cards carry no coordinates — but
it means any listing the user opens or saves can be pinned properly, and the
detail map can show a real approximate point instead of a city centre.

## 7. Open questions

- Does any spelling of the radius parameter survive on the mobile **search**
  path specifically? Probes so far covered browse and one search URL; worth
  ruling out completely before building local-only radius enforcement.
- Can the location picker be driven in a hidden webview without a login prompt?
  If so, the app could set session location the way a user does. Note that
  synthetic taps do **not** work on WebLite (established earlier), so this may
  be a dead end.
- Do shipping listings ever carry a city line too? If so, the "no city"
  heuristic needs the explicit "Ships" text match rather than relying on
  absence.
