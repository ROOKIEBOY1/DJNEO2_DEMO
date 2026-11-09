#pragma once
#include <stdint.h>

namespace neo {
// One preview worker owns this policy; a new session gets a fresh budget.
class VideoRecovery {
public:
    bool Failed() {
        OnDiscontinuity();
        if (failures_ < MaximumFailures) ++failures_;
        return Paused();
    }
    unsigned Failures() const { return failures_; }
    bool Paused() const { return failures_ >= MaximumFailures; }

    // A burst or one late output does not prove recovery. Require five seconds
    // of successful rendering with no gap longer than one second.
    bool OnRendered(int64_t nowMs) {
        if (Paused() || failures_ == 0) return false;
        if (!healthy_ || nowMs < lastRendered_ || nowMs - lastRendered_ > MaximumRenderGapMs) {
            healthy_ = true;
            healthySince_ = lastRendered_ = nowMs;
            return false;
        }
        lastRendered_ = nowMs;
        if (nowMs - healthySince_ < HealthyDurationMs) return false;
        failures_ = 0;
        OnDiscontinuity();
        return true;
    }

    void OnDiscontinuity() {
        healthy_ = false;
        healthySince_ = lastRendered_ = 0;
    }

private:
    static constexpr unsigned MaximumFailures = 3;
    static constexpr int64_t HealthyDurationMs = 5000;
    static constexpr int64_t MaximumRenderGapMs = 1000;
    unsigned failures_ = 0;
    bool healthy_ = false;
    int64_t healthySince_ = 0, lastRendered_ = 0;
};
} // namespace neo
