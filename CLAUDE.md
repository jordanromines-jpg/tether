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
| macOS permissions | On the controlled Mac: System Settings → Privacy & Security → **Screen Recording** and **Accessibility** → turn on **Tether**. On this Mac, setup opens Settings plus a Finder window with Tether selected, so they can drag it into the list. Tether lives in the Applications folder *inside their home folder*, not the main one. If it was allowed before an update, remove it with **−** and add it again. macOS may also ask once to let Tether access Downloads and Desktop (for file transfer) and to show notifications; they should click **Allow**. |
| Their phone/tablet | Install Tailscale, sign in with the **same** account, open the link, then Share → **Add to Home Screen**. The Tether menu-bar icon on the Mac has **Show QR code for your phone…** |

### 4. Safety rules
- **Never** type, ask for, or store a password. They type passwords themselves, in the dialog or Terminal.
- **Never** turn on privacy permissions (Screen Recording, Accessibility) for them, including by clicking through a remote screen. macOS requires the person to do it.
- **Never** use Tailscale Funnel or anything that exposes Tether to the public internet.
- Only change Tailscale admin settings after explaining the effect and getting a yes.

### 5. Finish
When `setup.sh` prints **"✓ Tether is ready"**:
1. Give them the link.
2. Walk them through the phone steps above.
3. Suggest they try it.
4. Point them to `SECURITY.md` if they ask how it's protected. In short: only their tailnet devices can reach it, and only their Tailscale login is allowed.

### Turning it off, or removing it
- **Pause:** the Tether menu-bar icon → **Pause remote access**. Same place to resume.
- **Quit:** **Quit Tether** stays off until they open Tether from `~/Applications` or Spotlight.
- **Start at login:** a checkbox in the same menu.
- **Remove:** `scripts/uninstall.sh` (this Mac) or `scripts/uninstall.sh <name>` (another Mac); add `--all` to delete settings and passkeys too. Confirm with them before running it.

### Updating later
- **This Mac:** run `scripts/setup.sh` again.
- **Another Mac:** run `scripts/deploy.sh <name>`. The target name was saved during setup, in `~/.config/tether/targets/`.

## Working on the code

- `agent/`: a Swift package with these targets:
  - `Tether`: menu-bar app (capture, encoder, input, server).
  - `TetherCore`: pure, testable logic.
  - `SelfTest`: tests. Command Line Tools ship without XCTest, so run them with `swift run --package-path agent SelfTest`.
- `web/`: the browser client. Plain ES modules, no build step.
- `scripts/dev.sh`: runs the agent on this Mac at `http://localhost:7400` in dev mode. Dev mode allows header-less local requests, so never use it for real installs. Use it to test the client, and don't inject input into the developer's own Mac without asking.
- `scripts/build-app.sh`: builds `build/Tether.app`, signed with the stable identity from `scripts/setup-signing.sh`.
- `scripts/lib/install-agent.sh`: runs on the controlled Mac (locally or over SSH). It writes `~/Library/Application Support/Tether/config.json` and sets up the LaunchAgent and `tailscale serve`. The LaunchAgent restarts Tether only after a crash (`KeepAlive.SuccessfulExit = false`), so Quit stays quit. It uses only built-in macOS tools, so the controlled Mac doesn't need Apple's developer tools.
- Logs on the controlled Mac are in `~/Library/Logs/Tether.log`.
