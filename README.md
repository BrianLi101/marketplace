# Marketplace (working title)

A native iOS app for browsing local Facebook Marketplace listings without
signing in. SwiftUI renders everything the user sees; a hidden `WKWebView` is
the data layer. Any action that needs an account — messaging, offers, saving on
Facebook — hands off to the Facebook app via a universal link.

```
apps/ios/       the app (xcodegen: `xcodegen generate`, then build the Marketplace scheme)
apps/backend/   placeholder — runtime not chosen yet, see its README
tools/probe/    harness for measuring the live site; every finding below came from it
docs/           findings and decisions, listed at the bottom
```

---

## Which surface has what

Facebook serves two completely different sites depending on the user agent, and
they expose different data. This is the practical breakdown.

Legend: **yes** · **no** · **~** partial or conditional · **?** not yet verified

| | Mobile search | Mobile browse | Mobile item | Web search | Web browse | Web item |
|---|---|---|---|---|---|---|
| **Listing ID** | no | no | n/a | **yes** | **yes** | n/a |
| Title | **yes** untruncated (aria) | ~ truncated | yes | **yes** untruncated | yes | yes |
| Price | yes | yes | yes | yes | yes | yes |
| Was-price (strikethrough) | yes | yes | yes | yes | yes | yes |
| Badge ("Price drop") | yes | yes | — | ? | ? | — |
| City ("San Francisco, CA") | **yes** (aria) | yes | yes | yes | yes | yes |
| **Approximate coordinates** | no | no | **yes** (map URL) | no | no | **yes** (JSON) |
| "Location is approximate" note | — | — | no | — | — | yes |
| Description | — | — | yes (labelled) | — | — | ~ present, unlabelled |
| Condition | **yes** (aria) | ? | ~ layout-dependent | — | — | **yes** |
| Posted ("Listed 5 weeks ago") | — | — | yes | — | — | yes |
| Photos (full set) | — | — | yes (24) | — | — | yes (29) |
| **Seller name** | — | — | **yes** | — | — | **no** |
| Seller joined date | — | — | yes | — | — | no |
| Seller rating | — | — | ~ when present | — | — | no |
| Dimensions | — | — | yes | — | — | yes |
| Category breadcrumb | — | — | yes | — | — | yes |
| **Pagination past first batch** | **yes** (26→50→74→99) | **yes** | n/a | **no** (~16 cap) | **no** (~24 cap) | n/a |
| Location settable by URL | **yes** (city slug or place id) | ~ entry point only | n/a | yes | yes | n/a |
| `radius` URL parameter honoured | **no** (stripped) | **no** (stripped) | n/a | **no** (chip only) | ? | n/a |
| Sort / filter parameters honoured | **no** (all stripped) | **no** | n/a | **yes** (all but `radius`) | ? | n/a |
| `latitude`/`longitude` honoured | **no** (ignored, falls back to IP) | no | n/a | ? | ? | n/a |
| Shipping listings mixed in | yes | yes | — | yes, and filterable | yes | — |

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

**Mobile search cards carry everything in an `aria-label`.** The visible text
of a card is only a price and a truncated title, but every card labels itself:

```
Desk for sale - Used - Good - $75 in Oakland, CA
Free Computer desk for sale - Used - Like New in El Sobrante, CA
```

Measured 2026-08-04: **27 of 27 cards** carry one, on both search layouts, and
every card that is actually a listing parses. Two shapes — priced listings put
the price between condition and `in`; free listings prefix `Free ` to the title
and omit the price segment entirely. The only non-parsing label is the Facebook
logo, which isn't a listing and is already excluded by the `scontent` guard.

That single attribute supplies the **untruncated title**, the **city**, and the
**condition**, none of which are in the rendered text. Conditions observed form
a clean set: `New`, `Used - Like New`, `Used - Good`, `Used - Fair`.

