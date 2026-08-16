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

SIGNER="-"
for candidate in "${IDENTITIES[@]}"; do
  if security find-identity -p codesigning 2>/dev/null | grep -q "$candidate"; then
    SIGNER="$candidate"
    break
  fi
done

if [[ "$SIGNER" == "-" ]]; then
  echo "  (no local signing identity; using ad-hoc — run scripts/make-signing-cert.sh)" >&2
fi

for target in "$@"; do
  [[ -e "$target" ]] || continue
  # stderr is deliberately NOT silenced. A failed --force re-sign leaves the
  # PREVIOUS signature in place, so a silenced failure reports a valid
  # signature while the build is broken. That exact bug cost a session here.
  codesign --force --sign "$SIGNER" --timestamp=none "$target"
done
