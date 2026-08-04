# Data model — draft v0.1

What we'd store to accumulate listings across devices, so a feed card that
arrives knowing almost nothing can be enriched from what somebody else's phone
already learned.

Status: **proposal, nothing built.** Written against Postgres because concrete
DDL argues better than prose; the Convex mapping is at the bottom and the model
survives either choice. Expect this file to change as we verify the open
questions at the end.

---

## The one assumption everything rests on

**A listing is identified by the Facebook photo ID of its cover image.**

This is forced on us. Mobile feed cards carry no listing ID — WebLite resolves
taps to opaque server-side tokens, so the client is never told which listing a
card is. The photo FBID, pulled from the middle segment of the fbcdn filename,
is the only stable thing a card has, and it joins across surfaces (9 verified
joins, mobile ↔ web).

So `cover_photo_fbid` is the primary natural key, and `fb_listing_id` is a
*nullable enrichment* we get later, if ever. That inverts the obvious design and
it's the reason the rest of this looks the way it does.

Two things must be verified before building on it — both in the open questions
below: that a feed card's photo is always the item page's *first* photo, and
that a photo FBID is never reused across two listings.

---

## Tables

### `listings` — consensus, not observation

One row per listing we believe exists. Every field here is our current *best
belief*, derived from the observation log rather than written directly.

```sql
CREATE TABLE listings (
  id                    uuid PRIMARY KEY,          -- UUIDv7
  cover_photo_fbid      text NOT NULL UNIQUE,      -- natural key; see above

  -- Facebook's own id, when we manage to get one
  fb_listing_id         text UNIQUE,
  fb_listing_id_source  text,                      -- 'observed' | 'matched'
  fb_listing_id_conf    real,                      -- 0..1, only for 'matched'

  title                 text,
  title_truncated       bool NOT NULL DEFAULT false,
  description           text,
  condition             text,                      -- 'new' | 'used_like_new' | …
  dimensions            text,                      -- free-form, as published

  price_minor           bigint,                    -- integer minor units
  price_currency        char(3),                   -- ISO 4217
  was_price_minor       bigint,                    -- strikethrough price
  delivery              text,                      -- 'local' | 'shipping' | 'both'

  status                text NOT NULL DEFAULT 'unknown',
  status_raw            text,                      -- exactly what FB said

  city                  text,
  region                text,
  country               text,
  approx_lat            double precision,
  approx_lon            double precision,

  seller_id             uuid REFERENCES sellers(id),
  seller_name           text,                      -- first name only; FB redacts
  seller_rating         real,
  seller_rating_count   int,
  seller_joined_raw     text,                      -- "Joined Facebook in 2011"

  listed_at_raw         text,                      -- "Listed 5 weeks ago"
  listed_at_est         timestamptz,
  listed_at_precision   text,                      -- 'day' | 'week' | 'month'

  first_seen_at         timestamptz NOT NULL,      -- earliest device observation
  last_seen_at          timestamptz NOT NULL,
  sold_first_seen_at    timestamptz,
  observation_count     int NOT NULL DEFAULT 0,

  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON listings (fb_listing_id);
CREATE INDEX ON listings (approx_lat, approx_lon);
CREATE INDEX ON listings (status, last_seen_at);
```

### `listing_observations` — append-only claims

Every field a device extracted, on one page load, with provenance. Never
updated, never deleted except by retention.

```sql
CREATE TABLE listing_observations (
  id                uuid PRIMARY KEY,              -- UUIDv7
  listing_id        uuid NOT NULL REFERENCES listings(id),
  cover_photo_fbid  text NOT NULL,

  observed_at       timestamptz NOT NULL,          -- device clock, untrusted
  received_at       timestamptz NOT NULL DEFAULT now(),
  device_id         uuid NOT NULL,
  app_version       text,

  surface           text NOT NULL,                 -- 'mobile' | 'web'
  page_type         text NOT NULL,                 -- 'search' | 'browse' | 'item'
  layout_variant    text,                          -- which lottery draw

  -- the claimed payload; all nullable, shape mirrors `listings`
  fb_listing_id     text,
  title             text,
  price_minor       bigint,
  status_raw        text,
  approx_lat        double precision,
  approx_lon        double precision,
  seller_name       text,
  -- …

  raw               jsonb NOT NULL                 -- everything, verbatim
);

CREATE INDEX ON listing_observations (listing_id, observed_at DESC);
CREATE INDEX ON listing_observations (device_id, received_at DESC);
```

`raw` matters more than it looks. Our extraction logic has changed repeatedly
and will again — keeping the source payload means we can re-derive fields
retroactively instead of needing users to revisit listings.

### `listing_media`

