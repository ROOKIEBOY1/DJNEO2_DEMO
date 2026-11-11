# Frame readiness and subject timestamp repair

> Implement in the current checkout and preserve all existing uncommitted changes.

**Goal:** Repair the confirmed frame/subject matching failures and decoder resource handling, and obtain replayable evidence for the remaining device-only decoder stall.

**Evidence:** PID54669 at 00:11:49 produced RGBA but rejected subject timestamp matching. Post-confirmation tracking updates `trackingAt`, while matching only examined candidate `detectionAt`. The matching routine also retained only before/after snapshots, losing intermediate reports. PID43381/47028 stopped main and readback hardware decode at the same output positions (299/184), while input continued. System output-buffer inventories were owned by OMX/surface, not app users, so an independently confirmed output-attribute failure leak cannot honestly be called the root cause of these two stalls.

**Design:** Keep candidate selection and confirmed-track confirmation separate. Match candidate frames against detection reports, and confirmed IDs against same-ID, single-box tracking reports. Retain the existing 200ms alignment bound and a bounded observation history during the existing sample deadline; reject cross-session, control/flight-generation and decoder-epoch changes. Preserve the actual capture failure instead of converting a missing image into a claim that the subject changed.

Every delivered native output buffer must be rendered or freed exactly once, including attribute-read failures and codec-data/EOS outputs. A resource-release failure must be observable. Add bounded decoder progress diagnostics and an 8MiB, IRAP-anchored input trace; on a stall, at most two private diagnostic slots may be overwritten. Incomplete traces must be identified and must not be advertised as replayable. No new flight, camera, Wi-Fi or keyframe-request command is authorized by this work.

**Constraints:** Do not weaken subject identity/freshness rules, replay previous images as fresh, increase cloud action lifetimes, or count successful request ACKs as completed shooting. Do not restore the former requirement for a rendered ground frame before control initialization. Do not claim hardware stall prevention without reproducing and validating the offending stream.

- [x] Add failing behavioral cases for confirmed tracking vs stale detection, strict candidate matching, intermediate reports, cancellation/generation changes, and truthful capture errors. Implement and verify the narrow matching repair, including state/freshness checks after asynchronous image and ticket cleanup.
- [x] Reproduce finite-buffer ownership leaks with the production output consumer, repair the release/error paths, and run native regressions. Readback output-release errors are observable and reset only the readback decoder.
- [x] Add bounded native trace/progress diagnostics with executable policy tests; wire the private directory into the controller. Publish the manifest last after invalidating prior evidence, with deletion/write/rename fault coverage.
- [x] Record execution-stage failures and use actual freshness for frame-ready status without changing control readiness.
- [x] Independently review, run the domain/native checks, compile a signed package and compare the production sources with the build.
- [ ] Validate the real-device stall with user-operated shooting; if it recurs, replay the captured codec input and continue the investigation. This device-dependent check remains open until observed.

Validation: bundled Node 18 full domain suite 688/688 passed; independent candidate/frame/closeup review 55/55 passed; all seven native video regression runners passed; no diff whitespace errors. Independent final review found no outstanding P1/P2. Harmony signed build succeeded, with all 114 production source files matching the build copy.

Artifact: `diagnostics/frame-readiness-fix-signed.hap` (16,768,524 bytes), SHA256 `E938F83D03239821B335A2850DEC0DBB7463D9844E909C8814BC7D64F157B85C`. Build evidence: `diagnostics/frame-readiness-fix-result.json`.

After explicit user confirmation that the aircraft was grounded/motors off, replaced the installed package on the connected USB test phone and started EntryAbility successfully (PID29475). Startup log confirms initialization completed at 00:49:10.684; grounded telemetry remains non-airborne/motors-off, video is waiting for the initial IRAP, and the private diagnostic directory exists. Evidence: `diagnostics/frame-readiness-installed-startup.log`. Hardware shooting reproduction remains pending; no flight commands were sent.
