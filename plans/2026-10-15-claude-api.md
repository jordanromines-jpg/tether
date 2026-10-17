# An API so Claude can control Macs through Tether

<!-- graph: status P-3 -->
Status: in progress (approved 2026-10-16 by jordan: “all rec”)

- Work: 1 of 8 done; hours 16.75 · 19.84 of a 20 h box
- Doing: — · Ready: S-20 · Next: S-20
- Blocked (6):
  - T-4 waits on V-5
  - V-5 waits on PR-5
  - S-16 waits on S-20
  - S-17 waits on S-16, S-7
  - S-18 waits on S-17
  - S-19 waits on S-18, S-11
- Waiting on Jordan: —
- Late: S-15 used 19.84 h of 4 h (stop point 6 h)
- Estimates: done work took 4.96× its estimate (19.84 h of 4 h over 1 item)
- Critical path: S-20 → S-16 → S-17 → S-18 → S-19 → V-5 → T-4 (12.75 h left)
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
- **Act:** `POST actions` with a list of clicks, drags, scrolls, keys, text, open app and open link, checked as a whole before any of it runs (limits in S-16). Each becomes the same `ClientMessage` the web page sends. It goes through one API client per calling device in `Hub.swift` (S-20), which starts no video, keeps held buttons between calls so a drag can span them, and is removed after 2 minutes without a call. View only, Pause and the activity log then work for Claude as for any device. Coordinates are pixels of the screenshot they came from; S-15 fixes how they map to the Mac's points.
- **Safety:** an **Allow Claude** switch per Mac (D-6, in `StatusPanel.swift` and `AppState.swift`), off until turned on there, with Off, View only and Control settings if Jordan agrees (Q-1). A banner through `Notifier.swift` while Claude is connected, each action in Recent activity through `ActivityStore.swift`, and Claude listed under connected devices with **Disconnect**. Switching it off or pausing cuts Claude off at once.
- **Access:** Jordan's Tailscale login is the gate (D-4). `/api` stays off the passkey gate's list. Requests pass the Tailscale login check, then Pause (which gains `/api`), then the Allow Claude check, which answers 403 while the switch is off.
- **Discovery:** `Peers.swift` adds whether each Mac allows Claude to `/peers`, so the client can list them.
- **Docs:** `docs/API.md` describes every route.

The routes are versioned (`/api/v1`) so mcp-tether can say which version it needs. Order: P-3's steps change files that P-1's PR-1 and PR-2 also change (`SelfTest/main.swift`, `StatusPanel.swift`, `Snapshots/main.swift`), so S-15 waits on P-1's S-6 and S-17 on S-7, and the docs step S-19 on S-11. P-3 therefore starts after about 12.5 h of P-1 work (S-2 to S-6), and its own 16.75 h come on top of that.

## What this does NOT do
- The MCP server and the `tether` command: they live in `mcp-tether`, with their own plan.
- Live video for Claude: screenshots on request only.
- Files, clipboard and sound through the API: later, if Claude needs them.
- Any device that isn't a Mac running Tether.

## Requirements
<!-- graph: reqs P-3 -->
| Key | Requirement | Acceptance | Built by | Verified by | State |
|---|---|---|---|---|---|
| REQ-4 | Claude can see and control any Mac on the tailnet that runs Tether | WHEN a client on Jordan's tailnet calls the API of a Mac with Claude allowed THEN it gets a screenshot, the window list, and its clicks, keys and text arrive on that Mac | S-15, S-16, S-18, S-19, S-20 | V-5 | open |
| REQ-5 | The Mac's own safety controls apply to Claude | WHEN Claude is not allowed on a Mac, or the Mac is paused, or Claude's session is view only THEN the API refuses input; and while Claude is connected the Mac shows a banner and logs each action in Recent activity | S-16, S-17, S-19, S-20 | T-4, V-5 | open |
<!-- /graph -->

