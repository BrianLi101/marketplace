# Discover: the home screen feed

**Date:** 2026-08-07
**Code:** `apps/ios/Sources/Store/DiscoverFeed.swift`,
`ResultsView.discoverSection`
**Related:** `embedded-payload.md` §8, `filter-parameters.md` §3 and §11,
`mobile-location-radius-notes.md` §3

The home screen is three sections: **Recently viewed** and **Saved**, one
horizontal rail each and both read from disk, then **Discover**, which runs to
the bottom of the scroll. Either rail disappears when empty, so a new install
lands directly in Discover.

Discover exists because the home screen used to be entirely local. That is the
right content for someone coming *back*, and nothing at all for someone
arriving: a new install saw an empty state and a search field, and had to think
of something to type before the app would do anything.

---

## 1. What it does now

Up to three of the user's own recent searches, re-run and mixed.

| Step | Rule | Why |
|---|---|---|
| Seed | `recentSearches`, newest first, up to 3 | The one strong statement of interest anyone makes in this app |
| Seed fallback | `Preferences.suggestedCategories`, shuffled | A new install has no history and this is the screen it lands on |
| Sample | shuffle the results, *then* take 10 | Taking the top 10 would make Discover the first rows of three searches — which the user could have got by running them |
| Mix | round-robin across the three buckets | The mix has to be visible in the first row, not three blocks stacked up |
| Filters | the user's own — delivery, price, condition, sort | A Discover that ignored them would show results their own search wouldn't |
| Drop | cards badged `Ships` | A local marketplace's home screen isn't a shipping catalogue |
| Distance | applied on-device, as everywhere | No surface honours `radius` (§3) |

**Its own engine**, for the reason `ComparableSearch` has one: sharing the browse
tab's would mean the home feed and the user's first search taking turns
navigating one webview. No extra request budget — `RequestPacer` is shared — but
it is three page loads per fill, which is why the fill happens once.

