#include "../../entry/src/main/cpp/AudioPcm.h"
#include "../../entry/src/main/cpp/AudioAac.h"
#include "../../entry/src/main/cpp/AudioSourceDuration.h"
#include "../../entry/src/main/cpp/MovieRecipe.h"
using namespace neo::movie::pcm;
#if defined(_WIN32)
extern "C" { int _fltused = 0; }
#endif

static bool Cancelled(void *value) { return *static_cast<bool *>(value); }
static bool CancelDuringBlock(void *value) { return ++*static_cast<int *>(value) == 2; }

struct TestStereoPcm {
    size_t count;
    unsigned resizes = 0;
    size_t size() const { return count; }
    void resize(size_t value) { count = value; ++resizes; }
};

static int RunSourceDurationTests();

// Hand-checked fixtures catch offset/stride errors, lost channels, wrong rate,
// repeated one-second fades, missing final fade, and ignored cancellation.
extern "C" int RunMovieAudioTests()
{
    // A user-supplied replacement starts at its beginning and carries no Titan credit.
    if (neo::movie::MUSIC_START_SECONDS != 0 || neo::movie::MUSIC_SHOW_CREDIT) return 54;
    int16_t stereo[2]{};
    const uint8_t padded[] = {0xe8, 0x03, 0x18, 0xfc, 0xff, 0xff, 0xd0, 0x07, 0x30, 0xf8};
    View packed{padded, sizeof(padded), 2, 2, SampleKind::S16, 6, 2};
    if (!ReadStereo(packed, 1, stereo) || stereo[0] != 2000 || stereo[1] != -2000) return 1;
    packed.byteCount = 9;
    if (ReadStereo(packed, 1, stereo)) return 2;
    const float planes[] = {0.5f, -0.5f, 1.0f, -1.0f};
    View planar{reinterpret_cast<const uint8_t *>(planes), sizeof(planes), 2, 2, SampleKind::F32, 4, 8};
    if (!ReadStereo(planar, 1, stereo) || stereo[0] != -16384 || stereo[1] != -32768) return 3;
    const uint8_t mono[] = {0, 128, 255};
    View monoView{mono, sizeof(mono), 3, 1, SampleKind::U8, 1, 1};
    if (!ReadStereo(monoView, 2, stereo) || stereo[0] != 32512 || stereo[1] != 32512) return 4;
    const int16_t source[] = {0, 1000, 10000, 11000, 20000, 21000, 30000, 31000};
    if (!ResampleLoop(source, 4, 24000, 3, stereo) || stereo[0] != 15000 || stereo[1] != 16000) return 5;
    if (!ResampleLoop(source, 4, 24000, 8, stereo) || stereo[0] != 0 || stereo[1] != 1000) return 6;
    if (Envelope(0, 240000) != 0.0 || Envelope(239999, 240000) != 0.0 ||
        Envelope(24000, 240000) != 0.5 || Envelope(100000, 240000) != 1.0) return 7;
    if (Envelope(0, 5) != 0.0 || Envelope(1, 5) != 0.5 || Envelope(2, 5) != 1.0 ||
        Envelope(3, 5) != 0.5 || Envelope(4, 5) != 0.0 || Envelope(0, 1) != 0.0) return 8;
    const int16_t tone[] = {10000, -10000};
    int16_t output[10]{};
    bool cancelled = false;
    if (!Render(tone, 1, 48000, 0, 5, 5, output, Cancelled, &cancelled) ||
        output[0] != 0 || output[2] != 5000 || output[4] != 10000 ||
        output[5] != -10000 || output[6] != 5000 || output[8] != 0) return 9;
    cancelled = true;
    output[0] = 1234;
    if (Render(tone, 1, 48000, 0, 5, 5, output, Cancelled, &cancelled) || output[0] != 1234) return 10;
    if (Render(tone, 0, 48000, 0, 5, 5, output, nullptr, nullptr) ||
        Render(tone, 1, 0, 0, 5, 5, output, nullptr, nullptr) ||
        Render(tone, 1, 48000, 4, 5, 2, output, nullptr, nullptr)) return 11;
    const uint8_t adts[] = {0xff, 0xf1, 0x4c, 0x80, 0x01, 0x5f, 0xfc, 0x11, 0x22, 0x33};
    neo::movie::aac::Packet packet;
    if (!neo::movie::aac::ParseAdts48kStereo(adts, sizeof(adts), packet) ||
        packet.offset != 7 || packet.size != 3 || packet.config[0] != 0x11 || packet.config[1] != 0x90) return 12;
    if (neo::movie::aac::ParseAdts48kStereo(adts, 6, packet) ||
        neo::movie::aac::ParseAdts48kStereo(adts, 9, packet)) return 13;
    const uint8_t wrongRate[] = {0xff, 0xf1, 0x50, 0x80, 0x01, 0x5f, 0xfc, 0x11, 0x22, 0x33};
    if (neo::movie::aac::ParseAdts48kStereo(wrongRate, sizeof(wrongRate), packet)) return 14;
    const uint8_t s24[] = {0, 0, 0x40, 0, 0, 0xc0};
    View s24View{s24, sizeof(s24), 1, 2, SampleKind::S24, 6, 3};
    if (!ReadStereo(s24View, 0, stereo) || stereo[0] != 16384 || stereo[1] != -16384) return 15;
    const uint8_t s32[] = {0, 0, 0, 0x40, 0, 0, 0, 0xc0};
    View s32View{s32, sizeof(s32), 1, 2, SampleKind::S32, 8, 4};
    if (!ReadStereo(s32View, 0, stereo) || stereo[0] != 16384 || stereo[1] != -16384) return 16;
    if (!ResampleLoop(source, 4, 24000, 7, stereo) || stereo[0] != 15000 || stereo[1] != 16000 ||
        !ResampleLoop(source, 4, 96000, 1, stereo) || stereo[0] != 20000 || stereo[1] != 21000) return 17;
    int16_t block[256];
    int checks = 0;
    block[128] = 1234;
    if (Render(tone, 1, 48000, 50000, 240000, 128, block, CancelDuringBlock, &checks) ||
        block[126] != 10000 || block[128] != 1234) return 18;
    const uint8_t crcAdts[] = {0xff, 0xf0, 0x4c, 0x80, 0x01, 0x9f, 0xfc, 0, 0, 0x11, 0x22, 0x33};
    if (!neo::movie::aac::ParseAdts48kStereo(crcAdts, sizeof(crcAdts), packet) ||
        packet.offset != 9 || packet.size != 3) return 19;
    // All PCM may be accepted before a codec prematurely emits EOS. The actual
    // packets must still cover the movie; a nonempty 46-packet prefix of 1s fails.
    using neo::movie::aac::HasCompleteDuration;
    if (HasCompleteDuration(960000, 46, 1000000)) return 20;
    if (!HasCompleteDuration(981333, 47, 1000000) ||
        !HasCompleteDuration(0, 1, 1) || !HasCompleteDuration(21333, 2, 42666)) return 21;
    if (HasCompleteDuration(981333, 46, 1000000) ||
        HasCompleteDuration(1000000, 47, 1000000) ||
        HasCompleteDuration(0, 0, 1) || HasCompleteDuration(0, 1, 0)) return 22;
    neo::movie::aac::Timeline timing;
    int64_t normalized = -1;
    if (!timing.Push(-21333, normalized) || normalized != 0 ||
        !timing.Push(0, normalized) || normalized != 21333 ||
        !timing.Push(21333, normalized) || normalized != 42666 ||
        !timing.Push(42667, normalized) || normalized != 64000) return 23;
    if (timing.Push(42667, normalized) || timing.Push(42666, normalized) ||
        timing.Push(85333, normalized)) return 24;
    if (!timing.Push(64000, normalized) || normalized != 85333) return 25;
    // Some codecs increment each packet by the integer 21333us period, rather
    // than rounding the cumulative rational clock. At 120s that is a 1874us
    // timestamp drift, while 5625 access units still contain exactly 120s PCM.
    if (!HasCompleteDuration(119976792, 5625, 120000000) ||
        HasCompleteDuration(119955459, 5624, 120000000)) return 26;
    // Phone capture, 2026-11-09: the target is 534400 PCM samples (522 AAC
    // access units). Two additional drain packets carry a 42666us jump even
    // though the complete retained prefix has already passed its checks.
    using neo::movie::aac::Disposition;
    using neo::movie::aac::TrackTimeline;
    TrackTimeline phoneTrack(11133333);
    if (phoneTrack.Complete()) return 30;
    for (int64_t i = 0; i < 522; ++i) {
        if (phoneTrack.Push(-42666 + i * 21333, normalized) != Disposition::Keep) return 28;
        if (i < 521 && phoneTrack.Complete()) return 31;
    }
    if (normalized != 11114493 || !phoneTrack.Complete()) return 29;
    if (phoneTrack.Push(11114493, normalized) != Disposition::Padding ||
        phoneTrack.Push(11135826, normalized) != Disposition::Padding ||
        normalized != 11114493 || !phoneTrack.Complete()) return 27;
    // A gap before the target is complete must still fail permanently. Later
    // output cannot turn a truncated prefix into a complete music track.
    TrackTimeline missing(11133333);
    if (missing.Push(-42666, normalized) != Disposition::Keep ||
        missing.Push(0, normalized) != Disposition::Invalid || normalized != 0 ||
        missing.Complete() || missing.Push(-21333, normalized) != Disposition::Invalid) return 32;
    TrackTimeline duplicate(1000000);
    if (duplicate.Push(100, normalized) != Disposition::Keep ||
        duplicate.Push(100, normalized) != Disposition::Invalid || duplicate.Complete()) return 33;
    TrackTimeline backwards(1000000);
    if (backwards.Push(100, normalized) != Disposition::Keep ||
        backwards.Push(99, normalized) != Disposition::Invalid || backwards.Complete()) return 34;
    // A single AAC packet covers even a sub-sample movie; extra drain data
    // does not change its saved PTS, and no packet means no complete track.
    TrackTimeline shortest(1);
    if (shortest.Complete() || shortest.Push(-42666, normalized) != Disposition::Keep ||
        normalized != 0 || !shortest.Complete() ||
        shortest.Push(-21333, normalized) != Disposition::Padding || normalized != 0) return 35;
    TrackTimeline zero(0), negative(-1), excessive(INT64_MAX);
    normalized = 1234;
    if (zero.Push(0, normalized) != Disposition::Invalid || zero.Complete() ||
        negative.Push(0, normalized) != Disposition::Invalid || negative.Complete() ||
        excessive.Push(0, normalized) != Disposition::Invalid || excessive.Complete() ||
        normalized != 1234) return 36;
    // Valid cadence still cannot put a retained packet outside the target.
    TrackTimeline tooLate(21334);
    if (tooLate.Push(0, normalized) != Disposition::Keep ||
        tooLate.Push(21334, normalized) != Disposition::Invalid || tooLate.Complete()) return 37;
    // The wrapper also preserves the original overflow-safe raw PTS handling.
    TrackTimeline overflow(1000000);
    if (overflow.Push(INT64_MIN, normalized) != Disposition::Keep ||
        overflow.Push(INT64_MAX, normalized) != Disposition::Invalid || overflow.Complete()) return 38;
    // MovieAudio passes attr.pts as both the copied raw input and normalized
    // output. This must preserve priming rebasing without corrupting raw PTS.
    TrackTimeline aliased(42666);
    int64_t attrPts = -42666;
    if (aliased.Push(attrPts, attrPts) != Disposition::Keep || attrPts != 0) return 39;
    attrPts = -21333;
    if (aliased.Push(attrPts, attrPts) != Disposition::Keep || attrPts != 21333 ||
        !aliased.Complete()) return 40;
    attrPts = 11135826;
    if (aliased.Push(attrPts, attrPts) != Disposition::Padding || attrPts != 11135826 ||
        !aliased.Complete()) return 41;
    // The distinct negative intro must never be sampled, even when the tail
    // loops. Output time is already beyond fade-in; it is not a music offset.
    const int16_t excerpt[] = {-30000, 30000, -20000, 20000,
        1200, -1200, 2400, -2400, 3600, -3600};
    int16_t excerptOutput[10]{};
    if (!Render(excerpt, 5, 48000, 48000, 240000, 4, excerptOutput, nullptr, nullptr, 2) ||
        excerptOutput[0] != 1200 || excerptOutput[1] != -1200 ||
        excerptOutput[2] != 2400 || excerptOutput[3] != -2400 ||
        excerptOutput[4] != 3600 || excerptOutput[5] != -3600 ||
        excerptOutput[6] != 1200 || excerptOutput[7] != -1200) return 42;
    // 44100 -> 48000: source positions in the two-frame tail are
    // 0, 0.91875, 1.8375; the last value interpolates back to the tail start.
    const int16_t fractional[] = {-30000, 30000, -20000, 20000,
        0, 1000, 16000, 17000};
    if (!Render(fractional, 4, 44100, 48000, 240000, 3, excerptOutput, nullptr, nullptr, 2) ||
        excerptOutput[0] != 0 || excerptOutput[1] != 1000 ||
        excerptOutput[2] != 14700 || excerptOutput[3] != 15700 ||
        excerptOutput[4] != 2600 || excerptOutput[5] != 3600) return 43;
    // Half-rate seam interpolation is 5000 -> 1000, never 5000 -> intro.
    const int16_t seam[] = {-30000, 30000, 1000, 1100, 3000, 3100, 5000, 5100};
    if (!Render(seam, 4, 24000, 48003, 240000, 4, excerptOutput, nullptr, nullptr, 1) ||
        excerptOutput[0] != 4000 || excerptOutput[1] != 4100 ||
        excerptOutput[2] != 5000 || excerptOutput[3] != 5100 ||
        excerptOutput[4] != 3000 || excerptOutput[5] != 3100 ||
        excerptOutput[6] != 1000 || excerptOutput[7] != 1100) return 44;
    // Both fades follow the movie clock although the source begins later.
    const int16_t fadeExcerpt[] = {-30000, 30000, -20000, 20000, 10000, -10000};
    if (!Render(fadeExcerpt, 3, 48000, 0, 5, 5, excerptOutput, nullptr, nullptr, 2) ||
        excerptOutput[0] != 0 || excerptOutput[1] != 0 ||
        excerptOutput[2] != 5000 || excerptOutput[3] != -5000 ||
        excerptOutput[4] != 10000 || excerptOutput[5] != -10000 ||
        excerptOutput[6] != 5000 || excerptOutput[7] != -5000 ||
        excerptOutput[8] != 0 || excerptOutput[9] != 0) return 45;
    if (!Render(fadeExcerpt, 3, 48000, 24000, 240000, 1, excerptOutput, nullptr, nullptr, 2) ||
        excerptOutput[0] != 5000 || excerptOutput[1] != -5000 ||
        !Render(fadeExcerpt, 3, 48000, 215999, 240000, 1, excerptOutput, nullptr, nullptr, 2) ||
        excerptOutput[0] != 5000 || excerptOutput[1] != -5000 ||
        !Render(fadeExcerpt, 3, 48000, 239999, 240000, 1, excerptOutput, nullptr, nullptr, 2) ||
        excerptOutput[0] != 0 || excerptOutput[1] != 0) return 46;
    // Independent blocks must keep the same fractional source phase. Splits
    // are deliberately neither AAC boundaries nor integer source positions.
    int16_t wholeExcerpt[514], splitExcerpt[514];
    if (!Render(fractional, 4, 44100, 48000, 240000, 257, wholeExcerpt, nullptr, nullptr, 2) ||
        !Render(fractional, 4, 44100, 48000, 240000, 73, splitExcerpt, nullptr, nullptr, 2) ||
        !Render(fractional, 4, 44100, 48073, 240000, 111, splitExcerpt + 146, nullptr, nullptr, 2) ||
        !Render(fractional, 4, 44100, 48184, 240000, 73, splitExcerpt + 368, nullptr, nullptr, 2)) return 47;
    for (size_t sample = 0; sample < 514; ++sample) {
        if (wholeExcerpt[sample] != splitExcerpt[sample]) return 48;
    }
    // Reject offsets before pointer arithmetic, including empty output and a
    // huge declared source whose shortened tail would otherwise seem valid.
    excerptOutput[0] = 1234;
    if (Render(excerpt, 5, 48000, 48000, 240000, 1, excerptOutput, nullptr, nullptr, 5) ||
        Render(excerpt, 5, 48000, 48000, 240000, 1, excerptOutput, nullptr, nullptr, 6) ||
        Render(excerpt, 5, 48000, 48000, 240000, 1, excerptOutput, nullptr, nullptr, UINT64_MAX) ||
        Render(excerpt, 5, 48000, 48000, 240000, 0, excerptOutput, nullptr, nullptr, 5) ||
        excerptOutput[0] != 1234) return 49;
    if (Render(tone, 120000001, 48000, 48000, 240000, 0, excerptOutput, nullptr, nullptr, 120000000) ||
        Render(tone, SIZE_MAX, 48000, 48000, 240000, 0, excerptOutput, nullptr, nullptr, SIZE_MAX - 1) ||
        Render(nullptr, 5, 48000, 48000, 240000, 1, excerptOutput, nullptr, nullptr, 2) ||
        Render(excerpt, 5, 192001, 48000, 240000, 1, excerptOutput, nullptr, nullptr, 2) ||
        Render(excerpt, 5, 48000, 48000, 240000, 1, nullptr, nullptr, nullptr, 2) ||
        excerptOutput[0] != 1234) return 50;
    cancelled = true;
    if (Render(fadeExcerpt, 3, 48000, 0, 240000, 1, excerptOutput, Cancelled, &cancelled, 2) ||
        excerptOutput[0] != 1234) return 51;
    checks = 0;
    block[128] = 1234;
    if (Render(fadeExcerpt, 3, 48000, 50000, 240000, 128, block, CancelDuringBlock, &checks, 2) ||
        block[0] != 10000 || block[126] != 10000 || block[127] != -10000 || block[128] != 1234) return 52;
    const int16_t limits[] = {1000, -1000, 32767, -32768};
    if (!Render(limits, 2, 48000, 48000, 240000, 1, excerptOutput, nullptr, nullptr, 1) ||
        excerptOutput[0] != 32767 || excerptOutput[1] != -32768) return 53;
    const int16_t userMusic[] = {1200, -1200, 2400, -2400, 3600, -3600, 4800, -4800};
    const uint64_t recipeOffset = uint64_t(48000) * neo::movie::MUSIC_START_SECONDS;
    if (!Render(userMusic, 4, 48000, 48000, 240000, 4, excerptOutput, nullptr, nullptr, recipeOffset)) return 55;
    for (unsigned i = 0; i < 8; ++i) if (excerptOutput[i] != userMusic[i]) return 56;
    return RunSourceDurationTests();
}

