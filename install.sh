#!/bin/bash
# Installs the scripts, the Services menu item and (optionally) the Karabiner rule file.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$HOME/.local/bin" "$HOME/Library/Services"
install -m 755 "$here/bin/refine-text" "$here/bin/refine-selection" "$HOME/.local/bin/"

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
