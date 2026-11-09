# Synchronize subject scanning and visual observation

**Report:** After installing the clean-startup package, the drone appears not to recognize a subject.

## Evidence

Source: `diagnostics/subject-miss-archives.log`, PID 45053, 2026-11-09; read-only phone layout: `diagnostics/subject-miss-layout.json`.

- 15:32:01.689: cloud ground intent returns `dolly_zoom`; 01.760: takeoff acknowledged.
- 05.043: mode 6, task `0000000102`, scan bit 1, candidate count 1, but automatic scan request for this flight is not yet acknowledged.
- 05.261: task `0509000100`, candidates cleared while scanning is reset.
- 09.204: automatic scan confirmation; 09.327: scan bit 1, candidate count still 0.
- 09.578: candidate count becomes 1 and remains 1 until the landing request at 14.987.
- During scanning, decoding is live, with no decode errors. Only the ground-intent cloud request was sent; no visual subject request followed.
- Phone UI explicitly reports: “没有可用的主体画面，未开始拍摄”. No frame-capture failure was logged.

## Cause and fix

`waitForCandidates()` accepts an early fresh candidate before automatic scan preparation finishes. Next, `captureAgentObservation()` waits for automatic scanning, which can restart scanning and clear that candidate. The scan-ready condition does not require nonempty candidates, so selection immediately receives an empty candidate frame and fails. Exact frame-capture milliseconds were not logged; the ordering is inferred from these state reports, the UI error and the code path, and will be reproduced in an offline test.

Move the automatic-scan readiness barrier before inspecting candidate readiness, read a fresh snapshot after that asynchronous barrier, and retain link/session/generation/cancellation and freshness checks. Keep the visual model call behind the fresh nonempty frame check. Log selection-observation readiness and preparation failures so future UI-only errors are diagnosable.

## Verification

- `tests/scan-frame-readiness.test.cjs` keeps the real controller, capture observation, automatic scan wait/poll, scan request, selection request, workflow and flight service. Only session transport, decoded frames, cloud and the clock are substituted. An early subject 11 is cleared by reset; a new subject 13 arrives 400ms after scan acknowledgement.
- Before the fix, the real path fails with the exact phone UI error “没有可用的主体画面，未开始拍摄”; the continuously empty and landing-cancellation cases pass. RED evidence: `diagnostics/scan-frame-race-red.log`.
- After the fix, all **4** cases pass: wait for the new candidate; explicit empty-scan timeout; landing prevents late visual inference; control cancellation interrupts the readiness barrier. An in-memory mutation removing the callback causes the fourth case to fail, without changing production files.
- Existing scanned-airborne fixtures now identify their already acknowledged generation. Media-recovery tests explicitly substitute their pre-existing scan boundary, retaining real scan/selection behavior in the new replay suite.
- Related controller/entry/recovery checks: **55/55 pass** (`diagnostics/scan-frame-regressions.log`).
- Full suite: **356 tests, 353 pass, 3 fail**, 21.847 seconds (`diagnostics/scan-frame-core.log`). The failures concern newly edited text-response lifetime / local confirmation lifetime / HTTP transfer-timeout tests. `AgentAction.ets` and `CloudVlmClient.ets` still use the existing 20-second limit; this scan fix does not change either implementation or those tests. These failures are recorded rather than changing an unrelated in-progress requirement or claiming the full suite passes.
- Independent review found no blocker in the scan fix. Cancellation is checked before/after the barrier, on every internal loop and after scan polling. An already awaited scan operation can still settle before its cancellation check, as with the previous transport behavior.
- Signed build succeeds in **26.150 seconds**. Package: `diagnostics/subject-scan-frame-ready-signed.hap`, **11,079,665 bytes**, SHA-256 `D3ED201E023D88B103247C1555C3E8818AE14FECC6269784D9B271C5EBCC5449`.
- No phone installation, cache deletion, commit, push or flight command was issued during this investigation. Actual flight verification remains outstanding.

## Timeout consistency follow-up

The user asked why the separate three timeout tests failed. The earlier result was a partially synchronized timeout change: new tests required text-only planning up to 60 seconds, while response validation, HTTP deadlines and confirmation expiry still used the visual 20-second limit. These were offline assertion failures, not three observed aircraft/cloud request timeouts.

The latest source now centralizes the limit in `agentObservationTimeoutMs`: no frame = 60 seconds; a visual frame = 20 seconds. The HTTP client, response validation and local confirmation deadline all use it. Re-running this source passes the original three tests. One older media-recovery test still simulated a 21-second text intent as expired; its expiry setup now uses `AGENT_TEXT_TIMEOUT_MS + 1000`. The visual expiry tests retain 21 seconds.

- Final full suite: **356/356 passed, 0 failed**, 21.999 seconds; `diagnostics/timeout-consistency-final.log`.
- Rebuilt signed HAP from this synchronized source: **BUILD SUCCESSFUL**, 25.113 seconds; `diagnostics/subject-scan-frame-ready-build.log`. Package size **11,079,179 bytes**, SHA-256 **`BD45588FF11DA5FAD09A812639D3560E8F1B6FA01A5C62ED03D724F0764C32AB`**. This package supersedes the earlier D3ED hash above.
- Phone remains on the previously installed clean-startup package. Neither the scan fix nor this newer timeout behavior has been installed yet.

## Installation (2026-11-09 16:16)

- User requested installation. Verified the online device `<device-id>`, previous app in background, and final package hash `BD45588FF11DA5FAD09A812639D3560E8F1B6FA01A5C62ED03D724F0764C32AB` (11,079,179 bytes).
- Stopped the old process, replaced the app (`install bundle successfully`) and launched `EntryAbility` (`start ability successfully`). New PID: `23729`.
- 16:16:58: initialization completed, connection ready/verified, fresh link/video telemetry, grounded and motors off. Startup log: `diagnostics/scan-ready-installed.log`.
- Read-only UI layout confirms the voice input is present, the large assistant header is absent, and the old “成片与飞行任务结果” is absent: `diagnostics/scan-ready-installed-layout.json`.
- No takeoff, scanning, subject selection or shooting command was issued during deployment. The actual flight scenario remains to be tested by the user.
