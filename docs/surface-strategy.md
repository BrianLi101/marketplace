# Surface strategy: mobile vs. desktop

**Status:** analysis + recommendation, not yet implemented
**Date:** 2026-07-31
**Related:** `feasibility-2026-07-31.md` (how we got here), `status.md` (what's built)

Facebook serves two entirely different Marketplace sites depending on the user
agent, and they have opposite strengths. Everything below was measured from a
`WKWebView` on an iPhone 17 Pro simulator, logged out, same city, same query
("anthurium") unless noted.

---

## 1. The two surfaces

### Mobile — WebLite

A **server-driven UI**. Cards are `data-mcomponent` containers keyed by an
opaque token (`data-action-id="32511"`). Tapping sends that token to Facebook,
which decides server-side where to navigate. The client is never told which
listing a card represents.

Measured, with 26 listings on screen:

| Probe | Result |
|---|---|
| `/marketplace/item/{id}` hrefs | **0** |
| Anchors on the entire page | 4 — Safari promo, Chrome promo, logo, "Log in" |
| Elements with `aria-label` / `alt` / `title` | 64 |
| …that reference a listing | **0** |
| The string `listing <digits>` anywhere in the markup | **0** |
| Distinct 13–17 digit numbers in the document | 4 (for 26 cards — so not per-listing) |

Also ruled out earlier: React fiber props, embedded JSON in `<script>` tags,
and every `data-*` attribute on the card and six levels of ancestors.

**There are no listing IDs on the mobile site, in any form.** This is
architectural, not an oversight, and no better selector will find them.

### Desktop

A conventional web page, so it *has* to put a real URL in a real anchor:

```html
<a aria-label="Anthurium Red Gunsal x Bess add, $38, San Francisco, CA, listing 1030250539438843"
   class="x1i10hfl xjbqb8w x1ejq31n …"
   href="/marketplace/item/1030250539438843/?ref=search&referral_code=null&referral_story_type=post">
```

The ID appears twice — in the `href` and in the `aria-label` — and the label is
a comma-delimited record of **title, price, city, and ID** in one string.
Accessibility labels are a far more durable parsing target than obfuscated
class names (`x1i10hfl xjbqb8w`), because Facebook can't churn them without
breaking screen readers.

Renders fine on iOS: a desktop UA in a `WKWebView` produced 16 listing anchors
at real layout sizes (first card 189×262pt), with `navigator.userAgent`
reporting macOS. The app already relies on this for detail pages.

---

## 2. Head to head

| | Mobile (WebLite) | Desktop |
|---|---|---|
| Listing IDs | none, anywhere | in `href` **and** `aria-label` |
| Results per search | 26, then paginates | ~16, hard cap |
| Pagination logged out | **yes** — 26 → 50 → 74 → 99, batches of ~25 | **no** |
| Per-card location | only on one of two layout variants | reliably present |
| Title, price | yes (titles truncated) | yes, untruncated, in the label |
| Category pages | paginates | ~24, capped |
| Parsing target | structural guesswork | anchor + accessibility label |
| Layout stability | two variants served at random | one consistent layout observed |

Pagination on mobile responds **only** to stepping the native
`scrollView.contentOffset`. `window.scrollTo` and synthesized `TouchEvent`s
both leave the page frozen.

Neither surface can be fetched without a browser: `URLSession`, `curl`, and
even same-origin `fetch()` with valid cookies all return a dataless JS shell.
A real top-level navigation in a webview is required either way.

---

## 3. The login modal on desktop

**Sustained scrolling on the desktop surface brings up a login-required modal.**

What we've observed, in order of confidence:

- A dismissible "See more on Facebook" overlay appears on load and returns on
  scroll. Listings stay fully rendered in the DOM behind it, so extraction is
  unaffected while it's merely an overlay.
- After enough scrolling, it escalates to a login-required modal — reported
  from hands-on use, and consistent with the full login page the spike hit
  after repeated requests during a long probing session.
- **The exact scroll threshold has not been measured.** Worth pinning down
  before committing to any desktop-heavy design, because it sets a hard ceiling
  on how far a desktop feed can be driven even if pagination worked.

This matters less than it sounds for the recommendation below, since the
desktop plan doesn't scroll the feed at all — it reads the first ~16 cards and
stops. But it's a real constraint on any "just scroll desktop instead" idea,
and it's a second reason (alongside the hard result cap) that desktop can't be
the depth mechanism.

Also worth remembering: heavy probing during development *did* trigger a full
login wall. The backoff ladder in §7.3 is not theoretical.

---

## 4. What routing through desktop would gain

1. **Exact identity, free.** Today identity is inferred from a photo's CDN
   filename, and grid listings are matched to search results by fuzzy title
   prefix. Both disappear. Correct dedupe and correct hidden-listings follow,
   and so does the elimination of a real risk: a mis-match opens someone else's
   listing.
2. **Instant deep links.** No ~5s resolve step on tap. Opening a listing costs
   one page load instead of two.
3. **Location on every card**, hence distance on every card. Locality is the
   product thesis; on mobile it depends on which layout variant we're served.
4. **Fewer requests.** Current: 1 per search + 2 per listing opened. Desktop
   first: 1 per search + 1 per listing opened.
5. **Much less fragile code.** These exist only to cope with WebLite and could
   be deleted: document-order text bucketing, the ~25s settle/re-read loop,
   native-scroll pagination, the synthetic tap machinery (which never worked
   in-app), `ItemMatcher`'s fuzzy matching, and variant handling.

### What it costs

**Depth.** ~16 results per search versus mobile's 26-and-climbing. That is the
single reason not to go all-desktop.

---

## 5. Options

| Option | Depth | IDs / location | Complexity |
|---|---|---|---|
| A. All mobile | best | none — no deep links, no detail | high, fragile |
| B. Current hybrid — mobile feed, desktop per-tap resolve | best | fuzzy, ~5s per open | highest |
| C. **Desktop first, mobile for depth** | good | exact for the first ~16 | medium |
| D. All desktop | ~16 per query | exact everywhere | lowest |

**Recommendation: C**, with D as the honest simplification if depth turns out
not to matter in practice.

Under C, the first page comes from desktop — exact IDs, untruncated titles,
prices, cities, instant deep links — and mobile is spun up only when the user
scrolls past ~16 results. Most sessions never leave the first screen, so most
of the time you get the good surface and the reliable parser.

The seam is the honest wrinkle: merging the two feeds means recognising when a
mobile card is a listing desktop already returned, which needs the same fuzzy
matching C otherwise deletes. It would be confined to the boundary past card
16 rather than applying to every listing. Measured overlap for a single query:
desktop returned 16 links against mobile's 26 cards, and 15 of 21 sampled
mobile cards matched a desktop entry by 12-character title prefix (~60%). The
misses were near-duplicate titles — three "Anthurium Luxurians" listings plus
one "Anthirium Luxurians" typo — which is exactly where title matching is
weakest and where having desktop's price and city in the label would help.

---

## 6. Open questions

1. **Does desktop search accept an offset or cursor parameter?** If page two
   were reachable by URL, option D becomes strictly better than anything else
   and the mobile path can be deleted outright. Facebook's own desktop
   pagination is infinite-scroll and login-gated, so this is unlikely — but
   it's ~15 minutes to rule out and it would settle the whole question.
2. **How much scrolling triggers the desktop login modal?** (§3.) Sets the
   ceiling on any desktop-driven feed.
3. **Does the modal ever block extraction, or is it always just an overlay?**
   So far listings have stayed readable in the DOM behind it.
4. **How often do users actually scroll past the first ~16 results?** This is
   the product question that decides C vs. D. Worth answering with the
   handoff/scroll-depth telemetry in §8 before building either.
