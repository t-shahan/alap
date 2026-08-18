#!/usr/bin/env bash
#
# Signs a binary or bundle with the local development identity.
#
#   ./scripts/sign.sh <path> [more paths...]
#
# Falls back to ad-hoc when the identity is absent, so a fresh checkout still
# builds. The fallback is announced rather than silent: under ad-hoc signing the
# designated requirement is a cdhash that changes on every build, so macOS
# treats each build as a new application and re-prompts for Keychain access
# forever. That is a real cost, not a cosmetic one.
#
# Run ./scripts/make-signing-cert.sh once to create the identity.
#
set -euo pipefail

# The former name is still accepted. Switching certificates would change the
# designated requirement, which is precisely what the Keychain ACL matches on —
# so anyone who set up before the rename would be re-prompted for every stored
# credential. Not worth it to make a local certificate's label tidy.
IDENTITIES=("Alap Local Dev" "Mail Local Dev")

# Two lookups, because neither is reliable alone. `-v` lists only identities
# the system considers VALID, which a self-signed certificate is not, so it
# reports nothing here. `-p codesigning` finds it — but returns nothing at all
# when the login keychain happens to be locked, and that silence is
# indistinguishable from "no identity installed".
SIGNER="-"
for candidate in "${IDENTITIES[@]}"; do
  if security find-identity -p codesigning 2>/dev/null | grep -q "$candidate" \
     || security find-identity 2>/dev/null | grep -q "$candidate"; then
    SIGNER="$candidate"
    break
  fi
done

if [[ "$SIGNER" == "-" ]]; then
  echo "  (no local signing identity; using ad-hoc — run scripts/make-signing-cert.sh)" >&2
  echo "  every build will re-prompt for Keychain access until you do" >&2
fi

for target in "$@"; do
  [[ -e "$target" ]] || continue
  # stderr is deliberately NOT silenced. A failed --force re-sign leaves the
  # PREVIOUS signature in place, so a silenced failure reports a valid
  # signature while the build is broken. That exact bug cost a session here.
  codesign --force --sign "$SIGNER" --timestamp=none "$target"

  # Assert the OUTCOME rather than trusting the lookup above.
  #
  # The entire point of the identity is a designated requirement anchored to a
  # certificate, because that is what the Keychain ACL matches on and what lets
  # a rebuilt binary keep its access. Ad-hoc signing anchors it to a cdhash
  # instead, which changes on every build — so macOS treats each build as a new
  # application and prompts for the password again, every ten seconds, for
  # every stored credential the daemon reads.
  #
  # Checking the requirement catches that whatever the cause: a lookup that
  # came back empty, a certificate that was deleted, a keychain that was locked
  # when the build ran. Silence here was costing an afternoon at a time.
  if [[ "$SIGNER" != "-" ]]; then
    if ! codesign -d -r- "$target" 2>&1 | grep -q "certificate root"; then
      echo "error: $target was signed without a stable designated requirement." >&2
      echo "  It would re-prompt for Keychain access on every build." >&2
      echo "  Re-run scripts/make-signing-cert.sh, or unlock the login keychain." >&2
      exit 1
    fi
  fi
done
