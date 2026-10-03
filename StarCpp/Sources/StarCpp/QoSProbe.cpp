// QoSProbe.cpp — see QoSProbe.h
#include "QoSProbe.h"

#include <opencv2/core.hpp>

#include <atomic>
#include <chrono>
#include <thread>

#if defined(__APPLE__)
#include <pthread/qos.h>
#endif

int star_debug_parallel_qos(int stripes, int *counts) {
#if defined(__APPLE__)
    if (!counts || stripes <= 0) return 0;
    std::atomic<int> tally[6];
    for (auto &t : tally) t.store(0);

    cv::parallel_for_(cv::Range(0, stripes), [&](const cv::Range &range) {
        for (int i = range.start; i < range.end; ++i) {
            // long enough that GCD brings in its workers rather than the caller doing all of it
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            int slot;
            switch (qos_class_self()) {
                case QOS_CLASS_USER_INTERACTIVE: slot = 0; break;
                case QOS_CLASS_USER_INITIATED:   slot = 1; break;
                case QOS_CLASS_DEFAULT:          slot = 2; break;
                case QOS_CLASS_UTILITY:          slot = 3; break;
                case QOS_CLASS_BACKGROUND:       slot = 4; break;
                default:                         slot = 5; break;
            }
            tally[slot].fetch_add(1);
        }
    }, stripes);

    int total = 0;
    for (int i = 0; i < 6; ++i) { counts[i] = tally[i].load(); total += counts[i]; }
    return total;
#else
    (void)stripes; (void)counts;
    return 0;
#endif
}
