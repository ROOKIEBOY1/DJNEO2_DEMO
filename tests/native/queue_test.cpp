#include "FrameQueue.h"
#include <cassert>
#include <iostream>
int main() {
    neo::FrameQueue queue(2, 5, 4);
    assert(queue.Push({1, 2}) == neo::QueueResult::Accepted);
    assert(queue.Push({3, 4}) == neo::QueueResult::Accepted);
    assert(queue.Push({5}) == neo::QueueResult::Discontinuity);
    assert(queue.Size() == 1 && queue.Bytes() == 1);
    assert(queue.Dropped() == 2);
    assert(queue.Pop() == std::vector<uint8_t>({5}));
    assert(queue.Push({1,2,3,4,5}) == neo::QueueResult::Rejected);
    assert(queue.Size() == 0);
    queue.Push({1,2,3,4});
    assert(queue.Push({1,2}) == neo::QueueResult::Discontinuity);
    assert(queue.Bytes() == 2);
    queue.Clear(); assert(queue.Size() == 0 && queue.Bytes() == 0);
    std::cout << "Frame queue tests passed\n";
}
