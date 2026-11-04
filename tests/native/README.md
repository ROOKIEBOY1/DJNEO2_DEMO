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
