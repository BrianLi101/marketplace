# Search filter parameters: what works, on which surface

**Date:** 2026-08-04
**Method:** desktop parameters read off `location.href` while driving Facebook's
own filter controls; mobile tested from a `WKWebView` with `customUserAgent`
(`tools/probe`, `runFilterMatrix` / `runCarryOverTests`).
**Related:** `mobile-location-radius-notes.md`, `surface-strategy.md`

The question: can the app change city, distance, local-vs-shipping, and
sort order on the mobile surface it uses for browsing?

**Short answer: no.** Mobile discards every query parameter except `query`.
Desktop honours all of them except `radius`, which is decorative on both.

---

## 1. The parameter vocabulary

Read off `location.href` while clicking the real desktop controls, so these are
Facebook's own names rather than guesses:

| Parameter | Values |
|---|---|
| `sortBy` | `best_match` · `creation_time_descend` · `distance_ascend` · `price_ascend` · `price_descend` |
| `deliveryMethod` | `local_pick_up` · `shipping` |
| `daysSinceListed` | `1` · `7` · `30` |
| `availability` | `in stock` · `out of stock` |
| `itemCondition` | `new` · `used_like_new` · `used_good` · `used_fair` — comma-separated, no spaces |
| `minPrice` / `maxPrice` | integers |
| `radius` | **kilometres**, snapped to the picker's steps |
| `exact` | `true` · `false` — added automatically alongside `query` |

Location is not a parameter. It is the path segment: `/marketplace/<slug>/search/`.

`radius` is genuinely kilometres despite a miles-only UI: selecting "5 miles"
emitted `radius=8`, and `radius=161` rendered the chip as "Within 100 mi"
(161 km = 100.04 mi).

## 2. What each one actually does

Verified against result sets, not against whether the parameter survived the
URL. `docs/probe-checklist.md` §6 — a parameter that survives normalisation is
not a parameter that works.

| Parameter | Desktop | Mobile | Evidence |
|---|---|---|---|
| city slug in path | **works** | **works** | `/sanjose/` returns San Jose · Mountain View · Los Altos · Sunnyvale · Santa Cruz |
| `sortBy` | **works** | stripped | `price_ascend` returned 24 listings all at $0; `creation_time_descend` verified against item pages, below |
| `deliveryMethod` | **works** | stripped | `shipping` → 24/24 cards read "Ships to you"; `local_pick_up` → 15 results, 0 shipping |
| `daysSinceListed` | **works** | stripped | `=1` → first result's item page read "Listed a day ago" |
| `itemCondition` | **works** | stripped | `used_good,used_like_new` → both boxes rendered checked |
| `minPrice`/`maxPrice` | **works** | stripped | `100`–`200` → all 15 prices inside the range, filter boxes echoed $100/$200 |
| `radius` | **no** | stripped | see §3 |

**`sortBy=creation_time_descend` really is newest-first.** Opening the first and
last of its 24 results: "Listed about an hour ago" and "Listed 9 hours ago". The
whole page was under 9 hours old, against a default feed full of listings five
weeks old.

**Mobile strips everything.** Twelve URLs, one per parameter, all normalised
back to `?query=desk` and all returning a byte-identical 26-card result set —
same prices, same cities, same first three labels. The city-slug case is the
control that proves the harness works: it alone came back different.

## 3. `radius` is decorative on *both* surfaces

Previously recorded as "web honours `radius`, mobile strips it". The first half
was wrong — it was believed because the chip updates.

Two independent measurements, logged out:

1. `radius=8` (5 mi) and `radius=161` (100 mi) returned **the same 15 listing
   ids**, differing only in order.
2. `sortBy=price_ascend&radius=8` — chip reading "Within 5 mi" — returned
   listings in Santa Rosa, Penngrove, Brentwood, Livermore and Suisun City, all
   45–60 mi from San Francisco.

So `radius` moves the chip and nothing else. Distance has to be enforced
client-side, against the per-listing coordinates we already extract.

## 4. Two ways round mobile's stripping, both closed

**Session carry-over — no.** Mobile treats *location* as session state, so
filters plausibly work the same way: apply one where it works, then switch
surfaces. Tested inside a single `WKWebView` (one cookie jar, one continuous
session): mobile baseline → desktop with `sortBy=price_ascend&deliveryMethod=
local_pick_up&radius=8` (which the desktop page applied, chip and all) → back
to mobile on an unfiltered URL. The mobile result was **byte-identical to the
control**. Filters do not persist across the surface boundary.

