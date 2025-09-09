#import "ImageAligner.h"
#import "logging.h"
#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/features2d.hpp>
#import <opencv2/calib3d.hpp>
#include <iostream>

@implementation ImageAligner

#include <opencv2/opencv.hpp>
#include <iostream>


/*
  This ImageAligner replaces hugin's align_image_stack with in-process usage of opencv2
  it's faster and better at detecting stars using SIFT.

  However, it's still not good at detecting detail in the ground, especially when it's dark.
  tried flipping the image, and boosting contrast, but so far, no dice.
  returns the original image when there are not enough found control points.
 */

cv::Mat preprocessMaskForSIFT_BLUR(const cv::Mat& mask) {
    cv::Mat grayMask;

    if (mask.channels() > 1)
        cv::cvtColor(mask, grayMask, cv::COLOR_BGR2GRAY);
    else
        grayMask = mask.clone();

    if (grayMask.type() != CV_8UC1)
        grayMask.convertTo(grayMask, CV_8UC1);

    // Turn sharp edges into smooth gradients
    cv::GaussianBlur(grayMask, grayMask, cv::Size(9, 9), 2);

    return grayMask;
}


cv::Mat preprocessMaskForSIFT_LAPACIAN(const cv::Mat& mask) {
    cv::Mat grayMask, grad;

    // Ensure grayscale
    if (mask.channels() > 1)
        cv::cvtColor(mask, grayMask, cv::COLOR_BGR2GRAY);
    else
        grayMask = mask.clone();

    // Convert to 8-bit
    if (grayMask.type() != CV_8UC1)
        grayMask.convertTo(grayMask, CV_8UC1);

    // Slight blur for stability
    cv::GaussianBlur(grayMask, grayMask, cv::Size(3, 3), 0);

    // Laplacian to get edges but with gradient info
    cv::Laplacian(grayMask, grad, CV_8U, 3);

    return grad;
}

cv::Mat preprocessMaskForSIFT(const cv::Mat& mask) {
    cv::Mat grayMask, edges;

    // Ensure grayscale
    if (mask.channels() > 1) {
        cv::cvtColor(mask, grayMask, cv::COLOR_BGR2GRAY);
    } else {
        grayMask = mask.clone();
    }

    // Ensure it's 8-bit
    if (grayMask.type() != CV_8UC1) {
        grayMask.convertTo(grayMask, CV_8UC1);
    }

    // Edge detection to give SIFT something to latch onto
    //cv::Canny(grayMask, edges, 50, 150);

    return createGradientMaskIntoSky(grayMask, 100); // XXX guess on tradient distance
    //return grayMask;
}

// gradients into the zero area of the mask
cv::Mat createGradientMask(const cv::Mat &binaryMask, int gradientDistance) {
    CV_Assert(binaryMask.type() == CV_8UC1); // Must be single-channel 8-bit
    
    // Step 1: Invert binary mask (so ground=255, sky=0)
    cv::Mat inverted;
    cv::bitwise_not(binaryMask, inverted);

    // Step 2: Find edges using Canny or morphological gradient
    cv::Mat edges;
    cv::Canny(inverted, edges, 50, 150);

    // Step 3: Distance transform on inverted mask
    cv::Mat dist;
    cv::distanceTransform(inverted, dist, cv::DIST_L2, 3);

    // Step 4: Normalize distances to 0..255 based on gradientDistance
    cv::Mat distNormalized;
    dist.convertTo(distNormalized, CV_32F);
    distNormalized = cv::min(distNormalized, (float)gradientDistance);
    distNormalized = 1.0f - (distNormalized / (float)gradientDistance);
    distNormalized *= 255.0f;

    // Step 5: Create gradient mask
    cv::Mat gradientMask;
    distNormalized.convertTo(gradientMask, CV_8UC1);

    // Step 6: Keep original sky pixels at 255
    cv::Mat output = cv::max(binaryMask, gradientMask);

    return output;
}

