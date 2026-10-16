#!/bin/bash
# Installs the scripts, the Services menu item and (optionally) the Karabiner rule file.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/refine-anywhere" "$HOME/Library/Services"
install -m 755 "$here/bin/refine-text" "$here/bin/refine-selection" "$HOME/.local/bin/"
install -m 644 "$here/lib/common.sh" "$HOME/.local/share/refine-anywhere/common.sh"

# Small native helpers, required (the Xcode Command Line Tools provide swiftc):
#   refine-hud   the floating progress pill
#   refine-clip  fast key presses and clipboard access, plus Slack rich-text support (keeps bold, links, mentions...)
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools first:  xcode-select --install" >&2
  exit 1
fi
swiftc -O -o "$HOME/.local/bin/refine-hud" "$here/tools/refine-hud.swift"
swiftc -O -o "$HOME/.local/bin/refine-clip" "$here/tools/refine-clip.swift"

rm -rf "$HOME/Library/Services/Refine using AI.workflow"
cp -R "$here/services/Refine using AI.workflow" "$HOME/Library/Services/"
/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

kdir="$HOME/.config/karabiner/assets/complex_modifications"
if [ -d "$HOME/.config/karabiner" ]; then
  mkdir -p "$kdir"
  cp "$here/karabiner/refine-anywhere.json" "$kdir/"
  echo "Karabiner rule file copied. Enable it in Karabiner-Elements > Complex Modifications > Add predefined rule."
else
  echo "Karabiner-Elements not found; skipping the hotkey (the Services menu item still works)."
fi

command -v claude >/dev/null 2>&1 || echo "WARNING: 'claude' CLI not found on PATH. Install Claude Code and run: claude /login"

cat <<'EOF'

Installed. Remaining manual steps:
  1. claude /login                     (once, in your own terminal)
  2. System Settings > Privacy & Security > Accessibility: allow
       /Library/Application Support/org.pqrs/Karabiner-Elements/Karabiner-Console-User-Server.app
     then restart it:
       launchctl kickstart -k gui/$(id -u)/org.pqrs.service.agent.Karabiner-Console-User-Server
  3. System Settings > Keyboard > Keyboard Shortcuts > Services > Text: make sure "Refine using AI" is ticked.
EOF
