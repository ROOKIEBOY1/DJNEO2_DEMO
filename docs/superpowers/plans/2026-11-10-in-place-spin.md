# In-place spin shortcut

The user requests “原地转圈” and similar phrases to default to left yaw for10seconds. During those10seconds the yaw input remains active; the existing flight service centers at completion. This does not add an unlimited spin loop or promise an exact360-degree rotation.

- Named in-place spin defaults to move/turn_left/seconds10; explicit right direction or supported finite duration wins.
- Subject-centered orbit remains circle and retains common subject confirmation.
- Existing slight yaw/short adjustment defaults stay short; no exact-degree inference or indefinite-until-stop execution.
- Preserve eight-axis bounds, direct execution, duplicate/cancellation/connection gates and interruption.

## Verification

- [x] TDD phone/desktop prompt contract and parity: new policy tests failed before changes and passed after; all22 targeted checks pass, with no review findings.
- [x] Real FlightCommandService replay confirms continuous10s yaw, one final center, no automatic restart, and cancellation/link-loss interruption.
- [x] Synthetic live cloud interpretation checks:18/18 pass after tightening explicit-duration and indefinite-request precedence; initial results retained separately. No flight commands sent to hardware.
- [x] Domain suite:495/495 pass. Signed HAP built successfully; copied build sources match the workspace. Package is not installed.

Evidence: `diagnostics/in-place-spin-core.log`, `diagnostics/in-place-spin-cloud-results.json`, `diagnostics/in-place-spin-build-result.json` and `diagnostics/in-place-spin-signed.hap`. Cloud samples and simulated movement checks do not guarantee an exact revolution or real aircraft behavior.