// gradients into the non-zero area of the sky
cv::Mat createGradientMaskIntoSky(const cv::Mat &binaryMask, int gradientDistance) {
    CV_Assert(binaryMask.type() == CV_8UC1); // Must be single-channel 8-bit
    
    // Step 1: Distance transform on sky (non-zero) region
    cv::Mat skyMask;
    cv::threshold(binaryMask, skyMask, 1, 255, cv::THRESH_BINARY); // Ensure binary
    
    // Invert so sky becomes 255, ground becomes 0
    cv::Mat inverted;
    cv::bitwise_not(skyMask, inverted);

    // Distance transform on skyMask (we want distance into sky)
    cv::Mat dist;
    cv::distanceTransform(skyMask, dist, cv::DIST_L2, 3);

    // Step 2: Normalize distances to 0..255 based on gradientDistance
    cv::Mat distNormalized;
    dist.convertTo(distNormalized, CV_32F);
    distNormalized = cv::min(distNormalized, (float)gradientDistance);
    distNormalized = distNormalized / (float)gradientDistance;  // 0 near edge, 1 far inside sky
    distNormalized *= 255.0f;

    // Step 3: Create gradient mask
    cv::Mat gradientMask;
    distNormalized.convertTo(gradientMask, CV_8UC1);

    // Step 4: Keep original ground pixels black, merge gradient into sky
    cv::Mat output = cv::min(binaryMask, gradientMask);

    return output;
}


void printMatInfo(const cv::Mat& mat, const std::string& name = "") {
    if (!name.empty()) {
        std::cout << "Mat '" << name << "':\n";
    } else {
        std::cout << "Mat info:\n";
    }

    std::cout << "  Size: " << mat.cols << " x " << mat.rows << "\n";

    int depth = mat.depth();
    int bitsPerComponent = 0;
    switch (depth) {
        case CV_8U: case CV_8S: bitsPerComponent = 8; break;
        case CV_16U: case CV_16S: bitsPerComponent = 16; break;
        case CV_32S: case CV_32F: bitsPerComponent = 32; break;
        case CV_64F: bitsPerComponent = 64; break;
        default: bitsPerComponent = 0; break;
    }

    int channels = mat.channels();
    std::cout << "  Bits per component: " << bitsPerComponent << "\n";
    std::cout << "  Components per pixel: " << channels << "\n";
    std::cout << "  Total depth (bits per pixel): " << bitsPerComponent * channels << "\n";

    // Guess alpha information
    if (channels == 4) {
        std::cout << "  Alpha channel: Present (assumed)\n";
        std::cout << "  Channel order: Likely BGRA (OpenCV default)\n";
        std::cout << "  Premultiplied alpha: Unknown (must track separately)\n";
    } else if (channels == 3) {
        std::cout << "  Alpha channel: None (RGB/BGR)\n";
    } else if (channels == 1) {
        std::cout << "  Alpha channel: None (Grayscale)\n";
    } else {
        std::cout << "  Alpha channel: Unknown (non-standard channel count)\n";
    }
}

// Convert image to 8-bit grayscale, normalize only within mask area
cv::Mat toGray8UWithMask(const cv::Mat& src, const cv::Mat& mask, bool normalize = true) {
    if (src.empty()) {
        throw std::runtime_error("Input image is empty!");
    }

    cv::Mat gray;
    if (src.channels() > 1) {
      cv::cvtColor(src, gray, cv::COLOR_BGR2GRAY);
    } else {
      gray = src.clone();
    }

    cv::Mat tmp;

    // If normalization is requested and a valid mask is provided
    if (normalize && !mask.empty() && mask.type() == CV_8U) {
        double minVal, maxVal;
	//printMatInfo(mask, "mask");
        cv::minMaxLoc(gray, &minVal, &maxVal, nullptr, nullptr, mask);


        // Avoid divide-by-zero
        double scale = (maxVal > minVal) ? 255.0 / (maxVal - minVal) : 1.0;
        double shift = -minVal * scale;

        // Apply scaling
        gray.convertTo(tmp, CV_8U, scale, shift);
	
    } else {
        // Fall back to existing conversion logic
        if (gray.depth() == CV_16U) {
            gray.convertTo(tmp, CV_8U, 1.0 / 256.0);
        } else if (gray.depth() != CV_8U) {
            double minVal, maxVal;
            cv::minMaxLoc(gray, &minVal, &maxVal);
            double scale = (maxVal > 0) ? 255.0 / maxVal : 1.0;
            gray.convertTo(tmp, CV_8U, scale);
        } else {
            tmp = gray.clone();
        }
    }

    // Convert to grayscale if needed
    if (tmp.channels() > 1) {
        cv::cvtColor(tmp, tmp, cv::COLOR_BGR2GRAY);
    }

    return tmp;
}

