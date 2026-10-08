# Security model

Tether gives full control of a Mac, so it is built to be reachable **only by you, only over your Tailscale network**.

## Who can connect

1. **Network: only devices in your tailnet.** The agent listens on `127.0.0.1` only. `tailscale serve` publishes it at `https://<machine>.<tailnet>.ts.net`, which resolves to a private `100.x` Tailscale address. The public internet can't reach that address, so a leaked link alone gets nobody anything. Tailscale Funnel (public exposure) is never used.
2. **Identity: only allowlisted Tailscale logins.** For every request, `tailscale serve` adds the caller's verified identity (`Tailscale-User-Login`), derived from the device's WireGuard key. Browsers can't forge it. The agent refuses any request whose login isn't in `TETHER_ALLOWED_LOGINS`, which defaults to the login that installed it, and returns `403`. Tagged devices carry no user login and are refused.
3. **Optional passkey lock.** When enabled from the menu bar, a browser must also pass a Face ID / Touch ID passkey check. That gives it a signed 12-hour session cookie, required for the screen, input, uploads and file access.

## What that means in practice

- **Any of your signed-in devices counts as you.** If a device is lost, remove it in the Tailscale admin console (Machines → the device → Remove) to cut off access immediately. Turning on the passkey lock adds a second factor.
- **Sharing the machine in Tailscale doesn't grant control.** Other users would get `403` unless you add their login to the allowlist.
- **Local software on the host can bypass the identity check.** It can talk to `127.0.0.1` and fake the header. That isn't a new risk: software already running as you on that Mac can control it anyway.
- **HTTPS certificates publish the machine name.** Tailscale HTTPS certificates are recorded in public Certificate Transparency logs, so `<machine>.<tailnet>.ts.net` becomes publicly visible. It still isn't reachable. Pick a generic machine name if that matters to you.
- **macOS permissions.** Screen Recording and Accessibility are granted to the `com.tether.agent` app by you, in System Settings. The app is signed with a self-signed identity kept in a dedicated keychain on the build Mac, so the grants survive updates.
- **Uploads and downloads are sandboxed.** Browsing, downloads and uploads are limited to `~/Downloads`, `~/Desktop` and `~/Documents` (each only once macOS has allowed Tether that folder), and paths are checked so they can't escape them, through `..` or symlinks. **Show on Mac** after an upload selects the file in Finder through the same check, and is refused in view only.

- **View only is enforced by the Mac.** A device in view-only mode can watch, but the Mac ignores its clicks, typing, clipboard pastes and actions, not just its browser.
- **Curtain mode is for privacy, not access control.** It blacks out the Mac's own screen so people in the room can't see what you're doing. The Mac's keyboard and mouse keep working, and pressing ⌃⌥⌘ Return on that keyboard lifts the curtain. Keys sent remotely can't lift it: Tether marks every event it injects and the escape check ignores marked keys.
- **Idle and background pauses end the session.** When a device pauses (no interaction for the chosen time, or the page goes out of sight), it disconnects. If the passkey lock is on, it also discards its unlock, so resuming asks for Face ID or Touch ID again.

- **Removing one passkey signs every device out.** Sessions are signed with a secret that changes when a passkey is removed, so the removed device can't keep using its unlock; the others unlock again with Face ID.
- **Quick actions are limited.** "Open a link" only opens `http`/`https` links. "Open an app" only opens apps from the standard Applications folders that the Mac itself listed. Uploads can go into Downloads, Desktop or Documents (the folder you're browsing) and nowhere else.
- **Activity log.** The Mac keeps the last 500 sessions (login, device name, start, end) in `~/Library/Application Support/Tether/activity.json`. `scripts/uninstall.sh --all` deletes it.
- **Update check.** Once a day the Mac asks `api.github.com` how the commit it was built from compares with `main` of the repo it was built from (to list what's new). It sends nothing about you or your Mac beyond the request itself. Untick **Check for updates** in the panel to stop it.
- **Updating.** Nothing is installed automatically. **Update now** runs only when someone clicks it in the Mac's own panel or menu; a connected phone or computer can't start it. `scripts/update.sh` only fast-forwards `main` from the repo Tether was built from, refuses a copy with uncommitted changes or commits of its own, and rebuilds with the same local signing identity. It runs as a one-off job under your login (`com.tether.updater`), not as root, and logs to `~/Library/Logs/Tether-update.log`.
- **Self-updating Macs.** `scripts/deploy.sh <name> --self-update` copies the Tether signing keychain (and its password file, both mode 600) to that Mac over SSH so its own builds keep the same identity. That identity can only sign code as Tether on your Macs; it isn't trusted by anyone else. `scripts/uninstall.sh <name> --all` removes the copy.

- **Screen pictures and clipboard images use the same gates as the stream.** `/thumbnail` (used by the Macs picker on your other Macs' pages) and `/clipboard/image` need your Tailscale login, and the passkey unlock when the lock is on. A passkey-locked Mac doesn't show its picture on another Mac's page. Thumbnails are limited to two a second.
- **Single-window mode** raises and, if you ask, resizes a window using Accessibility, then puts it back. It never closes or moves windows otherwise.

- **Your other Macs' pages can read a little.** `/healthz` (is it up, its name, permissions, and its network for waking) and `/peers` (which of your Macs Tailscale sees, and when it last saw each) answer pages from your own tailnet's other Macs (`https://*.<your tailnet>.ts.net`), without cookies. They still need your Tailscale login. That's how a page says "Studio went offline at 2:55 PM (seen by MacBook Pro)" and offers **Wake**.
- **Waking a Mac.** `/healthz` includes the Mac's local network (for example `192.168.1.0/24`) and, for a real hardware address, its MAC address, so your other Macs can wake it. `POST /wake?mac=…` makes the Mac send a Wake-on-LAN packet on its own network. It needs your Tailscale login like everything else, and a wake packet can only wake a machine; it carries no other command. Randomized (Private Wi-Fi) addresses aren't published.
- **Crash notes.** If Tether quit unexpectedly, the panel offers **Report a problem**, which opens a GitHub new-issue page pre-filled with the version, macOS version, the kind of crash and the top of the stack (with file names, not full paths). Nothing is sent unless you submit that page yourself.
- **Clipboard history stays in the page.** Recent clipboard items are kept in the page's memory only, never saved to storage, and are gone when the page closes. Clipboards hold passwords.

## Reporting a problem

Please open a GitHub issue. Don't include secrets, and for anything sensitive, contact the maintainer privately first.
