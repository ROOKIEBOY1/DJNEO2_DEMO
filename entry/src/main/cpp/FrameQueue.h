#pragma once
#include <cstdint>
#include <deque>
#include <utility>
#include <vector>
namespace neo {
enum class QueueResult { Accepted, Discontinuity, Rejected };
// External synchronization: the preview mutex covers every operation.
class FrameQueue {
public:
    explicit FrameQueue(size_t count = 16, size_t bytes = 8 * 1024 * 1024, size_t frame = 2 * 1024 * 1024)
        : maxCount_(count), maxBytes_(bytes), maxFrame_(frame) {}
    QueueResult Push(std::vector<uint8_t> value) {
        if (value.empty() || value.size() > maxFrame_ || value.size() > maxBytes_) {
            ++dropped_; return QueueResult::Rejected;
        }
        bool overflow = queue_.size() >= maxCount_ || bytes_ + value.size() > maxBytes_;
        if (overflow) { dropped_ += queue_.size(); Clear(); }
        bytes_ += value.size(); queue_.push_back(std::move(value));
        return overflow ? QueueResult::Discontinuity : QueueResult::Accepted;
    }
    std::vector<uint8_t> Pop() {
        auto value = std::move(queue_.front()); queue_.pop_front(); bytes_ -= value.size(); return value;
    }
    void Clear() { queue_.clear(); bytes_ = 0; }
    size_t Size() const { return queue_.size(); }
    size_t Bytes() const { return bytes_; }
    uint64_t Dropped() const { return dropped_; }
private:
    size_t maxCount_, maxBytes_, maxFrame_, bytes_ = 0;
    uint64_t dropped_ = 0;
    std::deque<std::vector<uint8_t>> queue_;
};
}