// Convert any depth image to 8-bit grayscale for SIFT
cv::Mat toGray8U(const cv::Mat& src) {
    if (src.empty()) {
        throw std::runtime_error("Input image is empty!");
    }

    cv::Mat tmp;
    // Handle 16-bit
    if (src.depth() == CV_16U) {
        src.convertTo(tmp, CV_8U, 1.0 / 256.0);
    }
    // Handle 32-bit float/int
    else if (src.depth() != CV_8U) {
        double minVal, maxVal;
        cv::minMaxLoc(src, &minVal, &maxVal);
        double scale = maxVal > 0 ? 255.0 / maxVal : 1.0;
        src.convertTo(tmp, CV_8U, scale);
    }
    else {
        tmp = src.clone();
    }

    // Convert to grayscale if needed
    if (tmp.channels() > 1) {
        cv::cvtColor(tmp, tmp, cv::COLOR_BGR2GRAY);
    }

    return tmp;
}

+(Mat)createGradientMaskIntoSky:(Mat)binaryMask
	       gradientDistance:(int)gradientDistance
{
  cv::Mat &mat = *(cv::Mat *)binaryMask;

  cv::Mat result = createGradientMaskIntoSky(mat, gradientDistance);

  cv::Mat* resultPtr = new cv::Mat(result);

  return resultPtr;
}

+(Mat)createGradientMaskIntoGround:(Mat)binaryMask
		  gradientDistance:(int)gradientDistance
{
  cv::Mat &mat = *(cv::Mat *)binaryMask;

  cv::Mat result = createGradientMask(mat, gradientDistance);

  cv::Mat* resultPtr = new cv::Mat(result);

  return resultPtr;
}

