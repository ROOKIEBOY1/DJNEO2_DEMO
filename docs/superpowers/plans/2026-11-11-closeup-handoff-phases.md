# Closeup Handoff Phase Recovery Implementation Plan

**Goal:** Allow the logged dolly-to-circle transition to finish automatic picture recovery after the aircraft completes its normal finishing phase.

**Architecture:** Keep the existing controller and keyframe policy. Split the handoff clock and add a local rendered-progress window; retain the existing post-frame identity and motion gates.

**Tech Stack:** ArkTS, existing Harmony APIs, Node core test runner.

**Spec:** `docs/superpowers/specs/2026-11-11-closeup-handoff-phases-design.md`

- [x] Reproduce the 7.1-second finishing delay plus output stall in a failing real-controller regression.
- [x] Implement fixed phase deadlines, bounded recovery observation, stable output and retry cleanup in AppController; adapt existing partial preview fixtures to report real progress.
- [x] Verify original-subject/candidate paths, no-output deadline, capture failure, decoder change and cancellation; independently review the change.
- [x] Build and copy a signed HAP to the project root, then run the complete core suite and check exact production-source/native parity.
- [ ] Real-device validation of the original 12:33 trajectory and longer-term intermittent decoder behavior. Leave pending until observed.

## Verification

- New handoff regression suite: 7 groups, including the original timeline, bounded phase clocks, real rendered-counter progress, missing-frame retry, cancellation/identity/hover fencing, shared automatic keyframe quota and actual `captureVlmFrame` deadline clipping (97ms remaining and unchanged 600ms default).
- Existing closeup boundary suite: 36/36 passed. Combined reacquire/new handoff suites: 20/20 passed. Full core suite: 736 passed, 0 failed/skipped/cancelled (`diagnostics/handoff-recovery-core-full.log`).
- Independent review found no outstanding P1/P2; independently exercised a 75ms remaining frame budget and image packing returning past the phase deadline. Overdue packed pixels are rejected and pixel/packer resources released. The asynchronous pack itself is not force-cancelled or raced.
- Signed build succeeded and was delivered before the full regression run completed: `D:/无人机demo/Neo2/Neo2-handoff-recovery-20261111.hap`, 16,765,818 bytes, SHA256 `043FE58C24D918C2D6066ABB7E424175ECEFED70BB130A5D6E5957DF5F635AF4`.
- All 114 production sources match the build copy in both file set and hashes. Native library remains identical to the reverted baseline (`1409021AAF54BDB59073538192461C8A346519FC321C56A6C897E232EA0E986E`). Receipt: `diagnostics/handoff-recovery-artifact-verification.json`.
- No installation or live aircraft action. This fixes the confirmed handoff recovery/timing gaps; the underlying cause of intermittent native decoder stalls remains unconfirmed.
