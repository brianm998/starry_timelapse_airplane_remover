#import "ImageAligner.h"
#import "logging.h"
#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/features2d.hpp>
#import <opencv2/calib3d.hpp>
#include <iostream>


@implementation AlignmentResult
@end


@implementation ImageAligner

#include <opencv2/opencv.hpp>
#include <iostream>


/*
  This ImageAligner replaces hugin's align_image_stack with in-process usage of opencv2
  it's faster and better at detecting stars using SIFT.

  However, it's still not good at detecting detail in the ground, especially when it's dark.
  tried flipping the image, and boosting contrast, but so far, no dice.
  returns the original image when there are not enough found control points.

  TODO:

   - cleanup alignment code (get rid of old method)
   - change return value to be two lists, one aligned, the others that failed
   - update calling code to deal with the situation as it is

  
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


// Helper: compute star mask from special frame
static cv::Mat makeStarMask(const cv::Mat &gray, int dilateSize = 3, int thresholdVal = 200) {
    cv::Mat mask, thresh;
    // Threshold for bright spots (stars)
    cv::threshold(gray, thresh, thresholdVal, 255, cv::THRESH_BINARY);
    // Dilate to give SIFT some gradients around stars
    if (dilateSize > 0) {
        cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE,
                          cv::Size(2*dilateSize+1, 2*dilateSize+1));
        cv::dilate(thresh, mask, kernel);
    } else {
        mask = thresh;
    }
    return mask;
}

+ (id)alignFrames:(Mat)special
           frames:(NSArray<NSValue *> *)frames
      matchMethod:(FeatureMatchMethod)matchMethod
             mask:(Mat)mask	// assumed to be zero for ground, non-zero for sky
     maxDeviation:(double)maxDeviation
maxCornerDeviation:(double)maxCornerDeviation
       invertMask:(BOOL)invertMask // true when processing ground, false for sky
     maxKeypoints:(int)maxKeypoints
{
    try {
        cv::Mat &specialMat = *(cv::Mat *)special;

	//uint32_t logID = arc4random_uniform(1000);

	//Log_i(@"id %d: starting to align frames", logID);
	
        // Horizon mask (sky = nonzero, ground = 0)
        cv::Mat horizonMask;
        if (mask != NULL && !(*(cv::Mat *)mask).empty()) {
            horizonMask = *(cv::Mat *)mask;
        } else {
            horizonMask = cv::Mat(specialMat.size(), CV_8U, cv::Scalar(255));
        }
        if (invertMask) {
            cv::bitwise_not(horizonMask, horizonMask);
        }

        // Prepare grayscale special frame
        cv::Mat specialGray = toGray8UWithMask(specialMat, horizonMask, true);

	horizonMask = toGray8U(horizonMask);
	
	cv::Mat detectionMask = horizonMask;

	if(!invertMask) {
	  // Build star mask for special frame
	  //Log_i(@"id %d: making star mask", logID);
	  detectionMask = makeStarMask(specialGray, /*dilateSize=*/30, /*thresholdVal=*/200);
	}

	//cv::imwrite("/tmp/detectionMask.png", detectionMask);
	
        // Detector and matcher
        cv::Ptr<cv::SIFT> detector = cv::SIFT::create(maxKeypoints);
        std::vector<cv::KeyPoint> kpSpecial;
        cv::Mat descSpecial;
	//Log_i(@"id %d: starting base SIFT detection", logID);
        detector->detectAndCompute(specialGray, detectionMask, kpSpecial, descSpecial);
	//Log_i(@"id %d: finished base SIFT detection", logID);

        NSMutableArray *aligned = [NSMutableArray arrayWithCapacity:frames.count];
        NSMutableArray *failed  = [NSMutableArray arrayWithCapacity:frames.count];
        dispatch_group_t group = dispatch_group_create();
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

        for (NSUInteger i = 0; i < frames.count; i++) {
            [aligned addObject:[NSNull null]];
            [failed  addObject:[NSNull null]];
        }

	cv::setNumThreads(10);	// XXX make this a parameter?

	cv::BFMatcher matcher(cv::NORM_L2);
	
        for (NSUInteger idx = 0; idx < frames.count; idx++) {
	  cv::Mat &frame = *(cv::Mat *)frames[idx].pointerValue;
	  try {
	    //Log_i(@"id %d: neighbor %lu starting", logID, idx);
	    //cv::Ptr<cv::SIFT> detector = cv::SIFT::create(maxKeypoints);
	    cv::Mat frameGray = toGray8UWithMask(frame, horizonMask, true);

	    std::vector<cv::KeyPoint> kpFrame;
	    cv::Mat descFrame;

	    cv::Mat detectionMask = horizonMask;

	    if(!invertMask) {
	      // XXX this is using specialGray, not frameGray, try that XXX
	      //detectionMask = makeStarMask(specialGray, /*dilateSize=*/30, /*thresholdVal=*/200);
	      //Log_i(@"id %d: neighbor %lu making star mask", logID, idx);
	      detectionMask = makeStarMask(frameGray, /*dilateSize=*/30, /*thresholdVal=*/200);
	      //Log_i(@"id %d: neighbor %lu made star mask", logID, idx);
	      // XXX this is using specialGray, not frameGray, try that XXX
	    }
		    
	    //Log_i(@"id %d: neighbor %lu starting SIFT detection", logID, idx);
	    detector->detectAndCompute(frameGray, detectionMask, kpFrame, descFrame);
	    //Log_i(@"id %d: neighbor %lu finished SIFT detection", logID, idx);

	    if (descFrame.empty() || descSpecial.empty()) {
	      Log_d(@"frame %lu is empty\n", idx);
	      failed[idx] = [NSValue valueWithPointer:new cv::Mat(frame)];
	      continue;
	    }

	    std::vector<cv::Point2f> ptsFrame, ptsSpecial;
	    std::vector<std::vector<cv::DMatch>> knnMatches;
	    double cutoff = 0;
	    double minDist = 0;
	    std::vector<cv::DMatch> matches;
	    
	    switch (matchMethod) {
	    case FeatureMatchMethodBruteForce:
	      // brute force method
	      
	      matcher.match(descFrame, descSpecial, matches);

	      minDist = std::numeric_limits<double>::max();
	      for (auto &m : matches) {
		minDist = std::min(minDist, (double)m.distance);
	      }
	      cutoff = std::max(2 * minDist, 30.0);

	      for (auto &m : matches) {
		if (m.distance <= cutoff) {
		  ptsFrame.push_back(kpFrame[m.queryIdx].pt);
		  ptsSpecial.push_back(kpSpecial[m.trainIdx].pt);
		}
	      }
	      break;
	      

	    case FeatureMatchMethodKNNLowes:
	      // kNN + Lowe's Ratio Test
	      matcher.knnMatch(descFrame, descSpecial, knnMatches, 2);

	      for (size_t i = 0; i < knnMatches.size(); i++) {
		if (knnMatches[i].size() == 2) {
		  const cv::DMatch &m1 = knnMatches[i][0];
		  const cv::DMatch &m2 = knnMatches[i][1];
		  if (m1.distance < 0.75 * m2.distance) { // Lowe’s ratio test
		    ptsFrame.push_back(kpFrame[m1.queryIdx].pt);
		    ptsSpecial.push_back(kpSpecial[m1.trainIdx].pt);
		  }
		}
	      }
	      break;

	    case FeatureMatchMethodFLANN:
	      // FLANN based matcher
	      // Convert to CV_32F because FLANN requires float descriptors
	      cv::Mat descFrame32f, descSpecial32f;
	      descFrame.convertTo(descFrame32f, CV_32F);
	      descSpecial.convertTo(descSpecial32f, CV_32F);

	      cv::FlannBasedMatcher flann;
	      flann.knnMatch(descFrame32f, descSpecial32f, knnMatches, 2);

	      for (size_t i = 0; i < knnMatches.size(); i++) {
		if (knnMatches[i].size() == 2) {
		  const cv::DMatch &m1 = knnMatches[i][0];
		  const cv::DMatch &m2 = knnMatches[i][1];
		  if (m1.distance < 0.75 * m2.distance) {
		    ptsFrame.push_back(kpFrame[m1.queryIdx].pt);
		    ptsSpecial.push_back(kpSpecial[m1.trainIdx].pt);
		  }
		}
	      }
	      break;
	    }
	    
	    bool acceptWarp = FALSE;

	    cv::Mat warped;
	    if (ptsFrame.size() >= 4) {
	      //Log_i(@"id %d: neighbor %lu finding homography", logID, idx);
	      cv::Mat H = cv::findHomography(ptsFrame, ptsSpecial, cv::RANSAC, 10);
	      //Log_i(@"id %d: neighbor %lu found homography", logID, idx);
	      if (!H.empty() && H.type() != CV_32F && H.type() != CV_64F) {
		H.convertTo(H, CV_64F);
	      }

	      if (!H.empty() && H.rows == 3 && H.cols == 3) {
		// Check warp quality
		cv::Mat I = cv::Mat::eye(3, 3, H.type());
		double deviation = cv::norm(H - I, cv::NORM_L2);

		std::vector<cv::Point2f> corners = {
		  {0, 0},
		  {(float)frame.cols, 0},
		  {(float)frame.cols, (float)frame.rows},
		  {0, (float)frame.rows}
		};
		std::vector<cv::Point2f> projectedCorners;
		cv::perspectiveTransform(corners, projectedCorners, H);

		double maxCornerDist = 0.0;
		for (size_t i = 0; i < corners.size(); i++) {
		  maxCornerDist = std::max(maxCornerDist,
					   (double)cv::norm(projectedCorners[i] - corners[i]));
		}

		acceptWarp = (deviation < maxDeviation) &&
		  (maxCornerDist < maxCornerDeviation);
		/*
		if(acceptWarp) {
		  Log_i(@"id %d: neighbor %lu acceptWarp TRUE = (%f < %f) && (%f < %f)", logID, idx, deviation, maxDeviation, maxCornerDist, maxCornerDeviation);
		} else {
		  Log_w(@"id %d: neighbor %lu acceptWarp FALSE = (%f < %f) && (%f < %f)", logID, idx, deviation, maxDeviation, maxCornerDist, maxCornerDeviation);
		  }*/
		if (acceptWarp) {
		  cv::warpPerspective(frame, warped, H, frame/*specialMat*/.size(),
				      cv::INTER_LINEAR, cv::BORDER_CONSTANT,
				      cv::Scalar(0,0,0,0));
		} else {
		  warped = frame;
		}
	      } else {
		warped = frame;
	      }
	    } else {
	      warped = frame;
	    }

	    if (warped.channels() == 4) {
	      cv::cvtColor(warped, warped, cv::COLOR_BGRA2BGR);
	    }

	    cv::Mat *result = new cv::Mat(warped);
	    if(acceptWarp) {
	      aligned[idx] = [NSValue valueWithPointer:result];
	    } else {
	      failed[idx] = [NSValue valueWithPointer:result];
	    }
	  } catch (const cv::Exception &e) {
	    Log_e(@"Error: %@", [NSString stringWithUTF8String:e.what()]);
	    cv::Mat *result = new cv::Mat(frame);
	    failed[idx] = [NSValue valueWithPointer:result];
	  } catch (const std::exception &e) {
	    Log_e(@"Error: %@", [NSString stringWithUTF8String:e.what()]);
	    cv::Mat *result = new cv::Mat(frame);
	    failed[idx] = [NSValue valueWithPointer:result];
	  } catch (...) {
	    Log_e(@"Unknown Error");
	    cv::Mat *result = new cv::Mat(frame);
	    failed[idx] = [NSValue valueWithPointer:result];
	  }
	}

	//Log_i(@"id %d: waiting for dispatch group", logID);
	dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
			      
	//Log_i(@"id %d: done waiting for dispatch group", logID);

	// Remove NSNulls from aligned and failed arrays
	NSMutableArray *alignedClean = [NSMutableArray array];
	for (id obj in aligned) {
	  if (obj != [NSNull null] && obj != nil) {
	    [alignedClean addObject:obj];
	  }
	}

	NSMutableArray *failedClean = [NSMutableArray array];
	for (id obj in failed) {
	  if (obj != [NSNull null] && obj != nil) {
	    [failedClean addObject:obj];
	  }
	}

	AlignmentResult *resultObj = [AlignmentResult new];
	resultObj.aligned = alignedClean;
	resultObj.failed  = failedClean;
	return resultObj;
 
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
