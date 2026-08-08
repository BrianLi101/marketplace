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
| Seed fallback | The interests picked at onboarding, shuffled, topping up to 3 | A new install has no history and this is the screen it lands on. Shuffled because there are usually more than three and the array is in pick order — taking the first three every launch would make the rest decorative |
| Sample | shuffle the results, *then* take 10 | Taking the top 10 would make Discover the first rows of three searches — which the user could have got by running them |
| Mix | round-robin across the three buckets | The mix has to be visible in the first row, not three blocks stacked up |
| Filters | the user's own — delivery, price, condition, sort | A Discover that ignored them would show results their own search wouldn't |
| Drop | cards badged `Ships` | A local marketplace's home screen isn't a shipping catalogue |
| Distance | applied on-device, as everywhere | No surface honours `radius` (§3) |

**One engine per search**, and all of them run at once.

An engine can't be shared, in either direction. Not with the browse tab, for the
reason `ComparableSearch` has its own: the home feed and the user's first search
would take turns navigating one webview. And not between the three searches
either — an engine is one `WKWebView` with one in-flight navigation, and the
markup fallback reads whatever document that webview is *currently* showing, so
three concurrent searches through one would read each other's cards.

The cost is two more hidden webviews resident for the app's lifetime; the return
is the entire wait on the home screen, since nothing is shown until the fill
finishes:

| | Fill, three searches |
|---|---|
| Sequential, one engine | 13–20 s |
| Concurrent, one engine each | **2.0 s** and **3.3 s** on two measured launches |

No extra request budget — `RequestPacer` is shared and still spaces the starts
0.4 s apart. It did not, at first: `waitForSlot` slept and *then* stamped
`lastRequest`, and an `await` inside an actor method lets the next call in, so
all three callers measured the same gap and two of them left at the same
millisecond. It now reserves the slot before sleeping. Nothing had exercised
that path before, because nothing in the app had ever made two requests at once.

**A fill publishes once, when all of it is in.** It used to republish after each
search, so the grid arrived in three instalments and reflowed twice — cards
moving out from under a thumb, which is the one thing a feed must not do. It
also made the wait look longer than it was by drawing attention to each stage of
it. The section holds a skeleton under its heading and caption for the whole
fill; on a *refresh*, the current cards stay up instead, because there is
something better than a skeleton to look at and the gesture meant "get me a
fresh one", not "take this away".

**The seed terms are printed under the heading** ("From your searches for
lamp · couch · desk"). This is load-bearing, not decoration: a shuffled feed with
no stated basis is indistinguishable from a random one, which was the complaint
that got the previous version deleted.

Each seed carries where it came from, and the sentence changes with it — "From
your interests: Furniture · Bikes · Plants" on a fresh install, "From your
searches and interests" while history is filling up. Printing the interest
labels under the searches wording would claim a history the user doesn't have
yet, on a screen whose entire job is to be legible as a consequence of something
they did.

Note the labels are not the terms. An interest searches for the searchable half
of its category — "Home & garden" runs `home decor`, "Jewellery" runs `jewelry`
— because Marketplace search is a fuzzy match over listing text, not a category
filter. The chip is what the user chose; the term is what finds anything.

## 2. Cache lifetime

Three things rebuild it: **relaunching the app, pulling to refresh, and editing
interests in Settings.** Nothing else.

The third is new with interests and is the exception that proves the rule below:
it doesn't change what the feed *contains*, it changes what the feed is *for*.
It doesn't refill on the spot either — the Settings sheet is over the top of the
feed, so there'd be nothing to watch — it marks the feed stale and rebuilds when
the sheet closes.

Not a new search — recent searches are the seed, so every search would otherwise
throw away the feed the user is about to return to, and they'd come back from a
search to a screen mid-reload. Not a change of city or signing in either, for the
same reason: a reshuffle under someone who is halfway down the feed is worse than
a feed that is an hour old.

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
something in a category you have never asked about *or picked at onboarding*.
That is the trade: relevance over surprise, from signals that never leave the
device. Interests widen it slightly — eighteen categories is more range than
most people's recent searches — but the ceiling is still the user's own stated
taste, by construction.

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

Interests make this worse rather than better, because there is now something
good to fall through *to*: a junk term costs a third of the feed that an
interest would otherwise have filled.

### 4.2 Cold start is still three page loads — but they overlap now

**Largely fixed 2026-08-07.** With no disk cache (§2), the first launch of a
session has nothing to paint and has to fetch everything. Running the three
searches concurrently took that from 13–20 s to 2–3 s (§1), which is short
enough to hold a skeleton through rather than something to paper over.

What remains: it is still a network wait on a screen the user did not ask to
wait for, and it is a floor set by the slowest of three Facebook page loads, so
a bad connection restores the old problem in full. The levers if that shows up
are `searchCount` and, at that point, reconsidering the no-disk-cache rule —
which exists for honesty (§2), not for speed.

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

### 4.7 Three searches retire the interests completely

Seeds are recent-first and there are three of them, so the moment someone has
three searches in history their interests stop contributing anything at all —
including a one-off search for a gift, or a term typed once a month ago. The
standing preference loses to the incidental one, permanently, and the only route
back is clearing search history.

The fix is probably a mix rather than a precedence: two searches and one
interest, say, so a chosen category keeps a seat. Not implemented, because it
wants a real feed to judge — the alternative failure is a home screen that keeps
showing furniture to someone who has moved on to bike parts.

### 4.8 An interest's search term is a guess

Each interest searches for the searchable half of its category, and some of
those choices are more obviously right than others. "Furniture" and "Plants"
match how people title listings; `home decor` for "Home & garden" and
`sports equipment` for "Sports gear" are editorial guesses at what a listing in
that category actually says. None of them have been measured against result
counts, and a term that under-returns costs a third of a fresh install's feed —
the same failure as 4.1, with nobody to blame it on.

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

## 6. The two inputs to this screen, and what that changed

### 6.1 Interests

Picked during onboarding, required, three minimum, stored as `Interest` ids in
`Preferences.interests` (`docs/onboarding.md`). They exist for this file and
nothing else: they are what Discover is made of before there is any history.

Ids rather than labels or terms, so a category can be re-worded or its search
term improved without emptying anybody's saved choices — and `Interest.resolve`
drops ids this build no longer knows, so a retired category can't sit in the
count as a ghost.

They are also what the search field offers under "Try", which is the same answer
to the same question: the completion inserted is the *term*, not the label,
because searching for "Home & garden" finds nothing.

### 6.2 Search history

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
