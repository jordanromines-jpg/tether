# Tether design

This is the source of truth for how Tether looks, moves and reads, in the browser client (`web/`) and the Mac app (`agent/Sources/Tether`). Change it here first, then in code.

## Read

Tether is a utility. One person uses it on their own devices, daily, often for a minute on a phone. The remote screen is the content. Everything else is chrome, and the chrome should stay quiet, fast and obvious.

- Feel: native Apple utility, calm, precise.
- Design dials: variance 3 · motion 3 · density 6.
- Motion lens: restraint first (Emil Kowalski), production polish on sheets (Jakub Krehel).

## Colour

One neutral family (cool grey) and one accent (the blue of the app icon), defined as CSS variables in `web/app.css`. The page follows the system light/dark setting.

| Token | Dark | Light | Use |
|---|---|---|---|
| `--bg` | `#0c0d10` | `#f3f4f6` | Page and the space around the remote screen |
| `--surface` | `#17181c` | `#ffffff` | Toolbar, banner, toasts |
| `--surface-raised` | `#1f2126` | `#ffffff` | Sheets, menus, cards |
| `--fill` | `rgb(255 255 255 / .06)` | `rgb(15 20 30 / .05)` | Buttons at rest, inputs |
| `--fill-strong` | `rgb(255 255 255 / .12)` | `rgb(15 20 30 / .10)` | Hover and pressed |
| `--line` | `rgb(255 255 255 / .09)` | `rgb(15 20 30 / .10)` | Hairlines and borders |
| `--text` | `#eef0f3` | `#15171c` | Body text, icons |
| `--text-muted` | `#9aa0aa` | `#5d6470` | Secondary text (6.1:1 and 5.4:1 on their surfaces) |
| `--accent` | `#3a6fd8` | `#2f63cc` | Primary buttons, selected state (white text 4.7:1 / 5.6:1) |
| `--accent-text` | `#8db0f7` | `#2f63cc` | Links and accent text on surfaces |
| `--ring` | `#6f9bf0` | `#2f63cc` | Focus ring |
| `--danger` | `#f07070` | `#c23b3b` | Errors, destructive actions |
| `--ok` / `--warn` | `#3fb37f` / `#e0a339` | `#1f8a5a` / `#b7791f` | Connection quality only |

Rules:
- No pure black or white surfaces.
- Shadows are tinted to the neutral family and used only where something floats (toolbar, sheets, menus, tooltips).
- Colour never carries meaning alone: the connection dot also has a label and a tooltip.

## Type

The system stack (`-apple-system, BlinkMacSystemFont, system-ui`), which is SF Pro on Apple devices. It is chosen on purpose: it matches iOS and macOS, works offline and needs no font download.

| Role | Size / weight |
|---|---|
| Sheet title | 17 / 600 |
| Body, buttons | 15 / 400–500 |
| Secondary, captions | 13 / 400 |
| Section label in sheets | 13 / 600, sentence case, `--text-muted` |
| Stats (fps, ms, Mbps) | `font-variant-numeric: tabular-nums` |

Inputs are at least 16px so iOS does not zoom when they get focus.

## Shape and space

- Radius: controls 10 · tooltips 8 · toolbar 18 · panels and menus 16 · sheets 20 · pills fully round.
- Spacing steps: 4 · 8 · 12 · 16 · 24.
- Touch targets are at least 44 × 44 with 2px between toolbar buttons.
- The toolbar and floating UI keep 12px from the screen edge plus the device's safe area.

## Layers

| z-index | Layer |
|---|---|
| 10 | Remote cursor |
| 20 | Toolbar, collapsed toolbar pill |
| 22 | Key row above the on-screen keyboard |
| 25 | Mac state banner |
| 30 | Status screen (connecting, paused, locked) |
| 35 | First-run tips and the toolbar tour |
| 40 | Sheets and the More menu |
| 50 | Toasts |
| 60 | Tooltips |

## Icons

