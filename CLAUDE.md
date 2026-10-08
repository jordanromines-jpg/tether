# Tether — guide for Claude

Tether lets someone see and control a Mac from their iPhone, iPad or another computer, privately over Tailscale.
People will often open this repo in Claude Code and say something like *"set this up on my Mac"*.
Assume they are **not technical**. This file tells you how to take them from zero to working.

## Setting Tether up for someone

### 1. Ask one question first
> "Which Mac do you want to control remotely — **this Mac** (the one we're on), or **another Mac** you own?"

- **This Mac:** use `scripts/setup.sh`.
- **Another Mac:** the setup builds Tether here and installs it there over SSH.
  - **Machine name:** run `tailscale status` yourself and show them the list, so they can just pick their other Mac.
  - **Username:** that Mac's short account name, as shown in System Settings → Users & Groups on that Mac. It's often the same as this Mac's `whoami`.
  - Then run `scripts/setup.sh --remote <username>@<machine-name> --name <short-name>`. Add `--key <path>` if they already use an SSH key for it.
  - Requirements:
    - Both Macs must have the same chip type (Apple silicon or Intel); setup checks this.
    - The other Mac must be logged in at its desktop.
    - Someone must be able to click two permission switches on it, either in person or through Screen Sharing.

### 2. Run the setup script, and keep re-running it
- Start with `scripts/setup.sh --check` (read-only) so you can tell them what's ahead.
- Then run `scripts/setup.sh` (plus any `--remote` options). Each step prints `✓` when done.
- **Exit code 3 means `ACTION NEEDED`.** A step only the person can do. Relay the printed instructions in plain, friendly words, wait until they say it's done, then **run the same command again**. It skips finished steps.
- The first build takes 10–20 minutes. Run it in the background and tell them it's normal.
- **Exit code 1 means a real error.** Every error ends with a `✗` line. Read it, fix what you can, and explain the rest.
- **Build failures** keep the full log at `build/build.log`.
- **"Tether isn't answering"** means you should check `~/Library/Logs/Tether.log` on the controlled Mac.
- Re-running is cheap: the build is skipped when nothing changed.

### 3. Human-only steps you'll relay (don't try to do these for them)

| Step | What to tell them |
|---|---|
| Command Line Tools | A dialog appears. Click **Install** and wait about 5–15 minutes. If the setup instead asks them to accept Xcode's license, they run `sudo xcodebuild -license accept` in Terminal and type their own password. |
| Tailscale | Install it from tailscale.com/download/mac, open it, and sign in or create a free account. |
| Remote Login (another Mac only) | **On the other Mac:** System Settings → General → Sharing → **Remote Login** on. **On this Mac:** they run the printed `ssh-copy-id …` command in Terminal, answer `yes` if asked "continue connecting?", and type the *other* Mac's password themselves. |
| HTTPS certificates | Explain first: Tailscale publishes machine names (like `my-mac.tailXXXX.ts.net`) in a public certificate log. The names become visible but stay unreachable. Get a clear "yes" before anything is changed. They click **Enable HTTPS** at login.tailscale.com/admin/dns. You may do it for them in their browser only if they explicitly ask. |
| macOS permissions | Setup opens the **Tether Setup Assistant** window on the controlled Mac. Tell them to follow its **Permissions** step: **Open Settings** → turn on **Tether** under **Screen Recording** and **Accessibility**; the checkmarks turn green by themselves. If the window isn't showing: Tether menu-bar icon → **Setup Assistant…**. Tether lives in the Applications folder *inside their home folder*, not the main one (the assistant's **Show Tether in Finder** helps). If it was allowed before an update, remove it with **−** and add it again. macOS may also ask once to let Tether access Downloads and Desktop (for file transfer) and to show notifications; they should click **Allow**. |
| Shortcut | Setup puts a **Tether** shortcut in `/Applications` by default. Before running setup, ask: *"Setup will add a Tether shortcut to your Applications folder so you can start it again after quitting. Is Applications OK, or would you like it somewhere else (like the Desktop)?"* Pass their answer as `--shortcut-dir <folder>`, or `--no-shortcut` if they don't want one. |
| Their phone/tablet | Install Tailscale, sign in with the **same** account, open the link, then Share → **Add to Home Screen**. The Tether menu-bar icon on the Mac has **Show QR code for your phone…** |

### 4. Safety rules
- **Never** type, ask for, or store a password. They type passwords themselves, in the dialog or Terminal.
- **Never** turn on privacy permissions (Screen Recording, Accessibility) for them, including by clicking through a remote screen. macOS requires the person to do it.
- **Never** use Tailscale Funnel or anything that exposes Tether to the public internet.
- Only change Tailscale admin settings after explaining the effect and getting a yes.

### 5. Finish
When `setup.sh` prints **"✓ Tether is ready"**:
1. Give them the link.
2. Walk them through the phone steps above. The Setup Assistant's **Your phone** step shows the QR code too.
3. If they'll control it from another Mac, offer the viewer shortcut: on *that* Mac, in this repo, `scripts/shortcut.sh viewer <name or link>` makes a "Tether - <name>" app (Applications by default; pass a folder to choose).
4. Suggest they try it.
4. Point them to `SECURITY.md` if they ask how it's protected. In short: only their tailnet devices can reach it, and only their Tailscale login is allowed.

