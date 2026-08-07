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
| **Embedded GraphQL payload** | **no** | **no** | **no** | **yes** (per card) | ? | **yes** |
| Exact posting timestamp | no | no | **no** | **yes** (`creation_time`) | ? | **yes** |
| Location settable by URL | **yes** (place id; slug only if it exists) | ~ entry point only | n/a | **yes** (same) | yes | n/a |
| `radius` URL parameter honoured | **no** (stripped) | **no** (stripped) | n/a | **no** (chip only) | ? | n/a |
| Sort / filter parameters honoured | **no** (all stripped) | **no** | n/a | **yes** (all but `radius`) | ? | n/a |
| `latitude`/`longitude` honoured | **no** (ignored, falls back to IP) | no | n/a | **no** (same) | ? | n/a |
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

**How fuzzed, measured (2026-08-06).** Facebook publishes no number for this.
Every range the item page shows — "Within 40 mi" in the sidebar, "San Francisco
· 40 mi" over the picks — is the *viewer's own search radius*; against the
listing it says only "Location is approximate". But the coordinates are
quantised, and 56 cached item pages (46 distinct points, Bay Area, logged out)
recover the lattice exactly:

| axis | step | on the ground at 37.8°N |
| --- | --- | --- |
| latitude | `360/2^16` = 0.0054931640625° | 611 m |
| longitude | `360/2^15` = 0.010986328125° | 966 m |

Worst residual across the sample is `4.6e-10°` — this is exact snapping, not
rounding noise — and five different listings share one identical point, which
is what a grid this size looks like in a dense city. So a published point means
"somewhere in this cell", the cell is **wider than it is tall**, and the true
location is at most ~572 m away (half-diagonal).

`FacebookCoordinateGrid` holds the constants. The map draws the **circle that
circumscribes** the cell rather than the cell itself: Facebook shows an area
around its own listings, and matching that shape is worth more to someone
comparing the two screens than the extra fidelity of a rectangle. The size is
still measured — the circle can overstate slightly at the corners and can never
understate.

The lattice is a *lower* bound: Facebook may also jitter before snapping, and
nothing observable from outside can rule that out.

Coordinates are **per item page only**. Feed cards never carry them, so
card-level distance still has to come from geocoding the city name.

That point is also what the detail screen routes against: `MapKitTravelTime`
asks Apple for a walking, driving and transit ETA from the device's own fix
(`MKDirections.calculateETA`). **Both ends have to be real or the row doesn't
draw**: the destination must be the listing's own point, never a city centroid
— routing to the middle of San Francisco from the Inner Sunset returns a
confident "8 min walk" for something an hour away, and a travel time reads as a
plan in a way a fuzzy distance doesn't — and the origin must be a live device
fix, since the chosen search city says which listings come back, not where the
user is. With no fix, an inline prompt offers one. Transit is ETA-only by
design: the SDK marks `MKDirectionsTransportType.transit` as "Only supported for
ETA calculations", which is exactly the question being asked. The row is hidden
outright without a live fix, since the chosen search city says which listings
come back, not where the user is standing.

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
indefinitely. Desktop cannot: there is exactly **one** free dismissal of its
login overlay per page load. It serves 15 cards with a dismissable "See more on
Facebook" overlay up from the start; clicking Close unlocks scrolling and
paginates to 39; the overlay then returns as a *different* modal offering only
Log In and Create Account — no close control, Escape and backdrop clicks both
no-ops. Hard ceiling: **39 cards, of which only the first 15 carry the embedded
payload** (the rest are markup only, no `creation_time` or `delivery_types`).
All 39 stay extractable behind the modal. `docs/surface-strategy.md` §3.

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

**The desktop surface embeds its GraphQL response, and it's a goldmine.** Every
card on a desktop search page ships a structured `listing` object — exact
`creation_time` as a unix timestamp, numeric price, `delivery_types`,
`is_sold`/`is_live`, the city's place id, the untruncated title, and the photo
FBID the app already uses as its identity key. That removes the need to call
Facebook's internal GraphQL endpoint at all, which would otherwise mean a
`doc_id` that rotates every few weeks plus a session-bound CSRF token. There is
no public Marketplace API and never has been; the official research API is
cleanroom-only.

Mobile embeds **none** of it — zero occurrences of every key on a page rendering
26 listings, against 15-of-15 on desktop from the same webview. WebLite ships
rendered components, not a hydration payload. Details and verification in
`docs/embedded-payload.md`.

