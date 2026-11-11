# Recording State Observation Repair

**Goal:** Preserve an actual recording report even when an idle report arrives in the same UDP packet or before the 250ms UI notification.

**Design:** `TelemetryStore.observe` returns only the camera report accepted by that call. DroneSession synchronously notifies a dedicated camera listener immediately after each accepted report and before processing the next DUML message. AppController records native-task, camera-lock and media evidence through a local synchronous helper; the normal UI and automatic download polling remain unchanged.

Keep existing READY/video-enabled and per-task/session lifecycle gates. Do not introduce a global historical recording flag, change protocol filtering, alter aircraft commands or bypass media finalization. Isolate observer exceptions so later messages, reply matching and unrelated evidence observers can still run. Report camera status transitions for diagnosis without logging every unchanged frame.

- [x] Convert the demonstrated overwrite cases to failing production-class tests, with normal and idle-only controls and lifecycle isolation.
- [x] Add the typed camera return/listener and immediate observation helper; preserve delayed download and UI behavior.
- [x] Pass focused regressions and independent review, build signed HAP and deliver in the project root first.
- [x] Complete full core regression and exact production-source/native artifact verification.
- [ ] Validate on a connected aircraft; leave pending until observed. No installation or live aircraft action is part of this change.

## Verification and delivery

- New `tests/recording-observation.test.cjs`: 6 groups passed, including same-packet and 250ms-window transitions, no-positive/stale-positive controls, new step/session isolation, exact-event Store returns and real AppController constructor registration independent of its UI listener. Original overwrite case was observed RED before implementation.
- Independent lifecycle probes: 5 passed, covering early recording before ACK, late ACK after reset and new capture sequences. Observer-exception injection also passed: later task/camera reports, command reply resolution and normal UI notification survive a listener exception.
- Full core suite: 742 passed, 0 failed/skipped/cancelled (`diagnostics/recording-state-fix-core-full.log`). Independent final review found no outstanding P1/P2.
- Signed HAP delivered before full-suite completion: `D:/无人机demo/Neo2/Neo2-recording-state-fix-20261111.hap`, 16,763,009 bytes, SHA256 `E23BF172A975195F0FD391B139064C6D6F914E3DA7A1BE1FA1BA470FAACB1E2A`.
- Project/build copy contain the same 114 production files with matching hashes. Native library SHA256 is unchanged from the reverted baseline (`1409021AAF54BDB59073538192461C8A346519FC321C56A6C897E232EA0E986E`). Receipt: `diagnostics/recording-state-fix-artifact-verification.json`.
- No installation or aircraft commands. This repairs lost observation of received reports; it does not invent recording evidence when the aircraft never reports a recording state.
