# Location: everything we know

The canonical reference for how location works on Facebook Marketplace across
both surfaces, and how this app handles it. Everything here was measured
against the live site — mostly logged out, mostly from a San Francisco IP, in a
real `WKWebView` unless noted.

The two older documents are the raw session records and stay as they are:
`location-targeting.md` (desktop, and the correction in §5a/§5b) and
`mobile-location-radius-notes.md` (WebLite). Where they disagree with this
file, this file is newer.

---

## 1. The one-paragraph version

Facebook targets **places**, not coordinates. It will not accept a latitude and
longitude as a URL parameter, and it never asks the browser where it is on its
own. But its location picker has a "use my current location" button that *does*
ask, and it accepts any answer — so a coordinate is a usable input after all,
as something you feed the picker rather than something you put in a URL. What
comes back is a place, and that place is what every later request uses. Radius
is decorative everywhere; distance is ours to enforce.

---

## 2. What each input does

Measured on desktop; mobile agrees everywhere both were tested.

| input | accepted? | notes |
|---|---|---|
| `/marketplace/<slug>/` | **yes, if the slug is real** | see §3 for what "if" costs |
| `/marketplace/<place id>/` | **always** | numeric, ≥8 digits |
| `latitude=`/`longitude=` params | **no** | silently ignored — a San Diego pair against an SF IP returned San Francisco ×15 |
| ZIP as a path segment | **no** | `94110`, `94103`, `m5v` all rejected |
| `navigator.geolocation`, unprompted | **never called** | 0 calls across load and search, both surfaces, recorder proved live |
| coordinate via the picker's arrow | **yes** | §5 — the useful one |
| `radius` / `radius_in_km` | **decorative** | §7 |

### Place ids

Always work, keep their path, and genuinely recentre. Every search payload
carries one per card at `location.reverse_geocode.city_page.id`, so they can be
harvested from ordinary browsing. Toronto is `110941395597405`.

We no longer need them — §5 gives a general resolver — but they remain the
most durable identifier if a slug ever stops working.

---

## 3. The silent refusal — the failure mode that matters

**An unrecognised place does not produce an error.** Facebook rewrites the path
to `/marketplace/category/search/` and serves the **IP-inferred city** with a
full, healthy-looking result set. Nothing about the response says "wrong city".

This is the single most important fact in this document. It means:

* You cannot tell success from failure by "did it load" or "were there
  results". Both are yes in the failure case.
* Any code that sets a location **must verify it afterwards** (§6).
* Guessing slugs is not a cheap approximation, it's a silent-wrong-answer
  generator.

Ambiguity fails the same quiet way: `richmond` resolves to Richmond,
**Virginia**.

### How bad was guessing?

Naive slugification — lowercase, strip spaces and dots — was wrong for **five
of the twelve** cities this app once shipped:

| worked | refused |
|---|---|
| sanfrancisco, oakland, sanjose, la, nyc, seattle, chicago | berkeley, dalycity, paloalto, fremont, marin |

International slugs work where they exist: `toronto`, `vancouver`, `london`.

The app no longer guesses. Every slug it holds was returned by Facebook.

---

## 4. The two surfaces

Keyed entirely off User-Agent (`docs/surface-strategy.md`).

| | desktop | mobile (WebLite) |
|---|---|---|
| location pill | yes, with radius | no |
| location picker dialog | yes | no |
| coordinate per listing | item pages only, embedded JSON | item pages only, inside a static-map URL |
| `latitude`/`longitude` params | ignored | ignored |
| `navigator.geolocation` | not called | not called |

Desktop is the app's primary surface, and it is the only one with a picker — so
§5 is desktop-only. That is not a limitation in practice: the resolved place is
a plain path segment that works on both.

---

## 5. Feeding a coordinate to the picker

The route that makes arbitrary targeting possible.

In the "Change location" dialog, at the top-right of the map:

```
div[role="button"][aria-label="Marketplace geolocation picker"]
```

Present **logged out as well as logged in**. Clicking it calls
`navigator.geolocation.getCurrentPosition` once, synchronously, and *waits* —
left unresolved, it sits there as a spinner.

Facebook consumes the coordinate, reverse-geocodes it, and **discards it**.
What persists is a place. So this is a *resolver*, not a coordinate mode, and
that is exactly what makes it useful: Facebook picks the slug, so the slug is
valid by construction and §3 stops applying.

### In `WKWebView`

WKWebView's own Geolocation support has never been dependable, so the app
doesn't use it. `GeoPickerScripts.feeder` **replaces** `navigator.geolocation`
at `atDocumentStart` with an implementation that answers from
`window.__geoFeed`.

