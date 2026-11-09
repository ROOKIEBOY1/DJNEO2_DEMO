#include "../../entry/src/main/cpp/VideoRecovery.h"

// Exit codes identify assertions without a host C++ runtime. The same header is
// used by the native preview; these tests do not model the policy in JavaScript.
int main()
{
    neo::VideoRecovery separated;
    if (separated.Failures() != 0 || separated.Paused()) return 1;
    for (int cycle = 0; cycle < 3; ++cycle) {
        if (separated.Failed() || separated.Failures() != 1) return 2;
        const int64_t start = cycle * 20000;
        for (int sample = 0; sample < 5; ++sample)
            if (separated.OnRendered(start + sample * 1000)) return 3;
        if (separated.Failures() != 1 || separated.Paused()) return 4;
        if (!separated.OnRendered(start + 5000) || separated.Failures() != 0 || separated.Paused()) return 5;
    }
    if (separated.Failed() || separated.Failures() != 1) return 6;

    neo::VideoRecovery consecutive;
    if (consecutive.Failed() || consecutive.Failed() || !consecutive.Failed()) return 7;
    if (!consecutive.Paused() || consecutive.Failures() != 3) return 8;
    // Late outputs from the retired codec cannot lift an exhausted budget.
    for (int sample = 0; sample <= 10; ++sample)
        if (consecutive.OnRendered(sample * 1000)) return 9;
    consecutive.OnDiscontinuity();
    if (!consecutive.Paused() || consecutive.Failures() != 3 || !consecutive.Failed()) return 10;

    neo::VideoRecovery shortRecovery;
    shortRecovery.Failed();
    if (shortRecovery.OnRendered(0) || shortRecovery.Failures() != 1) return 11;
    if (shortRecovery.Failed() || shortRecovery.Failures() != 2) return 12;
    for (int sample = 0; sample < 5; ++sample)
        if (shortRecovery.OnRendered(10000 + sample * 1000)) return 13;
    if (shortRecovery.OnRendered(14999) || shortRecovery.Failures() != 2) return 14;
    if (!shortRecovery.Failed() || !shortRecovery.Paused()) return 15;

    neo::VideoRecovery exactBoundary;
    exactBoundary.Failed();
    for (int sample = 0; sample < 5; ++sample)
        if (exactBoundary.OnRendered(sample * 1000)) return 16;
    if (exactBoundary.OnRendered(4999) || !exactBoundary.OnRendered(5000)) return 17;
    if (exactBoundary.Failures() != 0 || exactBoundary.Paused()) return 18;

    neo::VideoRecovery silence;
    silence.Failed();
    for (int sample = 0; sample <= 4; ++sample)
        if (silence.OnRendered(sample * 1000)) return 19;
    // A single frame after a long silence must start a new healthy window.
    if (silence.OnRendered(10000) || silence.Failures() != 1) return 20;
    for (int sample = 1; sample < 5; ++sample)
        if (silence.OnRendered(10000 + sample * 1000)) return 21;
    if (!silence.OnRendered(15000) || silence.Failures() != 0) return 22;

    neo::VideoRecovery overBoundary;
    overBoundary.Failed();
    for (int sample = 0; sample <= 4; ++sample)
        if (overBoundary.OnRendered(sample * 1000)) return 23;
    if (overBoundary.OnRendered(5001) || overBoundary.Failures() != 1) return 24;
    for (int sample = 1; sample < 5; ++sample)
        if (overBoundary.OnRendered(5001 + sample * 1000)) return 25;
    if (!overBoundary.OnRendered(10001)) return 26;

    neo::VideoRecovery discontinuity;
    discontinuity.Failed();
    for (int sample = 0; sample <= 4; ++sample)
        if (discontinuity.OnRendered(sample * 1000)) return 27;
    discontinuity.OnDiscontinuity();
    if (discontinuity.Failures() != 1 || discontinuity.OnRendered(5000)) return 28;
    for (int sample = 1; sample < 5; ++sample)
        if (discontinuity.OnRendered(5000 + sample * 1000)) return 29;
    if (!discontinuity.OnRendered(10000)) return 30;

    neo::VideoRecovery rollback;
    rollback.Failed();
    for (int sample = 0; sample <= 4; ++sample)
        if (rollback.OnRendered(10000 + sample * 1000)) return 31;
    if (rollback.OnRendered(1000) || rollback.Failures() != 1) return 32;
    for (int sample = 1; sample < 5; ++sample)
        if (rollback.OnRendered(1000 + sample * 1000)) return 33;
    if (!rollback.OnRendered(6000)) return 34;

    // Rendering before a fault does not pre-pay the next recovery window.
    neo::VideoRecovery priorHealthy;
    for (int sample = 0; sample <= 10; ++sample)
        if (priorHealthy.OnRendered(sample * 1000)) return 35;
    priorHealthy.Failed();
    if (priorHealthy.OnRendered(11000) || priorHealthy.Failures() != 1) return 36;
    return 0;
}
