# Shared subject preparation and explicit early-termination failure

> Implement with test-driven-development and independent review. User approved the previously described changes; preserve unrelated work and do not install or send flight commands during offline implementation.

**Goal:** Ordinary Hitchcock and fixed closeup shooting use the same subject preparation, confirmation and plan from ground or hover. An aircraft task that ends before any observed recording fails clearly instead of hanging until landing.

**Architecture:** The initial cloud request captures context and an optional ready image without waiting for scan preparation. A `shoot_intent` phase permits a recognized dolly request to defer its subject ID when no usable candidate exists. Every `dolly_zoom` enters the existing shared workflow; its scan barrier waits for fresh candidates, its visual phase resolves/retains the target, and execution takes a fresh observation. Existing local scan/select functions remain independently available. Non-subject commands never wait for this subject workflow.

## Requirements

- Preserve grounded takeoff, owned-hover checks, task/camera mutual exclusion, cancellation, session/generation checks and 20-second visual lifetime.
- Ordinary dolly has no implicit circle. Only explicit `dolly_circle` appends same-subject 2m circle.
- Preserve parameters and both user subject confirmation and flight-plan execution.
- Reuse a valid first visual decision when available; with no candidate, classify the shooting intent and defer selection instead of reporting a missing person before scanning.
- Never guess a person among ambiguous candidates. Confirm a visible matching target or ask for clarification.
- Active/unknown native state, stale camera/task evidence or an ACK alone cannot prove an early terminal failure.
- Proven terminal task + continuously fresh idle camera + no observed recording may fail after a short settling interval. Keep the unresolved media ticket; do not auto-retry flight or start circle.
- Additional logs identify native start parameters/reply and terminal flight/task/camera/subject state; do not claim to fix the aircraft's unknown early-exit condition.

## Tasks

- [x] RED then GREEN: independent ordinary-dolly entry tests; update initial capture/phase and route all dolly commands through shared preparation in `AppController.ets`.
- [x] RED then GREEN: add `shoot_intent` schema/prompt/desktop parity and validation tests.
- [x] RED then GREEN: detect proven no-recording terminal failure in `waitForCloseupStep`; preserve media and add useful diagnostics.
- [x] Run relevant tests, independent whole-change review, full suite, signed HAP build and record exact verification/artifact metadata.

## Ownership

- Root: `AppController.captureAgentObservation`, `runCloudVoiceRequest`, shared subject selection; overall verification/build.
- Prompt agent: `AgentObservation.purpose`, `DeepSeekPayload`, desktop debug phase and prompt tests.
- Terminal agent: only `AppController.waitForCloseupStep`, closeup tests and native diagnostic logging.
- Entry-test agent: new ordinary-dolly entry tests only.

## Verification results

- Ordinary entry: **8 failures / 2 passes before the change**, then **10/10 pass**. Real controller observation/candidate wait, validators, workflow, flight service and selection are exercised. Intent requests skip only automatic scan waiting; direct observation capture retains its default barrier. Grounded ordinary dolly takes off once; hover ordinary dolly confirms its target and plan; no ordinary command acquires a circle recipe.
- Prompt/schema: phase tests first failed for missing `shoot_intent` and desktop phase parity. **16/16 targeted checks pass** after implementation, including current-target priority, proposing a sole visible candidate, ambiguous people, relative switches, candidate whitelist and retained parameters. Existing timeout limits and output budget are unchanged.
- Early terminal: replay of the latest state logs originally waited to the 180-second timeout. It now fails after 2 seconds of continuously fresh, positively idle camera evidence following proven execution and terminal task state. The fixture explicitly describes reconstructed state logs, not raw DUML. Tests also cover interrupted idle evidence, stale/unknown/active/busy/previously recorded states, late recording, retained media and no circle/retry/stop side effects.
- Final full suite: **387 tests, 5 suites, 387 passed, 0 failed**, 21.905 seconds. Log: `diagnostics/shared-shoot-core-final.log`.
- Signed build: **BUILD SUCCESSFUL**, 26.186 seconds; `diagnostics/shared-subject-shoot-build.log`. Package: `diagnostics/shared-subject-shoot-signed.hap`, **11090347 bytes**, SHA-256 **`869E961112FEA3F7457633C3E231052F647810F02BF0183932C65A605066A6A3`**.
- Tracked-file `git diff --check` passes. No installation, flight commands, commit or push were performed.
- Independent review found two entry boundaries; both were reproduced in failing tests and corrected. With no optional initial image, target binding uses the captured context ID, while a present image retains strict ID matching. Fresh-image selection still follows. Stop commands may interrupt confirmation/planning; new shooting/recording/settings commands cannot overwrite an active plan.
- Explicit short stop/stop-recording speech uses the existing local stop controls before scan/cloud work. Anchored parsing excludes negative, question, hypothetical, quoted and compound requests. Two UI busy checks were removed; controller mutual exclusion continues to reject non-interrupting work. Failure from a stop is propagated rather than reporting success.
- Added native startup diagnostics before and after the request, including settings, selected ID, flight/task/camera state and the actual stored `startReply`. The early-terminal failure also logs the complete relevant state and retains the unresolved media ticket.
- Final independent review reports no remaining blocker and independently passes 97 related tests. The reason the aircraft itself abandoned the native task remains unknown; this change makes that failure explicit and records useful state without changing flight parameters or retrying it.

## Installation (2026-11-09 17:31)

- User requested installation. Device `<device-id>` online; previous app was in background. Verified final HAP size 11,090,347 bytes and SHA-256 `869E961112FEA3F7457633C3E231052F647810F02BF0183932C65A605066A6A3`.
- Replacement installation returned `install bundle successfully`; launch returned `start ability successfully`. New foreground PID: `3543`.
- Startup connection attempt ended with `The system Wi-Fi confirmation timed out` at 17:31:25; the app is disconnected. Log: `diagnostics/shared-shoot-installed.log`.
- No takeoff, subject selection, recording or other flight commands were issued during deployment. Real flight validation remains outstanding.
