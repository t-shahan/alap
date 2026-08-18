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

## Reading the output

`postH` is the document height AFTER any scale is applied. It is the number
the app must be handed. `documentElement.scrollHeight` already accounts for
`zoom`, which is exactly the trap that produced the clipping bug — multiplying
it by the scale a second time silently discards a quarter of the message.

## Requirements

Postgres running with the `mailapp` database. Reads message bodies directly;
it does not need the app, zero-cache, or the sync daemon.