**The seed terms are printed under the heading** ("From your searches for
lamp · couch · desk"). This is load-bearing, not decoration: a shuffled feed with
no stated basis is indistinguishable from a random one, which was the complaint
that got the previous version deleted.

## 2. Cache lifetime

Two things rebuild it: **relaunching the app, and pulling to refresh.** Nothing
else.

Not a new search — recent searches are the seed, so every search would otherwise
throw away the feed the user is about to return to, and they'd come back from a
search to a screen mid-reload. Not a change of city or signing in either, for the
same reason: three page loads and a reshuffle under someone who is halfway down
the feed is worse than a feed that is an hour old.

**Nothing is written to disk.** Restoring a shuffle from yesterday and presenting
it as today's would be a lie the cache tells for free. The cost is a slower cold
start, which §4 tracks.

## 3. Why not Facebook's own feed

The first version loaded `/marketplace/<place>/` — "Today's picks". Measured,
logged out, three loads of the identical URL in one session:

| | vs previous load |
|---|---|
| load 1 → 2 | **0 of 5** top cards survived |
| load 2 → 3 | 17 of 20 overlapped |
| load 4 | reverted to load 1's contents |

The geography swung with it: 9-of-20 in San Francisco on one load, an East Bay
spread reaching Napa and Antioch (~50 mi) on the next. That is a couple of cached
popularity pools being alternated, not a ranking.

Logged out there is also very little to personalise *with*: an IP, an anonymous
cookie, and whatever item pages that cookie has opened. The last one does reach
Facebook — every engine shares one persistent `WKWebsiteDataStore`
(`BrowserSession.dataStore`), so opening a listing is visible to it. Whether that
feeds the picks is **untested and expensive to test**: the feed's own churn
(0–100% between loads) is far larger than the effect a personalisation test would
be looking for. One trial — three guitar item pages, then a reload — returned one
guitar in twenty, which establishes nothing.

It was also markup-only: the embedded payload is effectively absent on that path
(6 `"listing"` blocks against 20 rendered cards, none carrying a title, price or
photo — `embedded-payload.md` §8). That was the *smaller* of its two problems.

**What the current design gives up is novelty.** Discover cannot show you
something in a category you have never asked about. That is the trade: relevance
over surprise, from signals that never leave the device.

## 4. Known issues

Open, in rough order of how likely they are to bite.

### 4.1 Junk terms in history become permanent home-screen seeds

Observed live: a mangled term from an earlier session — `Couchantique writing
desk`, two searches run together — was one of the three seeds. Facebook's fuzzy
matching rescued it into desk results, but a term that returns **nothing**
silently costs a third of the feed, and there is no signal to the user that it
did.

Two candidate fixes, neither implemented: don't record a term that returned zero
results, or have Discover skip a seed that comes back empty and fall through to
the next one. The second is better — it also handles a term that worked once and
stopped, like a sold-out model name.

### 4.2 Cold start is three sequential page loads

With no disk cache (§2), the first launch of a session has nothing to paint. It
fills progressively — a batch at a time, spinner under the grid — rather than
holding a skeleton for the whole run, but it is still noticeably slower than the
version that restored from disk. The obvious lever if this proves annoying is
dropping `searchCount` to two.

### 4.3 The distance-filter disclosure is at the bottom, where nobody is

Discover states what it removed — "11 more further than 6 mi", with a widen
button — but only *after* the grid. On a result set that works, because the user
reads to the end. On a home feed people scroll until something catches their eye
and stop, so the disclosure is functionally invisible.

Measured case: Facebook's browse feed returned 20 cards across 11 cities and the
6 mi radius cut 11 of them, leaving a screen that looked like "San Francisco has
nine things in it". The current search-seeded feed is more local by construction,
but the same failure mode applies whenever a seed term is sparse nearby.

Candidate fix: move the count into the section header, next to the seed terms.

### 4.4 Signed in, Facebook's own radius is a floor we cannot raise

An account carries its own Marketplace radius, it is the only thing that actually
filters server-side, and the URL parameter is ignored (`filter-parameters.md`
§11). So a signed-in user whose account says 10 mi cannot see a 30-mile listing
in Discover no matter what the app's control says — including "Any". The widen
button is honest logged out and potentially a lie signed in.

### 4.5 A saved listing can appear twice on the same screen

The Saved rail and Discover are independent, so a saved item matching a seed term
renders in both. Not a correctness bug — the rail uses `RecentCard`, which
carries no `matchedGeometryEffect`, so the hero-transition ids stay unique — but
it is the same card twice within one scroll.

### 4.6 Discover cards are markup-grade until opened

Cards come from search results, so the first ~15 of each search carry the
embedded payload and anything past that is markup only. Nothing downstream should
assume an exact `creation_time`, `delivery_types` or sold state on a Discover
card. Opening one enriches it from its item page.

## 5. If Discover ever draws on external or older sources

Right now every card in Discover was fetched seconds ago, in this session, which
hides two problems that a wider source would expose immediately. Anything that
adds cached, shared, or externally-supplied listings has to deal with both.

### 5.1 Photo URLs expire

fbcdn image links are generated with an expiry and a signature — they are not
stable addresses for a photo. A URL captured a couple of days ago will stop
resolving, and the failure is silent: `AsyncImage` renders an empty frame, so a
stale feed degrades into a grid of grey rectangles rather than an error anyone
can act on.

Consequences for any design that stores cards for longer:

- **Never treat a stored photo URL as durable.** It is a fetch hint with a
  shelf life, not an identifier.
- **The identity built from it is fine.** `Listing.photoFBID` parses the fbcdn
  *filename segment*, which is stable across surfaces and outlives the signed
  URL — that is why dedupe is an equality check. Identity and fetchability are
  different properties of the same string and only one of them expires.
- **A card whose image won't load needs a visible state**, or "expired" and
  "still loading" look identical forever.

### 5.2 Sold status goes stale, and we can't cheaply re-check it

A cached card says what was true when it was captured. Listings sell. The app has
no push, no polling, and no route to a listing's current state short of loading
its item page — which is a request per card, and exactly the automation-shaped
traffic the app avoids everywhere else (`decision-desktop-primary.md`).

It is worse than ordinary staleness, because a default search *cannot* see sold
listings at all: a plain search returns 0 sold and 0 pending, so everything the
app has ever shown is live **by construction of the query**, not by verification
(`filter-parameters.md` §10). A stored card carries no evidence of still being
for sale; it carries evidence that it was for sale once.

So any longer-lived Discover has to:

- **Say how old a card is**, rather than presenting stored state as current.
- **Re-check on open, never in bulk.** The detail path already re-fetches, and
  the item page does carry `is_sold` — read anchored on `location_text`, since a
  sold page carries 21 `is_sold` values and only one of them is the listing's.
- **Not claim sold status it hasn't seen.** `ListingDetail.isSold` is optional on
  purpose: `nil` means "nothing told us", never "available".

Both risks point the same way: the further Discover moves from "fetched just
now", the more it needs to state its own age rather than imply freshness.

## 6. Search history is now a home-screen input

Recording a search used to be a private matter between the search field and its
own suggestions. Seeding Discover from it changed the stakes: anything searched
once becomes the home screen until it ages out, which is a different bargain than
the user agreed to when the list only drove autocomplete.

Two rules follow, both enforced in `Preferences.recordSearch` rather than at call
sites:

- **`recordSearchHistory` gates it** — Settings → History → "Include searches in
  history". Off means a search changes neither the suggestions nor Discover.
  It does not clear what is already saved; "stop recording" and "erase" are
  different requests and there is a separate button for the second.
- **The Seller tab never records.** Its search terms are derived from whatever
  the user is drafting a listing for, so recording them would fill the home
  screen with the thing they are trying to sell. `SellerToolsModel` reads
  `Preferences` for location and filters and never writes to it.
