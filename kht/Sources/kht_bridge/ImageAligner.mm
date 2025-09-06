#import "ImageAligner.h"
#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/features2d.hpp>
#import <opencv2/calib3d.hpp>
#include <iostream>

@implementation ImageAligner


void printMatInfo(const cv::Mat& mat, const std::string& name = "") {
    if (!name.empty()) {
        std::cout << "Mat '" << name << "':\n";
    } else {
        std::cout << "Mat info:\n";
    }

    std::cout << "  Size: " << mat.cols << " x " << mat.rows << "\n";

    int depth = mat.depth(); // depth = CV_8U, CV_16U, CV_32F, etc.
    int bitsPerComponent = 0;

    switch (depth) {
        case CV_8U: case CV_8S: bitsPerComponent = 8; break;
        case CV_16U: case CV_16S: bitsPerComponent = 16; break;
        case CV_32S: bitsPerComponent = 32; break;
        case CV_32F: bitsPerComponent = 32; break;
        case CV_64F: bitsPerComponent = 64; break;
        default: bitsPerComponent = 0; break;
    }

    int componentsPerPixel = mat.channels();

    std::cout << "  Bits per component: " << bitsPerComponent << "\n";
    std::cout << "  Components per pixel: " << componentsPerPixel << "\n";
    std::cout << "  Total depth (bits per pixel): " << bitsPerComponent * componentsPerPixel << "\n";
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

    NSMutableArray *aligned = [NSMutableArray arrayWithCapacity:frames.count];

    // Prepare special image for SIFT
    cv::Mat specialGray = toGray8U(specialMat);

    cv::Ptr<cv::SIFT> detector = cv::SIFT::create(maxKeypoints);
    std::vector<cv::KeyPoint> kpSpecial;
    cv::Mat descSpecial;

    //cv::imwrite("/tmp/special_gray.png", specialGray);
    
    detector->detectAndCompute(specialGray, maskMat, kpSpecial, descSpecial);

    cv::BFMatcher matcher(cv::NORM_L2);

    int count = 0;
    
    for (NSValue *val in frames) {
        cv::Mat &frame = *(cv::Mat *)val.pointerValue;

        // Convert to 8-bit grayscale for SIFT
        cv::Mat frameGray = toGray8U(frame);
	//cv::imwrite("/tmp/frame_gray.png", frameGray);

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

        cv::Mat warped;
        if (ptsFrame.size() >= 4) {
            cv::Mat H = cv::findHomography(ptsFrame, ptsSpecial, cv::RANSAC);
            cv::warpPerspective(frame, warped, H, specialMat.size(),
                                cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(0,0,0,0));
	    //cv::imwrite("/tmp/FU3.png", H);
        } else {
            // fallback: empty image with alpha
            warped = cv::Mat(frame.size(), CV_8UC4, cv::Scalar(0,0,0,0));
        }

	//cv::imwrite("/tmp/warped.png", warped);

        cv::Mat *result = new cv::Mat(warped);
 
	//cv::imwrite("/tmp/result.png", *result);
 
	printMatInfo(*result, "result");
  
        [aligned addObject:[NSValue valueWithPointer:result]];

	count++;
    }

    return aligned;
}

@end
