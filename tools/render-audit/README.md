# render-audit

Renders real stored messages in a headless `WKWebView` and reports what the
reading pane will actually do with them.

## Why this exists

Three rendering regressions shipped in one afternoon — messages clipped to 74%
of their height, 75% of mail silently shrunk, and 38% of it rendered as light
grey text on a white background — and every one of them passed a full unit
test suite. Unit tests cannot see a layout. Nothing here is testable by
asserting on strings.

This harness is the missing half of that loop. It builds the document exactly
as the app does (`build_doc.py` parses the CSS out of `MessageWebView.swift`
rather than copying it, so the two cannot drift), renders it at a given pane
width, and measures what came out.

## Usage

    python3 tools/render-audit/sweep.py <pane-width-pt> <message-count>

`<pane-width-pt>` is the width the WEB VIEW gets, not the window: subtract the
sidebar, the message list, and any horizontal padding around the message.

Writes PNGs and a `res<width>.json` beside them, and prints:

  * how many messages overflow the pane, and the scale they are reduced to
  * images present, loaded, and missing a source entirely
  * text blocks whose contrast against their own background is under 2:1

`render` is not checked in. Build it once, and again after editing
`render.swift`:

    swiftc -O tools/render-audit/render.swift -o tools/render-audit/render

### Targeted mode

    python3 tools/render-audit/sweep.py 685 5 --subject "Rainier Arms"

Renders the newest messages whose subject contains that text instead of the
newest N overall. Newest-first is right for measuring a population and useless
for reproducing one message: a layout bug that only appears in a product-grid
template falls off the front of the list within a day.

## Named regressions

`cases.py` holds assertions about two specific messages, run as part of
`--check`. They exist because the sweep measures rates, and a rate cannot see a
regression that ruins one *kind* of message — two product grids in a sample of
thirty will not move any threshold far enough to trip it.

  * **Back in Stock & Ready to Go at Rainier Arms** — a product grid whose
    column widths live in a `<style>` block. Strip the stylesheet and it
    renders one product per row at 10,863px instead of two columns at ~6,926px.
    Checked geometrically: find the repeated tile (the modal image width, 130px
    here, 16 of them), then count horizontal bands holding two or more tiles
    side by side. Document height is checked too, but only as corroboration — a
    message can get shorter for bad reasons.
  * **Taylor, revisit your memories in Google Photos** — ships two "See your
    photos" buttons, one desktop-only. Without the stylesheet both render and
    overlap. Asserted on how many are VISIBLE, never on how many are in the
    DOM: hiding the duplicate rather than deleting it is a correct fix.

A named message that is not in this database is skipped, not failed — these are
one developer's mail, and a gate that fails on a fresh database is a gate people
route around.

Both messages are stored *sanitised* (`store.cpp` writes
`html::sanitize(...).html`), so fixing the sanitiser does not fix these rows on
its own. The affected messages have to be fetched again before the stylesheet is
back in the stored body, and until then these checks fail — correctly, because
the reading pane really would render the broken layout.

## Reading the output

`postH` is the document height AFTER any scale is applied. It is the number
the app must be handed. `documentElement.scrollHeight` already accounts for
`zoom`, which is exactly the trap that produced the clipping bug — multiplying
it by the scale a second time silently discards a quarter of the message.

## Requirements

Postgres running with the `mailapp` database. Reads message bodies directly;
it does not need the app, zero-cache, or the sync daemon.

## The 600px mail breakpoint

Every sweep now reports which side of `max-width: 600px` the pane width lands
on, and `--check` says so again on the way out when it is the mobile side.

This matters because a media query matches the **viewport**, and the viewport
here is the web view rather than the window. The four widths this harness
measures — 557 / 645 / 685 / 700 — straddle the line that marketing mail almost
universally switches layouts at, so at 557 a message renders its *phone* layout
and at 645 and up its desktop one.

That is not obviously wrong: a 557pt column genuinely is phone-shaped, and
rendering the layout the sender designed for that width beats scaling a desktop
layout down. But it is a layout threshold nobody in this codebase chose, and it
means **a message that renders correctly at 685 says nothing about 557.**
Measure the corpus at both:

```sh
python3 sweep.py 557 30 --check
python3 sweep.py 685 30 --check
```

The `viewport under 600px` line is a cross-check on the same fact, measured
inside the document rather than assumed from the argument — if the two ever
disagree, the harness and the app are rendering at different widths and every
other number in the report is unattributable.
