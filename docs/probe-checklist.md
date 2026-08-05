# Probe checklist

Four rules, each written after a specific mistake. The aria-label miss cost
several weeks and produced a documented "server-side layout lottery" that did
not exist, so this is worth the two minutes it takes to run through.

## 1. A negative needs a positive control

"Cards carry no location" is a claim about a *probe*, not about the site. Before
recording an absence, prove the probe can detect the thing somewhere it is known
to be present.

The condition measurement got this right by accident: it read the same listing
on both surfaces, so "mobile has no condition" could be separated from "this
seller never set one". The location measurement didn't, and was wrong for weeks.

## 2. Echo what you sampled

Probes that inspect one element must print enough of it to identify it.

`locationHuntJS` inspects `cards[0]` — and its card filter matches any `fbcdn`
URL, while the app's `__mpIsListingPhoto` additionally requires `scontent` and
rejects `rsrc.php`. Facebook's wordmark is served from
`static.xx.fbcdn.net/rsrc.php`, so in the spike it *is* `cards[0]`. The probe
built to hunt for card locations was reading the Facebook logo. It even
collected `aria-label` — the exact attribute that held the answer — and reported
`Facebook Logo`.

Had it printed its sample's text or label alongside the verdict, that would have
been obvious immediately.

## 3. Four places, not one, before concluding absence

For any "field X isn't available here", check all of:

| surface | how |
|---|---|
| Rendered text | `innerText`, text-node walk |
| **Attributes** | `aria-label`, `alt`, `title`, `data-*` |
| Embedded JSON | `<script>` contents |
| Raw markup | `documentElement.outerHTML` |

Every extractor in this project reads text nodes, so every negative finding
made before 2026-08-04 was really a statement about text nodes only. Two of
them — search-card city, and card-level condition — were false.

The reverse trap applies too: a hit in raw markup is not a hit *on this
listing*. Mobile item pages contain condition strings that belong to the
"Today's picks" cards, ~80,000 characters from the listing's own id. Check what
a match is attached to before believing it.

## 4. Record the method with the finding

A cell in the README matrix that says `no` should be traceable to how it was
measured. When the method is written down, a wrong negative is visible as soon
as someone reads it with fresh eyes; when it isn't, the claim looks like a fact
about Facebook.

## 5. Verify the page is the one you asked for

Before believing anything extracted, confirm the document is the one you
requested. Every one of these renders perfectly well and extracts cleanly:

| what loaded | what it produced |
|---|---|
| Marketplace's landing page | "Buy and sell in your community on Marketplace" as a description |
| A QR sign-in modal | "Scan the QR code and confirm the codes match to log in." as a description |
| The previous listing, mid-navigation | the wrong listing's content under the right title |

`extractDetail` reports the item id from `location.pathname` and `loadDetail`
rejects any result whose id doesn't match the requested one. That catches
redirects, walls, landing pages and stale documents generically — as opposed to
blacklisting each string as it turns up, which is what the first two fixes did
before the third one made the pattern obvious.

The same applies mid-navigation: mark the outgoing document
(`window.__mpStale = true`) so a poll can't read the old page while the new one
loads.

## 6. A plausible value is not a verified one

The bugs that survived longest all produced output that looked right:

| symptom | actual cause |
|---|---|
| Description showed one sentence | regex captured `([^\n]{1,120})` — one line, under 120 chars |
| Description read as one block | whitespace-only nodes are skipped, so paragraph breaks never arrived |
| Seller name rendered as `(11)` | the line above "Joined Facebook" is the rating count, not the name |
| Seller name rendered as a glyph box | WebLite icons are private-use characters arriving as text |
| Photo strip held a grey avatar | seller avatars are `scontent` too — but PNG, where listings are JPEG |
| Condition matched on an item page | the string belonged to a "Today's picks" card 80,000 chars away |

None of these threw. Each produced a value a reviewer would accept. Every one
was caught by looking at the rendered screen and comparing it against the live
page — not by a test, and not by reading the extractor.

So: when a field is wrong rather than missing, compare against the real page
before theorising. And when adding an extractor, ask what it returns on a page
that *nearly* matches.

---

## Prior art in this repo

Mistakes these rules would have caught, all real:

- Concluding the mobile surface serves no listings, from one selector that
  happened to have no matches (there are zero `/marketplace/item/` anchors on
  mobile — the cards are `data-mcomponent` containers).
- Concluding search cards carry no city, from a probe pointed at the logo.
- Concluding condition is item-page-only, from reading rendered text.
- Nearly writing a condition extractor that would have attributed a neighbouring
  listing's condition to the listing being viewed.
- Recording that synthetic taps don't fire WebLite's action, when they always
  did — the app watched `decidePolicyFor`, and WebLite routes client-side
  through `history.replaceState`, so no navigation ever arrives. The probe that
  "proved" it worked in the spike was tapping the Facebook wordmark.
- Concluding mobile pagination's transport was unfindable, from two instruments
  that share a blind spot. A `fetch`/XHR hook injected at document start caught
  nothing and Resource Timing showed no content request, which looked like two
  independent negatives. Neither observes **WebSockets**, which is what WebLite
  actually uses (`embedded-payload.md` §5b). See the rule below.

- Recording that desktop doesn't paginate, from scroll calls issued into a pane
  whose `innerHeight` was 0. Nothing can lazy-load without a viewport, so the
  absence of new cards measured the absence of a viewport. Desktop paginates
  15 → 39 once its login overlay is dismissed (`surface-strategy.md` §3).

## 6a. Confirm the instrument can see a positive

Before recording a negative, make the setup produce a *known* positive. If a
scroll test can't grow the page even in principle — no viewport, no scroll
container, a modal holding a scroll lock — then "nothing loaded" is a statement
about the harness. Cheapest version: assert the precondition (`innerHeight > 0`,
`scrollHeight > clientHeight`) in the probe itself and fail loudly when it does
not hold.

## 7. Agreeing instruments are not independent evidence

Two probes returning nothing is one piece of evidence if they can both miss the
same thing. Before treating a negative as settled, name what would be invisible
to *every* instrument used — and reach for one that fails differently.

For a "where did this content come from" question the coverage ladder is
roughly: `fetch`/XHR hooks → Resource Timing → WebSocket/EventSource wrapping →
Service Worker interception → a proxy or `WKURLSchemeHandler` below the page
entirely. The first two miss sockets; the first three miss anything a Service
Worker serves from cache. Only the last sees everything.
