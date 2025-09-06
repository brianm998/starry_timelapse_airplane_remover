#import "ImageAligner.h"
#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/features2d.hpp>
#import <opencv2/calib3d.hpp>

@implementation ImageAligner


cv::Mat toGray8U(const cv::Mat& src) {
    if (src.empty()) {
        throw std::runtime_error("Input image is empty!");
    }

    cv::Mat tmp;
    if (src.depth() == CV_16U) {
        // Scale down by shifting right (divide by 256)
        src.convertTo(tmp, CV_8U, 1.0 / 256.0);
    } else if (src.depth() != CV_8U) {
        // Other depths (float, double) -> clamp
        src.convertTo(tmp, CV_8U);
    } else {
        tmp = src;
    }

    if (tmp.channels() > 1) {
        cv::cvtColor(tmp, tmp, cv::COLOR_BGR2GRAY);
    }

    return tmp;
}

+ (NSArray<NSValue *> *)alignFrames:(Mat)special
			     frames:(NSArray<NSValue *> *)frames
			       mask:(Mat)mask
		       maxKeypoints:(int)maxKeypoints;
{
  printf("crap1\n");
    cv::Mat &specialMat = *(cv::Mat *)special;

    cv::Mat maskMat;
    if (mask != NULL) {
      maskMat = *(cv::Mat *)mask;
    } else {
      maskMat = cv::Mat(specialMat.size(), CV_8U, cv::Scalar(255));
    }

    bool hasMask = (mask != NULL && !maskMat.empty());
    
    NSMutableArray *aligned = [NSMutableArray arrayWithCapacity:frames.count];

    // Convert special to grayscale
    cv::Mat specialGray = toGray8U(specialMat);

    if(mask == NULL) {
      printf("crap2 NULL\n");
    }

    if(maskMat.empty()) {
      printf("crap2 empty\n");
    } else {
      printf("crap2 NOT empty\n");
    }

    // Create SIFT detector (now part of core OpenCV)
    cv::Ptr<cv::SIFT> detector = cv::SIFT::create(maxKeypoints);

    // Compute keypoints & descriptors for special
    std::vector<cv::KeyPoint> kpSpecial;
    cv::Mat descSpecial;
    printf("really\n");
    detector->detectAndCompute(
        specialGray,
	maskMat,
        kpSpecial,
        descSpecial
    );
    printf("SHITTY\n");
    
    // Matcher
    cv::BFMatcher matcher(cv::NORM_L2);
  printf("crap3\n");

    for (NSValue *val in frames) {
      printf("crap4\n");

      cv::Mat *framePtr = (cv::Mat *)val.pointerValue;
      cv::Mat &frame = *framePtr;

      // Convert to grayscale
      cv::Mat frameGray = toGray8U(frame);

      // Keypoints/descriptors for this frame
      std::vector<cv::KeyPoint> kpFrame;
      cv::Mat descFrame;
      detector->detectAndCompute(
				 frameGray,
				 maskMat,
				 kpFrame,
				 descFrame
				 );

      // Match descriptors
      std::vector<cv::DMatch> matches;
      matcher.match(descFrame, descSpecial, matches);

      // Filter matches
      double minDist = std::numeric_limits<double>::max();
      for (auto &m : matches) {
        minDist = std::min(minDist, (double)m.distance);
      }
      double cutoff = std::max(2 * minDist, 30.0);

      std::vector<cv::Point2f> ptsFrame, ptsSpecial;
      ptsFrame.reserve(matches.size());
      ptsSpecial.reserve(matches.size());
      for (auto &m : matches) {
        if (m.distance <= cutoff) {
	  ptsFrame.push_back(kpFrame[m.queryIdx].pt);
	  ptsSpecial.push_back(kpSpecial[m.trainIdx].pt);
        }
      }

      cv::Mat warped;
      if (ptsFrame.size() >= 4) {
        cv::Mat H = cv::findHomography(ptsFrame, ptsSpecial, cv::RANSAC);
        cv::warpPerspective(
			    frame, warped, H, specialMat.size(),
			    cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(0, 0, 0, 0)
			    );
      } else {
        warped = cv::Mat(frame.size(), CV_8UC4, cv::Scalar(0, 0, 0, 0));
      }

      // Efficient alpha channel
      if (warped.channels() == 3) {
        cv::Mat alpha, grayValid;
        cv::cvtColor(warped, grayValid, cv::COLOR_BGR2GRAY);
        cv::inRange(grayValid, cv::Scalar(1), cv::Scalar(255), alpha);

        std::vector<cv::Mat> channels;
        cv::split(warped, channels);
        channels.push_back(alpha);
        cv::merge(channels, warped);
      }

      cv::Mat *result = new cv::Mat(warped);
      [aligned addObject:[NSValue valueWithPointer:result]];
    }

    return aligned;
}

@end
