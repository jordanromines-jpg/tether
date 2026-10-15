# An API so Claude can control Macs through Tether

<!-- graph: status P-3 -->
Status: awaiting approval

- Work: 0 of 7 done; hours 12.25 of a 20 h box
- Doing: — · Ready: — · Next: —
- Blocked (7):
  - T-4 waits on V-5, P-3 approval
  - V-5 waits on PR-5, P-3 approval
  - S-15 waits on S-6, S-4, S-5, P-3 approval
  - S-16 waits on S-15, S-6, S-4, S-5, P-3 approval
  - S-17 waits on S-16, D-6, S-4, S-7, P-3 approval
  - S-18 waits on S-17, P-3 approval
  - S-19 waits on S-18, S-11, P-3 approval
- Waiting on Jordan: D-6
- Critical path: S-15 → S-16 → S-17 → S-18 → S-19 → V-5 → T-4 (12.25 h left)
<!-- /graph -->

What started it: Jordan, 15 Oct 2026: "Is there also an MCP where Claude can connect to Tether to control my other Macs?" Then: "I want this. It would be an entirely separate tool, right it would be tether CLI/API/MCP", "Basically, the MCP would allow you to use Tether to connect to anyone of your devices on the Tailscale network" and "D-A: new repo mcp-tether for the MCP server and the tether command. Write the plans." It replaces the Inbox item S-1. The client half, an MCP server plus a `tether` command, is a separate repo, `mcp-tether`, with its own plan; it needs this API first.

## Why
Claude can only see and click on the Mac it runs on. Tether already does everything needed for the other Macs, but only for its web page:
- capture: `Thumbnails.capture` for still images, and live HEVC video over `/ws`;
- input: `ClientMessage` move, button, scroll, key, text, openApp and openURL, applied by `Hub.apply`;
- the identity check: `TailscaleAuthMiddleware`.

A program can't easily use the live video stream. A small request-and-answer API is the missing piece.

