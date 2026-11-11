# Common Subject Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make every subject-aware action reuse the same visible subject confirmation before execution.

**Architecture:** A protocol-independent SubjectSelectionWorkflow owns candidate preparation, model choice, confirmation, expiry and cancellation. SubjectTaskWorkflow composes it with authorized takeoff and an action-specific execution port; legacy dolly APIs remain adapters. AppController supplies fresh-frame and same-ID validation.

**Tech Stack:** Existing ArkTS/ArkUI, DeepSeek JSON intents, Node test harness, current Huawei SDK/native preview.

**Spec:** ../specs/2026-11-09-common-subject-selection-design.md

## Global Constraints

- Five-color inset selected box, hidden after confirmation; no visible full candidate list.
- No flight/protocol freshness or mutual-exclusion gate weakened; no new flight tests sent by automation.
- Follow/circle/dolly may authorize ground takeoff; photo/subject record_start/select_subject do not add takeoff.
- Preserve dolly plan/execute UX, pending media, partial/completed videos and movie sources.
- Visual selection accepts only real frame candidates; user confirmation remains required for one candidate/current target.
- No production decoder, flight-result-code or task-ending changes in this feature.

## Review Focus

- Cancelling/landing/reconnecting during scan or confirmation must invalidate late selection and prevent launch.
- Fresh same-ID evidence must be rechecked after user confirmation, with no automatic fallback to another person.
- Model selection must not change action/parameters, introduce another recipe, or add takeoff to photo/select.
- New shared flow must not cancel existing media/movie work or permit overlapping native tasks.
- Bare actions and urgent stop/landing must remain responsive without waiting for model selection.

## Task 1: Shared independent workflow

**Files:** new core/domain/SubjectSelectionWorkflow.ets and SubjectTaskWorkflow.ets; GroundDollyWorkflow.ets adapter; tests/subject-selection-workflow.test.cjs and subject-task-workflow.test.cjs.

**Interfaces:** SubjectTaskSnapshot compatible with GroundDollySnapshot (stage/message/entry/subjectId/plan/active). SubjectTaskPort compatible with GroundDollyPort (isCurrent/takeoff/waitForCandidates/select/shoot). SubjectTaskWorkflow.start(description,intent,port,entry), confirm(), execute(), cancel(), retireInactive(), snapshot(). Dolly confirm generates plan; other subject actions confirm executes once. Selection module owns target/expiry/epochs; only its confirmed action is executed.

- [x] Write failing tests for all action types, independent core, confirm/expiry/cancel/duplicate, parameter preservation.
- [x] Observe RED, implement minimal core/composition; retain dolly adapter tests.
- [x] Run targeted checks and review cancellation/late-callback behavior.

## Task 2: Model intent/selection contract

**Files:** AgentAction.ets, AgentPrompt.ets, DeepSeekPayload.ets; relevant payload/action tests.

**Interfaces:** AgentAction.subjectRequired?:boolean (photo/record_start/select_subject); AgentObservation.purpose includes subject_selection. Subject-selection phase returns only select_subject with candidate ID or none. Initial subject-aware intents can defer selection without invented IDs; execution validators stay strict. Export actionNeedsSubjectSelection(command):boolean.

- [x] Add failing validation/prompt tests for follow/circle intent without image, subject photo, plain photo, explicit selection and rejected malformed IDs/fields.
- [x] Implement schema/phase prompt and parse validation; preserve legacy dolly_subject compatibility and existing tests.
- [x] Verify target-ID whitelist, negation, relative switches, no parameter rewrite.

## Task 3: Controller/UI integration

**Files:** AppController.ets, AssistantSheet.ets, AssistantProgress.ets, AssistantFlightPresentation.ets, SubjectFramePresentation.ets and controller/presentation tests.

**Interfaces:** ConsoleSnapshot.subjectTask (legacy groundDolly alias), confirmSubjectTask(), executeSubjectPlan(); all subject tasks use SubjectTaskWorkflow and generic selection purpose. Existing controller startGroundDolly/confirmGroundDolly/executeGroundDolly delegate for compatibility. New UI reads generic snapshot with compatibility fallback for older test fixtures.

- [x] Add failing real-controller scenarios for hover follow/circle/photo/select and ground follow/circle, asserting no native task before subject confirmation.
- [x] Generalize existing checked scan/select/fresh execution host; route native subject task starts only after common workflow, preserve simple actions and stop/land.
- [x] Bind overlay/confirmation/progress to generic selection; hide after confirmation, no extra confirm for non-dolly actions.
- [x] Verify existing dolly/closeup/media/movie/repeat tests, independent review, full core and native checks.
- [x] Build signed production HAP, report offline results and remaining true-device verification.

## Completion evidence

- Shared core, generic task workflow and legacy adapter implemented; explicit intent parameters/recipe remain frozen.
- Follow, subject circle, dolly/closeup, subject photo/video and selection/switch all enter one controller confirmation host; naked photo/video and urgent stop/land remain direct.
- Confirm/plan-stage retarget preserves original action/settings and requests confirmation again. Post-confirmation capture checks same tracked ID and decoder epoch; direct cancellation invalidates pending native preparation tokens.
- Direct response and cloud voice paths share recipe defaults and grounded prior-media reconciliation.
- Independent review findings were reproduced and corrected. Movie-source revalidation preserves an already-authorized export when only the confirmation UI changes.
- Final domain tests: **478/478 passed** (`diagnostics/common-subject-final-core.log`); native parameter/recovery checks passed; signed HAP build succeeded in 25.496s.
- Artifact: `diagnostics/common-subject-confirmation-signed.hap`. Compared current controller, common workflows, schema, payload, UI and movie eligibility source hashes with the actual build copy; all match.
- No installation or automated aircraft actions performed for this feature. Ground/hover recognition, user-confirmation UX and physical task results still need device testing.
