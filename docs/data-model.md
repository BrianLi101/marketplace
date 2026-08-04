# Data model — draft v0.2

What we'd store to accumulate listings across devices, so a feed card that
arrives knowing almost nothing can be enriched from what somebody else's phone
already learned.

Status: **proposal, nothing built.** Written against Postgres because concrete
DDL argues better than prose; the Convex mapping is at the bottom and the model
survives either choice.

Changed since v0.1: the general-purpose observation log is gone from the core
model, replaced by a narrow price/status series. Search sightings are now a
write path, with explicit and deliberately narrow permissions.

---

## The one assumption everything rests on

**A listing is identified by the Facebook photo ID of its cover image.**

This is forced on us. Mobile feed cards carry no listing ID — WebLite resolves
taps to opaque server-side tokens, so the client is never told which listing a
card is. The photo FBID, pulled from the middle segment of the fbcdn filename,
is the only stable thing a card has, and it joins across surfaces (9 verified
joins, mobile ↔ web).

So `cover_photo_fbid` is the primary natural key and carries a `UNIQUE`
constraint. `fb_listing_id` is a *nullable enrichment* we get later, if ever.
That inverts the obvious design, and it's why the rest of this looks the way it
does.

We're assuming a photo FBID is never reused across two listings. One thing
still needs verifying: that a feed card's photo is always the item page's
*first* photo. See open questions.

---

## How data gets in

Two write paths, with very different privileges.

**Detail open** — the user taps a listing, we load its item page. This is the
authoritative path. It can write every field, and it sets `detail_fetched_at`.

**Search sighting** — cards observed while scrolling a feed, batched and sent
fire-and-forget, one request per feed page. It creates rows for listings nobody
has opened yet, and it monitors the two fields that actually change. It is
sharply limited in what it may touch.

The governing rule, which every write must satisfy:

> **A sighting can never reduce what we know.**

Concretely:

| Field group | Search sighting | Detail open |
|---|---|---|
| `last_seen_at` | write | write |
| `price_minor`, `status` | **write** — these are what it's for | write |
| Append to `listing_changes` | write | write |
| `city`, `title` | fill only if `NULL` | write |
| Description, photos, condition, dimensions | **never** | write |
| Seller name, rating, joined | **never** | write |
| `fb_listing_id` | **never** — cards have none | write when observed |
| `detail_fetched_at` | **never** | set |
| Row creation | yes, skeletal | yes |

A row created by a sighting has `detail_fetched_at IS NULL`. That flag is
load-bearing in three places: the UI knows not to promise details it doesn't
have, enrichment lookups can distinguish "never heard of this" from "seen it,
know nothing about it", and it doubles as a work queue.

The invariant is enforced in the statement itself rather than in application
logic, so it can't be forgotten:

```sql
-- SIGHTING: volatile fields overwrite, descriptive fields only fill nulls,
-- and the columns that must never regress simply aren't in the SET list.
INSERT INTO listings (id, cover_photo_fbid, title, title_truncated,
                      price_minor, price_currency, status, city,
                      first_seen_at, last_seen_at)
VALUES (…)
ON CONFLICT (cover_photo_fbid) DO UPDATE SET
  last_seen_at = EXCLUDED.last_seen_at,
  price_minor  = EXCLUDED.price_minor,
  status       = EXCLUDED.status,
  title        = COALESCE(listings.title, EXCLUDED.title),
  city         = COALESCE(listings.city, EXCLUDED.city),
  updated_at   = now();

-- DETAIL OPEN: everything, unconditionally.
INSERT INTO listings (…) VALUES (…)
ON CONFLICT (cover_photo_fbid) DO UPDATE SET
  title = EXCLUDED.title, description = EXCLUDED.description,
  condition = EXCLUDED.condition, seller_name = EXCLUDED.seller_name,
  fb_listing_id = COALESCE(EXCLUDED.fb_listing_id, listings.fb_listing_id),
  detail_fetched_at = EXCLUDED.detail_fetched_at,
  …;
```