**The search layout is decided by the URL, not by chance.** Requesting a place
that differs from the IP-inferred one yields the layout with a city printed on
every card; requesting the place you already appear to be in yields the one
without. Eight search observations, no exceptions:

| requested | IP says | layout |
|---|---|---|
| no place segment | San Francisco | no per-card city |
| `?latitude=&longitude=` (ignored) | San Francisco | no per-card city |
| `/sanfrancisco/` ×4 | San Francisco | no per-card city |
| `/sanjose/` | San Francisco | **city on every card** |
| `/oakland/` | San Francisco | **city on every card** |
| `/107929532567815/` (South SF) | San Francisco | **city on every card** |

This matters much less than it used to, because the aria-label carries the city
either way. It was previously recorded as a "server-side layout lottery"; it
isn't one.

**Condition is web-only among *item* pages.** Mobile item pages come in two layouts,
and only one of them renders a Details/Condition block — measured 1 of 3
listings (2026-08-04). The condition string does appear in the raw HTML of the
other two, which is a trap: it belongs to the "Today's picks" cards at the
bottom of the page, whose `aria-label`s read `"<title> for sale - <condition>"`.
Those sit ~80,000 characters away from the listing's own id and in zero script
tags, so there is no embedded JSON to fall back on. Reading the first HTML match
would silently attribute a neighbouring listing's condition to this one.

Consequence, given the aria-label finding above: condition no longer needs an
item page at all, so the web **item** page is only worth loading for its
embedded coordinates. A full record is card aria-label + mobile item page
(description, photos, coordinates, seller) + one desktop *search* to resolve the
listing id.

**Depth and precision are on opposite surfaces.** Mobile paginates
indefinitely; web caps at 15–24 results and doesn't paginate logged out
(scrolling it six times added nothing).

**Filters and sorting are desktop-only, and `radius` works nowhere.** Facebook's
own desktop controls emit `sortBy`, `deliveryMethod`, `daysSinceListed`,
`itemCondition`, `minPrice`/`maxPrice` and `radius`; every one of them is
verified to change the desktop result set except `radius`, which only repaints
its own chip — `radius=8` and `radius=161` return the same 15 listings, and a
search labelled "Within 5 mi" comes back with results 60 mi out. Mobile strips
all of them: twelve URLs, one per parameter, all normalised back to
`?query=desk` and all returning a byte-identical 26-card page. Neither applying
a filter on desktop and switching user agent mid-session nor driving mobile's
own "Distance" chip (an opaque WebLite action with no href) gets round it.

So the app's radius control is decorative, and distance can only be enforced
client-side against per-listing coordinates. Full matrix in
`docs/filter-parameters.md`.

**Freshness and locality trade against each other.** With `radius` dead,
`sortBy=creation_time_descend` returns a genuinely fresh page — first and last
of 24 results were listed one and nine hours ago — but drags the geography out
to Stockton, Davis and Sacramento. `daysSinceListed=1` keeps 10 of 15 results in
the requested city. For a local browser the date filter is the better lever, and
ordering can be done client-side.

---

## To do

Unchecked means not started. Notes are what we already know that bears on the
item — several of these are harder or easier than they look.

**Location and radius**

- [ ] **Make location actually work.** Only the city slug or place id in the URL
      path moves the result set — `latitude`/`longitude` are ignored in favour of
      the IP-inferred place, and `radius` is decorative on *both* surfaces
      (measured 2026-08-04, `docs/filter-parameters.md` §3). Changing city is
      solved; changing distance is not, and can't be.
- [ ] **Enforce radius client-side** — it's the only option left. Cards carry a
      city but no coordinate, so this is either geocoded city centroids at card
      level (cheap, coarse) or the listing's own coordinate once enriched
      (accurate, but only for listings already opened). Probably both: filter
      loosely on the card, precisely on the detail.
- [ ] Consider per-city fan-out to widen coverage, since radius can't narrow it:
      the same query against neighbouring slugs recentres the results and only
      partly overlaps. Coverage, not precision.
