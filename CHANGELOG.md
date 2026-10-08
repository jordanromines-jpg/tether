# Changelog

What changed in each version of Tether, newest first. The version is in the `VERSION` file and in
Tether's Info.plist; each build also carries the commit it was built from (shown as, for example,
`6.0 (573e17e)`). Versions are tagged in git as `v2.0`, `v3.0` and so on.

How to add to it: put each change under **Unreleased** as you make it, in plain words for the person
using Tether. When a version is finished, give that section its number and date, bump `VERSION`,
and tag the commit.

## Unreleased

Nothing yet.

## 6.0.1, 8 October 2026

### Fixes
- When a Mac can't show its screen, every device that connects is told why ("the lid is closed",
  "the display is asleep", Screen Recording off) instead of waiting for a picture that never
  comes, and the card always offers **Your other Macs**. Joining also retries straight away, in
  case the lid has been opened since.

## 6.0, 8 October 2026: polish pass

26 changes across connecting, touch, picture, files, other Macs and the look, each built and
tested on a Mac before shipping (and one tried and taken out again, see Picture).

### Connecting
- When a Mac can't be reached, the page says why: this device is offline, the Mac is off
  Tailscale (with when your other Macs last saw it), Tether isn't running on it, or it's paused.
- **Diagnose** lists every step between this device and the Mac, with a fix for what fails.
- Reconnects as soon as the network comes back or the page is reopened, and checks every 2 to
  10 seconds while waiting instead of backing off for longer and longer.
- The page's own files are kept for offline use, so the "can't connect" card still shows
  properly when the Mac is unreachable.

### The Mac app
- **Update now** opens its own Update Tether window with what's new and progress, and stays open.
- A notification when an update finishes or fails, and a "What's new" note on your phone after it.
- If Tether quit unexpectedly, the panel says when and offers **Report a problem**, which opens
  a pre-filled GitHub issue (nothing is sent by itself).
- The Setup Assistant finishes by itself once everything is green and a device has connected.

### Touch and typing
- A magnifier strip across the top while the pointer is in the Mac's menu bar, so small
  menu-bar icons are easy to hit.
- Two-finger scrolling keeps going after you let go and slows down, like a Mac trackpad;
  pinch-zoom is smoother.
- A ripple where a tap clicks (can be turned off).
- The key row gains ⌫ and ↩; on phones it's two rows with keys at least 44 px wide.
- **Type it on the Mac** in Clipboard types your text as keystrokes, for password managers and
  fields that block pasting.

### Toolbar
- Drag tools to reorder them in Edit toolbar.
- Labels has a new **Auto** setting (the default): labels when there's room, icons only before
  anything folds into More.

### Picture
- Auto quality doesn't send more pixels than your screen can show (a phone gets at most
  1920 px wide), which saves data.
- Tried and taken out again: a sharp extra frame when the screen goes still, and a lighter first
  picture. Measured side by side, neither made a difference (macOS's encoder already restores
  full sharpness within about half a second), so they only added data and code.

### Files and clipboard
- Uploads show speed and time left, can be cancelled, and offer **Show on Mac** when done.
- Clipboard keeps the last 10 things each way, to copy or send again. Only while the page is
  open; never saved, since clipboards hold passwords.
- Clipboard's buttons sit two to a line on phones instead of being squeezed into one row.

### Your Macs
- **Wake** a sleeping Mac from another of your Macs on the same network (Wake-on-LAN), from
  Your Macs or from the "is offline" card. Works for Macs on Ethernet with "Wake for network
  access" on; Macs using a Private Wi-Fi address can wake others but can't be woken.
- After showing only one window, reconnecting offers to go back to it.

### Look
- Lists say plainly when they're empty or couldn't load, with **Try again** where it helps
  (Windows, Files, Apps, Your Macs).
- Launch screens for iPhone and iPad when Tether is opened from the Home Screen, and an icon
  that fits Android's round and squircle shapes.
- The bottom of More shows the version, with a link to this changelog.
- The tap ripple is quicker (250 ms).

### Fixes
- Trackpad mode: the pointer drawn on the phone could drift from the Mac's real pointer, so taps
  clicked somewhere else. Quick moves no longer get lost on the Mac, and the drawn pointer goes
  back to the real one as soon as your finger pauses.
- Rotating a phone could leave the picture too low and cut off at the bottom (and taps off by
  as much). It now re-fits once the rotation has finished.

## 5.0, 7 October 2026: one-click updates and Toolbar 2.0
- **Update now** in the Mac's panel and menu updates Tether in place; Macs set up with the
  source update themselves, and `scripts/update.sh --all` updates every saved Mac.
- The update check lists what's new; the page reloads itself after an update.
- A "Tether Updater" app (`scripts/shortcut.sh updater`).
- Toolbar 2.0: every tool has a short label; a key row with ⌘ ⌥ ⌃ ⇧, esc, tab and arrows sits on
  top of the phone keyboard; More lists every tool as tiles; **Edit toolbar** to choose and
  reorder tools per device type; a short first-run tour.
- Keeps reconnecting while Tether restarts, instead of asking for a passkey.
- The Mac name in the toolbar is short ("Mac Studio", not "Jordan's Mac S…").

## 4.0, 6 to 7 October 2026: efficiency, privacy and phone upgrades
- Pauses streaming when idle (5, 15 or 30 minutes, or never) and when the page is hidden, so the
  Mac's display can sleep. With the passkey lock on, resuming asks for Face ID again.
- **View only**, enforced on the Mac. **Curtain** blacks out the Mac's own screen while you work.
- Quick actions: volume, media keys, Mission Control, sleep the display, lock, screenshot to
  your device, open a link or an app, Force Quit.
- A data meter with an optional warning, and a Battery saver quality preset.
- An activity log of sessions, device names, and passkeys you can remove per device.
- Windows: bring any window to the front, or show only that window (fitted to your phone if
  you like). Your Macs shows each Mac with a live picture and when it was last online.
- Images and formatted text on the clipboard both ways; pinned shortcuts on the toolbar.
- Files: Documents too, and upload into the folder you're browsing.
- Fixes: the picture now recovers after the Mac's display sleeps; Tailscale from the App Store
  works for the Macs list and Setup Assistant.

## 3.0, 4 October 2026: a real Mac app and a redesigned page
- A menu-bar panel: remote access on or off, your link and QR code, connected devices (with
  Disconnect), passkey lock, Start at login, Quit.
- A Setup Assistant that walks through permissions, network and your phone.
- Shortcuts: a Tether app in Applications (or wherever you like) and "Tether - <name>" viewer apps.
- A real off switch: Pause, a Quit that stays quit, and `scripts/uninstall.sh`.
- The page was redesigned: light and dark themes, one icon set, a toolbar you can move to any
  edge, tooltips, bottom sheets, first-run tips, and smooth motion (none with reduced motion).

## 2.0, 3 October 2026: Tether
- Renamed to Tether and published, with a guided setup Claude Code can run from start to finish.
- See and control a Mac from a phone, tablet or another computer, privately over Tailscale: only
  your tailnet can reach it and only your Tailscale login is allowed.
- Hardware video (HEVC or H.264) that adapts to the connection, a pointer drawn locally so it
  never lags, sound, clipboard, file transfer, fit to device, switching between Macs, and an
  optional passkey (Face ID / Touch ID) lock.

## 1.0: studio-remote
The first version, a private prototype for one Mac Studio, before this repository.
