# Tether API

A small request-and-answer API so a program (Claude, through [mcp-tether](https://github.com/jordanromines-jpg/mcp-tether)) can see and control a Mac running Tether. It lives next to the web page, at `https://<mac>.<tailnet>.ts.net/api/v1/…`.

The shapes are defined once, in `agent/Sources/TetherCore/APIProtocol.swift`, and checked by SelfTest.

## Who can use it

- **Only devices on your tailnet, signed in with your Tailscale login.** `tailscale serve` adds the verified login to every request, and Tether checks it, as for the web page.
- **The passkey lock does not cover the API.** Your Tailscale login is its gate (Jordan, 15 Oct 2026: "This is based on the Mac or device in question being on the same Tailscale network").
- **Pause** on the Mac refuses every API call with `503`, like the web page.
- **Allow Claude** (coming in this release): a switch on each Mac with Off, View only and Control. Until it's on, every route answers `403`. Until that switch ships, the API answers only in dev mode (`scripts/dev.sh`).

## Conventions

- Answers are JSON with sorted keys, except screenshots (PNG or JPEG).
- Every refusal is `{"error": "<plain reason>"}` with a 4xx or 5xx status. When an action list stops midway it also carries `"index"`, the action that was refused.
- Coordinates on the Mac are **points** (a Retina display is 2 pixels per point), with the origin at the top-left of the main display, as macOS reports window frames.
- The version is in the path. A breaking change gets `/api/v2`; new fields may appear in `v1` answers at any time, so ignore fields you don't know.

## Coordinates

An action's `x` and `y` are **pixels of the screenshot you're looking at**, so you never convert anything yourself:

1. Take a screenshot of a target: a display, or one window. Its headers say what it shows:
   - `X-Tether-Target: display 1` or `window 1234`
   - `X-Tether-Image-Size: 1280x720` (the image's pixels)
   - `X-Tether-Points: 0,0,2560,1440` (x, y, width, height of what it shows, in points)
2. Send actions with that same target and image size, and pixel coordinates read off the image.
3. Tether maps them: `point = target.origin + (x / image.w × target.w, y / image.h × target.h)`, then to the display that point is on.

So the same click lands in the same place whether the screenshot was full size or scaled down, on a Retina display or not. Pixels outside the image are refused.

## Routes

### `GET /api/v1/info`

The Mac, its displays and whether Tether has its permissions.

```bash
curl -s https://studio.example.ts.net/api/v1/info
```

```json
{
  "api": 1,
  "displays": [
    {
      "id": 1,
      "main": true,
      "name": "Studio Display",
      "pixels": { "h": 2880, "w": 5120 },
      "points": { "h": 1440, "w": 2560, "x": 0, "y": 0 },
      "scale": 2
    }
  ],
  "name": "Jordan's Mac Studio",
  "paused": false,
  "permissions": { "accessibility": true, "screenRecording": true },
  "version": "6.0 (573e17e)"
}
```

- `points`: where the display sits, in points. `pixels`: its native resolution. `scale`: pixels per point.
- `permissions`: without Screen Recording there are no screenshots; without Accessibility, input is ignored by macOS.

### `GET /api/v1/screenshot`

A PNG or JPEG of a display or one window. The cursor is left out, and so are Tether's own windows.

| Parameter | Meaning | Default |
|---|---|---|
| `display` | a display id from `info` | the main display |
| `window` | a window id from `windows` (not with `display`) | |
| `width` | width in pixels, 16 to 8192; the height keeps the aspect ratio. Never larger than full size. | full size (points × scale) |
| `format` | `png` or `jpeg` | `png` |
| `quality` | JPEG quality, more than 0 and at most 1 | `0.8` |

```bash
curl -s -D - -o shot.jpg 'https://studio.example.ts.net/api/v1/screenshot?width=1280&format=jpeg'
```

```
HTTP/1.1 200 OK
Content-Type: image/jpeg
X-Tether-Target: display 1
X-Tether-Image-Size: 1280x720
X-Tether-Points: 0,0,2560,1440
```

- `400` for a bad parameter, `404` for a display or window that isn't there (a window that closed or is off screen), `429` above 4 screenshots a second, `503` when Screen Recording is off or capture fails.

### `GET /api/v1/windows`

The Mac's on-screen windows, without Tether's own and without tiny or untitled ones.

```json
{
  "windows": [
    {
      "app": "Notes",
      "bundle": "com.apple.Notes",
      "display": 1,
      "frame": { "h": 600, "w": 800, "x": 120, "y": 90 },
      "id": 4213,
      "pid": 812,
      "title": "Shopping list"
    }
  ]
}
```

- `frame` is in points; `display` is the display the window's centre is on.

### `GET /api/v1/apps`

Apps the open-app action may launch (the `.app` bundles in the Applications folders), and whether each is running.

```json
{
  "apps": [
    { "name": "Safari", "path": "/Applications/Safari.app", "running": true }
  ]
}
```

### `POST /api/v1/actions` (planned)

Coming in the next step of this release; the shape below is the plan and may still change before it ships. A list of actions, checked as a whole before any of it runs, then run in order.

```json
{
  "target": { "display": 1 },
  "image": { "w": 1280, "h": 720 },
  "actions": [
    { "type": "click", "x": 640, "y": 360 },
    { "type": "text", "text": "hello" },
    { "type": "key", "keys": ["MetaLeft", "KeyS"] }
  ]
}
```

- `target` is `{"display": <id>}` or `{"window": <id>}`, and `image` the size of the screenshot the coordinates came from.
- Actions: `click` (`x`, `y`, optional `button` left, right or middle, and `count` 1 or 2), `move`, `down` and `up` (a button held between calls, for a drag), `drag` (`x`, `y` to `toX`, `toY`), `scroll` (`dx`, `dy` in pixels, positive `dy` scrolls down; optional `x`, `y`), `key` (key names as in the web page's key table, `KeyboardEvent.code`, pressed together then released), `text`, `openApp` (`path` from `apps`) and `openURL` (`url`).
- Limits: at most 50 actions and 64 KB per call, text at most 4,096 characters, coordinates inside the image.
- Answers `{"ok": true, "done": <count>}`, or a refusal with `index` when one action fails. View only and Pause refuse input like any device.