Note `title` on the sighting path: a card title is truncated, so it's only ever
a placeholder for a row that has no title at all. `title_truncated` records
which kind we're holding, and the detail path always replaces it.

---

## Tables

### `listings`

```sql
CREATE TABLE listings (
  id                    uuid PRIMARY KEY,          -- UUIDv7
  cover_photo_fbid      text NOT NULL UNIQUE,      -- natural key; see above

  fb_listing_id         text UNIQUE,
  fb_listing_id_source  text,                      -- 'observed' | 'matched'
  fb_listing_id_conf    real,                      -- 0..1, only for 'matched'

  title                 text,
  title_truncated       bool NOT NULL DEFAULT false,
  description           text,
  condition             text,
  dimensions            text,
  category_path         text[],                    -- ordered breadcrumb

  price_minor           bigint,                    -- integer minor units
  price_currency        char(3),
  was_price_minor       bigint,
  price_changed_at      timestamptz,               -- derived cache
  delivery              text,                      -- 'local'|'shipping'|'both'

  status                text NOT NULL DEFAULT 'unknown',
  status_raw            text,
  status_changed_at     timestamptz,               -- derived cache

  city                  text,
  region                text,
  country               text,
  approx_lat            double precision,
  approx_lon            double precision,

  seller_id             uuid REFERENCES sellers(id),
  seller_name           text,                      -- first name only; FB redacts
  seller_rating         real,
  seller_rating_count   int,
  seller_joined_raw     text,

  listed_at_raw         text,                      -- "Listed 5 weeks ago"
  listed_at_est         timestamptz,
  listed_at_precision   text,                      -- 'day'|'week'|'month'

  first_seen_at         timestamptz NOT NULL,      -- first sighting or open
  last_seen_at          timestamptz NOT NULL,
  detail_fetched_at     timestamptz,               -- NULL = skeletal row
  detail_surface        text,                      -- 'mobile'|'web'|'both'

  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON listings (fb_listing_id);
CREATE INDEX ON listings (approx_lat, approx_lon);
CREATE INDEX ON listings (status, last_seen_at);
CREATE INDEX ON listings (detail_fetched_at) WHERE detail_fetched_at IS NULL;
```

`price_changed_at` and `status_changed_at` are denormalised from
`listing_changes` so that rendering a feed never joins it. They're caches, not
the record.

### `listing_changes`

The price and status series. One row per observation where either value
differed from what we held, plus a seed row when the listing is first recorded.

```sql
CREATE TABLE listing_changes (
  id              uuid PRIMARY KEY,                -- UUIDv7
  listing_id      uuid NOT NULL REFERENCES listings(id) ON DELETE CASCADE,

  observed_at     timestamptz NOT NULL,            -- device clock, untrusted
  recorded_at     timestamptz NOT NULL DEFAULT now(),

  price_minor     bigint,
  price_currency  char(3),
  status          text NOT NULL,
  status_raw      text,

  changed         text[] NOT NULL,                 -- {initial}|{price}|{status}|{price,status}
  source_surface  text NOT NULL,                   -- 'mobile'|'web'
  source_page     text NOT NULL,                   -- 'search'|'browse'|'item'
  device_id       uuid
);

CREATE INDEX ON listing_changes (listing_id, observed_at DESC);
CREATE INDEX ON listing_changes (observed_at DESC) WHERE 'price' = ANY(changed);
```

Each row is a **snapshot of both fields**, not a `(field, old, new)` triple.
That keeps prices as `bigint` rather than coercing to text, records a
simultaneous price-and-status change as one row, and makes "price over time" a
plain column select. The `changed` array turns "recent price drops" into an
index scan instead of a self-join against the preceding row.

Most rows will come from sightings rather than detail opens, which is the point
— taps happen once per listing, scrolls repeat. The app restoring the last
search on launch means every cold start re-observes a feed, which is a
repeat-observation engine we get for free.

### `listing_media`