+ (id)alignFrames:(Mat)special
           frames:(NSArray<NSValue *> *)frames
             mask:(Mat)mask
     maxDeviation:(double)maxDeviation
       invertMask:(BOOL)invertMask
 invertBrightness:(BOOL)invertBrightness
     maxKeypoints:(int)maxKeypoints
{
    try {
        cv::Mat &specialMat = *(cv::Mat *)special;

        // Use mask or full white if none provided
        cv::Mat maskMat;
        if (mask != NULL && !(*(cv::Mat *)mask).empty()) {
            maskMat = *(cv::Mat *)mask;
        } else {
            maskMat = cv::Mat(specialMat.size(), CV_8U, cv::Scalar(255));
        }

        if (invertMask) {
            cv::bitwise_not(maskMat, maskMat);
        }

        if (invertBrightness) {
            cv::bitwise_not(specialMat, specialMat);
        }

        // Prepare special image for SIFT
        cv::Mat specialGray = toGray8UWithMask(specialMat, maskMat, true);

        // Detector & matcher (thread-safe because SIFT::create() returns a new instance)
        cv::Ptr<cv::SIFT> detector = cv::SIFT::create(maxKeypoints);
	//cv::Ptr<cv::Feature2D> detector = cv::ORB::create(2000); // more keypoints
        std::vector<cv::KeyPoint> kpSpecial;
        cv::Mat descSpecial;
        detector->detectAndCompute(specialGray, maskMat, kpSpecial, descSpecial);
	//cv::BFMatcher matcher(cv::NORM_HAMMING); // for ORB
        cv::BFMatcher matcher(cv::NORM_L2); // for SIFT

        NSMutableArray *aligned = [NSMutableArray arrayWithCapacity:frames.count];
        dispatch_group_t group = dispatch_group_create();
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

        // Pre-allocate result array with NSNull
        for (NSUInteger i = 0; i < frames.count; i++) {
            [aligned addObject:[NSNull null]];
        }

        // Parallelize frame processing
        [frames enumerateObjectsUsingBlock:^(NSValue *val, NSUInteger idx, BOOL *stop) {
            dispatch_group_async(group, queue, ^{
                try {
                    cv::Mat &frame = *(cv::Mat *)val.pointerValue;

                    if (invertBrightness) {
                        cv::bitwise_not(frame, frame);
                    }

                    // Convert frame to grayscale for SIFT
                    cv::Mat frameGray = toGray8UWithMask(frame, maskMat, true);
                    std::vector<cv::KeyPoint> kpFrame;
                    cv::Mat descFrame;
                    detector->detectAndCompute(frameGray, maskMat, kpFrame, descFrame);

                    std::vector<cv::DMatch> matches;
                    matcher.match(descFrame, descSpecial, matches);

                    double minDist = std::numeric_limits<double>::max();
                    for (auto &m : matches) {
                        minDist = std::min(minDist, (double)m.distance);
                    }
                    double cutoff = std::max(2 * minDist, 30.0);

                    std::vector<cv::Point2f> ptsFrame, ptsSpecial;
                    for (auto &m : matches) {
                        if (m.distance <= cutoff) {
                            ptsFrame.push_back(kpFrame[m.queryIdx].pt);
                            ptsSpecial.push_back(kpSpecial[m.trainIdx].pt);
                        }
                    }

                    cv::Mat warped;
                    if (ptsFrame.size() >= 4) {
                        cv::Mat H = cv::findHomography(ptsFrame, ptsSpecial, cv::RANSAC, 10);
                        if (!H.empty() && H.type() != CV_32F && H.type() != CV_64F) {
                            H.convertTo(H, CV_64F);
                        }

                        if (H.empty() || H.rows != 3 || H.cols != 3) {
			    // Fallback, couldn't warp
                            warped = frame.clone();
                        } else {
			  
                            // Compute deviation from identity
                            cv::Mat I = cv::Mat::eye(3, 3, H.type());
                            double deviation = cv::norm(H - I, cv::NORM_L2);
			    /*
			      need to fild other kinds of devation to also check.
			      the above one does help a lot, but for some yet unknown
			      reason, a numbe of frames still slip through with some
			      really poorly aligned neibhors.

			      XXX HERE XXX
			    */

			    // Compute corner reprojection error
			    std::vector<cv::Point2f> corners = {
			      cv::Point2f(0, 0),
			      cv::Point2f((float)frame.cols, 0),
			      cv::Point2f((float)frame.cols, (float)frame.rows),
			      cv::Point2f(0, (float)frame.rows)
			    };

			    std::vector<cv::Point2f> projectedCorners;
			    cv::perspectiveTransform(corners, projectedCorners, H);

			    double maxCornerDist = 0.0;
			    for (size_t i = 0; i < corners.size(); i++) {
			      double dist = cv::norm(projectedCorners[i] - corners[i]);
			      maxCornerDist = std::max(maxCornerDist, dist);
			    }

			    // Combined decision
			    bool acceptWarp = (deviation < maxDeviation) && (maxCornerDist < maxDeviation * 5.0);

			    if(acceptWarp) {
			      Log_i(@"acceptWarp TRUE = (%f < %f) && (%f < %f)", deviation, maxDeviation, maxCornerDist, maxDeviation * 5.0);
			    } else {
			      Log_w(@"acceptWarp FALSE = (%f < %f) && (%f < %f)", deviation, maxDeviation, maxCornerDist, maxDeviation * 5.0);
			    }
			    if(acceptWarp) {
                                // only warp if less than max deviation
                                cv::warpPerspective(frame, warped, H, specialMat.size(),
						    cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(0,0,0,0));
			    } else {
			      // XXX need to log these failures so the GUI can show them
			      // XXX need objc => swift logging bridge somehow
                                warped = frame.clone();
			    }
                        }
                    } else {
		        // Fallback, couldn't warp because not enough keypoints
                        warped = frame.clone();
                    }

		    if (invertBrightness) cv::bitwise_not(warped, warped);
		    
                    cv::Mat output;
                    if (warped.channels() == 4) {
                        cv::cvtColor(warped, output, cv::COLOR_BGRA2BGR);
                    } else {
                        output = warped;
                    }

                    cv::Mat *result = new cv::Mat(output);
                    @synchronized (aligned) {
		        aligned[idx] = [NSValue valueWithPointer:result];
                    }
                } catch (...) {
                    @synchronized (aligned) {
                        aligned[idx] = [NSValue valueWithPointer:nullptr];
                    }
                }
            });
        }];

        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        return aligned;

    } catch (const cv::Exception &e) {
        return [NSString stringWithUTF8String:e.what()];
    } catch (const std::exception &e) {
        return [NSString stringWithUTF8String:e.what()];
    } catch (...) {
        return @"Unknown Exception";
    }
}

