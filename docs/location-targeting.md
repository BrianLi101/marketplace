# Pointing Facebook at where the user actually is

**Date:** 2026-08-06
**Method:** `tools/probe`, `runLocationTests` and `runSlugSurvey`, in a real
`WKWebView` on an iPhone 17 Pro simulator. **Logged out**, 0 Facebook cookies,
desktop user agent unless stated. The simulator's IP resolves to San Francisco,
which is the control every "did it move" question is measured against.
**Related:** `mobile-location-radius-notes.md` §7, `filter-parameters.md`

The question: can the app drop its hand-written city list and target wherever
the user actually is?

**Short answer: yes, but not with slugs and not with a coordinate.** Place ids
are the only reliable mechanism, and Facebook hands them to us for free in the
payload it already ships.

---

## 1. The shipped city picker is wrong for 5 of its 12 cities

`MarketplaceCity.common` was written from the assumption that a lowercased,
space-stripped city name is a valid Facebook place. Measured, same query, one
after another:

| slug | accepted | listings actually returned |
|---|---|---|
| `sanfrancisco` | yes | San Francisco ×8 |
| `oakland` | yes | Oakland, Alameda, San Francisco |
| **`berkeley`** | **no** | **San Francisco ×8** |
| `sanjose` | yes | San Jose ×11, Santa Clara ×2 |
| **`dalycity`** | **no** | **San Francisco ×8** |
| **`paloalto`** | **no** | **San Francisco ×15** |
| **`fremont`** | **no** | **San Francisco ×8** |
| **`marin`** | **no** | **San Francisco ×15** |
| `la` | yes | Los Angeles ×15 |
| `nyc` | yes | New York ×12, Brooklyn ×3 |
| `seattle` | yes | Seattle ×14 |
| `chicago` | yes | Chicago ×14 |

Five of twelve silently return the IP-inferred city. A user in Berkeley picks
"Berkeley" and gets San Francisco listings, with nothing anywhere on the screen
saying so. `berkeley` was measured twice in separate runs, same result.

This directly contradicts the comment those entries shipped with — "slugs
verified to relocate the result set rather than merely the header". That was
true of the three slugs anyone checked, and assumed of the rest.

## 2. The failure mode is a silent rewrite, and it is detectable

An unrecognised place does not 404 and does not redirect to a chooser. Facebook
rewrites the path and serves the IP-inferred city's listings:

```
requested   /marketplace/berkeley/search/?query=desk
became      /marketplace/category/search/?query=desk
returned    San Francisco ×8
```

Every rejected slug produced exactly this, including a deliberately invented
one (`notarealplacexyz`). So the verdict is one comparison — **the place
segment survives in `location.pathname`, or it doesn't**:

```js
accepted: location.pathname.indexOf('/category/') === -1
```

That is the check the app has to make on every search, because the wrong-city
result set is otherwise indistinguishable from a right one.

## 3. Accepted is not the same as correct

`richmond` was accepted, kept its path, and returned **Richmond, Virginia**
×12 — from a session whose IP is in California, 2,400 miles away, with
Richmond CA thirty minutes up the road.

So slug validation needs two assertions, not one: the path survived, *and* the
dominant city in the results is the city that was asked for. A slug is a
guess at a name in a global namespace, and Facebook resolves it to whichever
place it thinks owns that name.

## 4. Coordinates are ignored on desktop too

The README carried `?` for this. It is now measured, and it matches mobile:

| requested | resulting path | listings |
|---|---|---|
| `/marketplace/search/?query=desk` | rewritten to `/marketplace/sanfrancisco/search/` | San Francisco ×7 |
| `…&latitude=32.7157&longitude=-117.1611` (San Diego) | `/marketplace/sanfrancisco/search/` | San Francisco ×15 |
| `/marketplace/sanfrancisco/search/…&latitude=…&longitude=…` | unchanged | San Francisco ×7 |

The parameters survive in the query string and change nothing. Facebook infers
the place from IP and ignores what it was told — the same behaviour recorded on
mobile in `mobile-location-radius-notes.md` §7, now confirmed on the surface the
app actually searches.

**A coordinate cannot be sent to Facebook *as a URL parameter*.** It can be
supplied another way — see §5a, which supersedes the conclusion §5 originally
drew.

## 5. The page never asks the browser where it is *unprompted*

`navigator.geolocation.getCurrentPosition` and `watchPosition` were wrapped at
`atDocumentStart`, before any page script existed, on both surfaces:

| page | calls by the page |
|---|---|
| desktop search | **0** |
| mobile search | **0** |

With the instrument proved live in the same breath — the harness called
`getCurrentPosition` on itself and the recorder caught it (`hooked: true`,
`sawOwnCall: true`) on both. So this is Facebook not asking, not a hook that
failed to install (checklist §1, §6a).

So Facebook does not reach for the browser's location on its own, during load
or during a search.

