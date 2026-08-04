# Probe harness

A disposable iOS app whose only job is to run JavaScript against Facebook's
live surfaces from inside a real `WKWebView` and print what it finds. Every
finding in `docs/` was measured with this.

It exists because the questions this project keeps asking — *is this field on
this surface? does this URL shape change the markup? is that string attached to
the listing I think it is?* — can only be answered against the live site, from
the same engine the app uses. `curl` and `URLSession` get a dataless shell;
desktop Safari gets a different surface entirely.

Was `spike/` at the repo root through 2026-08-04.

## Running it

```bash
cd tools/probe && xcodegen generate
xcodebuild -project MarketplaceSpike.xcodeproj -scheme MarketplaceSpike \
  -sdk iphonesimulator -destination 'id=<UDID>' -derivedDataPath build build
xcrun simctl install <UDID> build/Build/Products/Debug-iphonesimulator/MarketplaceSpike.app
xcrun simctl launch <UDID> com.brianli101.marketplace.spike
```

Results go to the unified log and to an on-screen console. Read them with:

```bash
xcrun simctl spawn <UDID> log show --last 3m --style compact \
  --predicate 'eventMessage CONTAINS "SPIKE|"' | grep -v "log run noninteractively"
```

## Three ways the log will lie to you

All three have cost real time. They are worth reading before you write a wait
loop.

**`log show` matches its own arguments.** The command line of the `log` process
is itself logged, so a predicate containing `SPIKE|` produces hits that are just
your own invocation echoed back. Filter with `grep -v "log run noninteractively"`
— filtering on `grep -v 'log show'` does *not* work, because the arguments are
printed individually quoted (`'log' 'show'`).

**A completion marker from the previous run is still in the window.** Polling
`--last 4m` for `=== DONE ===` will match the run before this one and hand you
stale results that look current. Either use a marker unique to this run, or poll
for a label only this run emits.

**A narrow predicate can exclude the marker you're waiting for.** Filtering on
`CONTAINS "HIDE"` and then waiting for `CONDPROBE COMPLETE` never terminates,
because the completion line doesn't contain `HIDE`.

## Writing a probe

`runTests()` is scratch — rewrite it per question. The durable value is the
library of JS constants below it, each of which answers something specific:

| constant | answers |
|---|---|
| `variantProbeJS` | which search layout was served, by header and city-node count |
| `ariaCoverageJS` | how many cards carry a parseable `aria-label` |
| `cardContentJS` | what a card renders vs. what it labels itself |
| `conditionProbeJS` | is condition on this page, and phrased how |
| `conditionContextJS` | what a string in the raw HTML is actually attached to |
| `hiddenConditionProbeJS` | is text in the DOM but not in `innerText` |
| `fieldDumpJS` | broad sweep of an item page's fields |
| `mobileIDHuntJS`, `deepIDHuntJS`, `fiberHuntJS` | is a listing id anywhere — DOM, attributes, React internals |
| `domShapeJS`, `cardStructureJS` | what the markup looks like, for designing selectors |
| `touchScrollJS`, `paginationProbeJS` | does this gesture paginate |

Before recording a result — especially a negative one — read
`docs/probe-checklist.md`. Its four rules were each written after this harness
produced a confident wrong answer.

Note the card selector here matches any `fbcdn` URL, while the app's
`__mpIsListingPhoto` also requires `scontent` and rejects `rsrc.php`. So in this
harness **`cards[0]` is the Facebook wordmark**, not a listing. Sample from
index 1, and print what you sampled.