The one open-source alternative found, [mcp_macos](https://mcpservers.org/servers/senseisven/mcp_macos), drives a Mac over VNC. That needs Screen Sharing and a VNC password on every Mac, a second way in that skips Tailscale's login check, so it isn't used.

## Design
One pull request, PR-5. A new `agent/Sources/Tether/API.swift` adds `/api/v1` routes to `Server.swift`, and `agent/Sources/TetherCore/APIProtocol.swift` holds the request and answer shapes so SelfTest can check them:
- **Read:** `info` (name, version, displays and their scale, permissions), `screenshot` (a display or one window), `windows` and `apps`.
- **Act:** `POST actions` with a list of clicks, drags, scrolls, keys, text, open app and open link. Each becomes the same `ClientMessage` the web page sends, from a Hub client named after the calling device. View only, Pause and the activity log then work for Claude as for any device, through `Hub.swift`.
- **Safety:** an **Allow Claude** switch per Mac (D-6, in `StatusPanel.swift` and `AppState.swift`), off until turned on there. A banner through `Notifier.swift` while Claude is connected, and each action in Recent activity through `ActivityStore.swift`.
- **Access:** Jordan's Tailscale login is the gate (D-4). The passkey gate skips `/api` only while that Mac's switch is on.
- **Discovery:** `Peers.swift` adds whether each Mac allows Claude to `/peers`, so the client can list them.
- **Docs:** `docs/API.md` describes every route.

The routes are versioned (`/api/v1`) so mcp-tether can say which version it needs. Order: the steps that share test files with P-1 come after P-1's PR-1 and PR-2.

## What this does NOT do
- The MCP server and the `tether` command: they live in `mcp-tether`, with their own plan.
- Live video for Claude: screenshots on request only.
- Files, clipboard and sound through the API: later, if Claude needs them.
- Any device that isn't a Mac running Tether.

## Requirements
<!-- graph: reqs P-3 -->
| Key | Requirement | Acceptance | Built by | Verified by | State |
|---|---|---|---|---|---|
| REQ-4 | Claude can see and control any Mac on the tailnet that runs Tether | WHEN a client on Jordan's tailnet calls the API of a Mac with Claude allowed THEN it gets a screenshot, the window list, and its clicks, keys and text arrive on that Mac | S-15, S-16, S-18, S-19 | V-5 | open |
| REQ-5 | The Mac's own safety controls apply to Claude | WHEN Claude is not allowed on a Mac, or the Mac is paused, or Claude's session is view only THEN the API refuses input; and while Claude is connected the Mac shows a banner and logs each action in Recent activity | S-16, S-17, S-19 | T-4, V-5 | open |
<!-- /graph -->

## Decisions
<!-- graph: decisions P-3 -->
| Key | Question | Recommendation | Answer | State |
|---|---|---|---|---|
| D-4 | How does Claude get past the passkey lock? | Being on Jordan's Tailscale network, with his login, is the gate; no separate key | Tailscale identity is the gate; no separate key — jordan, 2026-10-15: “This is based on the Mac or device in question being on the same Tailscale network” | answered |
| D-5 | Show a banner, log Claude's actions, and let View only and Pause block Claude? | Yes | “yes” — jordan, 2026-10-15 | answered |
| D-6 | Add an Allow Claude switch on each Mac, off until turned on there? | Yes: since the passkey lock doesn't stop Claude, this switch is how a Mac opts in; it's one click per Mac, in the Tether panel | — | open |
<!-- /graph -->

## Pull requests and keys
<!-- graph: steps P-3 -->
| Key | What | Files | Done when | Hours (est · used) | Waits on | State |
|---|---|---|---|---|---|---|
| T-4 | Jordan sees the Claude is connected banner and the activity log on the Studio | — | Jordan confirms the banner and the logged actions | 0.25 | V-5 | blocked |
| V-5 | Live: from the M5, screenshot and click on the Studio through its tailnet link | — | info answers; a screenshot comes back; a click lands in a test-bench window opened for it; with the switch off, or paused, the same calls are refused | 1 | PR-5 | blocked |

**PR-5 · Claude API in Tether** · branch `feat/claude-api` · open

| Key | What | Files | Done when | Hours (est · used) | Waits on | State |
|---|---|---|---|---|---|---|
| S-15 | Read routes: /api/v1/info, screenshot, windows and apps | agent/Sources/Tether/API.swift, agent/Sources/Tether/Server.swift, agent/Sources/TetherCore/APIProtocol.swift, agent/Sources/SelfTest/main.swift | the routes answer JSON (info: name, version, displays, permissions) and PNG or JPEG screenshots of a display or one window, reusing Thumbnails.capture and the window list; SelfTest covers the request and response shapes | 3 | S-6, S-4, S-5 | blocked |
| S-16 | POST /api/v1/actions: click, drag, scroll, type, keys, open app or link, through the Hub | agent/Sources/Tether/API.swift, agent/Sources/Tether/Hub.swift, agent/Sources/TetherCore/APIProtocol.swift, agent/Sources/SelfTest/main.swift | each action becomes the same ClientMessage the web page sends, from a Hub client named for the calling device, so View only and Pause refuse it like any device; SelfTest maps every action and rejects bad input | 3 | S-15, S-6, S-4, S-5 | blocked |
| S-17 | Allow Claude switch, banner and activity log | agent/Sources/Tether/Server.swift, agent/Sources/Tether/AppState.swift, agent/Sources/Tether/Notifier.swift, agent/Sources/Tether/ActivityStore.swift, agent/Sources/TetherUI/StatusPanel.swift, agent/Sources/Snapshots/main.swift | with the switch off every /api route answers 403 with a plain reason; on, the Mac shows a Claude is connected banner and Recent activity lists each action; the passkey gate skips /api only while the switch is on (D-4); Snapshots render the switch | 2.5 | S-16, D-6, S-4, S-7 | blocked |
| S-18 | /peers says which Macs allow Claude | agent/Sources/Tether/Peers.swift, agent/Sources/Tether/Server.swift | each peer in /peers carries claude: true or false, so a client can list the Macs it may use | 1 | S-17 | blocked |
| S-19 | docs/API.md, README, SECURITY.md and CHANGELOG | docs/API.md, README.md, SECURITY.md, CHANGELOG.md | docs/API.md lists every route with an example; SECURITY.md says what the switch allows and that the passkey lock does not cover the API | 1.5 | S-18, S-11 | blocked |
<!-- /graph -->

## Gates that need Jordan
<!-- graph: gates P-3 -->
None.
<!-- /graph -->

## Risks
<!-- graph: risks P-3 -->
| Key | Risk | Likelihood · impact | Trigger | Mitigated by | State |
|---|---|---|---|---|---|
| R-7 | The API skips the passkey lock, so anyone with Jordan's tailnet login on any device can use it | low · high | a device signed in to Jordan's tailnet is lost or compromised | S-17 | open |
| R-8 | Claude acts on instructions it reads on a remote screen | medium · medium | an action Jordan didn't ask for shows in Recent activity | S-17 | open |
<!-- /graph -->

## Verification
<!-- graph: checks P-3 -->
| Key | Check | Passes when | Command | Verifies | State |
|---|---|---|---|---|---|
| T-4 | Jordan sees the Claude is connected banner and the activity log on the Studio | Jordan confirms the banner and the logged actions | — | REQ-5 | blocked |
| V-5 | Live: from the M5, screenshot and click on the Studio through its tailnet link | info answers; a screenshot comes back; a click lands in a test-bench window opened for it; with the switch off, or paused, the same calls are refused | `curl -s https://<studio>.<tailnet>.ts.net/api/v1/info` | REQ-4, REQ-5 | blocked |
<!-- /graph -->

## Build log
<!-- graph: log P-3 -->
| When | Key | What | By | Commit |
|---|---|---|---|---|
| 2026-10-15 17:04 | P-3 | added | claude | — |
| 2026-10-15 17:04 | D-4 | added | claude | — |
| 2026-10-15 17:04 | D-4 | answered: “This is based on the Mac or device in question being on the same Tailscale netwo” | jordan | — |
| 2026-10-15 17:04 | D-5 | added | claude | — |
| 2026-10-15 17:04 | D-5 | answered: “yes” | jordan | — |
| 2026-10-15 17:04 | D-6 | added | claude | — |
| 2026-10-15 17:04 | PR-5 | added | claude | — |
| 2026-10-15 17:04 | REQ-4 | added | claude | — |
| 2026-10-15 17:04 | REQ-5 | added | claude | — |
| 2026-10-15 17:05 | R-7 | added | claude | — |
| 2026-10-15 17:05 | S-15 | added | claude | — |
| 2026-10-15 17:05 | S-16 | added | claude | — |
| 2026-10-15 17:05 | S-17 | added | claude | — |
| 2026-10-15 17:05 | S-18 | added | claude | — |
| 2026-10-15 17:05 | S-19 | added | claude | — |
| 2026-10-15 17:05 | T-4 | added | claude | — |
| 2026-10-15 17:05 | V-5 | added | claude | — |
| 2026-10-15 17:05 | R-8 | added | claude | — |
| 2026-10-15 17:05 | S-17 | mitigates R-6 | claude | — |
| 2026-10-15 17:05 | S-17 | mitigates R-7 | claude | — |
| 2026-10-15 17:05 | S-15 | depends_on S-6 | claude | — |
| 2026-10-15 17:05 | S-15 | depends_on S-4 | claude | — |
| 2026-10-15 17:05 | S-15 | depends_on S-5 | claude | — |
| 2026-10-15 17:05 | S-16 | depends_on S-6 | claude | — |
| 2026-10-15 17:05 | S-16 | depends_on S-4 | claude | — |
| 2026-10-15 17:05 | S-16 | depends_on S-5 | claude | — |
| 2026-10-15 17:05 | S-17 | removed mitigates R-6 | claude | — |
| 2026-10-15 17:05 | S-17 | mitigates R-8 | claude | — |
| 2026-10-15 17:05 | S-17 | depends_on S-7 | claude | — |
<!-- /graph -->

## Results
What happened: pull requests and commits, before/after numbers, what's left.