// Keep this independent of the large render fixtures above: the Windows
// freestanding executable intentionally links without CRT stack-probe helpers.
__attribute__((noinline)) static int RunSourceDurationTests()
{
    using neo::movie::audio::PlanSourceDuration;
    using neo::movie::audio::ApplySourceDurationPlan;
    using neo::movie::audio::SourceDurationStatus;
    // Real phone decode, 2026-11-10: 34.536s PCM vs 34.392s metadata.
    // Both sides reached EOS; retain declared frames and discard exactly 6912.
    const auto phoneSource = PlanSourceDuration(1657728, 48000, 34392000, true, true);
    if (!phoneSource.Accepted() || phoneSource.expectedFrames != 1650816 ||
        phoneSource.retainedFrames != 1650816 || phoneSource.trimmedFrames != 6912 ||
        phoneSource.status != SourceDurationStatus::TrimmedTail) return 57;
    TestStereoPcm phonePcm{1657728 * 2};
    if (!ApplySourceDurationPlan(phonePcm, phoneSource) || phonePcm.count != 1650816 * 2 ||
        phonePcm.resizes != 1) return 58;
    const auto exactSource = PlanSourceDuration(48000, 48000, 1000000, true, true);
    if (!exactSource.Accepted() || exactSource.status != SourceDurationStatus::Exact ||
        exactSource.retainedFrames != 48000 || exactSource.trimmedFrames) return 59;
    // The excess ceiling is 250ms of source samples, independent of song length.
    const int sourceRates[] = {8000, 8001, 44100, 44101, 48000, 96000, 192000};
    for (const int rate : sourceRates) {
        const uint64_t expected = static_cast<uint64_t>(rate);
        const uint64_t tail = static_cast<uint64_t>(rate) / 4;
        const auto boundary = PlanSourceDuration(expected + tail, rate, 1000000, true, true);
        const auto over = PlanSourceDuration(expected + tail + 1, rate, 1000000, true, true);
        if (!boundary.Accepted() || boundary.retainedFrames != expected || boundary.trimmedFrames != tail ||
            over.Accepted() || over.status != SourceDurationStatus::ExcessiveTail) return 60;
    }
    if (PlanSourceDuration(28800000 + 24000, 48000, 600000000, true, true).Accepted()) return 61;
    const auto shortBoundary = PlanSourceDuration(48000 - 1152, 48000, 1000000, true, true);
    if (!shortBoundary.Accepted() || shortBoundary.status != SourceDurationStatus::ShortWithinFrame ||
        shortBoundary.retainedFrames != 48000 - 1152 || shortBoundary.trimmedFrames ||
        PlanSourceDuration(48000 - 1153, 48000, 1000000, true, true).Accepted()) return 62;
    // An accepted short source is never filled or extended with fabricated PCM.
    TestStereoPcm shortPcm{(48000 - 1152) * 2};
    if (!ApplySourceDurationPlan(shortPcm, shortBoundary) || shortPcm.count != (48000 - 1152) * 2) return 63;
    const int incompleteEosCases[] = {0, 1, 2};
    for (const int bits : incompleteEosCases) {
        const auto incomplete = PlanSourceDuration(1657728, 48000, 34392000, bits & 1, bits & 2);
        TestStereoPcm untouched{1657728 * 2};
        if (incomplete.Accepted() || incomplete.status != SourceDurationStatus::IncompleteEos ||
            ApplySourceDurationPlan(untouched, incomplete) || untouched.resizes) return 64;
    }
    if (PlanSourceDuration(0, 48000, 1000000, true, true).Accepted() ||
        PlanSourceDuration(UINT64_MAX, 48000, 1000000, true, true).Accepted() ||
        PlanSourceDuration(neo::movie::audio::MAX_SOURCE_PCM_FRAMES + 1, 48000, 1000000, true, true).Accepted()) return 65;
    const uint64_t memoryBound = neo::movie::audio::MAX_SOURCE_PCM_FRAMES;
    if (!PlanSourceDuration(memoryBound, 48000, static_cast<int64_t>(memoryBound * 1000000 / 48000),
        true, true).Accepted()) return 71;
    const int invalidRates[] = {0, -1, 7999, 192001};
    for (const int rate : invalidRates) {
        if (PlanSourceDuration(48000, rate, 1000000, true, true).Accepted()) return 66;
    }
    const int64_t invalidDurations[] = {0, -1, INT64_MAX, neo::movie::audio::MAX_SOURCE_DURATION_US + 1};
    for (const int64_t duration : invalidDurations) {
        if (PlanSourceDuration(48000, 48000, duration, true, true).Accepted()) return 67;
    }
    // Ceil the source duration to whole PCM frames; do not lose the last sample.
    const auto fractionalDuration = PlanSourceDuration(3, 44100, 23, true, true);
    if (!fractionalDuration.Accepted() || fractionalDuration.expectedFrames != 2 ||
        fractionalDuration.retainedFrames != 2 || fractionalDuration.trimmedFrames != 1) return 68;
    TestStereoPcm wrongSize{phoneSource.rawFrames * 2 - 1};
    if (ApplySourceDurationPlan(wrongSize, phoneSource) || wrongSize.resizes) return 69;
    // The render loop receives the retained size, so a discarded tail cannot
    // reappear when the selected source loops; fades remain on the movie clock.
    const int16_t trimmedSource[] = {1200, -1200, -30000, 30000};
    int16_t retainedOutput[2];
    const auto tinySource = PlanSourceDuration(2, 8000, 125, true, true);
    TestStereoPcm tinyPcm{4};
    if (!ApplySourceDurationPlan(tinyPcm, tinySource) || tinyPcm.count != 2 ||
        !Render(trimmedSource, tinyPcm.count / 2, 8000, 48000, 240000, 1, retainedOutput, nullptr, nullptr) ||
        retainedOutput[0] != 1200 || retainedOutput[1] != -1200) return 70;
    return 0;
}

#ifndef __wasm__
int main() { return RunMovieAudioTests(); }
#endif
