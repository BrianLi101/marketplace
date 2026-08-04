# Backend

Nothing here yet. This directory is a placeholder so the decision has somewhere
to land.

## What it will do

Accumulate listings across devices so a feed card that arrives knowing almost
nothing can be enriched from what somebody else's phone already learned. The
schema, the two write paths, and the rules that stop a search sighting from
overwriting item-page data are specified in `docs/data-model.md`.

## What's decided

- **Not tRPC.** Its whole value is TypeScript-to-TypeScript type inference and
  the client is Swift, so it would contribute nothing but a URL convention.
- **Not gRPC.** Roughly three endpoints doesn't earn HTTP/2 plumbing or a
  `protoc` step in the build.
- **Not direct database access from the app.** The app has no user identity by
  design, so there is no principal to write row-level policies against, and any
  key shipped in the binary is extractable.

## What isn't

The runtime. Two candidates, both viable:

- **Convex** — leading option. The access pattern is document-shaped (photo
  FBID → record, batch lookup, no joins worth the name), mutations are
  transactional so the never-regress rule is plain code, and live queries mean
  feed cards fill in as other devices contribute rather than on next refresh.
  Costs: Swift client is thinner than the TS one, geospatial is beta, and
  leaving is a rewrite rather than a `pg_dump`.
- **Managed Postgres + a thin API** — Neon or Supabase as the database only.
  More moving parts, no reactivity for free, but no lock-in and PostGIS is
  mature.

The deciding experiment is a half-day: stand up a dev deployment, define the
two-table schema, drive a mutation and a live subscription from a throwaway
Swift target, restart the app mid-subscription. If subscriptions reconnect
cleanly and 16-digit ids survive the round trip as strings, take Convex.

Whichever wins, store every Facebook id as a **string**. They are 16 digits,
which is close enough to the 2^53 exact-integer ceiling that betting on a
double is unnecessary risk.
