# Tether

**Control your Mac from your iPhone, iPad, or any computer, privately, over Tailscale.**

Tether is a small, free, open-source alternative to apps like Screens. A tiny menu-bar app on your Mac streams the screen to a web page that only *your* devices can open. Add it to your Home Screen and it behaves like an app: sharp, low-latency video, a trackpad-style touch mode, keyboard shortcuts, clipboard sync and file transfer.

<!-- Screenshot: docs/screenshot-iphone.png -->

## Set it up with Claude (easiest)

You don't need to be technical. Install [Claude Code](https://claude.com/claude-code), then:

1. On the Mac you want to control, open Terminal. If you're setting up a different Mac, any of your Macs works. Then run:
   ```bash
   xcode-select --install
   ```
   Click **Install** in the window that appears, and wait for it to finish. This installs Apple's free developer tools, which Tether is built with. If it says they're already installed, move on.
2. Then run:
   ```bash
   git clone https://github.com/jordanromines-jpg/tether.git && cd tether && claude
   ```
3. Tell Claude: **"Set up Tether on my Mac."**

Claude runs the setup, explains each step, and tells you when it needs you. That includes installing Tailscale and turning on two permission switches in System Settings. Setup takes about 20–30 minutes, mostly waiting for the first build.

## Set it up yourself

