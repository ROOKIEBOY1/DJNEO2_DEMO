# Session readiness and recovery

> Implement in the current checkout, preserving the existing uncommitted work.

**Goal:** A cold start must establish fresh control, video and telemetry before reporting ready; a failed preparation must have a working, bounded recovery path.

**Design:** Keep transport readiness in DroneSession, with an optional preview readiness callback supplied by AppController. Require device verification and fresh control downlink, video, flight, task and camera observations. Preview must have a freshly rendered frame, without waiting for a keyframe. Do not require a particular task mode or camera shooting mode merely to connect. Reinitialization must fence session changes and clear the ready state on failure. Do not invent registration-state values as gates without protocol evidence.

For an already ready session, the connection button checks health again. Unhealthy or preparation-failed sessions may be replaced only with fresh grounded/motors-off telemetry, no recording and no active operations. Airborne/unknown states retain their existing control link and report that recovery requires landing. Recovery makes at most one fresh connection and initialization per click; no flight/camera action is replayed. Healthy repeated clicks are harmless. Reset the video identity before a new connection and retain existing local media behavior.

**Alternatives:** Reinitializing the same link alone cannot reset a stalled video stream or partial parameter state. Reconnecting after every error unnecessarily interrupts healthy sessions. Use a targeted ground-only fresh session for unhealthy/marked sessions instead.

**Files and steps**

- [x] DroneSession.ets + session readiness tests: demonstrate failure with missing/stale telemetry or preview, delayed success, cancellation/session changes, and failed-session resource cleanup; implement bounded readiness and release old resources before reconnecting.
- [x] AppController.ets + connection recovery tests: demonstrate that ready-but-unhealthy and parameter-preparation failure can recover; preserve a healthy link, serialize repeated clicks, forbid airborne/unknown/recording recovery, and avoid replaying actions. Supply preview readiness to initialization and mark failed native preparation.
- [x] Run targeted tests, then the full domain suite; inspect integration with an independent reviewer.
- [x] Compile a package with the available DevEco toolchain. Do not install or send aircraft commands as part of verification.

**Log evidence:** diagnostics/recent-two-20261110-archives.log covers 21:40–22:45, 36 archives / 3297 app records. At 22:22:42 selection failed to capture a frame; at 22:35:26 takeoff returned no_reply despite initialization success; at 22:36:28 scanning timed out. The later 22:37 and 22:40 flights both executed dolly/circle and returned two recordings each. Decode stalls also occur after successful shooting, so readiness/recovery improves the observed lifecycle gaps without proving a fix for every video failure.

**Verification:** 25 focused tests independently passed review. Final domain suite: 663 passed, zero failed (diagnostics/session-recovery-core-final.log). Final signed build succeeded in 27.509 seconds; diagnostics/session-readiness-recovery-result.json records the artifact hash and full production-source comparison. No installation or aircraft action was performed. The remaining real-device check is repeated cold starts and grounded recovery after a preparation failure; initial decode stalls and missing later IRAP frames are not claimed fixed by these lifecycle changes.

## Cold-start regression follow-up

New device logs (diagnostics/connect-failure-now-archives.log) show PID61942 completing device verification and all control/video/telemetry gates, but failing only the rendered-preview gate twice. Historical successful sessions 40521 and 44489 first decoded a keyframe after takeoff. The requirement for a rendered ground preview therefore introduced a startup regression. Keep the verified control/video/telemetry requirements in session initialization, and keep actual decoded-frame freshness in visual capture/subject actions. Display the connected-but-waiting-for-picture state separately; do not automatically replace an otherwise ready connection solely for decoder startup delay.

PID62902 then failed registration with no device reply, no video and none of the three telemetry streams. Repeated initialization reused the same consumed registration schedule because the recovery gate demanded telemetry it never obtained. Permit one new handshake for a never-ready, unverified registering/failed session only when flight/task/camera telemetry have never existed in that session and every local flight/recording/native authorization flag is explicitly clear. Existing/uncertain flight sessions retain the original grounded recovery gate. Never infer landing from missing telemetry or replay flight actions. The original registration failure's wire-level cause remains unproven; identical unknown capability requests also occur in a previous successful registration, so do not invent responses.

Regression checks: connection bootstrap tests cover keeping the control session while waiting for the first keyframe, exactly one fresh registration retry, and rejecting retries with established-session evidence, any telemetry history, active flags, or missing authorization flags.

Follow-up validation: 668/668 domain tests passed (diagnostics/connection-startup-fix-core.log). Signed build succeeded in 33.772 seconds; diagnostics/connection-startup-fix-result.json confirms all 112 production files match the built sources. New artifact: diagnostics/connection-startup-fix-signed.hap. It supersedes the previous readiness package for connection startup behavior. Not installed and no flight/connection command was sent during this follow-up investigation.
