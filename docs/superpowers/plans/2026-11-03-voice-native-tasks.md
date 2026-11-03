# Voice and Native Tasks Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans in the current checkout; preserve existing uncommitted SDK adaptations. Steps use checkbox syntax.

**Goal:** Port original Follow/Dolly Zoom and complete offline Chinese voice control on the phone.

**Architecture:** Pure protocol/intent modules, one cancellable native-task service, AppController orchestration, generation-guarded recognition loop.

**Tech Stack:** ArkTS, HarmonyOS API21 SDK, offline CoreSpeechKit, Node test runner with bundled TypeScript.

**Spec:** ../specs/2026-11-03-voice-native-tasks-design.md

## Global Constraints
- Keep working connection/profile/routing behavior and existing user data.
- Ground-start Follow/Dolly, captured parameters only; no unconfirmed starts or automatic retries.
- Independent confirmation within 10 seconds; stop/land/background cancels all in-flight preparation.
- Directions <=10 seconds; physical units require measured calibration.
- No live flight commands during automated verification.

## Review Focus
- Stop while a parameter reply is pending must suppress the next write/start.
- A late recognition callback after stop/restart must not execute.
- Confirmation after settings change, disconnect, stop or expiry must do nothing.
- No task may steal an active native mode, including stale/unknown completion.
- Timeout/NACK and command ACK must not be reported as observed execution.

## Task 1: Pure protocol, intent, confirmation and calibration
Files: NativeTaskCodec.ets, VoiceCommandAdapter.ets, VoiceMotion.ets, tests/voice-native.test.cjs, tools/test-core.cjs.
- [ ] Add failing offline tests for captured writes, Chinese numeric/unit parsing, rejected mixed/negative commands and confirmation expiry/cancellation.
- [ ] Implement codecs and parser/adapter; implement bounded calibration-based motion planning.
- [ ] Run offline tests; compare protocol vectors with original Python.

## Task 2: Cancellable task orchestration
Files: NativeTaskService.ets, CameraService.ets, DroneSession.ets, FlightCommandService.ets, AppController.ets.
- [ ] Add failing tests using fake session for ground guard, mode/camera preparation, ACK separation, cancellation and stop/land ordering.
- [ ] Implement shared circle/follow/dolly state and propagate cancellation through command sends and camera/media actions.
- [ ] Wire voice actions, explicit grounded restart, settings and state reporting; fix overlapping operation busy tracking.
- [ ] Run all core regression tests.

## Task 3: Recognition lifecycle and UI
Files: LocalSpeechRecognizer.ets, SpeechLoopState.ets, Index.ets, EntryAbility.ets.
- [ ] Add failing tests for stale callback rejection and stop during engine startup/restart.
- [ ] Implement serial offline listening with invalidation and bounded failure handling.
- [ ] Expose task controls, voice examples/status and calibration inputs; apply consistent light page theme.
- [ ] Build with actual SDK and resolve diagnostics.

## Task 4: Review and deliver
- [ ] Fresh reviewer checks task safety, stale callbacks, settings and controller wiring; fix actionable findings with tests.
- [ ] Run core suite, build signed HAP, verify diff.
- [ ] Install without removing app data after grounded confirmation, verify UI only; document command examples and actual validation limits.

## Execution Ledger
Pre-flight: Task1 produces VoiceCommand/NativeTaskConfig consumed by Tasks2/3. Task2 snapshots feed Task3; keep current circle snapshot fields for compatibility.
Ruling: Execute in current checkout and existing English build copy because user SDK changes are uncommitted; no branch integration or commits requested.
Ruling: User selected full task migration; continue implementation without additional design approval prompts.
Task 1 complete: offline intent, confirmation, motion and codec tests failed first, then passed; includes original protocol suite.
Task 2 complete: native cancellation/ground/echo/mode guards and controller stop-land ordering tested. Reviewer found restart token, external active task and photo-selection invalidation; all fixed with failing-then-passing regressions. An old manual ACK cannot bypass native ownership.
Task 3 implementation complete: offline speech lifecycle tests prove no stale callbacks/restart after stop, and deduplicate final results. SDK build passed after using InputType.NUMBER_DECIMAL. Original heartbeat mapping was ported with a regression test.
Task 4 complete: final SDK signed build succeeded and 45 offline tests passed. HDC replacement install succeeded and EntryAbility launched; B66D credentials/registration/routing remained configured. Phone UI showed offline recognition of 后退/下降 and repeated recognition sessions before the final display-only/slider update; no automated flight tests were performed. Final UI checked slider4.0 updates its header and both control paths use the shared controller setting. Returned slider to0.5 after checking.
User feedback ruling: unspecified duration (including 一点/一下) now follows the shared slider; explicit durations override it. Circle permits verified owned fresh manual hover with absent task telemetry or known manual mode0/9, while protecting active native modes. Dolly remains ground-start, as in the original implementation. Phone logs showed circle refused on task-state guard at20:22:50 and Dolly refused after acknowledged land at20:23:00; land lock was retained. Failure diagnostics now include raw task, age and flight mode.
Display follow-up: converted SectionHeader/Diagnostic builder parameters to reference arguments after phone verification exposed stale by-value labels. Final signed rebuild and replacement install succeeded; no aircraft commands sent during validation.