**Freshness and locality trade against each other.** With `radius` dead,
`sortBy=creation_time_descend` returns a genuinely fresh page — first and last
of 24 results were listed one and nine hours ago — but drags the geography out
to Stockton, Davis and Sacramento. `daysSinceListed=1` keeps 10 of 15 results in
the requested city. For a local browser the date filter is the better lever, and
ordering can be done client-side.

---

## Feedback from use

From Matt, recorded 2026-08-06. Kept in his words, because a thing a user asked
for reads differently from a thing we thought of — and four of these five landed
on work already on the list, which is worth knowing.

| What he said | Where it's tracked |
|---|---|
| **"location doesn't work"** | Confirmed, and worse than it looked: five of the twelve cities the picker offered were not places Facebook recognises, and a rejected place silently serves the IP-inferred city instead of failing. Fixed for those five; the general fix is **Location and radius** below (`docs/location-targeting.md`) |
| **"Feed should be recency based (recently listed)"** | **Feed quality**, first item. Unblocked — the desktop payload dates every card with an exact `creation_time`, so this sorts in Swift without opening a listing |
| **"Custom items that are ordered"** | **Feed quality**, the business/drop-shipper filter. Read as made-to-order listings — a seller advertising a thing they'll build rather than a thing they have. *Check this reading:* it is the one item here I inferred rather than confirmed |
| **"Agent, I want a new table and find the best ones on marketplace"** | **Agent shopping**. Almost exactly the framing already written there ("a desk under $100 within 5 miles, no particleboard"), which is a good sign for the shape of that feature |
| **"Filter out drop shipping"** | **Feed quality**, same bullet as above. Partly solved already: the app defaults to local pickup, and desktop marks shipping per card via `delivery_types` |

The pattern worth noting: nothing here is a request for a feature nobody had
considered. It is a request for the *local browsing* promise to actually hold —
right place, fresh listings, real people selling real objects. That is one
theme, not five items.

## To do

Unchecked means not started. Notes are what we already know that bears on the
item — several of these are harder or easier than they look. Items marked
**(Matt)** came from the feedback above rather than from us.

**Location and radius**

- [ ] **Cache city → place id, for a fast path.** Confirmed 2026-08-07: a
      coordinate resolves to a **city**, not a neighbourhood. Inner Sunset,
      Mission and SoMa all return `/marketplace/sanfrancisco`; Midtown East and
      Williamsburg both return `/marketplace/nyc`. Radius doesn't carry the
      neighbourhood either — every result came back at 5 mi regardless. So the
      ~10 s picker round-trip buys nothing a lookup couldn't, *for cities we
      already know*.
      Two caveats that shape the table. The grain is "incorporated city", not
      "metro": Berkeley, Daly City and Palo Alto each resolved to their own
      place rather than folding into San Francisco or Oakland. And each of those
      came back as a **numeric place id, not a slug** — the same three whose
      guessed slugs failed. So the table must store place ids, and the picker
      stays as the slow path that discovers ids for anything not in it.
      (`docs/location.md` §5.)
- [ ] **The drawn radius still needs work.** It is currently the half-diagonal
      of the measured lattice cell (~572 m in SF), which circumscribes the real
      uncertainty and so never understates — but the cell is only a *lower*
      bound on the fuzz, since Facebook may jitter a point before snapping it,
      and nothing observable from outside settles that. Whether the circle
      should be larger than the cell, and by how much, is unanswered. Two
      loose ends alongside it: the `.city` fallback circle is still an invented
      6 km (`CLPlacemark.region` would give a measured one), and the enriched
      distance is quoted to a tenth of a mile, which is finer than the grid it
      is derived from.
- [ ] **Resolve the user's own location to a place id. (Matt: "location doesn't
      work")** Changing city is *not* solved, which is what the picker's
      curated list was hiding: five of its
      twelve slugs were not places Facebook recognises, and a rejected slug
      silently serves the IP-inferred city instead of failing
      (`docs/location-targeting.md`, measured 2026-08-06). Numeric place ids
      always work, and every search payload already carries one per card at
      `location.reverse_geocode.city_page.id` — so the app can harvest ids as it
      browses and never guess a slug. Steps and fallbacks in §7 of that doc.
- [ ] **Validate the place on every search.** An unrecognised place rewrites the
      path to `/marketplace/category/search/`, and an ambiguous slug resolves
      somewhere else entirely (`richmond` → Richmond, *Virginia*). Both return a
      full, healthy-looking result set for the wrong city, so the path segment
      and the dominant returned city both have to be checked.