```sql
CREATE TABLE listing_media (
  id             uuid PRIMARY KEY,
  listing_id     uuid NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  fb_photo_id    text NOT NULL,
  kind           text NOT NULL DEFAULT 'photo',    -- 'photo' | 'video'
  position       int,                              -- 0 = cover
  last_url       text,                             -- signed, expires
  last_url_at    timestamptz,
  first_seen_at  timestamptz NOT NULL,
  last_seen_at   timestamptz NOT NULL,
  UNIQUE (listing_id, fb_photo_id)
);
```

Written only by the detail path — item pages carry 24–29 photos, cards carry
one. `last_url` is nearly worthless long-term because fbcdn URLs are signed and
expire; the FBID is the durable part.

### `sellers` — inferred, low confidence

```sql
CREATE TABLE sellers (
  id             uuid PRIMARY KEY,
  display_name   text,                             -- first name only
  approx_lat     double precision,
  approx_lon     double precision,
  rating         real,
  rating_count   int,
  listing_count  int NOT NULL DEFAULT 0,
  confidence     real,
  first_seen_at  timestamptz NOT NULL
);
```

**There is no stable seller ID on Facebook's side.** The avatar is a shared
placeholder — byte-identical PNG for two different sellers, verified. This table
is a guess built by clustering on `(seller_name, approx_lat, approx_lon)`, and
it will produce both false merges and false splits. Build it when "more from
this seller" is actually the next feature, not before.

### `devices`

```sql
CREATE TABLE devices (
  id             uuid PRIMARY KEY,                 -- generated on the device
  first_seen_at  timestamptz NOT NULL,
  last_seen_at   timestamptz NOT NULL,
  trust_score    real NOT NULL DEFAULT 1.0,
  blocked        bool NOT NULL DEFAULT false
);
```

For abuse control and de-duplication, not analytics. Must be a **random UUID
generated on first launch and stored locally** — not `identifierForVendor`, not
an advertising ID, and resettable by the user. Anything device-derived turns an
anonymous listing database into a tracking substrate, which is the opposite of
this app's posture.

---

## The two item surfaces still disagree

The detail path is authoritative, but "the detail path" is two different pages:

| | mobile item | web item |
|---|---|---|
| Seller name / rating / joined | **yes** | no |
| Listing ID | no | **yes** |
| Condition | ~ layout-dependent, 1 of 3 | **yes** |
| Coordinates, description, photos | yes | yes |

Measured 2026-08-04. Mobile item pages come in two layouts and only one renders
a Details/Condition block. The condition string is present in the raw HTML of
the pages that don't render it — but it belongs to the "Today's picks" cards at
the foot of the page, whose `aria-label`s read `"<title> for sale -
<condition>"`, sitting ~80,000 characters from the listing's own id and in zero
script tags. Reading the first HTML match would attribute a neighbour's
condition to this listing. There is no fallback: if the block isn't rendered,
mobile does not know the condition.

**So a complete detail record requires both surfaces.** Neither one is a
superset. `DetailEngine` currently uses the desktop UA, so today's flow gets
condition and the listing id and no seller data at all — and seller rating is
the "highly rated seller" signal we want.

Cost of a detail open, if we want everything: one desktop *search* load to
resolve the id via `ItemMatcher`, plus a web item page, plus a mobile item page.
Three loads. Dropping condition would take it to two; dropping seller data would
take it to two the other way. That's a product call, not a technical one.

Where both surfaces are loaded, the merge rule is: fill nulls, never overwrite a
non-null with a null. Coordinates are byte-identical across surfaces, so there
is nothing to reconcile. `detail_surface` records which page(s) fed the row.

---

## Decisions and their consequences

**Sold status is demand-driven.** It's detected by reloading the item page for
listings a user saved, so it's only reliable for listings somebody cared enough
to save. For everything else we know staleness, not sold. `status` must not be
presented as trustworthy across the whole corpus.

**Staleness is not sold.** A listing we stop seeing might be delisted, or nobody
searched that term lately. Three states: actively seen, stale (no sighting in N
days), confirmed sold. Only the third is a fact, and only via the above.