Two consequences worth stating plainly:

* The web view needs **no location permission of its own**.
* `__geoFeed` starts `null` and every call errors until the app sets it, so
  Facebook cannot obtain a position at a moment of its choosing — only the one
  the app hands over, at the moment it hands it over.

Measured end to end: fed London (51.5074, −0.1278) from a session sitting on
**Toronto** behind a **San Francisco** IP → `/marketplace/london`, pill
"London · 8 km", British listings. Neither leftover state nor IP could produce
that.

### How fine-grained is the answer? City-level. (measured 2026-08-07)

A coordinate does **not** buy neighbourhood targeting. Nine coordinates fed
through the picker, each trial reset to London first so a no-op couldn't be
mistaken for a result:

| fed | path returned | pill |
|---|---|---|
| SF / Inner Sunset | `/marketplace/sanfrancisco` | San Francisco · 5 mi |
| SF / Mission | `/marketplace/sanfrancisco` | San Francisco · 5 mi |
| SF / SoMa | `/marketplace/sanfrancisco` | San Francisco · 5 mi |
| NYC / Midtown East | `/marketplace/nyc` | New York · 5 mi |
| NYC / Williamsburg | `/marketplace/nyc` | *(stale — see below)* |
| Oakland | `/marketplace/oakland` | Oakland · 5 mi |
| Berkeley | `/marketplace/113857331958379` | Berkeley · 5 mi |
| Daly City | `/marketplace/109415672417245` | Daly City · 5 mi |
| Palo Alto | `/marketplace/104022926303756` | Palo Alto · 5 mi |

Three separate San Francisco neighbourhoods collapse to one place, and both New
York neighbourhoods collapse to `nyc`. **Neighbourhoods do not survive.**

The radius doesn't carry them either: every result came back at 5 mi, whether
the coordinate was a neighbourhood or a city centre, so there is no sense in
which "Midtown East" persists as a tighter circle around New York.

**But the city set is much finer than "major metros",** and this is the part
that matters for any lookup table. Berkeley, Daly City and Palo Alto each
resolved to their *own* distinct place rather than folding into San Francisco
or Oakland — and each came back as a **numeric place id, not a slug**. Those
are exactly three of the five cities whose guessed slugs failed in §3. So:

* granularity is roughly "incorporated city", not "metro area"
* only a minority of cities have a slug; the rest are ids
* a table for the fast path must therefore store **place ids**, and the picker
  is still needed to discover ids for anything not in it

One read is unreliable and is left in rather than quietly dropped: the
Williamsburg row's pill still said "London", the place the trial reset from.
The path had already changed to `/marketplace/nyc`, so the resolution worked
and the pill simply hadn't re-rendered when it was read. It is the same lag the
app's `confirm` step polls for (§6), showing up here because this probe reads
once on a fixed delay.

### The near-miss worth remembering

The first run of that probe fed *Toronto* into a session already showing
Toronto. It failed for an unrelated reason — the pill reads "Toronto · 8 km"
and the selector only matched `mi` — but had the click worked, a pass would
have been **indistinguishable from doing nothing**. Feed a place that is
neither the IP city nor the current state.

Units follow the *place*, not the viewer: a Canadian location renders `km`.

---

## 6. Verification: "applied" is not "worked"

Because of §3, setting a location and believing it are different acts.
`MarketplacePlaceResolver.confirm` runs after every resolution:

1. **Load the resulting URL from scratch.** Not the page still on screen — that
   one was mutated client-side by React and reports what the *picker* believes.
   What matters is what the server does with this URL on a cold request, which
   is the request every later search will make.
2. **Read the URL's place and the rendered pill together**, via
   `MarketplaceURLPlace` and `DesktopLocationPill`, so a disagreement between
   them is visible rather than averaged away.
3. **Poll for the pill** — it renders *after* the payload, up to ~2.5 s later.
   A single read reports "no pill" for a page that has one.
4. **Fail on refusal, and on a pill naming a different place.** A *missing*
   pill is not a failure (the page may not have drawn one); a pill naming
   somewhere else is.

Only a confirmed place is stored. The UI says so — "Confirmed on Facebook —
San Francisco · 40 mi" — because a place that resolved and then quietly served
somewhere else must never look identical to one that worked.

### What gets kept

`ResolvedPlace` holds the whole answer, not just the name:

