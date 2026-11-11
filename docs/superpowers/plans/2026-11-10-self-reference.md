# Self Reference Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans task by task.

**Goal:** Use the user-approved fixed portrait to assist first-person target selection in the existing Demo.

**Architecture:** A shared domain predicate identifies explicit first-person target requests. The phone cloud client loads a locally packaged, Git-ignored reference through a cached image provider only during common subject selection. The payload labels reference and live images separately, while the controller prevents reuse of an earlier decision made without the reference.

**Tech Stack:** Existing ArkTS, ImageKit, ResourceManager, RCP and Node domain tests.

**Spec:** `docs/superpowers/specs/2026-11-10-self-reference-design.md`

## Global Constraints

- Preserve current flight/subject confirmation, frozen parameters and freshness/cancellation gates.
- Fixed rawfile `demo-self-reference.jpg`; portrait excluded from Git and automated cloud tests.
- Reference JPEG: longest edge1024, quality82; source<=8MiB, normalized<=750000bytes.
- Reference only in `subject_selection` with a real current frame. All other requests remain unchanged.
- No installation, flight commands, commits or pushes.
- User steering: remove the conservative two-candidate cap while retaining exact count/length and per-record validation.

## Review Focus

- First-person helper text must not silently turn an explicitly described different person into the photo owner.
- Initial airborne inference must not bypass photo-assisted selection or subject confirmation.
- Expensive photo normalization must not consume an unchecked request lifetime or leak image resources.
- Missing/invalid reference must not silently choose a sole/current candidate.
- Private portrait must not enter tracked source or logs.

## Task1: Domain routing and payload

Files: new `core/domain/SelfReference.ets`, modify `core/domain/DeepSeekPayload.ets`, new `tests/self-reference-payload.test.cjs`.

Interfaces: `isSelfSubjectRequest(description:string):boolean`; `needsSelfReference(observation:AgentObservation,description:string):boolean`; optional fourth `makeDeepSeekBody` argument `referenceJpegDataUrl?:string`.

- [x] Write failing tests for explicit self-target vs helper/other-target text, stage/frame gates, two labeled images, no sole/current fallback and missing/oversized reference.
- [x] Implement minimal predicate and payload behavior; ordinary payloads unchanged.
- [x] Verify targeted payload tests and phone/desktop parity for ordinary requests.

## Task2: Cached phone reference provider and cloud transport

Files: new `core/platform/SelfReferencePhotoStore.ets`, modify `core/platform/CloudVlmClient.ets`, new platform tests.

Interfaces: `SelfReferencePhotoProvider {read:()=>Promise<string|undefined>}` in the store module; `SelfReferencePhotoStore(context:Context)` implements it. `CloudVlmClient(keys, referencePhotos?:SelfReferencePhotoProvider)`.

- [x] RED tests for bounded normalization/cache/resources and conditional provider use; missing photo/error/cancellation sends no request.
- [x] Load rawfile, normalize with ImageKit, cache successful JPEG data URL; retain deadline/cancellation checks after asynchronous load.
- [x] Verify targeted cloud/provider tests and unchanged ordinary requests.

## Task3: Controller integration and private local asset

Files: `core/domain/AppController.ets`, `.gitignore`, new controller regression tests, ignored rawfile JPEG.

- [x] RED test that an initial inferred ID does not skip reference-assisted common selection; ordinary initial ID reuse still works and confirmation remains required.
- [x] Instantiate client with provider from Ability context; force reference requests through fresh common selection, including bare model photo/record_start responses.
- [x] Copy the user-approved portrait to the exact ignored rawfile path; verify `git check-ignore`.
- [x] Review all deltas, full suite, signed HAP and source-hash comparison. Record build result; do not install.

## Task4: Variable-count candidate tables (explicit user addition)

Files: `core/domain/SubjectObservation.ets`, `tests/subject-observation.test.cjs`.

- [x] RED tests for three/five/many candidates and malformed/truncated/count-mismatched/invalid-coordinate tables.
- [x] Remove the `count > 2` rejection; retain all frame identity, exact table size, coordinate and lifetime checks, with compatible selectable IDs. Reject duplicate/out-of-range candidate IDs without rejecting the header's no-selection sentinel.
- [x] GREEN decoder and VLM candidate tests. Report this as structurally verified support; real crowd reporting still requires device validation.

## Final evidence

- Domain suite:533/533 pass; final scoped review reports no remaining findings.
- Cloud initial-intent text checks:6/6 pass. No portrait or camera image was transmitted in automated cloud checks. Initial invalid follow parameters were corrected with explicit schema-valid examples; a bare photo response is still locally forced through reference selection.
- Signed build succeeds; all copied source hashes match; the packaged portrait hash matches the supplied file and Git ignores the JPEG. `diagnostics/self-reference-build-result.json` records the final artifact.
- Artifact: `diagnostics/self-reference-crowd-signed.hap`. Not installed; no real crowd matching or aircraft action was tested.