**Facebook's own listing date is coarse.** Item pages carry relative text —
"Listed 5 weeks ago", "Listed over a week ago". Never on cards. Hence three
columns: raw string, derived timestamp, and the precision of the derivation, so
nothing downstream mistakes ±3 days for a real timestamp.

**Coordinates are stored exactly as observed**, all twelve decimal places, no
rounding. That precision is spurious as geography — Facebook fuzzes it and
labels it "Location is approximate" — but load-bearing as an *identifier*: both
of one seller's listings carry byte-identical coordinates,
`37.762756347656,-122.49206542969`, while a control seller sat 9.2 km away.
Rounding for tidiness would destroy the only seller-clustering signal we have.
Store exact, display fuzzy.

**Retention.** Listings rot fast and a sold couch is worse than no couch. A
staleness sweep and a TTL on `listing_changes` belong in the model from the
start rather than retrofitted.

---

## Open questions

Ordered by how much damage a wrong guess does.

1. **Is a feed card's photo always the item page's first photo?** The entire
   identity model depends on it. Cheap to test: resolve a card to its item page
   and compare the card's FBID against photo 0.
2. **How does a sold listing present on its item page?** We've decided *where*
   to detect it; we haven't verified *what* it looks like. Badge, banner,
   redirect, 404?
3. **Do mobile *feed* cards carry condition in an `aria-label`?** A lead, not a
   finding. The related-listing cards on mobile item pages label themselves
   `"<title> for sale - <condition>"`. If search cards do the same, condition is
   available at sighting time and the matrix row for mobile search is wrong.
4. **Do listings ever contain video?** Unverified — `kind` is modelled for it
   speculatively.
5. **Can an image URL be rebuilt from an FBID?** If not, cached images need
   either a live page load or us hosting copies, and the second has
   implications worth thinking about before it's load-bearing.

Closed since v0.2:

- ~~Can a card's price differ from the item page's?~~ No — shipping-inclusive
  and promotional pricing aren't things Facebook Marketplace does. But listings
  can be **free**, so `price_minor = 0` is a valid value distinct from `NULL`,
  and any truthiness check on price would silently drop free listings.
- ~~Is `condition` on mobile item pages?~~ Only sometimes — see below.

---

## When this stops being enough

Two things were in v0.1 and were cut deliberately. Recording why, so the
reasoning survives:

**A general observation log.** Every extracted field from every page load, with
provenance, resolved into the listing row by per-field precedence rules. It was
motivated by surfaces contradicting each other — truncated card titles clobbering
good ones. Restricting sightings to volatile fields solves that far more cheaply.
Reach for the log if we ever need per-field provenance ("where did this title
come from?") or retroactive re-extraction when the parser improves.

**Quorum on writes.** With one mutable row, writes are last-writer-wins, so
anyone who extracts the endpoint from the binary can rewrite listings. Fine at
current scale; not fine at public scale. The catch is that it isn't
retroactively addable — deciding you need it in six months means needing claim
history you didn't record. `listing_changes` preserves a partial trail for the
two fields most worth attacking (price and status), which covers the most likely
abuse. If broader coverage matters, a write-only append log alongside each
upsert — never read, never joined — is cheap insurance.

---

## If we go with Convex instead

The model survives, with three changes. `listings` and `listing_changes` become
documents with a `by_photo` index on `cover_photo_fbid`; the sighting upsert
becomes a mutation, which is transactional by default and expresses the
never-regress rule in plain TypeScript rather than a careful `ON CONFLICT`
clause. `listing_media` can collapse into an array field, since it's never
queried independently.

Every ID field must be `v.string()` rather than `v.number()` — Convex numbers
are Float64 and Facebook's IDs are 16 digits, close enough to the 2^53
exact-integer ceiling that betting on it is unnecessary risk.

Geo would be the geospatial component (beta, bounding-box queries) rather than
PostGIS.