```sql
CREATE TABLE listing_media (
  id             uuid PRIMARY KEY,
  listing_id     uuid NOT NULL REFERENCES listings(id),
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

You were right to want this separate. Item pages carry 24–29 photos; that's not
an array column. Note `last_url` is nearly worthless long-term — fbcdn URLs are
signed and expire. The FBID is the durable part.

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

Flagging this hard: **there is no stable seller ID on Facebook's side.** The
avatar is a shared placeholder — byte-identical PNG for two different sellers,
verified. So this table is a guess, built by clustering on `(seller_name,
approx_lat, approx_lon)`, and it will produce both false merges and false
splits. Build it only when the "more from this seller" feature is actually next.

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

This exists for abuse control and quorum de-duplication, not analytics. It must
be a **random UUID generated on first launch and stored locally** — not
`identifierForVendor`, not an advertising ID, and the user should be able to
reset it. Anything device-derived turns an anonymous listing database into a
tracking substrate, which is the opposite of the app's whole posture.

---

## Where I'm pushing back

**Observations belong in their own table, not as columns on the listing.**
This is the big one. You described `last_updated_at`, `updated_by_device_id`,
and an update source as listing fields — but the surfaces disagree with each
other in ways that make a single mutable row lossy. Mobile search titles are
truncated and web search titles aren't; only mobile item pages have a seller
name; only item pages have coordinates. If a mobile card overwrites a good web
title, we've destroyed data we already paid for. `ListingStore.fillGaps` already
fights exactly this locally.

Splitting it buys three things nearly free: price history, "when did we first
see it sold" (`min(observed_at) WHERE status='sold'` — you asked for this
directly), and the quorum defence against forged writes, which needs multiple
independent claims to compare anyway.

**`status` should be an enum *and* a raw string.** You wanted to avoid an enum
for language reasons — I'd do both instead. Normalise to
`listed | pending | sold | removed | unknown`, and keep `status_raw` as whatever
Facebook literally said. Unrecognised strings land in `unknown` and accumulate
in `status_raw`, which gives us a corpus to expand the mapping from. Avoiding
the enum entirely means every query does string matching against text in
languages we haven't seen.

**Price as integer minor units plus a currency code.** Not a float, not the
formatted string. Also worth capturing `was_price` — the strikethrough is
already in the DOM and price drops are exactly the signal a "watch this" feature
would want.

**Category is a breadcrumb, not tags.** Item pages give an ordered hierarchy
("Plants & Seeds", "Desks"), which is different from a free-form tag set. I'd
store the raw path and normalise separately, rather than flattening both into
one array and losing the ordering.

**`created_at` and `first_seen_at` are worth keeping separate, but not for the
reason given.** In the normal case they're the same instant — we create the row
the moment a device first reports it. The real distinction is that
`first_seen_at` comes from the *device's* clock and can precede `created_at` if
a device batches uploads or was offline, and device clocks are attacker-
controlled. So: `first_seen_at` for product logic, `created_at` for anything
that needs to be monotonic and trustworthy.

---

## Answers to the questions you raised

**Can we see when Facebook actually created the listing?** Yes, approximately.
Item pages on both surfaces carry relative text — "Listed 5 weeks ago", "Listed
over a week ago". That's coarse and it's item-page-only, so it never appears on
feed cards. Hence three columns: the raw string, a derived timestamp, and the
precision of that derivation, so nothing downstream mistakes ±3 days for a real
timestamp.

**Should we store when we first saw it sold?** Yes — and with an observation log
it's free rather than a column to maintain. But note it's *first observed sold*,
not *sold at*. We only find out when somebody happens to revisit the listing.

**Should lat/long be stored directly?** Yes, two `double precision` columns,
**stored exactly as observed** — all twelve decimal places, no rounding. That
precision is spurious as geography (Facebook fuzzes it, and labels it "Location
is approximate"), but it's load-bearing as an *identifier*: both of Trevor's
listings carry byte-identical coordinates, `37.762756347656,-122.49206542969`,
while a control seller sat 9.2 km away. Rounding for tidiness would destroy the
only seller-clustering signal we have. Store exact, display fuzzy.

---

## Things the model needs that weren't on your list

- **`delivery`** — shipping listings are mixed into both surfaces and you've
  said they're mostly not what users want. Needs to be a filterable field, not
  something we infer from a price string at render time.
- **`layout_variant` on observations** — records which draw of the layout
  lottery produced a claim. It explains why city is missing from a whole class
  of observations, and it's how we'd notice if the variant distribution shifts.
- **Staleness as distinct from sold.** A listing we stop seeing isn't sold — it
  might be delisted, or nobody's searched that term lately. Three states:
  actively seen, stale (no observation in N days), confirmed sold. Only the
  third is a fact.
- **Retention.** Listings rot fast and a sold couch is worse than no couch. A
  TTL on observations and a staleness sweep on listings should be in the model
  from the start rather than retrofitted.

---

## Open questions

Ordered by how much damage a wrong guess does.

1. **Is a feed card's photo always the item page's first photo?** The whole
   identity model depends on it. Cheap to test: resolve a card to its item page
   and compare the card's FBID against photo 0.
2. **Is a photo FBID ever reused across listings?** If a seller relists, do we
   get a new FBID or the old one? Determines whether `UNIQUE` on
   `cover_photo_fbid` is correct or actively harmful.
3. **How does a sold listing present?** Does it show a "Sold" badge, 404, or
   just quietly leave search results? If it's the third, `status = 'sold'` is
   largely unobservable and we're really modelling staleness.
4. **Is `condition` on mobile item pages?** Still the `?` in the README matrix.
   Decides whether one surface can serve a complete detail record.
5. **Do listings ever contain video?** Unverified — `kind` is modelled for it
   speculatively.
6. **Can an image URL be rebuilt from an FBID?** If not, cached images need
   either a live page load or us hosting copies, and the second has
   implications worth thinking about before it's load-bearing.

---

## If we go with Convex instead

The model survives, with three changes. `listings` and `listing_observations`
become documents with a `by_photo` index on `cover_photo_fbid`; the consensus
recompute becomes a mutation, which is transactional by default and therefore
simpler than the Postgres version. `listing_media` can stay a table or collapse
into an array field on the listing, since it's never queried independently. And
every ID field must be `v.string()` rather than `v.number()` — Convex numbers
are Float64 and Facebook's IDs are 16 digits, which is close enough to the
2^53 exact-integer ceiling that betting on it is unnecessary risk.

The geo index would be the geospatial component (beta, bounding-box queries),
rather than PostGIS.
