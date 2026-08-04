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
