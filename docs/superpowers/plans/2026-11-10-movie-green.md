# Repair green one-tap movie output

**Goal:** Export independently decodable video with the existing Titan audio/fades and invalidate previously broken cached movies.

## Evidence and root cause

The two current 4K HEVC originals decode normally. The exported12.433s MP4 has373 H.264 packets and AAC audio, but no software-decoded video pictures. Its11-byte avcC (`0164001fffe000fcf8f800`) contains zero SPS and zero PPS; the first packet contains only an IDR. `MovieExport.cpp` caches the encoder's30-byte CODEC_DATA output and sets metadata, but never submits that packet to the muxer. Earlier completion tests checked packet counts/timestamps/player callbacks without confirming decoded images.

Evidence: `diagnostics/movie-green-avc-structure.json`, `movie-green-pixels-stats.json`, `movie-green-archives.log` and the pulled output/originals. Keep recordings out of Git.

## Tasks

- [x] Native: forward original H.264 codec-data bytes through muxer before pictures; preserve EOS, counters, timestamps, audio and pixel layout. Validate parameter sets with native fixtures including the actual invalid avcC.
- [x] Cache: change template identity from `titan-v1` to `titan-avc-v2`; reject old template records both by group and latest-cache paths without deleting originals.
- [x] Offline proof: build a temporary no-controller/no-aircraft test HAP using the same two recorded source files, export again, and independently validate SPS/PPS plus decoded middle/tail/credits/audio/timeline.
- [x] Review, relevant native/domain tests, signed production build, source/hash verification, restore the production application after the temporary harness. No diagnostic app left installed.

No live flight is needed. Check fresh grounded telemetry/unlocked phone immediately before any update; if unavailable, ask the user before interrupting control. Existing reference photo, multi-person selection and movement changes must remain intact.

## Verified result

- 536/536 domain tests pass; native AVC10-case and movie-frame runners pass. Scoped review found no regression in the fix.
- Same original clips exported on the phone as12.433s,373video frames. New avcC contains1SPS+1PPS; whole software video decode succeeds.
- Actual frames at2/5/9/11s have PSNR41.58–42.57dB versus source pictures and correlation>0.999. Credit at11s is readable. Full stereo audio decodes for12.437s with nonzero samples.
- Evidence: `diagnostics/movie-green-fixed-avc-structure.json`, `movie-green-fixed-pixels-stats.json`, `movie-green-phone-codec.log`, `movie-green-core.log` and `movie-green-build-result.json`.
- Signed production HAP `diagnostics/movie-avc-config-fix-signed.hap` built with matching sources, installed and launched; the temporary offline app has been replaced. Existing recordings were preserved.
