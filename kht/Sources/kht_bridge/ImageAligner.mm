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
  printf("SHIT\n");
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
      printf("CAKES\n");
        double minVal, maxVal;
	printMatInfo(mask, "mask");
        cv::minMaxLoc(gray, &minVal, &maxVal, nullptr, nullptr, mask);


        // Avoid divide-by-zero
        double scale = (maxVal > minVal) ? 255.0 / (maxVal - minVal) : 1.0;
        double shift = -minVal * scale;

        // Apply scaling
        gray.convertTo(tmp, CV_8U, scale, shift);
	
    } else {
      printf("TIME\n");
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
      printf("CRAP\n");

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

+ (NSArray<NSValue *> *)alignFrames:(Mat)special
                             frames:(NSArray<NSValue *> *)frames
                               mask:(Mat)mask
                         invertMask:(BOOL)invertMask
		   invertBrightness:(BOOL)invertBrightness
                       maxKeypoints:(int)maxKeypoints
{
    cv::Mat &specialMat = *(cv::Mat *)special;

    // Use mask or full white if none provided
    cv::Mat maskMat;
    if (mask != NULL && !(*(cv::Mat *)mask).empty()) {
        maskMat = *(cv::Mat *)mask;
    } else {
        maskMat = cv::Mat(specialMat.size(), CV_8U, cv::Scalar(255));
    }
    printMatInfo(maskMat, "pre inversion mask");

    // Invert mask if requested
    if (invertMask) {
        cv::bitwise_not(maskMat, maskMat);
	printMatInfo(maskMat, "post inversion mask");
    }

    NSMutableArray *aligned = [NSMutableArray arrayWithCapacity:frames.count];

    if (invertBrightness) {
      cv::bitwise_not(specialMat, specialMat);
      cv::imwrite("/tmp/invert.png", specialMat);
    }

    // Prepare special image for SIFT
    printf("FUCK\n");
    cv::imwrite("/tmp/specialMat.png", specialMat);
    cv::Mat specialGray = toGray8UWithMask(specialMat, maskMat, true);
    cv::imwrite("/tmp/specialGray.png", specialGray);
    printf("YOU\n");

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

	printf("FUCK\n");
	
        // Convert to 8-bit grayscale for SIFT
        cv::Mat frameGray = toGray8UWithMask(frame, maskMat, true);
	
	printf("YOU\n");
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
        printMatInfo(frame, "frame");

	printf("ImageAligner.m: ptsFrame.size() %ld\n", ptsFrame.size());
	
        cv::Mat warped;
        if (ptsFrame.size() >= 4) {
            cv::Mat H = cv::findHomography(ptsFrame, ptsSpecial, cv::RANSAC);
            cv::warpPerspective(frame, warped, H, specialMat.size(),
                                cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(0,0,0,0));
        } else {
            printf("ImageAligner.m: FUCKING FALLBACK :(\n");
            warped = frame;
	    if (invertBrightness) {
	      cv::bitwise_not(warped, warped);
	    }
        }

	//cv::imwrite("/tmp/warped.png", warped);
	cv::Mat output;
        printMatInfo(warped, "warped");
	
	if (warped.channels() == 4) {
	  // If it's BGRA, convert to BGR
	  cv::cvtColor(warped, output, cv::COLOR_BGRA2BGR);
	} else {
	  output = warped;
	}

        cv::Mat *result = new cv::Mat(output);
        printMatInfo(*result, "result");
	//cv::imwrite("/tmp/result.png", *result);
        [aligned addObject:[NSValue valueWithPointer:result]];
        count++;
    }

    return aligned;
}

@end
