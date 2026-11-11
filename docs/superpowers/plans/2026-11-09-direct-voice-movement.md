# Direct voice movement

User requirement: execute basic eight-direction movement directly, with the VLM choosing how long to move from the utterance rather than defaulting every instruction to the 0.5-second slider.

- Keep the existing eight directions and 0.1–10 second per-command bound. Successful model `move` responses must include numeric `seconds`; missing/invalid time is rejected, never silently filled with the slider.
- Remove `move` from the additional confirmation list. Retain current subject confirmation, fresh connection, verified flight, task exclusion, cancellation, duplicate-response rejection and final stick centering.
- Explicit seconds/milliseconds win. Suggested qualitative anchors: tiny/稍微/一点点 0.3s, 一点/小幅 0.5s, bare direction 1s, 多一点/明显一点 1.5s, 多一些/大幅/远一点 2s. Vague duration stays at most 2s; unbounded movement is unavailable.
- Existing cloud controls are timed, not calibrated distance/angle control. Meter/degree instructions require clarification rather than invented timing. Negated, hypothetical, quoted, conditional and question-only requests produce no flight action.
- Synchronize phone/desktop prompts and validation. Preserve manual/offline movement settings; log the actual VLM direction/time used by the cloud path.

## Verification

- [x] TDD: direct execution across eight directions and varied durations; no pending confirmation; duplicate/cancelled/expired/busy requests do not move; missing/invalid durations rejected.
- [x] TDD: model policy and phone/desktop parity; preserve subject confirmation and unrelated actions.
- [x] Independent review, full domain tests and signed HAP build; no automated aircraft motion.
- [x] Use synthetic text-only cloud dry-runs without forwarding responses to flight controls.

## Results

- Domain suite: **488/488 passed** (`diagnostics/direct-movement-core.log`). Independent review: 58 targeted tests passed with no actionable finding.
- Actual DeepSeek text-only dry-run: **13/13 passed** (`diagnostics/direct-movement-cloud-results.json`). Explicit 2s/0.5s/300ms were preserved; tiny right movement returned0.3s, bare forward1s, larger forward2s. Negative, conflicting, indefinite, >10-second and degree requests returned none. These were synthetic model calls, never aircraft controls.
- Current movement duration is shown during execution and completion, without old video-result text masking it. Manual slider and offline motion settings remain unchanged.
- Signed artifact: `diagnostics/direct-voice-movement-signed.hap`; current controller/schema/prompt/presentation hashes match the actual build copy.
- No installation performed. Actual motion duration and UI behavior require device regression.
