# Direct video keyframe recovery

## Evidence and scope

Port the new reverse-engineered video request onto baseline `475ca44`. The reference is `开发基地1/tools/video_keyframe.py` and the controlled ground record `keyframe-probe-20261111-111407.json`: 15.036s baseline and 3.022s flag-zero control produced no IDR/output; the first flag-one request was followed by an IDR after 45.014ms and 154 decoded frames over the next five seconds. A second flag-one was sent only after that IDR arrived. The control log excludes automatic-request contamination.

Send direct DUML `02 → E9`, flags `00`, command `18/47`, ten-byte payload `00 08 + uint32LE(monotonic milliseconds) + uint32LE(enabled)`. The timestamp's exact meaning remains unverified; monotonic milliseconds modulo uint32 is the tested hypothesis. This is separate from the older unconfirmed camera `02/B3` command.

The current decoder rebuild clears references and waits for a real IRAP. An active request can fill that recovery gap. Ground evidence does not establish that every airborne/hardware stall is cured.

## Design

- A pure codec encodes only the observed request. DroneSession sends it through the existing reliable transport directly, with no task tunnel or DUML ACK waiter. Keep the camera/native-task whitelists unchanged.
- A Session-owned pulse sends true then independently attempts false after at least 120ms. Fence the complete operation to the original session generation and transport/socket. Decode recovery or task changes do not cancel the reset; replacing/disconnecting the session does. Bound asynchronous send completion and do not block the stick/ACK tick.
- A small policy observes fresh reliable control, video UDP age, native decoder progress and epoch. Normal preview does not trigger requests. Wait at least two seconds at preview startup or until output is older than two seconds, require video UDP age at most one second, impose a five-second cooldown and at most three automatic attempts per freeze episode. Require sustained healthy output before restoring the automatic budget.
- An accepted request is not proof of recovery. Only new accepted random-access input plus fresh rendered output establishes observed recovery. Retain explicit request/waiting/exhausted status independently of task/media feedback.
- Add a manual “恢复画面” control. A deliberate manual recovery may reopen a locally paused preview before requesting a keyframe; automatic recovery must not clear the existing native pause/failure budget. Preserve the aircraft session and every flight/task/subject gate.

No previous frame-matching, output-buffer, native GOP tracing or DFX changes are included. No installation or live aircraft request is part of implementation verification.

## Completed-task handoff extension

The user also requested the completed dolly → circle transition when the aircraft returns to ordinary hover (mode 6) with tracking disabled. Requiring tracking mode 26 before the existing reselect step prevents any new image or reselect from occurring.

Add a separate candidate-verification branch only at this closeup boundary. Require verified fresh control/video, this flight's acknowledged takeoff, fresh ordinary airborne hover, no landing/movement, positively completed native task and idle camera. Keep the sealed shared video-sequence handoff. The old native ownership may still be set before `completeForHover`; do not require it to be released before verifying the candidate.

This transition is automatic under the already confirmed closeup plan: no additional subject-selection prompt or user confirmation is introduced. If the original target cannot be verified, stop the remaining movements and retain the existing media sequence for recovery.

Recover the picture through the shared bounded keyframe policy. Capture without triggering an unrelated automatic scan. Require a new same-decoder image captured after this handoff began, session/flight/control identity, a fresh time-matched candidate report and the original target ID in both the image candidates and live candidates. Candidate evidence authorizes only the existing preparation/reselection path. It never counts as tracking. Preserve mode-26 fresh same-ID tracking and task/camera readiness before the actual circle start. Cancel, landing, a replaced session, a different target, stale input or a decoder reset invalidate pending evidence.
