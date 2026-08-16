#!/usr/bin/env bash
#
# Creates a stable, self-signed code-signing identity for local development.
#
#   ./scripts/make-signing-cert.sh
#
# ## The problem this solves
#
# An ad-hoc signature (`codesign -s -`) has no stable identity: every rebuild
# produces a different code directory hash, so macOS treats each build as a
# *different application*. The Keychain item holding the OAuth refresh token has
# an ACL naming the application allowed to read it, that ACL never matches, and
# every engine rebuild triggers a fresh authorisation dialog.
#
# That has already cost this project three separate stalls, once blocking a
# ten-minute backfill mid-run, and it is also why `os.Logger` output does not
# persist for these builds.
#
# A self-signed certificate fixes it because the *designated requirement*
# derived from it is stable across rebuilds. The Keychain ACL then matches, and
# the grant sticks.
#
# ## What this is NOT
#
# This is not a substitute for a Developer ID. Gatekeeper does not trust it, so
# it does nothing for distribution — a copy of the app given to anyone else
# still will not open. It only makes local rebuilds stop re-prompting.
#
# ## Undoing it
#
#   security delete-identity -c "Mail Local Dev" ~/Library/Keychains/login.keychain-db
#
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Mail Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# NOT `find-identity -v`: -v lists only identities that chain to a trusted
# root. A self-signed certificate never does, and reports
# CSSMERR_TP_NOT_TRUSTED forever — yet codesign signs with it perfectly well.
# Trust governs whether GATEKEEPER accepts the result, not whether we can
# produce one, and Gatekeeper is a distribution concern this does not address.
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  echo "✓ signing identity already present: $IDENTITY"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ generating a self-signed code-signing certificate"
# codeSigning EKU is mandatory — codesign ignores certificates without it, and
# the failure mode is a confusing "no identity found" rather than a refusal.
# CA:false and digitalSignature keep it to exactly the one job it has.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$IDENTITY/O=Local Development" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  2>/dev/null

# Two non-obvious requirements here, both of which fail as
# "MAC verification failed during PKCS12 import (wrong password?)" — a message
# that points at exactly the wrong cause:
#
#   -legacy    OpenSSL 3 defaults to AES-256-CBC with SHA-256 for PKCS#12, and
#              macOS's Security framework cannot read that container at all.
#   a password Importing a PKCS#12 with an EMPTY password fails the same way.
#              The password protects a throwaway file that exists for the
#              length of this script, so its value is irrelevant.
readonly TRANSIT_PASSWORD="transit-only-$$"
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$TRANSIT_PASSWORD" -name "$IDENTITY"

echo "▸ importing into the login keychain"
# -A allows any application to use this KEY. That is deliberate and is not the
# credential worth protecting: it signs local development builds and nothing
# else. Without it, macOS prompts for the login keychain password on every
# single codesign invocation — which would trade one prompt for a worse one.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$TRANSIT_PASSWORD" \
  -A -T /usr/bin/codesign >/dev/null

if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  echo "▸ authorising codesign to use the key without a password prompt"
  # `import -A` sets the key's trusted-application list, but since macOS 10.12
  # there is a SECOND gate: ACL partition IDs. A key with no partition entry
  # for codesign falls back to asking for the login keychain password — on
  # every single build, which is a worse prompt than the one this whole
  # exercise set out to remove.
  #
  # This asks for the keychain password ONCE, via macOS's own dialog. The
  # password is never read, stored or passed by this script; omitting -k is
  # what makes the system prompt directly.
  echo "  (macOS will ask for your login keychain password once)"
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -l "$IDENTITY" \
    "$KEYCHAIN" >/dev/null 2>&1 || {
      echo "! could not set the partition list automatically." >&2
      echo "  Run this yourself, then rebuild:" >&2
      echo "    security set-key-partition-list -S apple-tool:,apple:,codesign: \\" >&2
      echo "      -s -l \"$IDENTITY\" \"$KEYCHAIN\"" >&2
    }

  echo "✓ $IDENTITY is ready"
  echo
  echo "  Expect ONE more \"allow access\" prompt on the next engine run: the"
  echo "  stored token's ACL still names the old ad-hoc build. Click Always"
  echo "  Allow and it will stick from then on."
else
  echo "! certificate imported but codesign does not see it as an identity" >&2
  echo "  Falling back to ad-hoc signing; builds will keep re-prompting." >&2
  exit 1
fi