[Phosphor](https://phosphoricons.com), regular weight, one family, from the sprite `web/icons.svg` (built by `scripts/make-icon-sprite.py`). Icons are 22px in the toolbar and 20px elsewhere. Modifier keys use their real key symbols (⌘ ⌥ ⌃ ⇧) because those are labels, not icons. Every icon-only button has an `aria-label` and a tooltip.

## Motion

Ask how often something happens before animating it.

| Interaction | Frequency | Motion |
|---|---|---|
| Toolbar button press | hundreds a day | `scale(.96)`, 100ms. Nothing else. |
| Keyboard input | constant | None, ever |
| Tooltip | often | 120ms fade. 300ms delay for the first one, then instant for neighbours. |
| Sheets and the More menu | daily | Enter: spring, about 240ms, 16px rise and fade. Exit: 160ms ease-out, faster than enter. |
| Toolbar snap after a drag | occasional | Spring from the drop point to the dock (bounce 0.18) |
| Connecting spinner | while waiting | `svg-spinners` ring, 0.75s per turn |
| First-run tips | once | Cross-fade between cards |
| Tour ring moving to the next button | once | 200ms ease on position and size |

Animate only `transform` and `opacity`. With `prefers-reduced-motion: reduce`, everything is instant and the spinner is replaced by a static ring. Springs come from [Anime.js](https://animejs.com) (`web/vendor/anime.esm.min.js`), which is loaded only when first needed.

## Components

- **Toolbar.** A slim grip, then the person's tools, then More. Every tool is an icon over a short label (11px, 500), 56px wide and 54px tall; **Compact** (Display and quality, or Edit toolbar) drops the labels for 44px icon buttons. All tools are defined once in `web/js/tools.js`, which the toolbar, More and Edit toolbar all read.
  - Defaults: phone Keyboard · Actions · Windows · Clipboard; iPad adds Files, Sound, Display and the connection; desktop is Actions · Windows · Clipboard · Files · Sound · Display · Full screen · connection. The device class comes from the screen's short side, so rotating keeps it.
  - The connection is the Mac icon with a quality dot, labelled with the Mac's name.
  - It docks to the top, bottom or a side; sides make it vertical (64px wide, still labelled). Tools that don't fit fold away from the end, pinned shortcuts first. Nothing scrolls, and More still lists everything.
- **Key row.** On touch screens, while typing: ⌘ ⌥ ⌃ ⇧ (sticky, double-tap to lock), esc, tab and the four arrows, sharing the width evenly, plus a hide-keyboard button. It sits on the keyboard's top edge (`visualViewport`), acts on press without taking focus, repeats held arrows, and the toolbar steps aside while it's up.
- **More.** Every tool, whether or not it's in the bar. A connection card on top (name, quality dot, live line; opens Connection), then sections (Type, Control, Transfer, View, Toolbar, Help) of labelled tiles, four across on phones. Toggles show an On or Off pill; pinned shortcuts show their keys.
- **Edit toolbar.** A switch per tool ("On" puts it in the bar), up and down buttons to reorder, a note when some don't fit this screen, Labels on or off, and Reset to default. Saved per device class.
- **Tour.** After the gesture tips, once: a ring around one real toolbar button at a time (Keyboard, Actions, Windows, More, the grip) with a card beside it, placed by the dock. Steps for buttons that aren't showing are skipped. More → Tips runs it again.
- **Tooltip.** The tool's full name plus one line on what it does. Shown on hover with a mouse and on touch-and-hold on touch screens; a touch-and-hold never fires the button. Tether adds no keyboard shortcuts of its own, since nearly every key goes to the Mac.
- **Status screen.** One card: icon, title, one line of explanation, one primary action. Used for connecting, paused, locked, passkey, idle (the whole card is tappable to resume), error and unsupported browser.
- **Toggle rows.** Menu rows that switch something on or off (View only, Curtain) show an On/Off pill on the right; On uses the accent.
- **Sheet.** A bottom sheet on phones (with a drag handle), a centred panel on larger screens. Focus is trapped inside; Esc closes it; focus returns to the button that opened it.
- **Tiles.** Quick actions are a 3-column grid of icon tiles (24px accent icon, 13px label, 76px tall). Actions with consequences (Lock screen) ask for a second tap.
- **Magnifier.** A 120px circle, 2.5x, drawn 96px above the finger with a thin crosshair; only while a finger stays down.
- **Mac cards.** 16:10 live picture (or a lock or moon icon), name, and a status dot with words (Online, Paused, Not answering, Offline since…). Status never relies on colour alone.
- **Chips.** Accent-tinted toolbar pills that report a mode and undo it when tapped: View only, Whole screen.
- **Banner.** The Mac's state while video is live (display asleep, locked), with one action.
- **Toast.** Short confirmations at the top, auto-dismissed; at most one action.

## Copy

- Plain words, sentence case, active voice: "Couldn't load the folder", not "Oops! Something went wrong."
- No em dashes in interface text; use a period, comma or colon.
- No exclamation marks in confirmations.
- Name things the way macOS does: Screen Recording, Accessibility, Privacy & Security, Spaces, Mission Control.

## Mac app

The menu-bar icon is a template image, so macOS tints it. Left-click opens the status panel (SwiftUI in an `NSPopover`); right-click opens the classic menu. The Setup Assistant is a standard macOS window with a step list on the left. Both use system materials, system colours with the same blue accent, and SF Symbols.
