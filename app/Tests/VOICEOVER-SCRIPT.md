# VoiceOver Test Script

Manual script for a human tester. Requires a real build, a Mac, and VoiceOver
(Cmd+F5 to toggle). Nothing here can be automated — it is testing what
VoiceOver actually says, not what the code claims it says.

Before starting: System Settings > Accessibility > VoiceOver > Open VoiceOver
Utility > Verbosity, and set it to a normal/default verbosity so announcements
match what is described below. Use VO = Control+Option (the standard VoiceOver
modifier).

For each step: perform the action, then write down what VoiceOver actually
announces. Compare against "Expect." Mark PASS or FAIL. If it differs in a way
that still conveys the same information (e.g. word order), treat it as a PASS
and note the wording — the point is whether the information arrives, not
whether it matches verbatim.

---

## Flow 1 — The triage loop (navigate, archive, flag, mark unread)

Setup: launch the app with VoiceOver on, at least one account connected, and
the Inbox open with several unread conversations.

1. Press VO+Right repeatedly from the sidebar's first item until VoiceOver
   reaches the thread list.
   **Expect:** VoiceOver announces a mailbox/list context, then lands on a row
   whose announcement includes, in some order: "Unread" (if unread), the
   sender's name, the subject, the timestamp, and — if applicable — a message
   count and "has attachments." Example: *"Unread, from HelloFresh, Your order
   has shipped, 3 messages, has attachments, 2:14 PM."*
   **Also check:** does the announcement mention which ACCOUNT the message
   belongs to, if more than one account is connected? (Expected gap — see
   audit notes. Confirm whether this is still missing.)

2. Press VO+Right / VO+Left to move between rows without changing the open
   message.
   **Expect:** each row announces its own full sentence as in step 1. You
   should NOT hear five separate stops per row (name, then subject, then
   snippet, then time, as separate VO stops) — one stop, one sentence, per
   row.
   **Fail condition:** if a single row takes more than one VO-Right press to
   fully pass through, the row is not composed as one accessibility element.

3. With VoiceOver focus on a row, open the VO rotor to Actions (VO+Shift+M, or
   the Actions rotor) and look for "Select" (or "Deselect") and a flag action
   ("Flag" or "Unflag").
   **Expect:** both actions are listed and both work when triggered (VO+Space
   after selecting the action, or swipe up/down then activate). Triggering
   "Select" should be confirmed by re-reading the row: the sentence should now
   end in "...selected."
   **Fail condition:** the two gutter buttons (checkbox, flag) are not
   independently reachable as separate VO stops — this is expected and correct
   (they're intentionally folded into the row's actions). If instead you CAN
   tab to two extra unlabeled controls per row, that's a regression, not a fix.

4. Press J and K (with the list focused, not VoiceOver's own navigation) to
   move the "open" conversation, then press E to archive.
   **Expect:** the archived thread leaves the list, and if you're near the
   sidebar/toolbar afterward, the "N conversations" count updates and is
   re-announced or discoverable on next visit (VoiceOver will not auto-speak
   this in the background — check it manually via VO+Right into the count
   label). Watch for an undo banner appearing at the bottom-left — confirm
   VoiceOver can reach it and that its "Undo" and "Dismiss" controls are both
   individually announced with clear labels ("Undo", "Dismiss"), not just
   "button."

5. Press U on a read conversation to mark it unread.
   **Expect:** re-visiting the row afterward includes "Unread" in its
   announcement, i.e. the accessibility description picks up the state change
   without requiring the row to be closed and reopened.

6. Navigate to the sidebar's theme switcher (the small circle icon near the
   sync status line) and activate it once via VO+Space.
   **Expect:** BEFORE activating, VoiceOver announces what pressing it will DO
   — e.g. *"Switch to Dark appearance, button"* — not the theme you're
   currently in. AFTER activating, re-visiting the same control should now
   announce a DIFFERENT destination theme (it should never announce the theme
   you just switched to, nor repeat the same destination twice in a row).

---

## Flow 2 — Compose and send

1. From anywhere, press Cmd+N (or activate "New Message" in the sidebar).
   **Expect:** VoiceOver announces the composer opening; VO+Right should reach
   a "To" field, individually labeled (not just "text field" with no name).

2. Type a partial address into "To" and wait for suggestions to appear.
   **Expect:** VoiceOver should surface the suggestion list as reachable
   items — either an automatic announcement that suggestions appeared, or (at
   minimum) the items are reachable via VO+Right immediately after the field
   with legible name/address text. Confirm this manually; do not assume
   silence means failure if the items are reachable on the next swipe.

3. Continue to "Subject" and the message body (VO+Right through the fields).
   **Expect:** each field announces its own name ("Subject," "Cc" if visible)
   before its content. The body field, when empty, should not silently skip —
   confirm you can tell it's the body/message field and that it's editable.

4. Type a short message, then reach the "Send" button.
   **Expect:** VoiceOver announces "Send, button" (not an icon name or
   nothing). If the message has no recipient, Send should announce as
   disabled/dimmed (VoiceOver says "dimmed" or the action has no effect on
   activation).

5. Fill in a recipient and activate Send.
   **Expect:** the header's status area changes — reach it with VO+Right and
   confirm it announces something legible like "Queued" or "Sending," not a
   bare icon. If sending fails, confirm the failure state is announced with
   real text, not just a red icon.

