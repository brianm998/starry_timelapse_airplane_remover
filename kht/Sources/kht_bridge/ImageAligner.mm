#import "ImageAligner.h"
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

// Ensure alpha channel has same type and size as warped
cv::Mat addAlphaChannel(const cv::Mat& img) {
    if (img.channels() != 3) return img;

    cv::Mat gray, alpha;
    cv::cvtColor(img, gray, cv::COLOR_BGR2GRAY);
    cv::inRange(gray, cv::Scalar(1), cv::Scalar(255), alpha);

    // Match depth and size
    if (alpha.depth() != img.depth()) {
        alpha.convertTo(alpha, img.depth());
    }

    std::vector<cv::Mat> channels;
    cv::split(img, channels);
    channels.push_back(alpha);

    cv::Mat result;
    cv::merge(channels, result);
    return result;
}

+ (id)alignFrames:(Mat)special
	   frames:(NSArray<NSValue *> *)frames
	     mask:(Mat)mask
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
    //printMatInfo(maskMat, "pre inversion mask");

    // Invert mask if requested
    if (invertMask) {
        cv::bitwise_not(maskMat, maskMat);
	//printMatInfo(maskMat, "post inversion mask");
    }

    NSMutableArray *aligned = [NSMutableArray arrayWithCapacity:frames.count];

    if (invertBrightness) {
      cv::bitwise_not(specialMat, specialMat);
      //cv::imwrite("/tmp/invert.png", specialMat);
    }

    // Prepare special image for SIFT
    //cv::imwrite("/tmp/specialMat.png", specialMat);
    cv::Mat specialGray = toGray8UWithMask(specialMat, maskMat, true);
    //cv::imwrite("/tmp/specialGray.png", specialGray);

    cv::Ptr<cv::SIFT> detector = cv::SIFT::create(maxKeypoints);
    std::vector<cv::KeyPoint> kpSpecial;
    cv::Mat descSpecial;

    detector->detectAndCompute(specialGray, maskMat, kpSpecial, descSpecial);

    cv::BFMatcher matcher(cv::NORM_L2);

    int count = 0;
    
    for (NSValue *val in frames) {
        cv::Mat &frame = *(cv::Mat *)val.pointerValue;

	if (invertBrightness) {
	  cv::bitwise_not(frame, frame);
	}

	
        // Convert to 8-bit grayscale for SIFT
        cv::Mat frameGray = toGray8UWithMask(frame, maskMat, true);
	
        std::vector<cv::KeyPoint> kpFrame;
        cv::Mat descFrame;
        detector->detectAndCompute(frameGray, maskMat, kpFrame, descFrame);

        // Match descriptors
        std::vector<cv::DMatch> matches;
        matcher.match(descFrame, descSpecial, matches);

        // Filter matches
        double minDist = std::numeric_limits<double>::max();
        for (auto &m : matches) minDist = std::min(minDist, (double)m.distance);
        double cutoff = std::max(2 * minDist, 30.0);

        std::vector<cv::Point2f> ptsFrame, ptsSpecial;
        for (auto &m : matches) {
            if (m.distance <= cutoff) {
                ptsFrame.push_back(kpFrame[m.queryIdx].pt);
                ptsSpecial.push_back(kpSpecial[m.trainIdx].pt);
            }
        }

	//cv::imwrite("/tmp/frame.png", frame);
        //printMatInfo(frame, "frame");

	//printf("ImageAligner.m: ptsFrame.size() %ld\n", ptsFrame.size());
	
        cv::Mat warped;
	if (ptsFrame.size() >= 4) {
	  cv::Mat H = cv::findHomography(ptsFrame, ptsSpecial, cv::RANSAC);
	  
	  if (!H.empty() && H.type() != CV_32F && H.type() != CV_64F) {
	    H.convertTo(H, CV_64F);
	  }
	  
	  if (H.empty() || (H.rows != 3 || H.cols != 3) || !(H.type() == CV_32F || H.type() == CV_64F)) {
	    // fallback, cannot warp for some reason
	    //printf("ImageAligner.m: FUCKING FALLBACK :(\n");
	    // XXX expose that this has happened to callers somehow
            warped = frame;
	    if (invertBrightness) {
	      cv::bitwise_not(warped, warped);
	    }
	  } else {
	    cv::warpPerspective(frame, warped, H, specialMat.size(),
				cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(0,0,0,0));
	  }
	} else {
	  // fallback, cannot warp because of not enough control points
	  //printf("ImageAligner.m: FUCKING FALLBACK :(\n");
	  // XXX expose that this has happened to callers somehow
	  warped = frame;
	  if (invertBrightness) {
	    cv::bitwise_not(warped, warped);
	  }
	}

	//cv::imwrite("/tmp/warped.png", warped);
	cv::Mat output;
        //printMatInfo(warped, "warped");
	
	if (warped.channels() == 4) {
	  // If it's BGRA, convert to BGR
	  // had a real hard time getting CGImage to accept alpha from here :(
	  cv::cvtColor(warped, output, cv::COLOR_BGRA2BGR);
	} else {
	  output = warped;
	}

        cv::Mat *result = new cv::Mat(output);
        //printMatInfo(*result, "result");
	//cv::imwrite("/tmp/result.png", *result);
        [aligned addObject:[NSValue valueWithPointer:result]];
        count++;
    }

    return aligned;
  } catch (const cv::Exception& e) {
    return [NSString stringWithUTF8String:e.what()]; 
  } catch (const std::exception& e) {
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
