# QuotaBar

A native macOS menu-bar app that tracks your AI subscription quotas and API spend, and tells
you which account to use next.

| Source | What it shows | How it signs in |
|---|---|---|
| Claude (Pro/Max) | 5-hour session, weekly, weekly Opus/Sonnet, extra usage | Reuses the Claude Code login in your Keychain (read-only, never refreshed) |
| ChatGPT · Codex | 5-hour and weekly limits, credits | Reuses `~/.codex/auth.json`; falls back to the latest Codex session log |
| GLM · Z.ai Coding Plan | Prompt and tool-call quotas | Z.ai API key (Settings → Accounts) |
| Kimi Code | 5-hour, weekly and monthly limits | Kimi Code API key (Settings → Accounts) |
| MiniMax Coding Plan | 5-hour and weekly prompt quotas | Coding Plan key `sk-cp-…` (Settings → Accounts) |
| Cursor | Included usage per billing cycle, Auto/named split, on-demand spend | Reuses the Cursor app's login (read-only) |
| Grok · SuperGrok | Credit usage per period | Reuses `grok login` from `~/.grok/auth.json` (read-only) |
| Anthropic / OpenAI API | Month-to-date spend, budget, projection | Organisation **admin** key (optional) |

## Recommendation

Subscription quota is use-it-or-lose-it. QuotaBar ranks accounts by remaining long-window
quota weighted by how close that window is to resetting, penalises accounts whose session
window is nearly empty, and excludes any that hit a cap. It also warns when your burn rate
will exhaust a window before it resets, and when API spend is on pace to pass its budget.

Each bar has a tick for "even pace": if the fill is past the tick you are using quota faster
than the window refills.

## Now: next reset and agents

The Dashboard opens with a ring counting down to the soonest weekly (or longer) reset that frees
something, and the resets after it; 5-hour session windows are left out. Below it, a bubble per project shows which coding agents (Claude Code, Codex,
Cursor Agent, Gemini, OpenCode, Aider…) are running where: area follows how many agents are there
and how busy they are, and each dot on the rim is one agent, solid while working (its process tree
is using CPU) and hollow while it waits at a prompt. Worktrees fold into their repository, and a
Claude session is matched to its account by `CLAUDE_CONFIG_DIR` (or to GLM/Kimi/MiniMax by
`ANTHROPIC_BASE_URL`). The process table is read with libproc every 3s, only while a view showing
agents is open.

## Build

```bash
open QuotaBar.xcodeproj            # Xcode: QuotaBar scheme, ⌘R to run, ⌘U for tests
swift build && swift test          # or plain SwiftPM
./scripts/build-app.sh --install   # release .app into ~/Applications and launch it
.build/debug/QuotaBar --dump       # fetch once and print every account + the advice
.build/debug/QuotaBar --snapshot /tmp/qb.png   # render the dropdown, Dashboard and Settings to PNGs
.build/debug/QuotaBar --agents                 # scan running coding agents and print them by project
```

QuotaBar lives in the menu bar and, by default, the Dock: click the Dock icon (or ⌘-Tab to it)
for the Dashboard; ⌘1 Dashboard, ⌘R refresh, ⌘, Settings. Turn the Dock icon off in Settings →
General. Regenerate the icon with `--make-icon <dir>` and `iconutil` (see `scripts/build-app.sh`).

The Xcode project uses synchronized folders, so new files under `Sources/QuotaBar` and
`Tests/QuotaBarTests` appear without editing the project. Launch at login needs the app in a
stable place, which is what `--install` is for.

Secrets (API, admin and Z.ai keys) are sealed by the Secure Enclave into
`~/Library/Application Support/QuotaBar/vault.json` and need Touch ID to open. Raw responses from
the undocumented quota endpoints are kept in `diagnostics/` beside it for debugging parsing.

None of the subscription usage endpoints (Claude, Codex, Kimi, MiniMax, Cursor, Grok) are public APIs. If one changes shape, that card
shows the error and the rest of the app keeps working.
