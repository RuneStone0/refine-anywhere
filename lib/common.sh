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
hud_stop() { [ -n "$HUD_PID" ] && kill "$HUD_PID" 2>/dev/null; HUD_PID=""; return 0; }
# tell_user <message> [seconds]: brief result pill (or a notification when the pill is off/missing).
# Use a longer duration for anything the user needs to read, like errors.
tell_user() {
  if flag no-hud || ! command -v refine-hud >/dev/null 2>&1; then notify "$1"; return 0; fi
  refine-hud --flash "$1" "${2:-1.6}" </dev/null >/dev/null 2>&1 &
}