**Mobile's own filter UI — no URL to construct, but possibly drivable.** The
mobile search page renders a single filter control, a "Distance" chip. It is a
`data-action-id` div with no `href`, i.e. an opaque WebLite action, and no link
anywhere on the page carries a filter parameter. So there is nothing to build a
URL out of.

> **Corrected 2026-08-05.** This paragraph originally ended "WebLite ignores
> synthetic taps, so this could only be driven by a real user tap in a
> *visible* webview." That is false, and it was repeated here from a stale note
> rather than measured. Synthetic taps *do* work — `FeedEngine.openItem` clicks
> a card with `el.click()` and the feed lands on the item page; it is the app's
> primary enrichment path. The old negative came from watching
> `decidePolicyFor` for a navigation WebLite never generates.
>
> So the conclusion does not follow: whether the Distance chip can be driven
> synthetically is **untested**, not closed. Worth trying, because Facebook's
> own control might set a radius the URL parameter cannot (§3).

## 5. The trade-off this leaves

| | Mobile | Desktop |
|---|---|---|
| Filters and sorting | none | all but `radius` |
| Results per query | 26, paginating indefinitely (26→50→74→99) | 15–24, no pagination logged out |
| Listing id | no | yes |
| Seller name / join date / rating | yes | no |

Neither surface is sufficient alone.

> **Corrected 2026-08-05.** This previously read "Scrolling the desktop results
> six times added nothing — it is a hard cap, not lazy loading." The test ran
> in a pane with a 0×0 viewport, where scroll calls are no-ops and nothing can
> lazy-load, so it measured nothing. Desktop *does* paginate once the login
> overlay is dismissed: 15 → 39 cards. The conclusion that desktop can't be the
> depth mechanism survives, but for a different reason — only the first 15 cards
> carry the embedded payload. See `surface-strategy.md` §3.

## 6. Recency without losing locality

The obvious lever is the wrong one. Because `radius` doesn't work, sorting
strictly by recency pulls from the entire region:

| Query (desktop, `sanfrancisco`) | Result |
|---|---|
| `deliveryMethod=local_pick_up&daysSinceListed=1` | 15 results — **10 in San Francisco**, rest Brisbane, San Rafael, Emeryville, Hillsborough, one Fairfield |
| the same, plus `sortBy=creation_time_descend` | 24 results — Stockton, Lathrop, Davis, Sacramento, Gilroy, 60–90 mi out |

`daysSinceListed` buys freshness while staying local; `sortBy=creation_time_descend`
buys strict ordering and spends locality to get it. For a local-browsing app,
`daysSinceListed=1` is the better default, with client-side sorting on top.

All four filters do combine — `sortBy` + `deliveryMethod` + `daysSinceListed` +
`itemCondition` in one URL had every control rendered active.

## 7. Per-city fan-out as a partial substitute for radius

Since location is a path segment and works on both surfaces, several searches
can be run across neighbouring city slugs and merged. Same query against
`oakland` instead of `sanfrancisco` recentred the results (Oakland ×2,
Berkeley ×2, Alameda, Lafayette) while still overlapping the San Francisco set,
so this widens coverage without duplicating everything.

It is coverage, not precision — the sets overlap unpredictably and each still
reaches 60+ mi. Distance still has to be enforced client-side afterwards.

## 8. The second class: filters that are ours

Everything above is a request *to* Facebook. There is a second class that runs
entirely on the device, against state Facebook doesn't have, and the filter
sheet labels each one so the difference is visible rather than folklore.

| Filter | Where it runs | Why it isn't a parameter |
|---|---|---|
| Distance | device | `radius` is decorative on both surfaces (§3) |
| Only new listings | device | Facebook keeps no record of what *this user* opened |

"Only new" filters against `ViewedListings`, which records a listing id and a
timestamp when the user opens it. Two properties are worth stating because they
were decisions rather than accidents:

**Seen means opened.** Not scrolled past. A tap is unambiguous evidence that the
user chose the listing; anything looser needs a dwell-and-viewport judgement the
grid can't make honestly.

