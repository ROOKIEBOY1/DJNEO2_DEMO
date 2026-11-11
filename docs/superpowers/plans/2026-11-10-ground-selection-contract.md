# Ground-start subject selection repair

**Goal:** A ground-start closeup request reaches subject confirmation without requiring the user to repeat the whole instruction.

**Evidence:** Three ground requests in `diagnostics/selection-first-failure-archives.log` obtained a fresh frame and one candidate, then failed the `subject_selection` action contract. Airborne repeats returned an initial task plus candidate ID and reused that valid result, skipping the failing cloud selector. Rejected actions were not logged because logging happened after response validation.

**Scope:** Keep current ground/hover entry gates, hover ID reuse, reference-photo routing, frozen task parameters and user confirmation. Change the selector's prompt and protocol recovery only; no flight actions in tests, no installation or commits.

## Interfaces

- `makeDeepSeekBody(observation, description, jpeg?, referenceJpeg?, selectionRetry:boolean=false)` uses a standalone selector system prompt only for `subject_selection`; other stage prompts remain unchanged.
- Export `SubjectSelectionProtocolError extends Error` with a sanitized readonly `action:string`; only selection JSON/schema/action errors qualify. Expiry, cancellation, networking, HTTP and valid `none` do not.
- Phone cloud client retries that typed error once at most, using the same original frame, candidates and absolute deadline. The second body adds a short selection-only format reminder. Revalidate cancellation/deadline before every send and preserve outer busy ownership.
- Desktop debug selector uses the same standalone prompt for parity; phone-only selfie specialization remains intact.

## Tasks

- [x] Payload TDD: selection prompt has only select/none outputs and treats the original request as target data, not an instruction to plan/execute. Keep sole/current/relative/ambiguous rules and reference override; add safe error classification tests and preserve expiry behavior.
- [x] Transport TDD: wrong task response then valid ID succeeds in two requests; repeated bad responses stop after two; no retry on none, HTTP, cancellation or expiry; same frame/deadline/reference across attempts and no secret/image response logging.
- [x] Controller regression: a ground takeoff+scan reaches confirm with one takeoff and frozen closeup recipe through the real mocked cloud transport; hover valid-ID reuse stays one cloud request; cancellation prevents task execution.
- [x] Scoped review, full domain checks, signed build and matching source/artifact metadata. No autonomous flight or device installation.

## Verification limits

Offline mocks establish routing, retry and confirmation behavior, not live model vision accuracy. Any live cloud checks use synthetic non-identifying diagrams only. Real ground takeoff is tested by the user after installation.

## Result

- Controller RED:28pass/2fail; after implementation all69 entry/controller regressions pass. The current reviewer independently passed62 protocol/transport/controller tests.
- Full domain suite:555/555 pass. ArkTS build initially rejected two untyped rethrows; type assertions preserve error identity, then46 targeted tests and the signed build pass. Copied production sources match the workspace.
- Cloud:6/6 synthetic-diagram cases return selected real diagram IDs or none, including the exact original closeup wording. No portrait, real camera frame or aircraft command was sent.
- Artifact and hashes: `diagnostics/ground-selection-build-result.json`; HAP `diagnostics/ground-selection-contract-fix-signed.hap`. Not installed; no live ground flight was performed.
