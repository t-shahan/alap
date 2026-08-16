#!/usr/bin/env bash
#
# Imports a Google OAuth "Desktop app" client JSON into .env.
#
#   ./scripts/import-oauth-client.sh ~/Downloads/client_secret_*.json
#
# Reads the values programmatically so the secret is never echoed to the
# terminal, pasted into a chat, or copied by hand. Prints only a masked
# confirmation.
#
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <path-to-client_secret_*.json>" >&2
  exit 64
fi

SRC="$1"
[[ -f "$SRC" ]] || { echo "error: no such file: $SRC" >&2; exit 66; }
[[ -f .env ]]   || { echo "error: .env missing — run: cp .env.example .env" >&2; exit 65; }

# Desktop-app clients nest their fields under "installed"; web clients use
# "web". Accept either so a mis-selected client type fails loudly below rather
# than silently writing empty values.
read -r CLIENT_ID CLIENT_SECRET CLIENT_TYPE <<<"$(
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
key = "installed" if "installed" in d else "web"
c = d[key]
print(c.get("client_id", ""), c.get("client_secret", ""), key)
' "$SRC"
)"

[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || {
  echo "error: could not read client_id/client_secret from $SRC" >&2; exit 65; }

if [[ "$CLIENT_TYPE" != "installed" ]]; then
  echo "warning: this looks like a '$CLIENT_TYPE' client, not a Desktop app client." >&2
  echo "         Gmail desktop auth needs a Desktop app client (loopback + PKCE)." >&2
fi

# Rewrite in place. BSD sed on macOS requires an explicit -i suffix.
sed -i '' \
  -e "s|^GOOGLE_CLIENT_ID=.*|GOOGLE_CLIENT_ID=\"$CLIENT_ID\"|" \
  -e "s|^GOOGLE_CLIENT_SECRET=.*|GOOGLE_CLIENT_SECRET=\"$CLIENT_SECRET\"|" \
  .env

echo "✓ wrote GOOGLE_CLIENT_ID     ${CLIENT_ID:0:12}…${CLIENT_ID: -24}"
echo "✓ wrote GOOGLE_CLIENT_SECRET ${CLIENT_SECRET:0:6}…  (${#CLIENT_SECRET} chars)"
echo
echo "Next: move the downloaded JSON out of ~/Downloads, or delete it —"
echo "      .env is now the single source of truth."
