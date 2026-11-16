# AGENTS.md

Context for AI coding agents (and humans) working on **refine-anywhere**: a macOS tool that refines selected text in any app with the Claude Code CLI and pastes it back, with first-class support for Slack's rich text. See `README.md` for the user-facing description.

## ⚠️ This repository is PUBLIC

Everything committed here, including every past commit, is visible to anyone. Treat it that way.

- **Never commit** personal or employer details: real names of people, employer or internal project names, internal URLs, email addresses other than the GitHub noreply one, tokens or keys, logs, clipboard dumps or screenshots of real conversations.
- **Examples, tests and prompts must be generic.** No real names, channels, meeting titles or message text from real work. Invent neutral examples (like "Friday retro invite") and avoid personal names altogether.
- **Do a privacy scan before every push**, covering the working tree and the whole history:
  ```bash
  git log --all --format='%an <%ae> | %cn <%ce>' | sort -u          # only the GitHub noreply identity
  git grep -n -I -i -E 'gh[pousr]_[A-Za-z0-9]{20,}|sk-ant-|xox[abp]-|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|PRIVATE)' $(git rev-list --all) -- .
  git grep -n -I -i -E '<employer name>|<your local username>|<work email domain>|<names from test messages>' $(git rev-list --all) -- .
  ```
  Fill in the placeholders in the last pattern with the real strings to look for. `\b` does not work in `git grep -E` on macOS; use `(^|[^a-z])name([^a-z]|$)`.
- Check demo media (`docs/demo.gif`, `docs/demo.mp4`) for visible names, channels or message content, and check file metadata, before replacing or adding any.
- If something private reached history, rewrite it (`git filter-branch` or `git filter-repo`), delete `refs/original`, `git gc --prune=now`, force-push with `--force-with-lease`, and verify with a fresh clone. GitHub may keep old commits reachable by hash for a while.
- Commit identity: the GitHub noreply address (`<id>+RuneStone0@users.noreply.github.com`), set repo-locally. No AI co-author trailers in commits. Pushing needs the `RuneStone0` account, which may not be the default `gh` login: use a token from `gh auth token --user RuneStone0` in a one-off push URL, never stored in the repo or its git config.

## Layout

| Path | Role |
| --- | --- |
| `bin/refine-text` | stdin text to refined text via `claude -p`. Prompts, styles, retry and fallback logic. Exit codes: 0 ok, 1 claude failed, 3 cannot apply safely, 4 signed out |
| `bin/refine-selection` | Hotkey wrapper: copy, refine, paste, restore clipboard, safety guards |
| `lib/common.sh` | Shared env, flags, notifications, pill helpers, `sign_in`, `explain_login` |
| `tools/refine-clip.swift` | Native helper: key events, clipboard, Slack `slack/texty` parsing, diff and rebuild logic |
| `tools/refine-hud.swift` | Floating progress pill |
| `services/Refine using AI.workflow/` | Automator Quick Action for the Services menu |
| `karabiner/refine-anywhere.json` | Importable Karabiner rule for `Cmd+Shift+2` |
| `install.sh`, `uninstall.sh` | Compile helpers, copy files, no admin rights needed |

**Edits do not take effect until you run `./install.sh`.** The tool runs from `~/.local/bin`, `~/.local/share/refine-anywhere/` and `~/Library/Services/`, not from the repo. The Swift helpers need recompiling (the installer does it).

## Design rules (do not weaken without a good reason)

1. **Never lose the user's text.** On any failure the original stays untouched or the result goes to the clipboard.
2. **Never paste into the wrong place:** frontmost app must be unchanged, and the user must not have typed or clicked meanwhile.
3. **Never silently flatten Slack formatting.** If a rich rewrite cannot be applied faithfully, retry with the `light` style, otherwise paste nothing and leave the text on the clipboard.
4. **Mentions, smart links and URLs are protected:** they must come back exactly once and in order. Any attribute key starting with `slack`, or a link whose text equals its URL, is protected.
5. **Never output an em dash.** Enforced in the prompts and again in code (`perl` sanitizer in `refine-text`), so it holds for a custom `prompt.txt` too.
6. **Prompts and examples contain no real names** (see the privacy section).
7. **Privacy of runtime data:** debug logs record timings and lengths, never message text.

## How refinement is applied

- `full` style (default): the model rewrites freely. In Slack the message is **rebuilt** (`refine-clip render` gives the model text with `1. ` / `- ` list prefixes, `refine-clip rebuild` reconstructs runs and re-applies bold and links where their words survive, `verify-rebuild` checks protected runs).
- `light` style, custom `prompt.txt`, and the fallback: the **diff** path (`apply-diff` projects word-level changes onto single runs, then `verify`).
- Plain text and HTML paths skip the Slack logic. HTML has seen far less real-world testing.
- Signed-out claude: `refine-text` exits 4, `refine-selection` runs `sign_in` (`claude auth login` in the browser) and asks the user to re-run; if that fails a dialog explains the fix.

## Testing without breaking things

- There is no test suite. Verify by running the scripts directly with a clean environment, for example:
  ```bash
  echo "teh test" | env -i HOME="$HOME" PATH="/usr/bin:/bin" ~/.local/bin/refine-text --strict
  ```
  and with hand-written Slack ops JSON (`refine-text --ops`, `refine-clip rebuild`, `apply-diff`, `verify`). Check mentions, links and lists survive, and that dropping a mention or link makes the result get rejected (exit 3).
- `REFINE_CLAUDE` replaces the `claude` binary for offline tests; `REFINE_MODEL` and `REFINE_STYLE` override config.
- Real hotkey runs need Accessibility permission for Karabiner's helper and a human at the keyboard. Do not try to fake them with osascript keystrokes (Automation permission fails with -1743). `refine-clip trusted` is only meaningful from the Karabiner process.
- To debug a failure, `touch ~/.config/refine-anywhere/debug`, reproduce, read `~/Library/Logs/refine-anywhere.log`, then delete the flag and the log. Logging is off by default, so a failure often leaves no log: first run `claude auth status`.

## Gotchas learned the hard way

- Key events posted by a process that exits immediately are dropped: `refine-clip key` sleeps after posting.
- macOS ignores in-place `setData` on another app's clipboard: clear the pasteboard and rewrite every type. `NSStringPboardType` aliases the plain-text type.
- `claude` launched from Karabiner/Services needs `USER`, `LOGNAME` and `TMPDIR`, runs slowly at background priority (`taskpolicy -B -p $$` clears it), and is slow in a big working directory: run it from an empty temp dir with `MAX_THINKING_TOKENS=0`.
- The Services workflow must not carry `serviceApplicationBundleID`, or macOS treats it as Finder-only.
- Wrap drafts in `<draft></draft>` and tell the model to edit, never answer, or it answers messages that read like requests.
- A second synthetic Cmd+C races with the paste: use `typed-since` and `changecount` for guards instead.
- Slack's clipboard format (`org.chromium.web-custom-data` pickle with a `slack/texty` Quill-delta entry) is undocumented and can change; always keep the plain-text fallback working.

## Style

- Match the surrounding code: shell for glue, Swift for anything native, minimal comments that explain why.
- Keep the README, config table and troubleshooting section in sync with behaviour changes.
- Keep claims honest: do not state tested versions, timings or guarantees that were not measured.
