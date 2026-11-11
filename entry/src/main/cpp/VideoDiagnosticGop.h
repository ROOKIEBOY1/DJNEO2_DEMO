#pragma once
#include <stddef.h>

namespace neo {
// A diagnostic segment contains exactly the successfully submitted bytes from
// one IRAP onward. Configuration required for replay is separate metadata.
template<class Bytes> class VideoDiagnosticGop {
public:
    explicit VideoDiagnosticGop(size_t maximumBytes = 8 * 1024 * 1024) : maximumBytes_(maximumBytes) {}
    void Record(const Bytes &unit, bool randomAccess) {
        if (randomAccess) {
            Reset();
            started_ = true;
            // Reserving the fixed ceiling prevents vector growth from allocating
            // more than the requested diagnostic memory budget.
            bytes_.reserve(maximumBytes_);
        }
        if (!started_) return;
        ++frames_;
        inputBytes_ += unit.size();
        if (overflowed_) return;
        if (unit.size() > maximumBytes_ - bytes_.size()) {
            bytes_.clear();
            overflowed_ = true;
            return;
        }
        bytes_.insert(bytes_.end(), unit.begin(), unit.end());
    }
    void Reset() {
        bytes_.clear();
        started_ = overflowed_ = false;
        frames_ = inputBytes_ = 0;
    }
    const Bytes &Data() const { return bytes_; }
    bool Started() const { return started_; }
    bool Complete() const { return started_ && !overflowed_ && !bytes_.empty(); }
    bool Overflowed() const { return overflowed_; }
    size_t Frames() const { return frames_; }
    size_t InputBytes() const { return inputBytes_; }
    unsigned NextSlot() { const auto slot = nextSlot_; nextSlot_ ^= 1; return slot; }
    void SetNextSlot(unsigned slot) { nextSlot_ = slot & 1; }

private:
    Bytes bytes_;
    size_t maximumBytes_, frames_ = 0, inputBytes_ = 0;
    unsigned nextSlot_ = 0;
    bool started_ = false, overflowed_ = false;
};
} // namespace neo