## 5a. But there is a button that asks — and it takes any coordinate

**Corrects §5, measured 2026-08-06.** The reading above was "granting
geolocation to the webview would achieve nothing, there is no route by which
the site can read a real fix". That was too strong: §5 measured page *load* and
*search*, and never opened the location picker. The picker has a control that
asks.

In the "Change location" dialog, at the top-right of the map, sits
`div[role="button"][aria-label="Marketplace geolocation picker"]` — the
centring arrow. Present **logged out as well as logged in**.

| step | result |
|---|---|
| hook `getCurrentPosition`, never delegate, click the arrow | **1 call**, synchronous on click |
| leave it unresolved | the arrow becomes a spinner and stays there — it genuinely waits |
| resolve with a synthetic Toronto fix (43.6532, -79.3832) from a San Francisco IP | Location field becomes **"Toronto, Ontario"** |
| press Apply | URL → `/marketplace/toronto/?radius_in_km=65`, pill → "Toronto · 40 mi", cards → Toronto, Brampton, Vaughan, Markham, Mississauga, Ajax, Guelph, prices in CA$ |

Recorder proved live by positive control in the same breath, both times
(checklist §1, §6a).

**So an arbitrary lat/long *is* an accepted input** — just through this control
rather than the URL. Note what Facebook does with it: the coordinate is
consumed, reverse-geocoded, and thrown away. What persists is a place — the
slug `toronto` in the path — so this is a *resolver*, not a coordinate mode.

That is the useful part. It resolves any coordinate to a place Facebook itself
chose, so the slug is valid by construction and none of §2's broken-slug
problem arises. Two open questions become one mechanism: feed the device's real
fix to browse where the user actually is, or geocode a typed city name to a
coordinate and feed that to browse anywhere else.

### 5b. Confirmed in `WKWebView` — the app's own engine

Run with the `GeoFeed` probe, desktop UA, logged out. WKWebView has never
really shipped Geolocation, so the app doesn't rely on it: a documentStart user
script *replaces* `navigator.geolocation` with one that answers from
`window.__geoFeed`. The web view therefore needs no location permission of its
own, and Facebook can only ever receive a coordinate the app decided to hand
over.

| check | result |
|---|---|
| `navigator.geolocation` exists in WKWebView | yes (`geoWasMissing: false`) — the shim overwrites rather than defines |
| shim installed, positive control | `hooked: true`, `sawOwnCall: true` |
| Facebook calls it when the arrow is clicked | yes — `__geoFedCalls` 1 → 2 |
| fed London (51.5074, −0.1278) | → Apply → `/marketplace/london`, pill **"London · 8 km"**, UK listings |

The session was on **Toronto** when the run started (persistent store, left by
the picker probe) and the IP is **San Francisco**, so London can be neither
leftover state nor IP inference.

A false pass nearly happened here and is worth recording: the first run fed
*Toronto* into a session already showing Toronto. It failed for an unrelated
reason — the pill reads "Toronto · 8 km" and the selector only matched `mi` —
but had the click worked, the result would have been indistinguishable from
doing nothing (checklist §3: a probe whose expected output equals the starting
state measures nothing).

Still unverified: whether `radius_in_km` from this route is honoured or
decorative like every other radius control (§3).

## 6. Place ids work, and every search hands them over

A place id in the path is honoured, keeps its path, and genuinely recentres:

```
/marketplace/107929532567815/search/?query=desk
→ Daly City ×4, San Bruno, South San Francisco, Pacifica, San Francisco ×1
```

And the ids are already in the payload the app parses. Every card carries its
own city's id:

```json
"reverse_geocode": {
  "city": "San Francisco", "state": "CA",
  "city_page": { "display_name": "San Francisco, California", "id": "114952118516947" }
}
```

One South San Francisco search yielded five addressable places for free:

| city | place id |
|---|---|
| San Francisco, CA | `114952118516947` |
| Daly City, CA | `109415672417245` |
| South San Francisco, CA | `107929532567815` |
| San Bruno, CA | `112488205430730` |
| Pacifica, CA | `107897135899839` |

**A harvested id then works as a path segment** — `109415672417245` (Daly City,
whose *slug* is one of the five broken ones) was accepted and kept its path.
That closes the loop: the app can learn how to address a place from the same
response that showed it listings there, with no extra requests, no guessing, and
no private endpoint.

## 7. What this means for the app

Location resolves in four steps, cheapest first:

1. **Coordinate → city name.** CoreLocation for the fix, `CLGeocoder` to
   reverse it. Already in the app for distances; nothing new.
2. **City name → place id, from what we've already seen.** Harvest
   `reverse_geocode` on every search and persist `city, ST → id`. Free, and it
   grows toward the places this particular user actually browses.
3. **Miss → try the slug, then verify both things** (§2, §3): the path survived
   *and* the returned cities are the city asked for. On success, remember it.
