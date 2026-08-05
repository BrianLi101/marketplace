# What changes with a signed-in session

**Date:** 2026-08-05
**Method:** `tools/probe`, signed in by hand on a throwaway account in a visible
webview; battery in `runLoggedInTests`. Desktop user agent throughout except
the login itself.
**Related:** `surface-strategy.md`, `embedded-payload.md`, `filter-parameters.md`

Four questions could only be answered with a session. Two came back the way the
all-desktop plan needed, two did not.

---

## 1. Seller data: unlocked (the plan's best result)

Desktop item pages carry no seller fields logged out. Signed in, the same
listing:

| field | logged out | signed in |
|---|---|---|
| "Joined Facebook in …" | — | **"Joined Facebook in 2023"** |
| Seller information heading | no | **yes** |
| `/marketplace/profile/<id>` links | 0 | **3** |
| coordinates | yes | yes |
| rating | — | absent on this listing |

The profile links matter more than the join date: they are a **stable seller
id**, which no surface provides logged out and which mobile never provides at
all. That is the missing ingredient for the "filter out businesses and
drop-shippers" goal — listings can be grouped by seller instead of guessed at
from duplicate coordinates and repeated titles.

Rating was absent here; whether that is per-seller or needs a seller with
ratings is untested.

## 2. Payload past the first page: still capped (the plan's worst result)

**This is the finding that constrains the design.** Scrolling the signed-in feed
through ten rounds:

```
round   1     2     3     4     5     6     7     8     9    10
cards  18    45    27    12    29    10    12    10     8    13
creation_time keys  16 16 16 16 16 16 16 16 16 16
```

`creation_time` never moves off **16** while cards go past 45, and
`idsWithPayload` drops to 0 as soon as the original 15 scroll out of the DOM.
The embedded payload is only ever the server-rendered first page. Signing in
does not extend it.

So the structured data — exact timestamps, `delivery_types`, `is_sold`, numeric
price — remains capped at ~15 per query whether signed in or not. Everything
beyond that is markup, which is what mobile already provides.

## 3. Infinite scroll: yes, but the feed virtualises

Scrolling works logged in and does not stop at the logged-out ceiling of 39 —
document height reached 15,397 px and kept going.

But look at the card counts above: 45, then 27, then 12, then 29. They go *down*.
The desktop feed **recycles DOM nodes**, keeping only a window around the
viewport. Consequences for anything built on it:

- Cards must be **harvested incrementally while scrolling**. Scrolling to the
  end and then reading the DOM returns whatever the last window happened to
  hold, not the feed.
- The same applies to the payload: even the first 15 objects stop matching
  rendered cards once those cards are recycled out.

## 4. Radius: still decorative, even signed in

The one that would have justified login on its own. It does not.

| | `radius=8` (5 mi) | `radius=161` (100 mi) |
|---|---|---|
| chip | "Within 5 mi" | "Within 100 mi" |
| cards | 15 | 15 |
| first five ids | identical | identical |
| cities | San Francisco ×15 | San Francisco ×15 |

Byte-identical result sets. Radius moves the chip and nothing else, logged in
exactly as logged out.

**One genuine improvement, though not from `radius`:** signed in, all 15 results
were San Francisco, where the same logged-out query returned Martinez, Vallejo,
Oakland and Daly City. The plausible cause is the account's own saved location
tightening the default — worth confirming, because if it holds it is a real
locality gain that costs no filtering work.

## 5. Timing: the data lands at half the page-load time

Item pages, signed in, desktop, polled at 25 ms from navigation start:

| listing | payload readable | rendered text | `didFinish` |
|---|---|---|---|
| 1054280080442808 | 1.04 s | 1.18 s | 1.85 s |
| 1624050395351390 | 0.84 s | 1.14 s | 1.58 s |
| 1318664736543676 | 0.79 s | 1.08 s | 2.13 s |

The payload is readable at ~0.9 s against a ~1.85 s `didFinish`. **Nothing needs
to wait for the page to finish** — extract as soon as the JSON is in the
document and abandon the rest of the load. That is roughly a 2× improvement on
detail open, and it removes the images and third-party chrome from the critical
path entirely.

### The first version of this measurement was wrong

It reported `payload=0.01s` for all three, which would have been a ~200×
finding. `webView.load()` leaves the previous document in place until the new
one commits, and the previous document was another item page carrying the same
`creation_time` / `location_text` markers — so the first poll matched the page
we had just navigated away from.

Fixed by requiring `location.href` to contain the expected listing id before
either signal counts, plus an `about:blank` load between timings. The corrected
numbers are above. Same family as the 0×0-viewport and agreeing-instruments
mistakes: **a probe that can report success before the work starts is measuring
its own setup.**

## 6. What this means for the all-desktop plan

Holds up:

- Seller data and a stable seller id (§1), which mobile cannot give at all
- Filters and sorting, which only desktop has
- Coordinates on item pages
- Detail open at ~0.9 s if the load is abandoned early (§5)

Does not hold up:

- **Infinite scroll does not buy structured depth** (§2). Past card ~15 the
  cards are markup-only — the same quality mobile already provides without an
  account in the loop.
- **Radius still does not work** (§4), so client-side distance filtering is
  required regardless.
- The feed virtualises (§3), so harvesting is more complex than "scroll then
  read".

The honest summary: signing in fixes the *item page* (seller identity) and
leaves the *feed* essentially where it was. If login is adopted, the argument
for it is seller data and account-tightened locality — not depth.
