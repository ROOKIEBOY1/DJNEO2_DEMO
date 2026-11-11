# Camera Video Mode Readiness Implementation Plan

**Goal:** Reuse verified video standby during native dolly preparation and preserve useful camera rejection diagnostics.

**Architecture:** Keep the change inside `CameraService.prepareVideoMode`. Require the existing fresh reliable link, fresh idle camera telemetry, cancellation checks and camera operation lock. Synchronize the camera clock when required, then re-read current telemetry. Reuse mode 1 only when these conditions remain satisfied; otherwise retain the acknowledged mode-change request and subsequent telemetry confirmation.

**Tech Stack:** ArkTS, existing Node domain test runner, DevEco signed HAP build.

**Scope:** Based on the confirmed current workspace, equivalent to the registration-fix build. Preserve the registration fix, routing state, subject workflow, native-task startup checks, photo/record capture paths and UI. Do not alter the reference photo. Do not install or command the aircraft during offline verification.

The firmware reason for earlier nonzero mode replies is still unknown. This change removes an unnecessary write when the prerequisite already holds; it does not treat a rejected write as success.

- [x] Add behavioral regressions for reuse, clock synchronization, actual mode switching, stale/missing/busy/cancelled contexts, nonzero replies, timeouts and operation-lock release. Observed 6 expected failures and 14 passes before editing production code.
- [x] Implement the bounded readiness check and log actual mode reply plus before/after camera state. Preserve failure on rejection, timeout and unobserved mode changes.
- [x] Run targeted camera/native/combination checks (125 passed), full domain suite (634 passed), and review the focused diff independently (no blocking findings; independent 20/20 new checks and 64/64 camera/native checks passed).
- [x] Build a uniquely named signed HAP; verify its signature, packaged contents and exact source/build match. Record artifact hash and explicitly leave real-flight validation pending.

Artifact: `diagnostics/neo2-video-mode-fix-20261110-180529-signed.hap`.
SHA256: `9F6768C2B2254404B5FEF6C9810DCC128F6F2B7CD8CFA5F14BCABAAEA887CEC7`.
The 110 source files match the build copy exactly; only `CameraService.ets` differs from the previously confirmed package's source manifest. The signed package contains the compiled readiness fix. Device installation and real-flight validation remain pending.

No commit, push, phone installation or route reset is part of this task.
