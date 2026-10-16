#!/bin/bash
# Removes everything install.sh added. Does not touch your karabiner.json.
set -euo pipefail
rm -f "$HOME/.local/bin/refine-text" "$HOME/.local/bin/refine-selection" "$HOME/.local/bin/refine-hud" "$HOME/.local/bin/refine-clip"
rm -rf "$HOME/.local/share/refine-anywhere"
rm -rf "$HOME/Library/Services/Refine using AI.workflow"
rm -f "$HOME/.config/karabiner/assets/complex_modifications/refine-anywhere.json"
/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
echo "Removed. If you enabled the Karabiner rule, remove it in Karabiner-Elements > Complex Modifications."
echo "Optional leftovers: ~/.config/refine-anywhere and ~/Library/Logs/refine-anywhere.log"
