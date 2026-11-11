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
