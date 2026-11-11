#pragma once
#include <stddef.h>
#include <stdint.h>

namespace neo::movie::audio {
constexpr uint64_t MAX_SOURCE_PCM_FRAMES = (128ULL * 1024 * 1024) / (2 * sizeof(int16_t));
constexpr int64_t MAX_SOURCE_DURATION_US = 2LL * 60 * 60 * 1000000;
// A fixed compatibility ceiling, not a claim that every MP3 has 250ms padding.
// Both decoder input and output must reach EOS. Longer music never gets a
// percentage-based allowance; discard any accepted excess before rendering.
constexpr int64_t MAX_SOURCE_TAIL_US = 250000;

enum class SourceDurationStatus { Invalid, IncompleteEos, TooShort, ExcessiveTail, Exact, ShortWithinFrame, TrimmedTail };
struct SourceDurationPlan {
    SourceDurationStatus status = SourceDurationStatus::Invalid;
    uint64_t rawFrames = 0;
    uint64_t expectedFrames = 0;
    uint64_t retainedFrames = 0;
    uint64_t trimmedFrames = 0;
    bool Accepted() const
    {
        return status == SourceDurationStatus::Exact || status == SourceDurationStatus::ShortWithinFrame ||
            status == SourceDurationStatus::TrimmedTail;
    }
};

inline SourceDurationPlan PlanSourceDuration(uint64_t rawFrames, int rate, int64_t durationUs,
    bool inputEnded, bool outputEnded)
{
    SourceDurationPlan result;
    result.rawFrames = rawFrames;
    if (!rawFrames || rawFrames > MAX_SOURCE_PCM_FRAMES || rate < 8000 || rate > 192000 ||
        durationUs <= 0 || durationUs > MAX_SOURCE_DURATION_US) return result;
    result.expectedFrames = (static_cast<uint64_t>(durationUs) * rate + 999999) / 1000000;
    if (!inputEnded || !outputEnded) {
        result.status = SourceDurationStatus::IncompleteEos;
        return result;
    }
    if (rawFrames < result.expectedFrames && result.expectedFrames - rawFrames > 1152) {
        result.status = SourceDurationStatus::TooShort;
        return result;
    }
    const uint64_t maximumTailFrames = static_cast<uint64_t>(rate) * MAX_SOURCE_TAIL_US / 1000000;
    if (rawFrames > result.expectedFrames && rawFrames - result.expectedFrames > maximumTailFrames) {
        result.status = SourceDurationStatus::ExcessiveTail;
        return result;
    }
    result.retainedFrames = rawFrames < result.expectedFrames ? rawFrames : result.expectedFrames;
    result.trimmedFrames = rawFrames - result.retainedFrames;
    result.status = result.trimmedFrames ? SourceDurationStatus::TrimmedTail :
        (rawFrames < result.expectedFrames ? SourceDurationStatus::ShortWithinFrame : SourceDurationStatus::Exact);
    return result;
}

template<class StereoPcm>
inline bool ApplySourceDurationPlan(StereoPcm &samples, const SourceDurationPlan &plan)
{
    if (!plan.Accepted() || !plan.retainedFrames || samples.size() % 2 || samples.size() / 2 != plan.rawFrames ||
        plan.retainedFrames > plan.rawFrames || plan.retainedFrames > SIZE_MAX / 2 ||
        plan.trimmedFrames != plan.rawFrames - plan.retainedFrames) return false;
    samples.resize(static_cast<size_t>(plan.retainedFrames) * 2);
    return true;
}

inline const char *SourceDurationReason(SourceDurationStatus status)
{
    switch (status) {
        case SourceDurationStatus::Invalid: return "invalid source PCM/rate/duration";
        case SourceDurationStatus::IncompleteEos: return "source input/output EOS incomplete";
        case SourceDurationStatus::TooShort: return "source shortfall exceeds one MP3 frame";
        case SourceDurationStatus::ExcessiveTail: return "source tail exceeds fixed 250ms compatibility window";
        case SourceDurationStatus::Exact: return "source duration matched";
        case SourceDurationStatus::ShortWithinFrame: return "source shortfall within one MP3 frame";
        case SourceDurationStatus::TrimmedTail: return "complete source tail trimmed to declared duration";
    }
    return "unknown source duration status";
}
} // namespace neo::movie::audio