- [ ] Place ids for cities with no vanity slug (e.g. South San Francisco). A
      place-id page echoes its own id back in the markup; a slug page doesn't,
      so "try the slug, verify the header, fall back" is workable.

**Feed quality**

- [ ] **Order the feed by most recently listed.** Answered, with a catch:
      `sortBy=creation_time_descend` works and is verified genuinely
      newest-first, but **only on desktop**, which caps at 15–24 results and
      can't paginate. Mobile strips it. And because `radius` is dead, strict
      recency drags the results 60–90 mi out. `daysSinceListed=1` is the better
      lever — fresh *and* local — but it's equally desktop-only.
- [ ] **Decide the surface trade-off**, which is now the gating decision for
      everything in this section: mobile gives depth (paginates indefinitely)
      and seller identity; desktop gives every filter plus listing ids. Options
      are a desktop-backed "filtered search" mode alongside the mobile feed, or
      client-side filtering of the mobile feed on the fields cards already
      carry (price, condition, city — but *not* date).
- [ ] **Filter out businesses, drop-shippers and custom-order listings.**
      Shipping listings are now cheap to exclude on desktop —
      `deliveryMethod=local_pick_up` returned 0 of them, and shipping cards are
      separately identifiable by an empty city segment in their `aria-label`.
      Remaining signals for the harder cases: duplicate coordinates across many
      listings from one seller, seller rating count, repeated titles. The
      coordinate signal is real — two listings from one seller carry
      byte-identical coordinates (`docs/data-model.md`).
- [ ] Decide drop vs. badge. "Local marketplace browser" and "ships from three
      states away" are different products.

**Agent shopping**

- [ ] **Describe what you want, get a set of options.** Tell it "a desk under
      $100 within 5 miles, no particleboard" and have it run the searches, open
      the candidates, and come back with a shortlist and reasons.
- [ ] Needs the enrichment path to be cheap enough to open many listings —
      currently ~2s each and every open is traffic against Facebook, so this
      wants the backend and the shared cache before it's practical at scale.

**Known defects**

- [ ] **A saved listing's thumbnail dies after ~4.5 days.** fbcdn URLs are
      signed and time-limited: `oh` is a signature and `oe` is a hex unix
      expiry. Measured across three cached listings on 2026-08-04, the window is
      **106.9–107.5 hours** from fetch — call it 4.5 days. Saved items are meant
      to persist indefinitely, so a saved card older than that will render its
      price, title and city from the local store with a dead image. Fix is to
      cache the image bytes for saved listings rather than the URL.
- [ ] **`AsyncImage` never retries, so cards lose their image under load.**
      Reproducible: a card renders a permanent grey placeholder in the search
      grid while the *same URL* loads first try on the saved home, returns HTTP
      200 to `curl`, and has four days left on its expiry. The trigger is
      contention — the search grid loads ~26 thumbnails at once while two hidden
      `WKWebView`s render full pages and the prefetch walks 8 item pages of 12+
      photos each. Requests that lose report `.failure`, and nothing retries.
      Scrolling away and back doesn't help: `LazyVStack` keeps the view alive
      rather than rebuilding it. Needs a retrying image view, and probably fewer
      concurrent image requests while a prefetch is running.

---

## Docs

| File | What's in it |
|---|---|
| `docs/probe-checklist.md` | How to measure this site without recording false negatives |
| `docs/data-model.md` | Proposed schema for storing listings across devices |
| `docs/status.md` | What's built and verified, and the open gaps |
| `docs/surface-strategy.md` | Mobile vs. web trade-off, options, and recommendation |
| `docs/mobile-location-radius-notes.md` | Why mobile's location and radius don't behave as the URL implies |
| `docs/filter-parameters.md` | Every sort/filter parameter, which surface honours it, and what's measured |
| `docs/feasibility-2026-07-31.md` | The original §9 feasibility answers and how the architecture got here |