Requirements:
- A Mac running macOS 14 (Sonoma) or newer.
- A free [Tailscale](https://tailscale.com) account.

Steps:
1. Run this from the repo folder:
   ```bash
   scripts/setup.sh                                  # make THIS Mac controllable
   scripts/setup.sh --remote you@other-mac           # or set up ANOTHER Mac on your tailnet over SSH
   scripts/setup.sh --check                          # read-only: see what's done and what's left
   ```
   The script stops with **ACTION NEEDED** whenever you need to do something, such as clicking Install or flipping a permission. Do it, then run the same command again.
2. On each phone, tablet or computer you'll control from:
   1. Install Tailscale and sign in with the **same account**.
   2. Open the link setup printed, `https://<your-mac>.<tailnet>.ts.net`. The Tether menu-bar icon also has **Show QR code for your phone…**
   3. On iPhone or iPad, tap Share → **Add to Home Screen**.

## Using it

| | Touch (iPhone / iPad) | Mouse, trackpad and keyboard |
|---|---|---|
| Move | Drag one finger (trackpad mode) or tap where you want (direct mode) | Move the pointer |
| Click / right-click | Tap / two-finger tap | Click / right-click |
| Drag | Touch and hold, then drag | Click and drag |
| Scroll | Two fingers | Wheel or trackpad |
| Spaces / Mission Control | Three-finger swipe left/right, or up/down | Use the shortcuts menu (**…**) |
| Zoom the view | Pinch. The view follows the cursor; three fingers pan while zoomed | n/a |
| Type | ⌨︎ for keys and shortcuts, or **Compose** for autocorrect and dictation | Just type; ⌘ shortcuts pass through |

The toolbar also has:
- **Sticky ⌘ ⌥ ⌃ ⇧:** tap for the next key only, double-tap to lock.
- **…** for Esc, arrows, F-keys and common shortcuts.
- **Clipboard** sync in both directions.
- **Files:** send files to the Mac's Downloads folder, or download from its Downloads and Desktop.
- **Sound** on or off.
- **Display & quality:** pick a monitor, choose Auto, Fast, Balanced or Sharp, fit the screen to your device, or switch to another of your Macs running Tether.

## Turning it on and off

Tether lives in your Mac's menu bar. Setup makes it start automatically when you log in.

- **Pause remote access:** in the Tether menu, or press ⌘P with the menu open. Everyone is disconnected and nobody can connect until you choose **Resume**. Your phone shows "Paused on the Mac" and reconnects by itself when you resume. Pausing survives restarts.
- **Quit Tether:** Tether stops completely and stays off. To start it again, open **Tether** from the Applications folder in your home folder, or from Spotlight.
- **Start Tether at login:** a checkbox in the menu. Turn it off if you'd rather start Tether yourself.
- **While nobody is connected,** Tether isn't recording the screen or watching the clipboard. It just waits for a connection. If it ever crashes, it restarts by itself.
- **To remove it completely,** run `scripts/uninstall.sh` (this Mac) or `scripts/uninstall.sh <name>` (another Mac you set up). Add `--all` to also delete its settings and passkeys.

## How it stays private

- **Only devices on your Tailscale network can reach it.** Everyone else on the internet can't connect at all.
- **Only your Tailscale login is allowed in.** Each request carries an identity Tailscale verifies, and Tether checks it.
- **Optional second lock:** a Face ID / Touch ID passkey. Turn it on from the Tether menu-bar icon. You'll see a banner on the Mac whenever a device connects, and the menu lists active sessions with **Disconnect all**.

Details, including what to do if a device is lost: [SECURITY.md](SECURITY.md).

## How it works

Three diagrams map Tether end to end, top to bottom. GitHub draws them right here, so they stay sharp at any zoom; use the expand button to pan around.

Each has an **[interactive version](https://jordanromines-jpg.github.io/tether/)** made with [Archify](https://github.com/tt-a1i/archify). There you can click any box to see the exact file and lines that implement it, trace paths, and switch guided views.

### 1. System architecture

From your device at the top, through Tailscale and the identity gate, to the agent's routes, the Hub that feeds every viewer from one capture, the capture and input engines, and macOS at the bottom.

**Colours:**
- cyan: your device
- green: app logic
- rose: security
- violet: storage
- slate: outside systems
- amber: cloud

**Lines:**
- bold green: the main path
- dashed red: security checks
- dashed grey: returns

[Open the interactive architecture map →](https://jordanromines-jpg.github.io/tether/diagrams/architecture.html)

<!-- mermaid:architecture -->
```mermaid
%%{init: {"flowchart": {"curve": "stepBefore", "nodeSpacing": 28, "rankSpacing": 44, "padding": 10}, "themeVariables": {"fontSize": "14px"}}}%%
flowchart TB
  subgraph L1["Your device · screen and input"]
    direction LR
    you("`**You**
touch · mouse · keys`"):::external
    input("`**input + keys**
swipes · ⌘ keys`"):::frontend
    stream("`**stream.js**
WSS + WebCodecs decode`"):::frontend
    cursorc("`**cursor.js**
local cursor, predicted`"):::frontend
    audioc("`**audio.js**
AAC / PCM decode`"):::frontend
  end
  subgraph L2["Your device · lock, files and other Macs"]
    direction LR
    passkeyc("`**passkey.js**
WebAuthn Face/Touch ID`"):::frontend
    ui("`**App shell (app.js)**
toolbar · sheets · banner`"):::frontend
    filesui("`**Files sheet**
XHR upload · download`"):::frontend
    macs("`**Macs switcher**
probe peers' /healthz`"):::frontend
  end
  subgraph L3["Your tailnet → the Mac"]
    direction LR
    serve("`**tailscale serve**
HTTPS :443`"):::security
    gate("`**Identity gate**
login allowlist`"):::security
  end
  subgraph L4["Tether.app routes · 127.0.0.1:7400 only"]
    direction LR
    static("`**Static web client**
FileMiddleware · web/`"):::backend
    auth("`**/auth/∗ routes**
register · options · verify`"):::backend
    ws("`**/ws WebSocket**
JSON control + binary A/V`"):::backend
    files("`**File routes**
/files /download /upload`"):::backend
    peers("`**/peers · /healthz**
CORS: same tailnet`"):::backend
  end
  subgraph L5["Services and storage"]
    direction LR
    pstore("`**PasskeyStore**
P-256 · 12 h cookie`"):::security
    appsupport("`**App Support/Tether**
passkeys · HMAC secret`"):::database
    sandbox("`**FileSandbox**
blocks .. and symlinks`"):::security
    folders("`**Downloads · Desktop**
Files & Folders consent`"):::database
    peersnode("`**Peers**
tailscale status --json`"):::backend
  end
  subgraph L6["Hub · one capture feeds every viewer"]
    direction LR
    hub("`**Hub**
sessions`"):::backend
    adaptive("`**AdaptiveController**
RTT · queue · drops`"):::backend
  end
  subgraph L7["Capture and encode"]
    direction LR
    fit("`**FitDisplay (opt-in)**
CGVirtualDisplay mirror`"):::backend
    streamer("`**ScreenStreamer**
ScreenCaptureKit, no cursor`"):::backend
    encoder("`**VideoEncoder**
VideoToolbox HEVC / H.264`"):::backend
    audioenc("`**AudioEncoder**
AAC-LC 48k / PCM 24k`"):::backend
  end
  subgraph L8["Input and sync"]
    direction LR
    inputinj("`**InputInjector**
CGEvent mouse · keys · text`"):::backend
    clip("`**ClipboardSync**
poll changeCount 0.5 s`"):::backend
    cursorw("`**CursorWatcher**
shape 8 Hz · pos 60 Hz`"):::backend
  end
  subgraph L9["macOS"]
    direction LR
    displays("`**Displays**
physical + virtual`"):::external
    hid("`**macOS input**
HID event tap`"):::external
    pasteboard("`**NSPasteboard**
general pasteboard`"):::database
  end
  you -->|"gestures"| input
  input -->|"JSON input"| stream
  stream -->|"cursor pos"| cursorc
  stream -->|"audio frames"| audioc
  serve ==>|"→ :7400"| gate
  pstore -->|"persist"| appsupport
  sandbox -->|"read"| folders
  streamer -->|"samples"| audioenc
  streamer ==>|"frames"| encoder
  hub --> adaptive
  L1 -.-> L2
  L2 ==>|"HTTPS + WSS (tailnet only)"| L3
  L3 ==>|"verified login → :7400"| L4
  L4 -.->|"verify · resolve · list"| L5
  L4 ==>|"/ws messages"| L6
  L6 ==>|"start · keyframe · bitrate"| L7
  L7 -.-> L8
  L8 -->|"CGEvent · pasteboard · pixels"| L9
  L1 ~~~ L2 ~~~ L3 ~~~ L4 ~~~ L5 ~~~ L6 ~~~ L7 ~~~ L8 ~~~ L9
  you ~~~ input ~~~ stream ~~~ cursorc ~~~ audioc
  passkeyc ~~~ ui ~~~ filesui ~~~ macs
  serve ~~~ gate
  static ~~~ auth ~~~ ws ~~~ files ~~~ peers
  pstore ~~~ appsupport ~~~ sandbox ~~~ folders ~~~ peersnode
  hub ~~~ adaptive
  fit ~~~ streamer ~~~ encoder ~~~ audioenc
  inputinj ~~~ clip ~~~ cursorw
  displays ~~~ hid ~~~ pasteboard
  linkStyle 0 stroke:#94a3b8,stroke-width:1.5px
  linkStyle 1 stroke:#94a3b8,stroke-width:1.5px
  linkStyle 2 stroke:#94a3b8,stroke-width:1.5px
  linkStyle 3 stroke:#94a3b8,stroke-width:1.5px
  linkStyle 4 stroke:#059669,stroke-width:2.5px
  linkStyle 5 stroke:#94a3b8,stroke-width:1.5px
  linkStyle 6 stroke:#94a3b8,stroke-width:1.5px
  linkStyle 7 stroke:#94a3b8,stroke-width:1.5px
  linkStyle 8 stroke:#059669,stroke-width:2.5px
  linkStyle 9 stroke:#94a3b8,stroke-width:1.5px
  linkStyle 10 stroke:#94a3b8,stroke-width:1.5px,stroke-dasharray:4 4
  linkStyle 11 stroke:#059669,stroke-width:2.5px
  linkStyle 12 stroke:#059669,stroke-width:2.5px
  linkStyle 13 stroke:#e11d48,stroke-width:1.5px,stroke-dasharray:5 4
  linkStyle 14 stroke:#059669,stroke-width:2.5px
  linkStyle 15 stroke:#059669,stroke-width:2.5px
  linkStyle 16 stroke:#94a3b8,stroke-width:1.5px,stroke-dasharray:4 4
  linkStyle 17 stroke:#94a3b8,stroke-width:1.5px
  classDef frontend fill:#0891b21f,stroke:#0891b2,stroke-width:1.5px,rx:6,ry:6
  classDef backend fill:#0596691f,stroke:#059669,stroke-width:1.5px,rx:6,ry:6
  classDef security fill:#e11d481f,stroke:#e11d48,stroke-width:1.5px,rx:6,ry:6
  classDef database fill:#7c3aed1f,stroke:#7c3aed,stroke-width:1.5px,rx:6,ry:6
  classDef external fill:#64748b1f,stroke:#64748b,stroke-width:1.5px,rx:6,ry:6
  classDef cloud fill:#d977061f,stroke:#d97706,stroke-width:1.5px,rx:6,ry:6
  classDef messagebus fill:#d977061f,stroke:#d97706,stroke-width:1.5px,rx:6,ry:6
  classDef region fill:transparent,stroke:#d97706,stroke-width:1px,stroke-dasharray:6 4
  classDef guard fill:transparent,stroke:#e11d48,stroke-width:1px,stroke-dasharray:6 4
  class L1,L2,L3,L4,L5,L6,L7,L8,L9 region
```

### 2. One session, step by step

A whole session read top to bottom, as 43 numbered steps in eight shaded phases:
1. lock check
2. passkey unlock
3. WebSocket hello
4. first frame
5. the live loop with Auto quality
6. input
7. clipboard and sound
8. teardown

The columns are grouped by who acts: your device, Tailscale and the server gate, the Hub, and the Mac side.

[Open the interactive session timeline →](https://jordanromines-jpg.github.io/tether/diagrams/session.html)

<!-- mermaid:session -->
```mermaid
%%{init: {"sequence": {"mirrorActors": false, "messageAlign": "left", "actorMargin": 16, "width": 104, "boxMargin": 6, "messageFontSize": 14, "actorFontSize": 13, "noteFontSize": 13}}}%%
sequenceDiagram
  autonumber
  box rgba(8,145,178,0.10) Your device
    actor You as You
    participant App as Tether app
  end
  box rgba(225,29,72,0.08) Tailscale + server gate
    participant TS as Tailscale serve
    participant Server as Tether server
    participant Passkeys as Passkeys
  end
  box rgba(5,150,105,0.10) Hub
    participant Hub as Hub
  end
  box rgba(100,116,139,0.10) Mac side
    participant Input as InputInjector
    participant Capture as Capture
    participant macOS as macOS
  end
  rect rgba(225,29,72,0.05)
    Note over You,App: 1. Lock check (every load)
    You->>App: open the app
    App->>TS: GET /auth/status
    TS->>Server: + verified login
    Server->>Passkeys: lock on? cookie ok?
    Passkeys-->>App: locked → lock screen
  end
  rect rgba(124,58,237,0.05)
    Note over App,You: 2. Passkey unlock (only if the lock is on)
    App-->>You: Face ID prompt
    You->>App: approve
    App->>Server: POST /auth/verify
    Server->>Passkeys: check signature
    Passkeys-->>App: Set-Cookie (12 h)
  end
  rect rgba(5,150,105,0.05)
    Note over App,TS: 3. WebSocket hello
    App->>TS: WSS /ws?device=…
    TS->>Server: upgrade + login
    Server->>Hub: add client
    Hub-->>macOS: notify · wake display
    Hub-->>App: hello: displays · perms
    App->>Hub: hello: codecs · quality
  end
  rect rgba(8,145,178,0.05)
    Note over Hub,Capture: 4. First frame
    Hub->>Capture: start(HEVC, 1920 w, 60 fps)
    Capture->>macOS: SCStream, no cursor
    macOS-->>Capture: pixel buffers
    Capture->>Hub: keyframe + hvcC
    Hub->>App: config + keyframe
    App-->>You: decode → canvas
  end
  rect rgba(5,150,105,0.05)
    Note over Hub,App: 5. Live loop + Auto quality
    Hub-->>App: cursor shape + x,y @60 Hz
    Capture->>Hub: P-frames (≤3 in flight)
    Hub->>App: binary video
    App-->>Hub: ping + stats (1 s)
    Hub-->>App: pong
    Hub->>Capture: Auto: new bitrate / size
  end
  rect rgba(8,145,178,0.05)
    Note over You,App: 6. Input
    You->>App: drag · tap · type
    App->>Hub: mrel · btn · key · text
    Hub->>Input: apply
    Input->>macOS: CGEvent → HID tap
    macOS-->>Capture: screen changes → frames
  end
  rect rgba(217,119,6,0.05)
    Note over macOS,Hub: 7. Clipboard + sound
    macOS-->>Hub: pasteboard changed
    Hub-->>App: clip → Copy toast
    App->>Hub: sound on (AAC)
    Hub->>Capture: restart with audio
    Capture-->>Hub: AAC frames
    Hub-->>App: binary audio
  end
  rect rgba(100,116,139,0.05)
    Note over App,Hub: 8. Teardown
    App-->>Hub: socket closes
    Hub->>Input: release all keys
    Hub->>Capture: stop (last viewer)
    Hub-->>macOS: release keep-awake
  end
```

### 3. Setup

What `scripts/setup.sh` checks, builds and installs. The ✋ boxes are the moments it stops and waits for you; run it again afterwards and it carries on.

[Open the interactive setup flow →](https://jordanromines-jpg.github.io/tether/diagrams/setup.html)

<!-- mermaid:setup -->
```mermaid
%%{init: {"flowchart": {"curve": "stepBefore", "nodeSpacing": 28, "rankSpacing": 44, "padding": 10}, "themeVariables": {"fontSize": "14px"}}}%%
flowchart TB
  subgraph CHECKS["Checks — this Mac runs scripts/setup.sh"]
    direction TB
    macos("`**macOS 14+**
else ✗ stop`"):::external
    clt("`**Command Line Tools**
Swift toolchain`"):::backend
    tailscale("`**Tailscale**
installed · signed in`"):::cloud
    ssh("`**SSH to other Mac**
--remote only`"):::security
    https("`**HTTPS certificates**
tailnet CertDomains`"):::security
    signing("`**Signing identity**
dedicated keychain`"):::security
  end
  subgraph INSTALL["Build here → install on the Mac you'll control"]
    direction TB
    build("`**Build Tether.app**
skipped if unchanged`"):::backend
    copy("`**Copy app**
~/Applications`"):::backend
    agent("`**LaunchAgent**
runs at login`"):::backend
    serve("`**tailscale serve**
https://<mac>.ts.net`"):::cloud
    perms("`**Permission check**
asks Tether's /healthz`"):::security
    ready("`**✓ Tether is ready**
link + QR code`"):::frontend
  end
  a_clt(["`**✋ Click Install**
or accept license`"]):::action
  a_ts(["`**✋ Install + sign in**
same account`"]):::action
  a_ssh(["`**✋ Remote Login on**
+ ssh-copy-id once`"]):::action
  a_https(["`**✋ Enable HTTPS**
Tailscale admin → DNS`"]):::action
  a_perms(["`**✋ Allow Tether**
2 privacy switches`"]):::action
  macos ==> clt
  clt ==> tailscale
  tailscale ==> ssh
  ssh ==> https
  https ==> signing
  signing ==>|"build + install"| build
  build ==> copy
  copy ==> agent
  agent ==> serve
  serve ==> perms
  perms ==> ready
  clt -.->|"missing"| a_clt
  tailscale -.->|"missing"| a_ts
  ssh -.->|"no access"| a_ssh
  https -.->|"off"| a_https
  perms -.->|"not yet"| a_perms
  linkStyle 0 stroke:#059669,stroke-width:2.5px
  linkStyle 1 stroke:#059669,stroke-width:2.5px
  linkStyle 2 stroke:#059669,stroke-width:2.5px
  linkStyle 3 stroke:#059669,stroke-width:2.5px
  linkStyle 4 stroke:#059669,stroke-width:2.5px
  linkStyle 5 stroke:#059669,stroke-width:2.5px
  linkStyle 6 stroke:#059669,stroke-width:2.5px
  linkStyle 7 stroke:#059669,stroke-width:2.5px
  linkStyle 8 stroke:#059669,stroke-width:2.5px
  linkStyle 9 stroke:#059669,stroke-width:2.5px
  linkStyle 10 stroke:#059669,stroke-width:2.5px
  linkStyle 11 stroke:#e11d48,stroke-width:1.5px,stroke-dasharray:5 4
  linkStyle 12 stroke:#e11d48,stroke-width:1.5px,stroke-dasharray:5 4
  linkStyle 13 stroke:#e11d48,stroke-width:1.5px,stroke-dasharray:5 4
  linkStyle 14 stroke:#e11d48,stroke-width:1.5px,stroke-dasharray:5 4
  linkStyle 15 stroke:#e11d48,stroke-width:1.5px,stroke-dasharray:5 4
  classDef frontend fill:#0891b21f,stroke:#0891b2,stroke-width:1.5px,rx:6,ry:6
  classDef backend fill:#0596691f,stroke:#059669,stroke-width:1.5px,rx:6,ry:6
  classDef security fill:#e11d481f,stroke:#e11d48,stroke-width:1.5px,rx:6,ry:6
  classDef database fill:#7c3aed1f,stroke:#7c3aed,stroke-width:1.5px,rx:6,ry:6
  classDef external fill:#64748b1f,stroke:#64748b,stroke-width:1.5px,rx:6,ry:6
  classDef cloud fill:#d977061f,stroke:#d97706,stroke-width:1.5px,rx:6,ry:6
  classDef messagebus fill:#d977061f,stroke:#d97706,stroke-width:1.5px,rx:6,ry:6
  classDef region fill:transparent,stroke:#d97706,stroke-width:1px,stroke-dasharray:6 4
  classDef guard fill:transparent,stroke:#e11d48,stroke-width:1px,stroke-dasharray:6 4
  classDef action fill:#e11d4814,stroke:#e11d48,stroke-width:1.5px,stroke-dasharray:4 3
  class CHECKS,INSTALL region
```

### Code layout

- `agent/`: the Swift menu-bar app. It captures the screen, encodes it with the hardware encoder in low-latency mode, injects input, and adapts quality to your connection.
- `web/`: the client. Plain JavaScript modules with no build step, installable to the Home Screen.
- `scripts/`: the setup, build, signing and update scripts.
- `CLAUDE.md`: the runbook Claude follows.
- `docs/diagrams/`: the diagrams. `src/*.json` are the Archify sources for the interactive versions; rebuild one with `archify finalize <type> docs/diagrams/src/<name>.json <out>.html --repo-root .`. The README's Mermaid diagrams are generated from the same sources by `python3 docs/diagrams/make_mermaid.py`.

## Development

```bash
swift run --package-path agent SelfTest   # core logic tests
scripts/dev.sh                            # run the agent on this Mac at http://localhost:7400 (dev mode)
scripts/build-app.sh                      # build/Tether.app, signed with a stable local identity
scripts/deploy.sh <target>                # update another Mac (targets live in ~/.config/tether/targets/)
scripts/uninstall.sh [<target>] [--all]   # remove Tether from this Mac or another one
```

Logs on the controlled Mac are in `~/Library/Logs/Tether.log`.

## Known limits

- **You build it yourself, from source.** There's no signed or notarized download. Setup builds Tether on your Mac and signs it with a self-made identity kept in a dedicated keychain, so macOS permissions survive updates. If you build on a different Mac or delete that keychain, grant the two permissions once more.
- **Browser-reserved shortcuts.** Desktop browsers keep a few shortcuts for themselves (⌘W, ⌘T, ⌘Q). Use the **…** menu, or install the page as an app.
- **"Fit to device" uses an undocumented macOS feature.** A future macOS update could break it. If so, the toggle disables itself, and everything else keeps working.
- **Future ideas:** WebRTC transport for lossy networks, and a signed one-click download.

## License

MIT. See [LICENSE](LICENSE).
