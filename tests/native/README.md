# Native HEVC regression

The camera recording is kept out of Git. Copy the original capture described
below to the fixture path, or pass its original path to the test executable.

`hevc_test.cpp` is a C++17 assertion-based executable. Compile it with
`entry/src/main/cpp/HevcStream.cpp`, include `entry/src/main/cpp`, and leave
`NDEBUG` undefined. Pass the absolute path to
`tests/fixtures/video/follow-reordered-pair.assembled.bin` as its only argument.
The same main can be renamed and invoked from a temporary test HAP when a
retail device disallows executing shell-uploaded native binaries.

Fixture provenance: copied without modification from the original project's
`captures/follow-reordered-pair-fixture.assembled.bin` (86,594 bytes). Each record
is a little-endian IEEE754 double timestamp in seconds, a little-endian uint32
payload length, then the Annex B payload. There are seven records: VPS/SPS/PPS,
IDR, and five P pictures, including one transport-reordered pair. SPS is
1280 x 720, 4-bit POC, no decoder picture reordering.

`timing-only-repeat.h265` is derived from the real VPS/SPS by increasing only
num_units_in_tick by one in each RBSP, then restoring emulation-prevention bytes.
The same 90 bytes are embedded in the test so only the original record fixture
needs to be copied to an application test directory.

Coverage: parameter-only input, timing-only repeats, valid SPS dimensions,
complete access unit separation, a real reordered pair, synthetic 4-bit POC
wrap, missing-picture bounded release at three pictures or 120ms, retired late
pictures, ambiguous half-range bypass, unsupported B slices, truncated NAL,
IDR reset, and real PPS changes discarding pending old pictures.

The module receives complete transport payloads, not arbitrary partial byte
chunks. Feed(empty) does not flush pending pictures, matching the original. The worker
may call Drain(nowMs) on its idle timer to release pictures after the 120ms
waiting deadline. Drain advances POC retirement exactly as Feed does; it neither
flushes the codec nor clears parameter/change state.
Unknown syntax is passed through; only validated single-layer simple I/P streams
are reordered. ConfigChanged describes the most recent Feed and reports a
previously seen parameter ID changing after timing-only suppression. Reset clears
all cached syntax, dimensions, pending pictures and statistics. The class is
intended for one serial video worker, not concurrent calls.

`node tests/native/run_video_parameter_cache_test.cjs` runs the production
configuration cache policy on Windows without a device. Codec-local recovery
keeps the same stream's VPS/SPS/PPS; stream/queue discontinuity clears them.
Recovery still requires a new random-access picture and valid dimensions.
The native preview reports `configurationRetained` and `waitingForKeyAgeMs`
so a long keyframe wait can be distinguished from resumed decode output.

`node tests/native/run_video_output_ownership_test.cjs` executes the actual
native output-consumer branch against device API doubles. Metadata failures
must return their output index; non-picture release failures must reach the
existing recovery path. This fixes a separate resource leak, not a proven cause
of the observed 2026-11-11 hardware decoder stalls (both output pools were owned
by OMX at those stalls).

`node tests/native/run_video_diagnostic_gop_test.cjs` checks byte-preserving GOP
capture, the 8MiB storage ceiling, overflow remaining incomplete until another
IRAP, and two-slot rotation. `setDiagnosticDirectory` enables recording inside
the app's private files directory. On a decode stall only, `stall-0`/`stall-1`
contain the raw submitted `.h265` and a `.json` sidecar. Configuration is recorded
separately as `configurationPrefixHex`, never injected into the evidence stream.
`firstAuParameterMask` says which VPS/SPS/PPS were present in its initial AU.
An incomplete capture has metadata but no video file. Replay tools must check
`complete` and `configurationPrefixComplete` before preparing a separate input.
Readback progress records output availability and age/layout/metadata rejection
counts on requests, periodic summaries and stalls without per-frame logs.
`node tests/native/run_video_diagnostic_publish_test.cjs` covers publication
faults: the previous manifest must be removed successfully before writing;
temporary files are completed and renamed before the new manifest is published.
Missing or malformed metadata is not a committed diagnostic sample.

`node tests/native/run_video_frame_cancel_test.cjs` executes the real ticket
methods and checks that cancellation clears only its matching request/result,
leaving later tickets and the decoder session running.
`node tests/native/run_video_readback_release_test.cjs` executes the production
readback output loop and checks that a failed buffer return is logged and
resets only the readback decoder, while a successful return keeps it running.

`node tests/native/run_movie_audio_test.cjs` checks PCM layout, source looping,
fades, cancellation and the final AAC timeline. It also runs the production
`AudioSourceDuration.h` decision and normalization used after the BGM decoder
drains. The 2026-11-10 phone fixture contains 1,657,728 stereo frames at 48 kHz
(34.536s), while source metadata declares 34.392s: both sides reached EOS, so
6,912 excess frames are trimmed and 1,650,816 remain for the source loop.

Complete input and output EOS are both required. A real shortfall beyond
1,152 source frames still fails; an accepted short source is never extended.
Excess is accepted only within a fixed 250ms ceiling and is removed before
rendering. This is a bounded device/metadata compatibility window, not proof
that the excess consists of MP3 padding. The ceiling never scales with song
length. Tests include 250ms and 250ms plus one sample at several rates,
incomplete EOS, invalid inputs, the 128MiB stereo-PCM and two-hour bounds,
fractional-frame rounding and ensuring a removed tail cannot return on a loop.
Source checks do not replace the independent final AAC/video duration checks.