- [x] **Feed a coordinate to the picker's centring arrow — the answer to both
      location problems.** Shipped: `MarketplacePlaceResolver` +
      `LocationPickerSheet`. "Use my current location" resolved the device fix
      to `San Francisco [sanfrancisco]`; searching "Toronto" in Apple's
      completer (which disambiguates Toronto ON / NSW / OH, something a guessed
      slug never could) resolved to `Toronto [toronto]` and searches came back
      in CA$ from Toronto and Kawartha Lakes. The curated seven-city list and
      the slug whitelist are both gone, along with the reverse-geocode that
      used to overwrite a chosen city with a guessed slug. Detail below. `latitude`/`longitude` as *URL
      parameters* are ignored (San Diego pair against a San Francisco IP →
      San Francisco ×15), and Facebook never reaches for the browser's location
      on its own during load or search. But the "Change location" dialog has a
      control that does ask —
      `div[role="button"][aria-label="Marketplace geolocation picker"]`, present
      logged out too. Clicking it calls `getCurrentPosition` once, synchronously,
      and *waits*. Resolved with a synthetic Toronto fix from a San Francisco IP
      it set the field to "Toronto, Ontario", and Apply gave
      `/marketplace/toronto/?radius_in_km=65` with an all-Ontario result set in
      CA$ (`docs/location-targeting.md` §5a, measured 2026-08-06 — this corrects
      §5, which had concluded no such route existed).
      The coordinate is consumed and discarded; what persists is a **place**. So
      it's a resolver: hook `getCurrentPosition` in our own webview, feed the
      device's real fix to browse where the user is, or geocode a typed city to
      a coordinate and feed that to browse anywhere else. Facebook picks the
      slug, so it's valid by construction and the broken-slug problem above
      disappears. Unverified: that it behaves the same in `WKWebView`, and
      whether `radius_in_km` from this route is real or decorative.
- [ ] **Enforce radius client-side** — it's the only option left. Cards carry a
      city but no coordinate, so this is either geocoded city centroids at card
      level (cheap, coarse) or the listing's own coordinate once enriched
      (accurate, but only for listings already opened). Probably both: filter
      loosely on the card, precisely on the detail.
- [ ] Consider per-city fan-out to widen coverage, since radius can't narrow it:
      the same query against neighbouring slugs recentres the results and only
      partly overlaps. Coverage, not precision.
- [x] ~~Place ids for cities with no vanity slug (e.g. South San Francisco).~~
      Solved for free: every card in the desktop payload carries its city's
      place id at `location.reverse_geocode.city_page.id` (San Francisco =
      `114952118516947`), so a single search yields the ids of every city it
      returns. No slug-guessing needed.

**Feed quality**

- [ ] **Order the feed by most recently listed. (Matt)** No longer blocked: the desktop
      search payload dates **every card** with an exact `creation_time`, so this
      can be sorted in Swift without opening a single listing
      (`docs/embedded-payload.md`). The server-side `sortBy=creation_time_descend`
      also works but is a worse tool — it's desktop-only *and*, because `radius`
      is dead, it drags results 60–90 mi out. Sort locally instead.
- [ ] **Decide the surface trade-off**, which is now the gating decision for
      everything in this section: mobile gives depth (paginates indefinitely)
      and seller identity; desktop gives every filter plus listing ids. Options
      are a desktop-backed "filtered search" mode alongside the mobile feed, or
      client-side filtering of the mobile feed on the fields cards already
      carry (price, condition, city — but *not* date).
- [ ] **Filter out businesses, drop-shippers and custom-order listings.
      (Matt: "filter out drop shipping", "custom items that are ordered")**
      Shipping is now a structured per-card field on desktop: `delivery_types`
      containing `SHIPPING_ONSITE` marked 24 of 24 cards on a shipping-filtered
      page and none on a local one, and it distinguishes *ships only* from
      *ships or collect in person*. `created_with_seller_app` is a plausible
      business signal but came back `false` everywhere measured, so it's
      untested. Remaining signals for the harder cases: duplicate coordinates
      across many listings from one seller, seller rating count, repeated
      titles (`docs/data-model.md`).
- [ ] Decide drop vs. badge. "Local marketplace browser" and "ships from three
      states away" are different products.

**Mobile's WebSocket**

- [ ] **Read item ids off the feed WebSocket instead of tapping for them.**
      WebLite streams the feed over `wss://kaios-d.facebook.com`, and a single
      124 KB binary frame carries a canonical `/marketplace/item/<id>` route for
      every card — 26 ids for 26 cards, in DOM order, verified by tapping cards
      1 and 2 and landing at socket positions 1 and 2. That removes the ~1.9 s
      per-listing resolve tap and the prefetch budget built around it.
      `docs/embedded-payload.md` §5b.
