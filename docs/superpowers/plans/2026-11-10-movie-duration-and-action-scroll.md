# Movie Duration Compatibility and Action Visibility

**Goal:** Allow the current complete BGM decode to finish composition and reveal newly generated dialogue actions automatically.

**Base:** Current workspace including the verified registration and camera readiness fixes. Preserve prior unrelated changes, the supplied audio asset, reference photo, camera/flight commands and final movie timing checks.

**Audio design:** Extract a production helper for source-duration validation and retained PCM frame count. Require complete input/output EOS, valid nonempty PCM, bounded duration/rate and the existing one-MP3-frame tolerance for a short decode. Accept at most 250 ms of surplus decoded audio as a fixed compatibility window, then trim surplus to the declared source end. The window is not a claim that the observed surplus is all codec padding. Keep the memory limit, cancellation and final AAC/video coverage validation.

**Scroll design:** Track meaningful conversation/action/result transitions instead of every telemetry/progress update. Coalesce a pending request and scroll after content/viewport layout has settled; clear timers and pending state on disappearance. Preserve manual browsing between transitions and the existing live surface.

- [x] Audio regression first: reproduce 34.536 s vs 34.392 s at 48 kHz; test both EOS, the 250 ms boundary, true shortfall, invalid inputs and exact trimming. RED assertion 57 then GREEN assertions 1–71.
- [x] Scroll regression first: new messages, subject confirmation, plan execution, received video actions, finished movie and meaningful failures request scrolling; unchanged telemetry/progress does not. Seven policy tests passed after RED; layout callbacks coalesce into a single scroll entry.
- [x] Review focused changes independently; 641 domain checks and the native audio/frame/AVC/cache checks passed. Independent review found no remaining blocking issue.
- [x] Build one uniquely named signed package; check source/build equality, compiled assets and signature. Preserve source footage and report whether on-device composition was verified.

Formal package: `diagnostics/neo2-movie-scroll-fix-20261110-184423-signed.hap`.
SHA256: `D7C0A2CDABFCC2D21693C438C26013718666209F580CEBB0254A35C9B03FAFA3`.
All 112 source files matched the formal build. Installed with replacement on the USB test phone and launched successfully (PID 54724). The user explicitly requested skipping the temporary offline diagnostic package and directly installing this formal fix. Real-device composition and scrolling remain for user verification; no flight command was sent. The common build output was restored to the same formal signed HAP.

Source footage from the reported failure is retained privately in `diagnostics/movie-current-source-0079.mp4` and `movie-current-source-0080.mp4`. It is not a repository fixture and must not be committed.

No commit, push, aircraft command, route reset or unapproved interruption of flight is part of this task.
