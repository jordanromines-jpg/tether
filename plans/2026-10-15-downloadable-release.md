# Tether as a download that updates itself

<!-- graph: status P-1 -->
Status: in progress (approved 2026-10-16 by jordan: “all rec”)

- Work: 3 of 20 done; hours 28.75 · 0.19 of a 30 h box
- Doing: — · Ready: S-8, T-3 · Next: S-8
- Blocked (15):
  - T-1 waits on S-13
  - T-2 waits on S-12
  - V-1 waits on PR-2, PR-3
  - V-2 waits on S-14
  - V-3 waits on T-1
  - V-4 waits on T-2
  - S-5 waits on T-3
  - S-6 waits on S-5
  - … and 7 more (`plangraph status P-1`)
- Waiting on Jordan: G-1, G-2
- Estimates: done work took 0.027× its estimate (0.19 h of 7 h over 3 items)
- Critical path: T-3 → S-5 → S-6 → S-7 → … 2 more … → S-12 → T-2 → V-4 (12.25 h left)
<!-- /graph -->

What started it: Jordan, 15 Oct 2026, choosing the updater: "Yes" to "Use Sparkle for the updater". Then: "Back to the plan for Tether". It came from the question of whether Tether could be a download instead of a build on every Mac, without paying Apple. Jordan chose F-1 to F-3 from the options: two keys with different jobs, Sparkle as the updater, and GitHub's build attestation. The skill that teaches this pattern is a separate plan in hub-claude-skills.

