# Plans changelog

One line per change to any plan, newest first, in the same commit as the change.
- 2026-10-17: P-3 S-15 built and merged (#11): /api/v1 read routes, shapes and coordinate contract; S-15 gains docs/API.md (read routes and the planned actions shape, so mcp-tether can start; S-19 completes it)
- 2026-10-16: D-7 and D-8 answered (Jordan: "all rec"); S-15 no longer waits on S-6 (D-8)
- 2026-10-16: P-1 T-3 noted: Gatekeeper probe app on a draft release, ready for Jordan
- 2026-10-16: P-1 D-7 (make the release keys now, in a separate session on the Studio) and D-8 (build P-3 alongside P-1) added for Jordan, open (merged with #7); S-8 released until D-7 is answered
- 2026-10-16: P-1 S-8 built and tested but not yet run on the Studio (the permission check refused key creation over SSH; Jordan runs it as part of G-1); the update key goes in a dedicated Studio keychain because the login keychain is locked to SSH
- 2026-10-16: P-1 PR-1 built and merged (S-2, S-3, S-4); S-4's files gain MenuBar.swift, whose update banner switches over UpdateMode
- 2026-10-15: P-3 reviewed (11 findings): API client per device in the Hub (S-20), Q-1 on Claude's View only, Pause and the Allow Claude check cover /api with tests for each refusal, screenshot coordinate contract, action limits, docs checked against the routes, live check names the Studio; cross-plan waits cut to P-1's S-6 and S-7
- 2026-10-15: P-1 reviewed (10 findings): release builds numbered from the tag, rc1 and rc2 cut steps (S-13, S-14), withdraw path (R-6), live check of the real feed (V-4), early Gatekeeper probe (T-3), existing installs kept by first run; D-1 answered by Jordan
- 2026-10-15: plangraph switched on (plans only); P-1 Tether as a download that updates itself: new plan, awaiting Jordan's approval; MCP server idea held in the Inbox
