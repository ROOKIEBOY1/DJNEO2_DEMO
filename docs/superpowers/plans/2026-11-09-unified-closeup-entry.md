# Unified ground and hover closeup entry

> **For agentic workers:** Use superpowers:executing-plans and test-driven-development. Preserve the existing checkout and unrelated changes. No commit, push, installation or aircraft operation is part of this implementation request.

**Goal:** The same spoken closeup request fills in missing preparation steps from either ground or owned stable hover.

**Architecture:** Reuse the existing subject-confirmation / flight-plan workflow and the existing target-specific native sequence. An explicit entry mode determines whether to take off. Airborne input reuses its visual model decision after live-state verification, rather than implicitly retaining a previous person. Execution takes a fresh observation and retains all native task and media checks.

**Tech Stack:** ArkTS, existing Node domain test harness, HarmonyOS signed HAP build.

**Spec:** User-provided state-based entry design in this conversation: ground adds takeoff; hover selects; a locked target is verified; active or unknown states explain why they cannot proceed.

## Constraints and review focus

- Preserve subject confirmation, generated plan and explicit execute click.
- No repeated takeoff from airborne state; no silent switch while an active task owns flight.
- Require fresh flight, task, camera and link state. Tracking hover (mode 26) must not be mistaken for ordinary hover (mode 6).
- A visual choice must refer to the current image candidates and still match at execution; changing session, flight cycle, target or cancellation invalidates preparation.
- Existing completed-task handoff, pending-media protection and two-step deferred return remain intact.
- A second request must not reset an active closeup sequence or leak a stale result into the new workflow.

## Tasks

- [x] Add failing controller entry tests for airborne selection, same-target reuse, target change, active/unknown flight and camera conditions, and execution through the confirmed plan.
- [x] Add failing workflow / presentation tests for a hover entry with no takeoff and retained confirmation / timeout / cancellation behavior.
- [x] Extend `GroundDollyWorkflow.start` with a default-ground entry mode and correct hover progress text.
- [x] Route airborne fixed recipes to the shared controller preparation, verify live readiness and reuse fresh visual inference where available. Keep ordinary individual task handling compatible.
- [x] Run targeted tests, independent code review, full domain suite and signed HAP build. Record results and remaining real-device validation here.

## Validation

- Initial 7 controller tests failed for the missing airborne workflow / reset of an active sequence, then passed. Workflow and presentation added four RED-to-GREEN cases.
- Expanded controller coverage to 17 cases, including actual controller handoff, pending-media preservation, post-plan camera/task changes, expired inference, disappearing candidates, and a newer request during asynchronous handoff. The latter exposed and fixed stale intent revival.
- Independent review identified a missing local display selection when retaining an already tracked target. A failing test confirmed it; synchronizing `selectedSubjectId` fixes the confirmation overlay without sending another selection command.
- Final full test command: bundled Node `tools/test-core.cjs`; **348 tests passed, 0 failed, 5 suites**, 21.906 seconds. Log: `diagnostics/unified-closeup-core-final.log`.
- Final signed build: `diagnostics/build-movie-hap.ps1 -PackageName unified-closeup-entry`, **BUILD SUCCESSFUL**, 23.016 seconds. Package: `diagnostics/unified-closeup-entry-signed.hap`, 11,080,247 bytes. Existing deprecated-API warnings remain.
- Tracked-file `git diff --check` passes. No commit or push was made.
- The ordinary single dolly/circle paths are preserved. A mode-26 target with terminal task phase 3/4 may still be refused by the existing cancellation guard until the aircraft returns to a handoff-ready state; this produces an explicit wait/retry explanation and keeps native ownership. No low-level task condition was weakened.
- No phone installation or real flight was performed. Ground-to-confirm and hover-to-confirm-to-plan execution are verified offline; both entry paths still need a real-device flight check.

## Installation (2026-11-09 15:16)

- User requested installation. Device `<device-id>` was connected; the prior app was in the background.
- Verified the final package SHA-256: `B068668987004F8BE2F5C1CF60161ED3E3EC01CD538C87194B4C475F664559D3`.
- Stopped the old process, installed the signed HAP with replacement (`install bundle successfully`), and started `com.example.neo/EntryAbility` (`start ability successfully`). New PID: `34012`.
- Startup telemetry appears in `diagnostics/unified-closeup-installed.log`. No takeoff, target selection, shooting, or real flight test was issued during deployment.
- At 15:16:45 the new process reported `ready/true`, fresh link and video, preview `live` at 1280x720 with zero decode errors, and grounded/motors-off telemetry. The ability is in the foreground.