**The hidden set is snapshotted per search, not read live.** Reading it live
means opening a listing and coming back makes that card vanish and the grid
reflow around the gap — the filter working, but indistinguishable from a bug.
So "new" means new *as of when you ran this search*: cards opened since keep
their place and pick up a "Seen" chip, and drop out on the next search.

This is also the only filter the app has that Facebook could not implement
without being told what you looked at — which is the argument for the feature
and the reason the record never leaves the device.

## 9. Open questions

- Does `daysSinceListed` combined with mobile's pagination have any equivalent?
  It can't be passed, but if a listing's age were derivable from a card the same
  filtering could happen client-side. Cards carry no date today.
- Does the desktop cap change when logged in? Everything here is logged out,
  which is the app's permanent condition, so this is academic unless the
  backend ever fetches with a session.
- Does `availability=out of stock` work for saved listings specifically? §10
  answers the general question — it works, and it is the only route to sold
  data — but re-checking a *known* listing is a different call: it needs the
  item page rather than a search, and whether a sold item's own page still
  renders is untested.


---

## 10. `availability` reaches sold listings, and nothing else does

**Date:** 2026-08-07. San Francisco, logged out, desktop surface, all within
one hour. This answers the §9 question and opens the Seller tab's sold strip.

### It works, and the default search hides sold items completely

| Query | Cards | Sold | Pending |
|---|---|---|---|
| `dresser&daysSinceListed=30` | 14 | **0** | **0** |
| `dresser&availability=out of stock&daysSinceListed=30` | 15 | 11 | 4 |
| `couch&availability=out of stock` | 14 | 2 | 12 |
| `couch&availability=out of stock&daysSinceListed=7` | 15 | 12 | 3 |

The first row is the important one. A plain search returns **nothing** that has
sold or is pending, so every listing this app has ever shown anybody is, by
construction, still for sale. `availability=out of stock` is the only way past
that, and there is no third value — the control offers `in stock` and `out of
stock` and nothing more.

### `out of stock` is Pending ∪ Sold, and the ratio depends on the day filter

Compare the couch rows. Without a window: 2 sold against 12 pending, which is a
list of things that have *not* sold. With `daysSinceListed=7`: 12 sold against
3 pending. Recently-listed unavailable items have mostly sold outright, where
older ones accumulate in Pending — plausibly because Pending is a state
listings sit in rather than pass through.

So the day filter is not optional for this purpose, and callers must still
separate the two on `is_sold`. `ComparableSearch.soldComparables` uses
`daysSinceListed=30`: seven is a tighter recency claim and works, but the cap is
~15 cards *before* pending and free items are removed, and a narrow query with a
narrow window returns nothing at all.

### Sold cards carry the full payload — but there is no sale date

A sold listing's payload block is complete: `creation_time`, `listing_price`,
`strikethrough_price`, `location`, `delivery_types`, title, `is_sold: true`,
`is_pending: false`. Note `is_live` is **also true** on a sold card, so it is
not an availability signal.

The absence is the thing that matters. `creation_time` is the **only** time
field anywhere in the block — no sale, close, sold-at or updated timestamp
exists. So "recently sold" can only ever be inferred: an item listed *n* days
ago that is now gone sold in **at most** *n* days. That is an upper bound, and
the app states it as one ("Sold in ≤4 days") rather than as a fact.

It also means every price here is still an **asking** price. Facebook publishes
what a sold item was listed at, never what changed hands, so an accepted offer
below asking is invisible.

### Sold prices are *not* systematically lower than asking prices

The obvious hypothesis, and it did not survive contact:

| San Francisco dressers | n (priced) | Median |
|---|---|---|
| Active asking | 12 | **$50** |
| Recently sold, listed at | 10 | **$52.50** |

Close enough to be the same number. So the sold set's value is not "what things
really go for" — it is *liquidity*: evidence that a price is achievable, and
how fast. It is a **survivor's list**, and the bias runs one way only. Items
that failed to sell at a price are exactly the ones missing from it, so it can
support "this price works" and can never support "this price is too high".

### Free items swamp the sold set, by category

Of twelve recently-sold couches, **seven were listed at $0**. Free things sell,
so they are wildly over-represented in anything filtered on having sold. It is
category-dependent — only one of eleven sold dressers was free — which is
exactly why it has to be handled rather than eyeballed. `PriceGuide` excludes
non-positive prices from the arithmetic on both sides; the sold strip still
shows them, because "several of these went for free" is worth a seller knowing.
