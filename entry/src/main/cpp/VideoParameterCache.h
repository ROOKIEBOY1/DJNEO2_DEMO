#pragma once

namespace neo {
enum class VideoResetScope { Decoder, Stream };

// Configuration belongs to one transport stream, independently of codec
// references. Byte storage is the same vector used by the HEVC parser.
template <class Bytes> class VideoParameterCache {
public:
    const Bytes &operator[](unsigned index) const { return values_[index]; }
    bool Update(unsigned index, const Bytes &value) {
        const bool changed = !values_[index].empty() && values_[index] != value;
        values_[index] = value;
        return changed;
    }
    unsigned Mask() const {
        return (!values_[0].empty() ? 1u : 0u) | (!values_[1].empty() ? 2u : 0u) |
            (!values_[2].empty() ? 4u : 0u);
    }
    bool CanStart(bool randomAccess, int width, int height) const {
        return randomAccess && Mask() == 7 && width > 0 && height > 0 && width <= 8192 && height <= 8192;
    }
    void Reset(VideoResetScope scope) {
        if (scope == VideoResetScope::Decoder) return;
        for (auto &value : values_) value = {};
    }

private:
    Bytes values_[3];
};
} // namespace neo