## Decisions
<!-- graph: decisions P-3 -->
| Key | Question | Recommendation | Answer | State |
|---|---|---|---|---|
| D-4 | How does Claude get past the passkey lock? | Being on Jordan's Tailscale network, with his login, is the gate; no separate key | Tailscale identity is the gate; no separate key — jordan, 2026-10-15: “This is based on the Mac or device in question being on the same Tailscale network” | answered |
| D-5 | Show a banner, log Claude's actions, and let View only and Pause block Claude? | Yes | “yes” — jordan, 2026-10-15 | answered |
| D-6 | Add an Allow Claude switch on each Mac, off until turned on there? | Yes: since the passkey lock doesn't stop Claude, this switch is how a Mac opts in; it's one click per Mac, in the Tether panel | Yes: since the passkey lock doesn't stop Claude, this switch is how a Mac opts in; it's one click per Mac, in the Tether panel — jordan, 2026-10-16: “all rec” | answered |
| D-8 | Build P-3 alongside P-1 instead of after it? | Yes: a second Tether session builds PR-5 in its own worktree; S-15 and S-16 stop waiting on S-4, S-5 and S-6 (they only share SelfTest/main.swift, a small merge fix); S-17 still waits on S-4 and S-7 | Yes: a second Tether session builds PR-5 in its own worktree; S-15 and S-16 stop waiting on S-4, S-5 and S-6 (they only share SelfTest/main.swift, a small merge fix); S-17 still waits on S-4 and S-7 — jordan, 2026-10-16: “plangraph P-12, D-25, D-26, D-27, D-28, G-14, G-15, Tether D-7, D-8, mcp-tether D-4: all rec” | answered |
<!-- /graph -->

## Pull requests and keys
<!-- graph: steps P-3 -->
| Key | What | Files | Done when | Hours (est · used) | Waits on | State |
|---|---|---|---|---|---|---|
| T-4 | Jordan sees the Claude is connected banner and the activity log on the Studio | — | Jordan confirms the banner and the logged actions | 0.25 | V-5 | blocked |
| V-5 | Live: from the M5, screenshot and click on the Studio through its tailnet link | — | from the M5 (a tailnet device, so tailscale serve adds the login header): info answers; a screenshot comes back; after asking Jordan, the API's open-link action opens a data: URL test-bench page that logs clicks on the Studio, and a click at a point from the screenshot shows up in its log; with the switch Off, then with Pause on, the same curl for actions answers 403 | 1 | PR-5 | blocked |

**PR-5 · Claude API in Tether** · branch `feat/claude-api` · in progress

