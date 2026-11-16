# Shared helpers for refine-text and refine-selection. Sourced, never executed.
#
# Optional switches are empty files in ~/.config/refine-anywhere/:
#   debug      log timings/lengths (never your text) to ~/Library/Logs/refine-anywhere.log
#   no-hud     don't show the floating "Refining…" pill (a notification is used instead)
#   no-sound   don't play the start/finish sounds
#   no-paste   diagnostics: do everything but paste, leaving the refined result on the clipboard

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
# Karabiner may start us at background priority, which makes the claude call several times slower.
taskpolicy -B -p $$ >/dev/null 2>&1
# claude needs these to find its keychain login when launched with a bare environment (Karabiner, Services).
export HOME="${HOME:-$(eval echo ~)}"
export USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}"
export TMPDIR="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}"
export LANG=en_US.UTF-8

CONF_DIR="$HOME/.config/refine-anywhere"
LOG="$HOME/Library/Logs/refine-anywhere.log"

# Optional long-lived login (output of `claude setup-token`) in ~/.config/refine-anywhere/oauth-token. It does not
# depend on the keychain session that tends to expire, so Karabiner/Services keep working without a browser login.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -s "$CONF_DIR/oauth-token" ]; then
  CLAUDE_CODE_OAUTH_TOKEN=$(tr -d '[:space:]' <"$CONF_DIR/oauth-token"); export CLAUDE_CODE_OAUTH_TOKEN
fi

flag() { [ -f "$CONF_DIR/$1" ]; }
dbg() { flag debug && echo "$(date '+%F %T') [${TAG:-refine}] $*" >>"$LOG"; return 0; }
notify() { osascript -e "display notification \"$1\" with title \"Refine Anywhere\"" >/dev/null 2>&1; }

# sound <SystemSoundName>: fire and forget.
sound() { flag no-sound || afplay "/System/Library/Sounds/$1.aiff" </dev/null >/dev/null 2>&1 & }

# Floating progress pill (see tools/refine-hud.swift). Falls back to a notification if it isn't installed.
HUD_PID=""
hud_start() {
  if flag no-hud || ! command -v refine-hud >/dev/null 2>&1; then notify "${1:-Refining…}"; return 0; fi
  refine-hud "${1:-Refining…}" </dev/null >/dev/null 2>&1 &
  HUD_PID=$!
}
hud_stop() { [ -n "$HUD_PID" ] && { kill "$HUD_PID" 2>/dev/null; wait "$HUD_PID" 2>/dev/null; }; HUD_PID=""; return 0; }
# tell_user <message> [seconds]: brief result pill (or a notification when the pill is off/missing).
# Use a longer duration for anything the user needs to read, like errors.
tell_user() {
  if flag no-hud || ! command -v refine-hud >/dev/null 2>&1; then notify "$1"; return 0; fi
  refine-hud --flash "$1" "${2:-1.6}" </dev/null >/dev/null 2>&1 &
}

# claude_logged_in: is the claude CLI signed in right now?
claude_logged_in() {
  perl -e 'alarm 20; exec @ARGV' claude auth status 2>/dev/null </dev/null | grep -q '"loggedIn": *true'
}

# sign_in: self-heal a signed-out claude. `claude auth login` opens the browser itself and exits when the login is
# done; the only manual part is approving it there. Returns 0 once signed in, 1 if it did not finish (5 min limit).
sign_in() {
  dbg "claude is signed out: starting claude auth login"
  hud_start "Claude is signed out: approve the login in your browser…"; sound Funk
  perl -e 'alarm 300; exec @ARGV' claude auth login </dev/null >/dev/null 2>&1
  hud_stop
  if claude_logged_in; then dbg "sign-in ok"; return 0; fi
  dbg "sign-in did not finish"; return 1
}

# explain_login: the automatic sign-in did not finish, so tell the user exactly how to fix it. A dialog (not a pill that
# disappears) with a button that copies the command. Gives up after a minute so it never blocks a script for long.
explain_login() {
  local btn
  btn=$(osascript <<'OSA' 2>/dev/null
try
  set r to display dialog "Refine Anywhere can't run because Claude is signed out, and the automatic sign-in did not finish." & return & return & "To fix it, open Terminal and run:" & return & "    claude auth login" & return & return & "Approve the login in your browser, then press Cmd+Shift+2 again." with title "Refine Anywhere" buttons {"OK", "Copy command"} default button "Copy command" with icon caution giving up after 90
  if button returned of r is "Copy command" then set the clipboard to "claude auth login"
  return button returned of r
end try
OSA
  )
  dbg "explain_login: $btn"
  return 0
}
