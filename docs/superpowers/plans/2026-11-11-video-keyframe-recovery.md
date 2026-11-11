# Video Keyframe Recovery Implementation Plan

**Goal:** Integrate the capture-supported direct `18/47` request into the existing preview recovery path.

**Architecture:** Pure codec, bounded Session-owned pulse, and separately tested preview-observation policy. AppController connects them and supplies status/manual recovery to the existing preview card.

**Spec:** `docs/superpowers/specs/2026-11-11-video-keyframe-recovery-design.md`

- [x] Verify golden true/false DUML bytes and CRC; implement the codec and direct Session pulse with a single monotonic clock, timer ownership, freshness checks, five-second cooldown and bounded send waits.
- [x] Add failing policy cases for normal output, first-key wait, stale video/control, paused decoder, three-attempt exhaustion, cooldown, sustained recovery, delayed/rejected sends and superseded sessions. Implement the policy and actual-key/output success criteria.
- [x] Integrate controller observations, bounded logs/status and manual preview recovery. Test the real controller path and preserve existing capture, flight, task, camera and media behavior.
- [x] Reproduce the completed dolly → ordinary-hover handoff deadlock. Add a candidate-image branch, then reuse native completion, preparation, selection and strict tracking readiness before circle. Cover invalid identity/freshness/decoder/camera/task/flight evidence and cancellation. Keep the transition automatic without additional user confirmation.
- [x] Independently review asynchronous identity/reset and retry boundaries; run the complete domain suite and verify unchanged native code, then build a signed HAP and verify source parity.
- [ ] User-operated real-device verification: first ground preview and then the original freeze scenario. Leave this unchecked unless observed.

Review focus: false must follow true even if new frames arrive first; old callbacks must never send through a replacement session; no awaiting the pulse from the stick tick; no requests for a silent video stream or after a native automatic pause; neither a successful send nor an unrelated old frame is reported as a restored image.

## Verification and delivery

- Full core suite: 729 passed, 0 failed/skipped/cancelled (`diagnostics/keyframe-closeup-core-full.log`). New closeup boundary suite: 13 passed, including a real Controller policy path that waits for a new keyframe and new rendered pixels before candidate capture, selection and circle readiness.
- Independent review: cooldown publication timing and stale UI result issues were reproduced and fixed; final keyframe and closeup reviews found no outstanding P1/P2 issues.
- Signed Harmony build succeeded. Project and build copy contain exactly 114 source files, with no missing/extra/hash-mismatched source files. Native library SHA256 remains `1409021AAF54BDB59073538192461C8A346519FC321C56A6C897E232EA0E986E`, identical to the reverted baseline; no native implementation changes were included.
- Delivered first, as requested, to `D:/无人机demo/Neo2/Neo2-keyframe-closeup-20261111.hap`, 16,757,856 bytes, SHA256 `32151D7C56370133CCD190283188090D95788E0BEDDAA7E8E7D00F651BE7683A`. Build receipt and final artifact verification are under `diagnostics/neo2-keyframe-closeup-20261111-result.json` and `diagnostics/keyframe-closeup-artifact-verification.json`.
- No installation or aircraft commands were performed. Real-device confirmation of frozen-picture recovery and the complete automatic dolly-to-circle transition remains pending.