| Key | What | Files | Done when | Hours (est · used) | Waits on | State |
|---|---|---|---|---|---|---|
| S-15 | Read routes: /api/v1/info, screenshot, windows and apps | agent/Sources/Tether/API.swift, agent/Sources/Tether/Server.swift, agent/Sources/TetherCore/APIProtocol.swift, agent/Sources/SelfTest/main.swift, docs/API.md | the routes answer JSON (info: name, version, displays with size in points and pixels and their scale, permissions) and PNG or JPEG screenshots of a display or one window at full or a requested size, through a new capture function next to Thumbnails.capture (which only does JPEG of a display); one documented coordinate contract: screenshot pixels → points → the normalized 0…1 that ClientMessage.move takes (via WindowGeometry); SelfTest covers the shapes and the mapping for a display and a window at scale 1 and 2 | 4 · 19.84 | — | done |
| S-16 | POST /api/v1/actions: click, drag, scroll, type, keys, open app or link, through the Hub | agent/Sources/Tether/API.swift, agent/Sources/Tether/Hub.swift, agent/Sources/TetherCore/APIProtocol.swift, agent/Sources/SelfTest/main.swift | each action becomes the same ClientMessage the web page sends and goes through S-20's API client, so View only and Pause refuse it like any device; coordinates are pixels of the screenshot target (a display or one window) and map through S-15's contract; limits as named constants: at most 50 actions and 64 KB per call, text at most 4,096 characters, coordinates inside the target, keys only from the existing key table; the whole list is checked before anything runs (all or nothing); actions run in order, and a refusal midway (paused, switched off) stops the list and answers {error, index}; SelfTest maps every action and tests each rejection | 3.5 | S-15, S-20 | blocked |
| S-17 | Allow Claude switch, banner and activity log | agent/Sources/Tether/Server.swift, agent/Sources/Tether/AppState.swift, agent/Sources/Tether/Notifier.swift, agent/Sources/Tether/ActivityStore.swift, agent/Sources/TetherUI/StatusPanel.swift, agent/Sources/Snapshots/main.swift | a new AllowClaudeMiddleware answers 403 with a plain reason on every /api route while the switch is Off; /api is added to PauseMiddleware's list, so Pause refuses it; order is Tailscale login check, then pause, then Allow Claude; /api stays off the passkey gate's list (D-4); turning the switch Off or Pause mid-session removes the API client at once (releaseAll) and refuses calls already waiting; Claude's API client is listed under connected devices with Disconnect; while it is connected the Mac shows a Claude is connected banner and Recent activity lists each action; SelfTest or an HTTP-level test covers the three refusals (switch off, paused, view only); Snapshots render the switch in light and dark; CHANGELOG has an Unreleased line | 3 | S-16, D-6, S-7, Q-1 | blocked |
| S-18 | /peers says which Macs allow Claude | agent/Sources/Tether/Peers.swift, agent/Sources/Tether/Server.swift | each peer in /peers carries claude: true or false, so a client can list the Macs it may use | 1 | S-17 | blocked |
| S-19 | docs/API.md, README, SECURITY.md and CHANGELOG | docs/API.md, README.md, SECURITY.md, CHANGELOG.md, agent/Sources/SelfTest/main.swift | docs/API.md lists every route with an example, and a SelfTest case fails if a route registered in API.swift is missing from docs/API.md; SECURITY.md says what the switch allows and quotes D-4: the passkey lock does not cover the API | 1.5 | S-18, S-11 | blocked |
| S-20 | API session in the Hub: one reused client per calling device, no video | agent/Sources/Tether/Hub.swift, agent/Sources/TetherCore/APISession.swift, agent/Sources/SelfTest/main.swift | the first API call from a device adds one Hub client for it that starts no capture session and is reused by later calls; held buttons and keys stay down between calls, so a drag can span calls; after API_IDLE_SECONDS (120) with no call, or on Disconnect, the client is removed and releaseAll runs; its view only follows the Allow Claude setting (Q-1), not a message; SelfTest covers reuse, expiry with release, and view only refusing control | 2.5 | S-15, Q-1 | ready |
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
| R-8 | Claude acts on instructions it reads on a remote screen | medium · medium | Claude starts an action Jordan didn't ask for (seen in the banner or Recent activity) | S-17 | open |
<!-- /graph -->

