# Fresh startup without a historical task result

**Report:** Reopening the app displays “成片与飞行任务结果”. The desired fresh screen contains only the voice input bar.

**Cause:** `AppController` calls `restoreLatestMovie()` in its constructor. The helper loads the last completed manifest and promotes its source clips into `agentMediaUris`, sets `agentVideoResultReady=true`, then restores its completed movie. `AssistantSheet.updateMovieResult()` selects any completed output, and `resultVisible()` consequently presents it as a current task result whenever the conversation opens.

**UI distinction:** `Index.showAssistant` starts false. Disk restoration does not itself expand the conversation. Returning to an existing process can retain its expanded state; that is separate from putting a previous launch's movie into a new conversation. The observed process changed from installation PID 34012 to PID 38404, so cold-start restoration is relevant to this report.

**Fix:** Remove automatic latest-result promotion from the controller constructor. Keep completed cache files, source files, the same-process ongoing composition/result, and cache restoration for an explicitly current matching source group. Do not add foreground task resets or remove private media files.

**Validation plan:** Real constructor tests with historical manifests must begin with no current result. Once explicit current media are provided, the matching completed cache must still restore without export. Run existing movie/controller/presentation tests, full domain suite, independent review, then build a signed package. No phone update or flight commands are part of this diagnosis.

## Results

- `tests/startup-result.test.cjs` uses a real controller and movie composer with file/profile boundaries substituted. Before the fix, startup incorrectly reported `videoResultReady=true` (1 fail, 1 pass); after removing startup promotion, both cases pass. The frozen historical manifest remains accessible and current-source keyed restoration still works.
- Targeted controller, composer, progress and presentation tests: **64/64 passed** (`diagnostics/startup-result-green.log`).
- Full suite: **350 tests, 5 suites, 350 passed, 0 failed**, 21.960 seconds (`diagnostics/startup-result-core.log`).
- Signed package built successfully in 24.755 seconds: `diagnostics/clean-startup-result-signed.hap`. Existing deprecated-API warnings remain; no new compile error.
- Independent review confirms same-process close/reopen, in-progress movie composition, reconnect preservation and current-source cache reuse are unchanged. Cold-launch historical result promotion is the sole behavior change.
- No installation, commit, push, cache-file removal, or flight commands were performed for this fix. Returning to an existing background process can still retain its current conversation; this change targets a fresh app process.

## Installation (2026-11-09 15:30)

- User requested installation. Device `<device-id>` was online; fresh pre-update telemetry showed grounded, motors off, camera idle and no active task.
- Installed `diagnostics/clean-startup-result-signed.hap` (11,076,799 bytes), SHA-256 `FAEA3124B581E1FEB7B0A693A200F77E80E8BB8421C7D5015FFBB14CDE5BDE76`.
- Replacement installation returned `install bundle successfully`; launch returned `start ability successfully`. New foreground PID: `45053`.
- New process reported ready/verified connection at 15:30:49 with fresh link/video telemetry. Log: `diagnostics/clean-startup-installed.log`.
- No media files were deleted and no takeoff, selection, shooting or other flight action was issued during installation.
