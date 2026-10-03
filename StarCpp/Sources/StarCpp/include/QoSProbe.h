// QoSProbe.h — debug entry point for verifying the OpenCV QoS patch
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Runs a cv::parallel_for_ of `stripes` bodies and counts the QoS class each body ran at.
// counts must have room for 6 ints: user-interactive, user-initiated, default, utility,
// background, unspecified. Returns the number of bodies run, or 0 where QoS classes do not
// exist (anything but Apple platforms).
//
// opencv/build.sh patches the GCD branch of cv::parallel_for_ to DISPATCH_APPLY_AUTO so its
// workers inherit the calling thread's QoS; without the patch they all run at "default"
// whatever the caller's QoS is. The test calls this from .utility and .background threads.
int star_debug_parallel_qos(int stripes, int *counts);

#ifdef __cplusplus
}
#endif