6. While the composer is open, try tabbing/VO-navigating to the mailbox list
   and reading pane behind it.
   **Expect:** you CAN reach them — the composer is a floating panel, not a
   modal, so this is not a trap. If VoiceOver refuses to leave the composer's
   region entirely (via VO+Right endlessly cycling inside it, or Tab doing
   nothing), that is a keyboard trap and a FAIL.

7. Minimise the composer (the "–" button in its header) via keyboard/VoiceOver
   only, no mouse.
   **Expect:** the button announces "Minimise, button" beforehand; after
   activating, the panel visibly and audibly collapses to its header-only
   state, and VoiceOver does not lose focus into empty space.

---

## Flow 3 — Connect an account

1. In the sidebar, reach "Add Account" via VO navigation and activate it.
   **Expect:** clear announcement "Add Account, button" beforehand. After
   activating, a sheet titled "Connect a mailbox" should be announced —
   confirm VoiceOver reads the sheet's title, not silence.

2. While the sheet shows "Waiting for authorization in your browser…", check
   whether VoiceOver periodically re-announces this (it should NOT interrupt
   you every second/frequently — a slow, infrequent, or on-demand-only
   readout is correct; being interrupted repeatedly while you're doing
   something else is a FAIL).

3. Once syncing begins (progress bar with "N of M messages"), VO+Right onto
   the progress indicator.
   **Expect:** VoiceOver announces a percentage or fraction, not just
   "progress indicator" with no value. Confirm the value updates if you check
   back a few seconds later — but again, it should not be forcing repeated
   interruptions while your focus is elsewhere.

4. When syncing finishes, confirm the sheet's "Mailbox connected" state is
   announced along with the message count, and that a "Done" button is
   reachable and activatable via VoiceOver alone.
   **Expect:** activating "Done" (or pressing Return, since it's the default
   action) closes the sheet and returns focus somewhere sensible — the
   sidebar or the newly added account row — not to a blank region.

5. Back in the sidebar, VO-navigate to the newly connected account's row.
   **Expect:** the row announces the account's short name and, if unread mail
   exists, an unread count ("3 unread" or similar) — confirm the count is
   spoken as a real number, not "text" or silence.

6. Hover is not available to a VoiceOver-only user. With the account row
   focused, check the VO rotor's Actions menu for an "Account settings" (or
   equivalent) action.
   **Expect (this is the important check):** an action to open account
   settings (rename/recolor) should be present and should work. If NO such
   action exists in the rotor, and the only way to reach account settings is
   a mouse hover followed by a click on a small "..." glyph, that is a FAIL —
   note it explicitly, because it means account settings are entirely
   unreachable without a pointer.

7. If you do reach the account settings popover (by whatever means), VO+Right
   through the color swatch grid.
   **Expect:** each swatch announces a real color name ("Teal," "Clay," etc.),
   not "button" or a hex code. Activating one should be confirmed by the
   change taking effect (the row's dot changes when you next inspect it).

---

## Flow 4 — Bulk archive

Setup: select multiple conversations (Cmd-click several rows, or use "Select
All" in the message list toolbar) so the reading pane switches to the bulk
action view.

1. With several rows selected, VO-navigate into the reading pane.
   **Expect:** the pane announces something like "N conversations selected" as
   a real sentence, and a second line summarizing unread/flagged counts
   ("4 unread · 1 flagged" or similar) — both should be legible sentences, not
   bare numbers with no context.

2. Continue VO+Right through the list of selected conversations shown in the
   preview.
   **Expect:** EACH previewed conversation should announce as ONE unit —
   sender, subject, and time together — not as three or four separate
   unlabeled stops per conversation, and the small colored account dot next
   to each one should not produce its own silent/unlabeled stop.
   **This is a likely FAIL** — confirm carefully. If each preview row takes
   multiple VO-Right presses to get through (a stop for the dot, a stop for
   the name, a stop for the subject, a stop for the time), that is the exact
   "five sibling Text views" problem the redesign fixed elsewhere in the
   thread list, reappearing here.

3. Reach the action row (Archive, Mark read/unread, Flag/Unflag, Trash,
   Deselect).
   **Expect:** every button announces clear text ("Archive, button," "Mark
   read, button," etc.) — confirm the read/unread and flag/unflag buttons
   announce the ACTION they are about to take (matching whatever the visible
   label currently says), not a stale or generic label.

4. Activate "Archive."
   **Expect:** the selected conversations leave the list; VoiceOver's focus
   should land somewhere sensible afterward (not on a stale/removed element).
   Check whether an undo banner appears and is announced or at least
   reachable — same check as Flow 1, step 4.

5. Repeat with "Trash" on a fresh selection.
   **Expect:** same as Archive. Additionally, since Trash is presented at a
   visual distance from the other actions (by design, as the one irreversible
   bulk action), confirm VoiceOver still reaches it in a reasonable number of
   swipes and that nothing about its position makes it harder to reach by
   keyboard/VoiceOver than the reversible actions.

---

## Wrap-up checklist

After all four flows, answer yes/no:

- [ ] Did any control announce only an SF Symbol name (e.g. "archivebox,"
      "envelope open") instead of a real word?
- [ ] Did any row/list item take more VO-Right presses to pass through than a
      sighted user would need glances to read it (i.e. it's fragmented into
      too many stops)?
- [ ] Did any interactive control never receive VoiceOver focus at all, even
      though you could click it with a mouse?
- [ ] Did any live-updating text (sync status, counts) interrupt you
      repeatedly while your attention was elsewhere?
- [ ] Did you ever get stuck in a region you could not VO-navigate or Tab out
      of?

Any "yes" is a finding — note the exact control, the flow/step number, and
what was actually announced.