- [ ] Scope ids per frame and reset on navigation. The accumulated list is
      contaminated by item pages, which push their own "Today's picks" routes —
      measured growth 26 → 42 → 55 across two taps. A global `ids[cardIndex]`
      lookup drifts, and drifting means opening a stranger's listing.
- [ ] Keep DOM extraction as the correctness path. This is a private binary
      protocol with session-scoped ids; it wants fixtures, a health metric and
      a silent fallback before anything depends on it.
- [ ] **Raise the photo cap.** `WebLiteScripts.swift:406` hard-caps at
      `photos.slice(0, 12)`; sampled item pages carry 18–23. Independent of the
      socket work and roughly a one-line change plus a look at what the detail
      view does with more.

**Embeddings**

- [ ] **Vectorise listing titles, and descriptions where we have them.** Four
      things want it, in rough order of value: semantic search ("mid-century
      wooden desk, no particleboard" against a keyword-only backend);
      **repost detection**, below; "more like this" off a saved or opened
      listing; and clustering near-identical titles from one seller, which is a
      better version of the "repeated titles" business signal already noted
      under Feed quality.
- [ ] **Reposts are the case that actually needs it.** Identity is the photo
      FBID from the thumbnail URL (`Listing.identity`), so a seller who relists
      the same item with a re-uploaded photo produces a listing the app has
      never seen before. Everything keyed on that id inherits the blind spot —
      dedupe, saves, and the "Only new listings" filter, which will happily
      show you the same sofa every week as long as the photo keeps changing
      (`docs/filter-parameters.md` §8). Title similarity plus a matching price
      and city is the obvious detector.
- [ ] **Mind the data asymmetry.** Titles are available for *every* card and
      untruncated — from the desktop payload for the first ~15 and from the
      card aria-label for the rest. Descriptions exist only on item pages, so a
      description-based index covers only listings the user has already opened:
      sparse, and biased toward what they were already interested in. Titles are
      short enough to be noisy, which is the real risk here; a title-only index
      needs a similarity threshold set against measured pairs, not a guessed one.
- [ ] On-device first. Apple's Natural Language framework ships sentence
      embeddings (`NLEmbedding.sentenceEmbedding(for:)`, and
      `NLContextualEmbedding` on iOS 17+) — **unverified in this repo**, neither
      the API nor its quality on short listing titles has been measured. Local
      keeps it consistent with the two standing constraints: no extra traffic
      against Facebook, and nothing about what the user browsed leaves the
      device (`ViewedListings`). Vectors belong beside the profiles in
      `ListingCache` — 1,000 profiles × 512 floats is ~2 MB — and in
      `docs/data-model.md` if this ever moves server-side.

**Agent shopping**

- [ ] **Describe what you want, get a set of options. (Matt: "I want a new table
      and find the best ones on marketplace")** Tell it "a desk under $100
      within 5 miles, no particleboard" and have it run the searches, open the
      candidates, and come back with a shortlist and reasons. Matt's phrasing
      arrived independently and almost identically, which is the closest thing
      to validation this section has.
- [ ] Ranking the candidates is the Embeddings item above: the constraint
      "no particleboard" has to be matched against listing text, and Facebook's
      own search won't do it.
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
      `WKWebView`s render full pages. Requests that lose report `.failure`, and
      nothing retries. Scrolling away and back doesn't help: `LazyVStack` keeps
      the view alive rather than rebuilding it. Needs a retrying image view.
      **Partly mitigated:** the 8-listing prefetch that was the largest
      contributor is gone (`docs/decision-desktop-primary.md`), so this should
      be re-measured before being fixed — the remaining contention may be small
      enough not to trigger it.

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
| `docs/embedded-payload.md` | The GraphQL response Facebook ships inside desktop pages, and why the API isnt worth calling |
| `docs/logged-in-findings.md` | What a signed-in session changes: seller identity yes, structured depth no |
| **`docs/location.md`** | **Everything about location, both surfaces — start here.** What Facebook accepts, why a refusal is silent, the coordinate route, the verification protocol, the fuzz lattice, and where distances are measured from |
| `docs/location-targeting.md` | The raw desktop session record: slugs vs place ids, and the §5a/§5b correction that found the coordinate route |
| `docs/feasibility-2026-07-31.md` | The original §9 feasibility answers and how the architecture got here |