| field | why |
|---|---|
| `name` | Facebook's own display name, for the UI |
| `segment` | the path component every later search uses |
| `latitude`/`longitude` | what was *asked for* — explains a surprising answer, and lets a stale resolution be repeated without asking the user again |
| `browseURL` | the URL Facebook landed on, verbatim, e.g. `/marketplace/toronto/?radius_in_km=65` — reused rather than re-derived, and the thing to re-check against |
| `verifiedPill` / `verifiedAt` | proof, and when |
| `origin` | `.deviceFix` (can go stale as the user moves) or `.searchedCity` (stays true until changed) |

The URL is stored verbatim deliberately: Facebook chose that form, and
rebuilding it from parts is a chance to get it subtly wrong.

---

## 7. Radius is decorative

The `radius` parameter is ignored on both surfaces, and WebLite's own
"Distance" chip is an opaque action with no href. The picker's own
`radius_in_km=65` has **not** been shown to do anything either — that is an
open question, not a claim.

So distance filtering is the app's job, client-side, and it is enforced against
the best coordinate available per listing (§8).

---

## 8. What Facebook publishes about a listing's location

Only ever a **city name** on feed cards. Item pages — and only item pages —
carry an approximate coordinate, identical across both surfaces, so it's the
listing's published point rather than anything client-derived.

### The fuzz is quantised, and the lattice is measurable

Facebook publishes no number for how approximate "approximate" is. Every range
on an item page ("Within 40 mi", "San Francisco · 40 mi") is the *viewer's own
search radius*. But the coordinates are snapped to a grid — recovered from 56
cached item pages, 46 distinct points:

| axis | step | on the ground at 37.8°N |
|---|---|---|
| latitude | `360/2^16` = 0.0054931640625° | 611 m |
| longitude | `360/2^15` = 0.010986328125° | 966 m |

Worst residual `4.6e-10°` — exact snapping, not rounding noise — and five
listings shared a single point. So a published point means "somewhere in this
cell", the cell is wider than it is tall, and the true location is at most
~572 m away (half-diagonal). `FacebookCoordinateGrid` holds the constants.

The lattice is a **lower bound**: Facebook may also jitter before snapping, and
nothing observable from outside can rule that out.

---

## 9. The user's own location, in the app

* One-shot `CLLocationManager` fix, when-in-use, `kCLLocationAccuracyHundredMeters`.
  Never continuous tracking.
* It goes to Facebook **exactly once**, as the coordinate fed to the picker, and
  what comes back is a place name. Searches after that carry the place, not the
  position.
* The reverse-geocode writes a **display name only**. It used to write
  `city.lowercased()` into the slug on every fix, which was §3's failure by
  another route *and* silently overwrote whichever city the user had chosen.
  `MarketplacePlaceResolver` is the only writer of a slug in the app.

### Where distances are measured from

Browsing somewhere you are not breaks the assumption that "the user" and "the
search" share a location. The rules:

| number | origin | why |
|---|---|---|
| card/detail distance, radius filter | the **searched city** when one was deliberately chosen, else the device fix | measured from a San Francisco fix, every Toronto listing reads "~2273 mi" and the radius filter hides the entire result set |
| travel time | **always the device** | it answers "how long would it take *me* to go and get this", where the user's real position is the only honest origin — and it stops drawing past 100 miles rather than offering a two-day drive |

Known wart: the Saved shelf shows listings saved elsewhere at their distance
from the *browsed* city, which reads oddly. Splitting the rule per surface
would fix it at the cost of two meanings for one number.

---

## 10. Where the code lives

| type | job |
|---|---|
| `GeoPickerScripts` | the document-start shim and the picker-driving JS |
| `MarketplacePlaceResolver` | coordinate → confirmed `ResolvedPlace`, in a throwaway unauthed webview |
| `ResolvedPlace` | the stored answer (§6) |
| `AppleMapsCitySearch` | `MKLocalSearchCompleter` → coordinate, for "browse another city" |
| `MarketplaceURLPlace` | what place, if any, is in a URL — and whether it was refused |
| `DesktopLocationPill` / `DesktopPageLocation` | the rendered pill, its radius, and whether it agrees with the URL |
| `FacebookCoordinateGrid` | the measured fuzz lattice (§8) |
| `LocationPickerSheet` | both user journeys |

Apple and Facebook each do the half they are good at: Apple knows *where* a
typed place is and can tell Toronto ON from NSW from OH; Facebook knows *what
it calls* the place containing that point.

---

## 11. Open questions

* Does `radius_in_km` from the picker route do anything? (§7)
* Does the picker behave the same for a signed-in session? All of §5 was
  measured logged out.
* Should a `.deviceFix` place re-resolve when the user has moved a long way
  from where it was resolved? `ResolvedPlace.metres(from:)` exists for this and
  nothing calls it yet.