### Turning it off, or removing it
- **Pause:** click the Tether menu-bar icon and flip the **Remote access** switch. Same place to resume.
- **Quit:** **Quit Tether** stays off until they open Tether from `~/Applications` or Spotlight.
- **Start at login:** a checkbox in the same panel.
- **Shortcuts:** **Add a shortcut…** in the panel, or `scripts/shortcut.sh app [folder]`. Uninstall removes the shortcuts Tether made.
- **Remove:** `scripts/uninstall.sh` (this Mac) or `scripts/uninstall.sh <name>` (another Mac); add `--all` to delete settings and passkeys too. Confirm with them before running it.

### Updating later
- **The easy way:** **Update now** in the Tether panel on a Mac that has the source (set up with `scripts/setup.sh` on that Mac). It runs `scripts/update.sh`.
- **From Terminal:** `scripts/update.sh` (this Mac) or `scripts/update.sh --all` (this Mac and every saved Mac). Exit 1 ends with a `✗` line; the log is `~/Library/Logs/Tether-update.log` when started from the panel.
- **Another Mac:** `scripts/deploy.sh <name>` builds here and installs there. The target name was saved during setup, in `~/.config/tether/targets/`. If that Mac has Apple's developer tools, `scripts/deploy.sh <name> --self-update` (once) lets it update itself; ask before running it, since it copies the Tether signing identity to that Mac.
- `scripts/shortcut.sh updater` makes a "Tether Updater" app that runs `scripts/update.sh --all` in Terminal.

## Working on the code

- `agent/`: a Swift package with these targets:
  - `Tether`: menu-bar app (capture, encoder, input, server).
  - `TetherCore`: pure, testable logic.
  - `TetherUI`: the SwiftUI status panel and Setup Assistant. Use `ObservableObject`, not `@State`/`@Observable`: those are macros, and the Command Line Tools ship without macro plugins.
  - `Snapshots`: renders the Mac UI to PNGs, light and dark: `swift run --package-path agent Snapshots <folder>`.
  - `SelfTest`: tests. Command Line Tools ship without XCTest, so run them with `swift run --package-path agent SelfTest`.
- `web/`: the browser client. Plain ES modules, no build step. Tests: `node --test web/tests/*.test.mjs`. Design rules (colours, icons, motion, copy) are in `docs/DESIGN.md`.
- `scripts/dev.sh`: runs the agent on this Mac at `http://localhost:7400` in dev mode. Dev mode allows header-less local requests, so never use it for real installs. Use it to test the client, and don't inject input into the developer's own Mac without asking. `TETHER_DEV_PASSKEY=1` (dev mode only) turns the passkey lock on and opens enrollment at launch, for testing Face ID flows with a virtual authenticator; it writes `settings.json` and `passkeys.json` to `~/Library/Application Support/Tether`, so delete them afterwards.
- `scripts/update.sh`: pulls (fast-forward only) and reinstalls; tested by `bash scripts/tests/update.test.sh` (a throwaway repo, build and install stubbed).
- `scripts/build-app.sh`: builds `build/Tether.app`, signed with the stable identity from `scripts/setup-signing.sh`.
- `scripts/lib/install-agent.sh`: runs on the controlled Mac (locally or over SSH). It writes `~/Library/Application Support/Tether/config.json` and sets up the LaunchAgent and `tailscale serve`. The LaunchAgent restarts Tether only after a crash (`KeepAlive.SuccessfulExit = false`), so Quit stays quit. It uses only built-in macOS tools, so the controlled Mac doesn't need Apple's developer tools.
- Logs on the controlled Mac are in `~/Library/Logs/Tether.log`.
- **Changelog and versions:** every user-facing change gets a plain-words line under **Unreleased** in `CHANGELOG.md` (same copy rules as the interface). When a version ships, give that section its number and date, bump `VERSION` (stamped into Info.plist by `build-app.sh` and shown as "6.0 (commit)"), and tag the commit `vX.Y`.
- **Testing on a Mac someone uses:** prefer what can't disturb them.
  - Logic: `SelfTest`, `node --test`, `scripts/tests/update.test.sh`.
  - Layout: a mock Tether (a small Node server that serves `web/` and fakes `hello`, `/healthz`, `/peers`) and Playwright at phone, tablet and desktop sizes, light and dark.
  - Live input only into a throwaway browser window you opened yourself (a local "test bench" page that logs clicks, keys and scrolls), streamed with **Show only this window**, and only after checking that window is the target and in front. Never type into other apps, click the menu bar, turn on the curtain, or sleep or lock the Mac.
  - The display must be awake and the Mac unlocked for capture; if it's locked, stop and say so (don't try to unlock it).
  - Ask before running anything that brings a window to the front while the person may be using the Mac.