## Verification
<!-- graph: checks P-3 -->
| Key | Check | Passes when | Command | Verifies | State |
|---|---|---|---|---|---|
| T-4 | Jordan sees the Claude is connected banner and the activity log on the Studio | Jordan confirms the banner and the logged actions | — | REQ-5 | blocked |
| V-5 | Live: from the M5, screenshot and click on the Studio through its tailnet link | from the M5 (a tailnet device, so tailscale serve adds the login header): info answers; a screenshot comes back; after asking Jordan, the API's open-link action opens a data: URL test-bench page that logs clicks on the Studio, and a click at a point from the screenshot shows up in its log; with the switch Off, then with Pause on, the same curl for actions answers 403 | `curl -s https://jordans-mac-studio.taile356c2.ts.net/api/v1/info` | REQ-4, REQ-5 | blocked |
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
| 2026-10-15 17:09 | S-15 | removed depends_on S-6 | claude | — |
| 2026-10-15 17:09 | S-15 | removed depends_on S-4 | claude | — |
| 2026-10-15 17:09 | S-15 | removed depends_on S-5 | claude | — |
| 2026-10-15 17:09 | S-16 | removed depends_on S-6 | claude | — |
| 2026-10-15 17:09 | S-16 | removed depends_on S-4 | claude | — |
| 2026-10-15 17:09 | S-16 | removed depends_on S-5 | claude | — |
| 2026-10-15 17:09 | S-17 | removed depends_on S-4 | claude | — |
| 2026-10-15 17:09 | S-17 | removed depends_on S-7 | claude | — |
| 2026-10-15 17:09 | S-15 | depends_on S-6 | claude | — |
| 2026-10-15 17:09 | S-17 | depends_on S-7 | claude | — |
| 2026-10-15 17:09 | Q-1 | added | claude | — |
| 2026-10-15 17:09 | S-20 | added | claude | — |
| 2026-10-15 17:09 | S-15 | set done_when, estimate_h | claude | — |
| 2026-10-15 17:09 | S-15 | set body | claude | — |
| 2026-10-15 17:09 | S-16 | depends_on S-20 | claude | — |
| 2026-10-15 17:09 | S-16 | set done_when, estimate_h | claude | — |
| 2026-10-15 17:09 | S-17 | set done_when, estimate_h | claude | — |
| 2026-10-15 17:09 | S-17 | depends_on Q-1 | claude | — |
| 2026-10-15 17:09 | S-20 | set done_when | claude | — |
| 2026-10-15 17:09 | S-20 | depends_on Q-1 | claude | — |
| 2026-10-15 17:09 | D-6 | set body | claude | — |
| 2026-10-15 17:09 | R-7 | set body | claude | — |
| 2026-10-15 17:09 | R-8 | set body, trigger | claude | — |
| 2026-10-15 17:09 | S-19 | set command, done_when, files | claude | — |
| 2026-10-15 17:09 | V-5 | set command, done_when | claude | — |
| 2026-10-15 17:10 | P-3 | reviewed (11 findings): Reviewer found 10 (2 blocking) plus the open review gap. Added S-20, an API client per device in the Hub that starts no video, keeps drags across calls and expires after 2 min; Q-1 on how Claude's View only is set; S-17 now adds /api to Pause, a 403 Allow Claude check in a stated order, instant cut-off, Disconnect, tests for all three refusals and the CHANGELOG line; S-15 gains window and full-size capture and one tested coordinate contract; S-16 gains numeric limits and all-or-nothing checking; S-19 tests the docs against the routes; V-5 names the Studio and the bench; R-7 and R-8 reworded; cross-plan edges cut to S-6 and S-7 (check needs them for shared files), with P-1's 12.5 h lead stated | claude | — |
| 2026-10-16 14:25 | D-6 | answered: “all rec” | jordan | — |
| 2026-10-16 14:25 | P-3 | approved: “all rec” | jordan | — |
| 2026-10-16 14:25 | Q-1 | answered: “all rec” | jordan | — |
| 2026-10-16 14:43 | D-8 | added | claude | — |
| 2026-10-16 15:05 | D-8 | answered: “plangraph P-12, D-25, D-26, D-27, D-28, G-14, G-15, Tether D-7, D-8, mcp-tether ” | jordan | — |
| 2026-10-16 15:05 | S-15 | removed depends_on S-6 | claude | — |
| 2026-10-16 15:05 | S-15 | D-8 (Jordan, 16 Oct): P-3 builds alongside P-1, so S-15 no longer waits on S-6; SelfTest/main.swift is shared, so merge main before each PR | claude | — |
| 2026-10-16 15:07 | S-15 | claimed | claude | — |
| 2026-10-16 15:10 | S-15 | docs/API.md starts in S-15 with the read routes and the coordinate contract, so mcp-tether can build against them now; S-19 completes it | claude | — |
| 2026-10-17 10:58 | S-15 | done: SelfTest 253/253 (API shapes, screenshot query checks, pixel→point→normalized for a display and a wi | claude | 870b490 |
<!-- /graph -->

## Results
What happened: pull requests and commits, before/after numbers, what's left.