// aligns frames by finding keypoints on their horizon masks,
// instead of on the frames themselves
+ (id)alignFramesByMask:(Mat)mask
		   base:(Mat)special
		 frames:(NSArray<NSValue *> *)frames
	     frameMasks:(NSArray<NSValue *> *)frameMasks
	   maxKeypoints:(int)maxKeypoints;
{
    try {
        cv::Mat &specialMat = *(cv::Mat *)special;

        // Use mask or full white if none provided
        cv::Mat maskMat = *(cv::Mat *)mask;

        // Detector & matcher (thread-safe because SIFT::create() returns a new instance)
        cv::Ptr<cv::SIFT> detector = cv::SIFT::create(maxKeypoints);
        std::vector<cv::KeyPoint> kpSpecial;
        cv::Mat descSpecial;

	cv::Mat emptyMat;
	
        // Prepare special image for SIFT
	cv::Mat specialMaskProcessed = preprocessMaskForSIFT(maskMat);
  
	printMatInfo(specialMaskProcessed, "specialMaskProcessed");
	// detect on mask, not special base image
        detector->detectAndCompute(specialMaskProcessed, emptyMat, kpSpecial, descSpecial);
        cv::BFMatcher matcher(cv::NORM_L2);

        NSMutableArray *aligned = [NSMutableArray arrayWithCapacity:frames.count];
        dispatch_group_t group = dispatch_group_create();
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

        // Pre-allocate result array with NSNull
        for (NSUInteger i = 0; i < frames.count; i++) {
            [aligned addObject:[NSNull null]];
        }

        // Parallelize frame processing
        [frames enumerateObjectsUsingBlock:^(NSValue *val, NSUInteger idx, BOOL *stop) {
            dispatch_group_async(group, queue, ^{
                try {
                    cv::Mat &frame = *(cv::Mat *)val.pointerValue;
                    cv::Mat &frameMask = *(cv::Mat *)frameMasks[idx].pointerValue;

                    std::vector<cv::KeyPoint> kpFrame;
                    cv::Mat descFrame;

		    // Prepare special image for SIFT
		    cv::Mat frameMaskProcessed = preprocessMaskForSIFT(frameMask);
		    cv::imwrite("/tmp/frameMaskProcessed.png", frameMaskProcessed);
		    printMatInfo(frameMaskProcessed, "frameMaskProcessed");
                    detector->detectAndCompute(frameMaskProcessed, emptyMat, kpFrame, descFrame);

                    std::vector<cv::DMatch> matches;
                    matcher.match(descFrame, descSpecial, matches);

                    double minDist = std::numeric_limits<double>::max();
                    for (auto &m : matches) {
                        minDist = std::min(minDist, (double)m.distance);
                    }
                    double cutoff = std::max(2 * minDist, 30.0);

                    std::vector<cv::Point2f> ptsFrame, ptsSpecial;
                    for (auto &m : matches) {
                        if (m.distance <= cutoff) {
                            ptsFrame.push_back(kpFrame[m.queryIdx].pt);
                            ptsSpecial.push_back(kpSpecial[m.trainIdx].pt);
                        }
                    }

                    cv::Mat warped;
                    if (ptsFrame.size() >= 4) {
                        cv::Mat H = cv::findHomography(ptsFrame, ptsSpecial, cv::RANSAC);
                        if (!H.empty() && H.type() != CV_32F && H.type() != CV_64F) {
                            H.convertTo(H, CV_64F);
                        }

                        if (H.empty()) {
			    // Fallback, couldn't warp
                            warped = frame.clone();
                            Log_i(@"not warping because H is empty");
			} else if(H.rows != 3) {
			    // Fallback, couldn't warp
                            warped = frame.clone();
                            Log_i(@"not warping because H.rows %d != 3", H.rows);
			} else if(H.cols != 3) {
			    // Fallback, couldn't warp
                            warped = frame.clone();
                            Log_i(@"not warping because H.cols %d != 3", H.cols);
                        } else {
			  Log_i(@"warping");
                            cv::warpPerspective(frame, warped, H, specialMat.size(),
                                                cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(0,0,0,0));
                        }
                    } else {
		        // Fallback, couldn't warp because not enough keypoints
		        Log_d(@"NOT WARPING 4");
                        warped = frame.clone();
                    }

                    cv::Mat output;
                    if (warped.channels() == 4) {
                        cv::cvtColor(warped, output, cv::COLOR_BGRA2BGR);
                    } else {
                        output = warped;
                    }

                    cv::Mat *result = new cv::Mat(output);
                    @synchronized (aligned) {
                        aligned[idx] = [NSValue valueWithPointer:result];
                    }
                } catch (...) {
                    @synchronized (aligned) {
                        aligned[idx] = [NSValue valueWithPointer:nullptr];
                    }
                }
            });
        }];

        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        return aligned;

    } catch (const cv::Exception &e) {
        return [NSString stringWithUTF8String:e.what()];
    } catch (const std::exception &e) {
        return [NSString stringWithUTF8String:e.what()];
    } catch (...) {
        return @"Unknown Exception";
    }
}