4. **Still a miss → nearest place we do have an id for**, and say so in the UI.
   Distance is filtered client-side against the user's real coordinate anyway,
   so a neighbouring anchor degrades gracefully — results are still filtered to
   the radius around the user, just drawn from a slightly different pool.

The honest framing for the product: **the app can target the user's city
automatically, but it cannot target their coordinate.** Facebook's grain is a
city page; the exact fix only ever refines things on our side. That is also
what step 4 makes acceptable — the coordinate does the precise work regardless
of which city page the listings came from.

Bootstrapping is the one soft spot. On a first run with no harvested ids, the
IP-inferred search is what we have, and its results carry ids for the cities
*near* the user rather than necessarily the user's own. Step 3 covers the common
case; step 4 covers the rest.

## 8. Somewhere the user has never been: Facebook's own picker

§6 only learns places the user already got listings from, so it cannot answer
"I'm in San Francisco and I want to browse Toronto". Three routes tested.

**ZIP codes are not a path segment.** `94110`, `94103` and the Canadian `m5v`
all rewrote to `/marketplace/category/search/` and served San Francisco. Whatever
the picker means by "ZIP code", it is not something the URL accepts.

**Slugs do work worldwide for large cities.** `toronto` → Toronto ON ×15,
`vancouver` → Vancouver BC ×8, `london` accepted. So the slug path is not a
US-only mechanism; it is a big-place mechanism, and Toronto specifically needs
nothing more than `/marketplace/toronto/search/`.

**The picker is fully drivable, logged out.** This is the general answer. On a
desktop search page:

| step | how | result |
|---|---|---|
| open it | `.click()` on the element whose aria-label is `Location: San Francisco, California, Within 5 mi` | dialog "Change location — Search by city, neighborhood or ZIP code", with a `Location` input and a `Radius` select |
| type | native `value` setter + a bubbling `input` event | typeahead returned **Toronto, Ontario (City)**, *1 King St W, Toronto* (address), *New Toronto* (neighbourhood) |
| choose | tap the row | input filled, map recentred on Toronto with a radius circle |
| apply | tap **Apply** | results became Toronto, ON in CA$; the chip read "Toronto · 5 mi" |

React ignores a plain `input.value = x`, which is why the native setter matters.
The typeahead options render in a **portal outside** `[role="dialog"]` — the
first pass reported `options: []` and the screenshot showed three of them, which
is checklist §2 again: the probe was scoped to the wrong subtree, not the site
failing to answer.

**And the choice persists.** After relaunching the harness — new process, same
cookie jar — a URL with *no place segment at all* was rewritten to
`/marketplace/toronto/search/` and returned Toronto ×15. So the picker writes
durable session state, not page state.

**But an explicit place still overrides it**: `/marketplace/sanfrancisco/search/`
immediately returned San Francisco ×8 from that same Toronto session. The URL
wins, which is what makes the picker usable as a *resolver* rather than as a
mode the app has to stay in.

That is the useful shape: **drive the picker once to learn a place, then address
that place by URL forever after.** The Toronto run yielded exactly what a
resolver needs —

```
Toronto, ON → 110941395597405
```

— harvested from the payload of the page the picker landed on.

## 9. Open questions

- **Does a place id ever expire or move?** Ids look like stable page ids, but
  nothing here tested one older than this session. A stored map wants a
  validation path — the §2 check gives one for free.
- **What is the miss rate outside the Bay Area?** Measured 5 of 13 accepted in a
  general survey (`oakland`, `richmond`, `seattle`, `portland`, `boise` yes;
  `berkeley`, `sanmateo`, `hayward`, `concord`, `sunnyvale`, `santarosa`,
  `walnutcreek`, `sacramento` no). Metros mostly work, but `sacramento` — a
  state capital — does not, so size alone doesn't predict it.
- **Is there a cheaper id lookup than harvesting?** Facebook's own location
  picker must resolve a typed name to an id somehow. It was not investigated
  here, because it is a private endpoint and harvesting is free.
- **Does a signed-in account override all of this** with its own saved city?
  Everything above is logged out. Worth checking before relying on step 4's
  fallback for signed-in users.
- **Does the picker's Radius control actually filter?** It is the one thing in
  this dialog the URL has never been able to set, and `radius` as a parameter is
  decorative on both surfaces (`filter-parameters.md` §3). The Toronto run left
  it at its default 5 mi and returned Toronto ×15, which proves nothing either
  way. If Facebook's own control does bite, driving it is the only known route
  to a real server-side radius.
- **Does the picker accept a ZIP, given the URL doesn't?** Its own prompt says
  "city, neighborhood or ZIP code" and only a city was tried. Worth one run,
  because a ZIP is the easiest thing for a user to type unambiguously.
- **Is the picker reachable on the mobile surface?** Everything in §8 is
  desktop. Mobile renders a Distance chip whose behaviour is untested
  (`filter-parameters.md` §4).
