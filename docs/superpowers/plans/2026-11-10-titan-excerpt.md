# Start Titan from an energetic middle excerpt

**Goal:** One-tap movies start from a fixed energetic middle section of the bundled Titan rather than its intro.

**Approach:** Measure the actual bundled audio, choose one fixed middle start for this Demo, and keep the existing native audio pipeline. No new controls or per-export automatic music analysis. The original music resource and music credit remain available.

## Constraints and interfaces

- Fixed start:96seconds. The bundled track is175.80s; a strong attack at97.685s occurs after the one-second fade completes. Measured12.4s excerpt RMS is25.338dB above the intro (no gain boost added).
- New root-owned `MovieRecipe.h` defines `neo::movie::TITAN_START_SECONDS` as96 with an unsigned constant and no runtime setting.
- Append optional `uint64_t sourceStartFrames=0` to `pcm::Render` in `AudioPcm.h`; this is measured at the SOURCE sample rate. Validate before pointer arithmetic. Resampling/looping uses only `[sourceStartFrames, sourceFrames)`, so long movies loop back to the excerpt start, not the intro.
- Fade/envelope remains relative to the video timeline, not the music offset; existing one-second fade-in/out, block continuity, cancellation and exact AAC duration remain.
- MovieAudio computes `sourceStartFrames = pcm.rate * TITAN_START_SECONDS`, validates the range, and passes the same offset for every output block.
- Bump the shared movie template/cache identity so a previous intro-based result is regenerated. Keep H.264 SPS/PPS fixes and all flight/selection code intact.

## Tasks

- [x] Analyze local Titan energy/onsets, select96s and prepare a15s preview/measurement record.
- [x] Native RED/GREEN tests for source offset, fractional resampling, loop boundary, fade timeline, block continuity, invalid offsets and cancellation. Integrate the offset into native audio encoding.
- [x] Cache revision tests reject old intro-based movies while retaining `titan-climax-v3` reuse; update crop/change credit description.
- [x] Review, relevant native/domain tests, signed build and source/artifact hash checks. No installation or aircraft commands performed.

Tests must distinguish the requested music position from merely shifting output timestamps; video and audio still start at movie timestamp zero.

## Result

- Native RED exit42 confirmed intro playback before the fix; all53 fixture groups pass after it. Cache RED30pass/3fail; relevant cache/composer/controller/startup tests pass44/44. Full domain suite556/556 passes.
- Independent review found no actionable issue and reran53 native groups plus42 movie/cache/controller tests.
- Signed HAP `diagnostics/titan-middle-excerpt-signed.hap` builds successfully; all copied production sources match. Hashes and installation state: `diagnostics/titan-excerpt-build-result.json`.
- Audio evidence: `diagnostics/titan_middle_analysis.json`; preview `diagnostics/titan-middle-96s-preview-15s.wav`. Energy analysis is not a claim of subjective listening quality.
- Not installed; no device export or flight test was performed for this change. Future changes to the excerpt position must also advance the cache template identity.