@end
/*

  XXX code to do best match on multiple aligned images in opencv2


  How to Enable OpenMP on macOS
  
Apple Clang doesn’t ship OpenMP by default. Install libomp:

  brew install libomp

Then update your Xcode build flags (in Build Settings → Other C++ Flags):

  -fopenmp -I/usr/local/include -L/usr/local/lib -lomp

This gives you real multithreading with very little overhead.

  
// ImageAligner.mm
#import "ImageAligner.h"
#import <vector>
#import <cmath>
#import <algorithm>
#ifdef _OPENMP
#include <omp.h>
#endif

@implementation ImageAligner

+ (cv::Mat)buildAlignedFrameFromImages:(NSArray<NSValue *> *)images
                          thresholdK:(double)k
{
    if (images.count == 0) {
        throw std::runtime_error("No images passed");
    }

    // Convert NSArray<NSValue> to std::vector<cv::Mat>
    std::vector<cv::Mat> mats;
    mats.reserve(images.count);
    for (NSValue *val in images) {
        const cv::Mat *matPtr = (const cv::Mat *)val.pointerValue;
        mats.push_back(*matPtr);
    }

    const int nFrames = (int)mats.size();
    const int width = mats[0].cols;
    const int height = mats[0].rows;
    const int channels = mats[0].channels();
    CV_Assert(channels == 3 || channels == 4);

    // Validate all mats are the same size/type
    int type = mats[0].type();
    for (const auto &m : mats) {
        CV_Assert(m.type() == type);
        CV_Assert(m.cols == width && m.rows == height);
    }

    // Prepare output Mat
    cv::Mat out(height, width, type, cv::Scalar(0));
    CV_Assert(CV_MAT_DEPTH(type) == CV_16U);

    // Parallelize over rows
    #pragma omp parallel for schedule(dynamic)
    for (int y = 0; y < height; y++) {
        std::vector<double> intensities(nFrames);

        const uint16_t *srcPtrs[nFrames];
        for (int i = 0; i < nFrames; i++) {
            srcPtrs[i] = mats[i].ptr<uint16_t>(y);
        }
        uint16_t *dst = out.ptr<uint16_t>(y);

        for (int x = 0; x < width; x++) {
            // 1) Compute intensity and mean
            double sum = 0.0;
            for (int i = 0; i < nFrames; i++) {
                const uint16_t *pix = srcPtrs[i] + x * channels;
                double I = pix[0] + pix[1] + pix[2];
                intensities[i] = I;
                sum += I;
            }
            double mean = sum / nFrames;

            // 2) Compute stddev
            double varSum = 0.0;
            for (double v : intensities) {
                double d = v - mean;
                varSum += d * d;
            }
            double stddev = sqrt(varSum / nFrames);
            double threshold = mean + k * stddev;

            // 3) Merge good frames
            double acc[4] = {0, 0, 0, 0};
            double countGood = 0.0;

            if (channels == 3) {
                for (int i = 0; i < nFrames; i++) {
                    if (intensities[i] <= threshold) {
                        const uint16_t *pix = srcPtrs[i] + x * channels;
                        acc[0] += pix[0];
                        acc[1] += pix[1];
                        acc[2] += pix[2];
                        countGood += 1.0;
                    }
                }
                if (countGood > 0) {
                    dst[x * channels + 0] = (uint16_t)(acc[0] / countGood);
                    dst[x * channels + 1] = (uint16_t)(acc[1] / countGood);
                    dst[x * channels + 2] = (uint16_t)(acc[2] / countGood);
                }
            } else { // RGBA
                for (int i = 0; i < nFrames; i++) {
                    if (intensities[i] <= threshold) {
                        const uint16_t *pix = srcPtrs[i] + x * channels;
                        double a = pix[3];
                        double w = a / 65535.0;
                        acc[0] += pix[0] * w;
                        acc[1] += pix[1] * w;
                        acc[2] += pix[2] * w;
                        acc[3] += a;
                        countGood += 1.0;
                    }
                }
                if (countGood > 0) {
                    dst[x * channels + 0] = (uint16_t)(acc[0] / countGood);
                    dst[x * channels + 1] = (uint16_t)(acc[1] / countGood);
                    dst[x * channels + 2] = (uint16_t)(acc[2] / countGood);
                    dst[x * channels + 3] = (uint16_t)(acc[3] / countGood);
                }
            }
        }
    }

    return out;
}

@end
*/
