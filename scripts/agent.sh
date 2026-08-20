#!/usr/bin/env bash
#
# Installs, removes, or reports on the login agent that keeps the local stack
# running.
#
#   ./scripts/agent.sh install
#   ./scripts/agent.sh uninstall
#   ./scripts/agent.sh status
#
# ## What it is for
#
# The sidecar and zero-cache have to be up before the app shows anything, and
# `make dev` holds them in a terminal window that has to stay open. This hands
# that job to launchd — the same mechanism that already starts Postgres, which
# Homebrew installed the same way.
#
# Postgres is deliberately NOT managed here. Homebrew owns its agent already,
# and two agents starting the same cluster is a race with no upside.
#
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="$PWD"
LABEL="app.alap.services"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$REPO/.data/services.log"

ok()   { printf '  ✓ %s\n' "$1"; }
info() { printf '  %s\n' "$1"; }

# launchctl grew a new verb set; bootstrap/bootout are the supported ones and
# load/unload are deprecated but still work. Try the new form and fall back,
# because the failure mode of guessing wrong is a job that silently never runs.
agent_load() {
  launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null ||
    launchctl load -w "$PLIST"
}

agent_unload() {
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null ||
    launchctl unload -w "$PLIST" 2>/dev/null ||
    true
}

case "${1:-}" in
  install)
    command -v brew >/dev/null 2>&1 || { echo "error: Homebrew required" >&2; exit 69; }
    BREW_PREFIX="$(brew --prefix)"

    mkdir -p "$HOME/Library/LaunchAgents" "$REPO/.data"

    # Unload any previous copy first: launchctl refuses to bootstrap a label
    # that is already loaded, and an install that appears to succeed while the
    # OLD plist stays live is the worst outcome here.
    [[ -f "$PLIST" ]] && agent_unload

    # PATH is baked in rather than resolved at run time. launchd gives jobs
    # /usr/bin:/bin:/usr/sbin:/sbin, which has neither npm nor pg_isready — and
    # `brew --prefix` cannot help a script that cannot find brew either.
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$REPO/scripts/agent-run.sh</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$BREW_PREFIX/opt/postgresql@18/bin:$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>LC_ALL</key><string>en_US.UTF-8</string>
    <key>LANG</key><string>en_US.UTF-8</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <!-- Restart if a service dies, but not in a tight loop when it dies at
       startup: without a throttle launchd retries ten times a second and the
       log becomes unreadable. -->
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST_EOF

    agent_load
    ok "installed $LABEL"
    info "logs: .data/services.log"
    info "the sidecar and zero-cache now start at login — no more 'make dev'"
    ;;

  uninstall)
    if [[ ! -f "$PLIST" ]]; then
      info "not installed"
      exit 0
    fi
    agent_unload
    rm -f "$PLIST"
    ok "removed $LABEL"
    info "use 'make dev' to run the stack in a terminal again"
    ;;

  status)
    if [[ ! -f "$PLIST" ]]; then
      info "agent: not installed"
    elif launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
      ok "agent: loaded"
    else
      info "agent: installed but not loaded"
    fi
    pg_isready -q 2>/dev/null       && ok "postgres" || info "postgres: down"
    lsof -ti:3000 >/dev/null 2>&1   && ok "sidecar (:3000)" || info "sidecar: down"
    lsof -ti:4848 >/dev/null 2>&1   && ok "zero-cache (:4848)" || info "zero-cache: down"
    ;;

  *)
    echo "usage: $0 {install|uninstall|status}" >&2
    exit 64
    ;;
esac