## Why
Today every Mac that runs Tether either builds it itself (Apple's developer tools, a copy of the source, its own signing identity in `~/Library/Keychains/tether-signing.keychain-db`) or is updated from another Mac by `scripts/deploy.sh`. The evidence is in the code:
- `UpdateMode.decide` (`agent/Sources/TetherCore/Update.swift`) has only "here", "elsewhere" and "manual".
- `Updater.start` runs `scripts/update.sh` from the source folder.
- `build-app.sh` signs with whichever identity that Mac made.

That makes setup 20 to 30 minutes for anyone, mostly the first build, and Jordan's three Macs each need their own care. Nothing here has been tried yet: Sparkle under `swift build` (R-1) and Gatekeeper on macOS 26 (R-2) are checked early, by S-3 and by T-3, a hand-made zip opened on macOS 26 before PR-2 is built.

## Design
Four pull requests:

- **PR-1, Sparkle inside Tether.** Sparkle 2.x joins `agent/Package.swift`. `scripts/build-app.sh --release` embeds it and signs it inside out, and only release builds carry the feed address and the public update key. A new `agent/Sources/Tether/ReleaseUpdater.swift` drives Sparkle. `UpdateMode` gains a release case, so source builds keep today's git route (D-3). Updates download quietly and install only while no device is connected.
- **PR-2, first run without setup.sh.** A new `agent/Sources/Tether/FirstRun.swift` moves the app to `~/Applications`. Then it does in Swift what `scripts/lib/install-agent.sh` does today: `config.json` with the signed-in Tailscale login, the same LaunchAgent, and `tailscale serve`. The Setup Assistant gains Tailscale and HTTPS steps.
- **PR-3, release pipeline and keys.** `scripts/make-release-keys.sh` makes one release signing identity, which goes into a GitHub secret, and the Sparkle update key, which stays in the Studio's keychain (D-1). Jordan does the storing and the backup himself (G-1). `.github/workflows/release.yml` builds a universal app (D-2) on a pushed tag, zips it, attests where it was built and attaches it to a draft release. `scripts/release-approve.sh` runs on the Studio: it checks the attestation and the signing identity, signs the zip with the update key, and publishes the feed. The feed is `appcast.xml` on a permanent release named `appcast`; trial releases use `appcast-test.xml`, so no real install sees them.
- **PR-4, docs.** `README.md`, `CLAUDE.md`, `SECURITY.md` and `CHANGELOG.md`.

The order is rc1 (S-13, then T-1 and V-3), rc2 (S-14, then V-2), then the v6.1.0 gate. Release builds number themselves from the tag so Sparkle can tell rc1 < rc2 < v6.1.0 (S-3), rc tags point at the test feed and final tags at the real one (S-9, checked live by V-4), and a bad release can be withdrawn from the feed (S-10, R-6). Jordan's three Macs move last; each re-grants the two permissions once, because the signing identity changes from each Mac's own to the release one.

Choices made without asking, all easy to reverse:
- The download is a zip, not a disk image.
- The feed lives on GitHub Releases.
- plangraph is **not** switched on in `.claude/settings.json` here. Tether is public and its README tells strangers to run `claude` in it, so they would be asked to trust Jordan's plugin source. plangraph is already on the PATH of all three Macs.

## What this does NOT do
- No Apple Developer account, notarization or Mac App Store.
- No automatic approval: every release is approved on the Studio by a session (D-1).
- No change to the web client, the protocol or how devices connect.
- No MCP server for Claude to control Macs through Tether. It is parked in the Inbox (S-1) for its own plan.
- No rotating-key scheme (F-5): revisit only if F-1 proves not enough.

## Requirements
<!-- graph: reqs P-1 -->
| Key | Requirement | Acceptance | Built by | Verified by | State |
|---|---|---|---|---|---|
| REQ-1 | Install from a download, with no developer tools and no copy of the source | WHEN someone downloads Tether.zip from a GitHub Release and opens it on a Mac without Apple's developer tools THEN after Open Anyway, Tailscale and the two permissions, Tether serves its link | S-5, S-6, S-7, S-9, S-11, S-12, S-13 | T-1, T-2, T-3, V-1, V-3 | open |
| REQ-2 | Updates install themselves and keep the permissions | WHEN a newer release is approved THEN within a day each installed Tether downloads it, swaps it in while nobody is connected, restarts, and /healthz still reports screen and input permission true | S-2, S-3, S-4, S-14 | V-1, V-2, V-4 | open |
| REQ-3 | Only an update approved with the offline update key is installed | WHEN a release lacks a valid signature from the update key, or the key is absent from GitHub entirely THEN no installed Tether installs it, and the release workflow holds no update-key secret | S-3, S-8, S-9, S-10 | V-1, V-2 | open |
<!-- /graph -->

## Decisions
<!-- graph: decisions P-1 -->
| Key | Question | Recommendation | Answer | State |
|---|---|---|---|---|
| D-1 | Where does the update key live, and who approves each release? | The Mac Studio's keychain. After a release build passes, a Claude session runs scripts/release-approve.sh there (releasing is already a routine call) | The Mac Studio's keychain; a Claude session approves each release after its build passes — jordan, 2026-10-15: “This is good with me.” | answered |
| D-2 | Build for Apple silicon and Intel, or Apple silicon only? | Both (a universal app): one extra flag on the build, and Tether stays usable on older Intel Macs | Both (a universal app): one extra flag on the build, and Tether stays usable on older Intel Macs — jordan, 2026-10-16: “all rec” | answered |
| D-3 | Keep the build-from-source route for developers? | Yes: setup.sh and git-based Update now stay for people who change Tether; the download becomes the main way in, and Jordan's three Macs move to it | Yes: setup.sh and git-based Update now stay for people who change Tether; the download becomes the main way in, and Jordan's three Macs move to it — jordan, 2026-10-16: “all rec” | answered |
| D-7 | Make the release keys now, in a separate session on the Studio? | Yes: S-8 only touches scripts/make-release-keys.sh, so it can run beside the build, and G-1 reaches Jordan hours sooner | Yes: S-8 only touches scripts/make-release-keys.sh, so it can run beside the build, and G-1 reaches Jordan hours sooner — jordan, 2026-10-16: “plangraph P-12, D-25, D-26, D-27, D-28, G-14, G-15, Tether D-7, D-8, mcp-tether D-4: all rec” | answered |
<!-- /graph -->

## Pull requests and keys
<!-- graph: steps P-1 -->
| Key | What | Files | Done when | Hours (est · used) | Waits on | State |
|---|---|---|---|---|---|---|
| T-1 | Jordan installs rc1 from the download on one Mac | — | after Open Anyway and the two permissions, his phone shows that Mac's screen | 0.5 | S-13 | blocked |
| T-2 | Jordan's three Macs run the download | — | each Mac shows v6.1.0 in the panel after one last permission re-grant | 1 | S-12 | blocked |
| T-3 | Gatekeeper probe: a hand-made zip opens on macOS 26 with Open Anyway | — | the downloaded zip's app opens after System Settings → Privacy and Security → Open Anyway | 0.25 | S-3 | ready |
| V-1 | Logic tests pass | — | all five pass | 0.25 | PR-1, PR-2, PR-3 | blocked |
| V-2 | rc2 updates rc1 by itself and the permissions stay on | — | after rc2 is approved to the test feed, the Mac runs rc2 within a day without a prompt, and healthz shows screen and input true; an rc signed with a wrong update key is refused | 1 | S-14 | blocked |
| V-3 | Download install works on a Mac without developer tools | — | Tether serves its link there | 0.5 | T-1 | blocked |
| V-4 | v6.1.0 on Jordan's Macs reads the production feed | — | on each of Jordan's Macs the installed app's SUFeedURL is appcast.xml (not appcast-test.xml) and Sparkle's last check in Tether.log reached it without an error | 0.25 | T-2 | blocked |

**PR-1 · Sparkle inside Tether** · branch `feat/sparkle` · done

| Key | What | Files | Done when | Hours (est · used) | Waits on | State |
|---|---|---|---|---|---|---|
| S-2 | Add Sparkle 2.x, pinned, to the Swift package | agent/Package.swift, agent/Package.resolved | the release build links Sparkle | 1 · 0.03 | — | done |
| S-3 | build-app.sh --release: embed and sign Sparkle, set the feed address and the public update key | scripts/build-app.sh, scripts/tests/build-version.test.sh | build/Tether.app has Contents/Frameworks/Sparkle.framework, SUFeedURL and SUPublicEDKey only in --release builds, passes a deep signature check, and CFBundleVersion is the number from the tag; a script test checks rc1 < rc2 < final and that --feed test and --feed prod give the two feed addresses | 3 · 0.1 | S-2, D-2 | done |
| S-4 | Release builds update through Sparkle: download in the background, install while nobody is connected | agent/Sources/Tether/ReleaseUpdater.swift, agent/Sources/Tether/Updater.swift, agent/Sources/Tether/Updates.swift, agent/Sources/TetherCore/Update.swift, agent/Sources/SelfTest/main.swift, agent/Sources/TetherUI/StatusPanel.swift, agent/Sources/Tether/MenuBar.swift | UpdateMode has a release case chosen when the app carries SUFeedURL; the SelfTest cases for it pass; the panel shows Sparkle's status for release builds and the git route for source builds | 3 · 0.06 | S-3 | done |

**PR-2 · First run without setup.sh** · branch `feat/first-run` · open

| Key | What | Files | Done when | Hours (est · used) | Waits on | State |
|---|---|---|---|---|---|---|
| S-5 | Move itself to ~/Applications on first launch | agent/Sources/Tether/FirstRun.swift, agent/Sources/TetherCore/Setup.swift, agent/Sources/SelfTest/main.swift | opened from Downloads, Tether offers to move to ~/Applications and relaunches from there; SelfTest covers the path rules | 1.5 | S-4, T-3 | blocked |
| S-6 | First run does what install-agent.sh does: config, start at login, tailscale serve | agent/Sources/Tether/FirstRun.swift, agent/Sources/TetherCore/Setup.swift, agent/Sources/SelfTest/main.swift | with no config.json, Tether reads the signed-in login from tailscale status, writes config.json, installs the same LaunchAgent and runs tailscale serve; with an existing config.json it keeps it and clears updateFrom; SelfTest compares against install-agent.sh itself and covers the four failure paths and the existing-config case | 4 | S-5 | blocked |
| S-7 | Setup Assistant covers a download install: Tailscale, HTTPS certificates, permissions | agent/Sources/TetherUI/SetupAssistant.swift, agent/Sources/Snapshots/main.swift | Snapshots render the new Tailscale and HTTPS steps in light and dark | 2 | S-6 | blocked |

**PR-3 · Release pipeline and the update key** · branch `feat/release-pipeline` · open

| Key | What | Files | Done when | Hours (est · used) | Waits on | State |
|---|---|---|---|---|---|---|
| S-8 | Make the keys: one release signing identity, and the update key in the Studio keychain | scripts/make-release-keys.sh | the Studio keychain holds the update key; the script exports it to a file for G-1's backup, re-imports that export into a scratch keychain and signs a test file with it, prints the public key, and exits non-zero if the two public keys differ; it prints the one gh secret set command Jordan runs for the signing identity | 1.75 | D-1 | ready |
| S-9 | GitHub workflow: on a tag, build, sign, attest, attach to a draft release | .github/workflows/release.yml | a pushed rc tag produces a draft release with Tether.zip and a build attestation, and the workflow has no update-key secret | 2.5 | S-3, G-1 | blocked |
| S-10 | release-approve.sh: verify the build, sign it with the update key, publish the feed | scripts/release-approve.sh, scripts/tests/release-approve.test.sh | the script refuses a zip without a valid attestation or with the wrong signing identity, and otherwise writes the appcast item with sign_update and publishes it to the feed the tag names; --withdraw <tag> removes that item from the feed; the test covers refuse, publish and withdraw | 2.5 | S-9 | blocked |
| S-12 | Publish v6.1.0 | VERSION, CHANGELOG.md | the v6.1.0 release has Tether.zip and the live appcast lists it | 0.5 | G-2, S-10, S-11, S-14 | blocked |
| S-13 | Cut rc1: tag, build, approve to the test feed | VERSION, CHANGELOG.md | the v6.1.0-rc1 release has Tether.zip, gh attestation verify passes, and appcast-test.xml lists rc1 with an update-key signature | 0.75 | S-10, PR-1, PR-2 | blocked |
| S-14 | Cut rc2: tag, build, approve to the test feed | CHANGELOG.md | appcast-test.xml lists rc2 with a sparkle:version above rc1's | 0.5 | T-1 | blocked |

**PR-4 · Docs for the download** · branch `docs/download` · open

| Key | What | Files | Done when | Hours (est · used) | Waits on | State |
|---|---|---|---|---|---|---|
| S-11 | README, CLAUDE.md, SECURITY.md and CHANGELOG for the download | README.md, CLAUDE.md, SECURITY.md, CHANGELOG.md | README leads with Download; building from source is the developer route; SECURITY.md explains the two keys and the attestation; CLAUDE.md's runbook covers a download install | 2 | S-7, S-10, D-3, S-13 | blocked |
<!-- /graph -->

## Gates that need Jordan
<!-- graph: gates P-1 -->
| Key | What Jordan does | Recommendation | Answer | State |
|---|---|---|---|---|
| G-1 | Jordan stores the signing identity in GitHub and backs up the update key | Run the printed gh secret set command, and save the exported update key in your password manager | — | open |
| G-2 | First public release, v6.1.0 | Go once V-2 and V-3 have passed | — | open |
<!-- /graph -->

## Risks
<!-- graph: risks P-1 -->
| Key | Risk | Likelihood · impact | Trigger | Mitigated by | State |
|---|---|---|---|---|---|
| R-1 | Sparkle's helpers don't run when built with swift build instead of Xcode | medium · high | codesign --verify --deep fails, or Sparkle can't launch its installer | S-3 | open |
| R-2 | macOS 26 blocks unnotarized apps more tightly than Open Anyway | low · high | T-3 (right after S-3) finds no Open Anyway button | T-3 | open |
| R-3 | The update key is lost: downloaded installs can never update again | low · high | the Studio keychain is lost and no backup exists | S-8 | open |
| R-4 | The signing identity leaks from GitHub | low · medium | the GitHub secret is exposed | S-10 | open |
| R-5 | An update restarts Tether while someone is using it | medium · medium | a device is disconnected by an install | S-4 | open |
| R-6 | A published release is broken and every installed Tether takes it | low · high | after a release is published, a Mac's Tether doesn't start or loses its permissions | S-10 | open |
<!-- /graph -->

## Verification
<!-- graph: checks P-1 -->
| Key | Check | Passes when | Command | Verifies | State |
|---|---|---|---|---|---|
| T-1 | Jordan installs rc1 from the download on one Mac | after Open Anyway and the two permissions, his phone shows that Mac's screen | — | REQ-1 | blocked |
| T-2 | Jordan's three Macs run the download | each Mac shows v6.1.0 in the panel after one last permission re-grant | — | REQ-1 | blocked |
| T-3 | Gatekeeper probe: a hand-made zip opens on macOS 26 with Open Anyway | the downloaded zip's app opens after System Settings → Privacy and Security → Open Anyway | — | REQ-1 | ready |
| V-1 | Logic tests pass | all five pass | `swift run --package-path agent SelfTest && node --test web/tests/*.test.mjs && bash scripts/tests/update.test.sh && bash scripts/tests/build-version.test.sh && bash scripts/tests/release-approve.test.sh` | REQ-2, REQ-1, REQ-3 | blocked |
| V-2 | rc2 updates rc1 by itself and the permissions stay on | after rc2 is approved to the test feed, the Mac runs rc2 within a day without a prompt, and healthz shows screen and input true; an rc signed with a wrong update key is refused | `curl -s -H 'Tailscale-User-Login: <login>' http://127.0.0.1:7400/healthz` | REQ-2, REQ-3 | blocked |
| V-3 | Download install works on a Mac without developer tools | Tether serves its link there | `manual: on a Mac where xcode-select -p fails, install rc1 and open the link` | REQ-1 | blocked |
| V-4 | v6.1.0 on Jordan's Macs reads the production feed | on each of Jordan's Macs the installed app's SUFeedURL is appcast.xml (not appcast-test.xml) and Sparkle's last check in Tether.log reached it without an error | `plutil -extract SUFeedURL raw ~/Applications/Tether.app/Contents/Info.plist && grep -i sparkle ~/Library/Logs/Tether.log \| tail -5` | REQ-2 | blocked |
<!-- /graph -->

## Build log
<!-- graph: log P-1 -->
| When | Key | What | By | Commit |
|---|---|---|---|---|
| 2026-10-15 16:54 | D-1 | added | claude | — |
| 2026-10-15 16:54 | D-2 | added | claude | — |
| 2026-10-15 16:54 | D-3 | added | claude | — |
| 2026-10-15 16:54 | P-1 | added | claude | — |
| 2026-10-15 16:54 | REQ-1 | added | claude | — |
| 2026-10-15 16:54 | REQ-2 | added | claude | — |
| 2026-10-15 16:54 | REQ-3 | added | claude | — |
| 2026-10-15 16:55 | PR-1 | added | claude | — |
| 2026-10-15 16:55 | PR-2 | added | claude | — |
| 2026-10-15 16:55 | PR-3 | added | claude | — |
| 2026-10-15 16:55 | PR-4 | added | claude | — |
| 2026-10-15 16:55 | S-2 | added | claude | — |
| 2026-10-15 16:55 | S-3 | added | claude | — |
| 2026-10-15 16:55 | S-4 | added | claude | — |
| 2026-10-15 16:55 | S-5 | added | claude | — |
| 2026-10-15 16:55 | S-6 | added | claude | — |
| 2026-10-15 16:55 | S-7 | added | claude | — |
| 2026-10-15 16:55 | S-8 | added | claude | — |
| 2026-10-15 16:55 | V-1 | added | claude | — |
| 2026-10-15 16:55 | R-1 | added | claude | — |
| 2026-10-15 16:55 | R-2 | added | claude | — |
| 2026-10-15 16:55 | R-2 | set body | claude | — |
| 2026-10-15 16:55 | R-3 | added | claude | — |
| 2026-10-15 16:55 | R-3 | set body | claude | — |
| 2026-10-15 16:55 | R-4 | added | claude | — |
| 2026-10-15 16:55 | R-5 | added | claude | — |
| 2026-10-15 16:55 | S-3 | mitigates R-1 | claude | — |
| 2026-10-15 16:55 | S-4 | mitigates R-5 | claude | — |
| 2026-10-15 16:55 | G-1 | added | claude | — |
| 2026-10-15 16:55 | G-2 | added | claude | — |
| 2026-10-15 16:55 | S-9 | added | claude | — |
| 2026-10-15 16:55 | S-10 | added | claude | — |
| 2026-10-15 16:55 | S-11 | added | claude | — |
| 2026-10-15 16:55 | T-1 | added | claude | — |
| 2026-10-15 16:55 | V-2 | added | claude | — |
| 2026-10-15 16:55 | V-3 | added | claude | — |
| 2026-10-15 16:55 | S-10 | mitigates R-4 | claude | — |
| 2026-10-15 16:55 | S-12 | added | claude | — |
| 2026-10-15 16:55 | S-12 | depends_on S-11 | claude | — |
| 2026-10-15 16:55 | T-2 | added | claude | — |
| 2026-10-15 16:58 | R-6 | added | claude | — |
| 2026-10-15 16:58 | S-3 | review: comparable CFBundleVersion | claude | — |
| 2026-10-15 16:58 | S-9 | review: feed per tag, universal toolchain | claude | — |
| 2026-10-15 16:58 | S-10 | review: withdraw | claude | — |
| 2026-10-15 16:58 | S-10 | mitigates R-6 | claude | — |
| 2026-10-15 16:58 | V-4 | added | claude | — |
| 2026-10-15 16:59 | S-13 | added | claude | — |
| 2026-10-15 16:59 | S-14 | added | claude | — |
| 2026-10-15 16:59 | T-1 | depends_on S-13 | claude | — |
| 2026-10-15 16:59 | T-1 | removed depends_on S-10 | claude | — |
| 2026-10-15 16:59 | V-2 | depends_on S-14 | claude | — |
| 2026-10-15 16:59 | V-2 | removed depends_on T-1 | claude | — |
| 2026-10-15 16:59 | S-6 | review: no drift, failure paths, existing installs | claude | — |
| 2026-10-15 16:59 | R-2 | review: earlier trigger | claude | — |
| 2026-10-15 16:59 | R-3 | review: mitigation | claude | — |
| 2026-10-15 16:59 | R-4 | review: what a leak can and can't do | claude | — |
| 2026-10-15 16:59 | S-5 | depends_on T-3 | claude | — |
| 2026-10-15 16:59 | S-8 | mitigates R-3 | claude | — |
| 2026-10-15 16:59 | S-8 | review: checkable export | claude | — |
| 2026-10-15 16:59 | T-2 | review: migration steps | claude | — |
| 2026-10-15 16:59 | T-3 | added | claude | — |
| 2026-10-15 16:59 | T-3 | mitigates R-2 | claude | — |
| 2026-10-15 16:59 | V-1 | verifies REQ-1 | claude | — |
| 2026-10-15 16:59 | V-1 | verifies REQ-3 | claude | — |
| 2026-10-15 16:59 | V-1 | review: five suites | claude | — |
| 2026-10-15 16:59 | S-12 | review: withdraw | claude | — |
| 2026-10-15 16:59 | D-1 | answered: “This is good with me.” | jordan | — |
| 2026-10-15 16:59 | S-13 | review: files | claude | — |
| 2026-10-15 16:59 | S-14 | review: files | claude | — |
| 2026-10-15 17:00 | S-12 | depends_on S-14 | claude | — |
| 2026-10-15 17:00 | S-11 | depends_on S-13 | claude | — |
| 2026-10-15 17:00 | P-1 | reviewed (10 findings): Reviewer found 3 blockers, 4 gaps, 3 minor. Fixed: S-3 numbers release builds from the tag so Sparkle orders rc1 < rc2 < v6.1.0, and --feed picks the test or real feed (S-9 per tag, V-4 checks the real feed live); new S-13/S-14 cut and approve rc1 and rc2; S-10 gains --withdraw with new risk R-6; S-6 keeps existing installs, compares against install-agent.sh itself and names its failure paths; T-3 probes Gatekeeper on macOS 26 before PR-2; S-8 proves the key export restores (R-3); R-4 says what a leak can do; V-1 covers REQ-1 to REQ-3. Not changed: Package.resolved is tracked; plangraph has no decider field (decisions are Jordan's). 28.75 h of 30. | claude | — |
| 2026-10-16 14:25 | D-2 | answered: “all rec” | jordan | — |
| 2026-10-16 14:25 | D-3 | answered: “all rec” | jordan | — |
| 2026-10-16 14:25 | P-1 | approved: “all rec” | jordan | — |
| 2026-10-16 14:30 | S-2 | claimed | claude | — |
| 2026-10-16 14:32 | S-2 | done: swift build -c release: Build complete; otool -L Tether: @rpath/Sparkle.framework/Versions/B/Sparkle | claude | bde5f74 |
| 2026-10-16 14:32 | S-3 | claimed | claude | — |
| 2026-10-16 14:38 | S-3 | done: build-version.test.sh: 17 passed, 0 failed. --release --tag v6.1.0-rc1 (throwaway identity, random k | claude | d42640f |
| 2026-10-16 14:38 | S-4 | claimed | claude | — |
| 2026-10-16 14:38 | S-4 | files: MenuBar.swift builds the banner from UpdateMode, so the new case needs it | claude | — |
| 2026-10-16 14:42 | S-4 | done: SelfTest 221/221 (new: mode release wins over checkout, empty feed is source, install waits while a | claude | 2a61287 |
| 2026-10-16 14:43 | D-7 | added | claude | — |
| 2026-10-16 14:44 | S-8 | claimed | claude | — |
| 2026-10-16 14:49 | S-8 | Script built and tested (commit 25b0fb6, branch feat/release-pipeline): in a throwaway HOME it makes the update key, proves the backup restores (scratch keychain, sign_update, CryptoKit verify), exits 1 on a mismatched backup, keeps existing keys on re-run, and the secret imports as a code-signing identity. Uses a dedicated keychain on the Studio (tether-release.keychain-db, password in ~/.config/tether/release), because the login keychain is locked to SSH. Running it on the Studio over SSH was refused by the permission check, so Jordan runs it there himself as part of G-1. Studio checkout: ~/projects/tether on feat/release-pipeline. | claude | — |
| 2026-10-16 14:50 | S-8 | released (claimed 0.1 h) | claude | — |
| 2026-10-16 15:04 | T-3 | Probe ready (not the real Tether, so it can't clash with the running one): TetherGatekeeperProbe.app, bundle id com.tether.gatekeeper-probe, universal, Sparkle.framework embedded and signed inside out with a self-signed 'Tether Release'-style identity, the same codesign flags as build-app.sh --release (no hardened runtime, --timestamp=none), zipped with ditto; spctl rejects it as expected. On draft release https://github.com/jordanromines-jpg/tether/releases/tag/untagged-91ce7af59446643f91a6 (asset TetherGatekeeperProbe.zip, only visible signed in to GitHub). Pass = the window 'Gatekeeper probe OK' opens after Open Anyway. | claude | — |
| 2026-10-16 15:05 | D-7 | answered: “plangraph P-12, D-25, D-26, D-27, D-28, G-14, G-15, Tether D-7, D-8, mcp-tether ” | jordan | — |
| 2026-10-16 15:05 | S-8 | D-7 (Jordan, 16 Oct): built now, in its own session on the Studio | claude | — |
<!-- /graph -->

## Results
What happened: pull requests and commits, before/after numbers, what's left.
