#import "ImageAligner.h"
#import "logging.h"
#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/features2d.hpp>
#import <opencv2/calib3d.hpp>
#include <opencv2/opencv.hpp>
#include <iostream>


@implementation AlignmentResult
@end

// merges the provided vector of cv::Mat images with median brightness per channel
// throws out 99% or more of airplane and satellite signal
// gives a pretty clear horizon
// k is the threshold used for weeding out bright pixels 1.2 is good
// smaller weeds out more bright pixels, larger weeds out less.
// It is good to weed out these bright pixels before taking the median
// as otherwise areas with lots of bright bad pixels in the same spot across
// multiple images can sometimes allow the bad pixels to show up at the median 
cv::Mat medianImageFromArray(const std::vector<cv::Mat>& mats, double k) {
    if (mats.empty()) return cv::Mat();

    // grab first image to read its characteristics
    const cv::Mat& first = mats[0];

    // image height
    int rows = first.rows;

    // image width
    int cols = first.cols;

    // channels per pixel
    int ch   = first.channels();

    // size of each channel
    int depth = first.depth();

    // how many incoming images we're dealing with
    int n    = static_cast<int>(mats.size());

    // basic validation
    for (int i = 1; i < n; ++i) {
        if (mats[i].rows != rows || mats[i].cols != cols || mats[i].type() != first.type()) {
            throw std::runtime_error("All mats must have same size and type");
        }
    }
    if (ch != 1 && ch != 3 && ch != 4) {
        throw std::runtime_error("Unsupported channel count");
    }

    cv::Mat output(rows, cols, first.type());

    if (depth == CV_8U) {
        // 8-bit per channel
        for (int y = 0; y < rows; ++y) {
            const uchar* rowPtrs[n];
            for (int i = 0; i < n; ++i) rowPtrs[i] = mats[i].ptr<uchar>(y);
            uchar* outRow = output.ptr<uchar>(y);

            for (int x = 0; x < cols; ++x) {
                int vals[4][n]; // up to 4 channels, up to 12 mats
                for (int i = 0; i < n; ++i) {
                    const uchar* pix = rowPtrs[i] + x * ch; // bytes-per-pixel = ch * 1
                    for (int c = 0; c < ch; ++c) vals[c][i] = pix[c];
                }
                for (int c = 0; c < ch; ++c) {
                    std::sort(vals[c], vals[c] + n);

		    // sort values for this pixel component across images
                    std::sort(vals[c], vals[c] + n);

		    // calculate mean intensity for this channel
		    double sum = 0;
		    for(int z = 0 ; z < n ; ++z) {
		      sum += (double)vals[c][z];
		    }
		    double mean = sum / n; // mean intensity for this channel
		    
		    double varSum = 0.0;
		    for(int z = 0 ; z < n ; ++z) {
		      double d = (double)vals[c][z] - mean;
		      varSum += d * d;
		    }
		    double std = sqrt(varSum / n);
		    double threshold = mean + k * std; // our threshold

		    int maxIndex = 0;
		    for(int z = 0 ; z < n ; ++z) {
		      if((double)vals[c][z] < threshold) {
			maxIndex = z;
		      } else {
			break;
		      }
		    }
		    
                    outRow[x * ch + c] = static_cast<uchar>(vals[c][maxIndex / 2]);
                }
            }
        }
    } else if (depth == CV_16U) {
        // 16-bit per channel
        for (int y = 0; y < rows; ++y) {
            const uint16_t* rowPtrs[n];
            for (int i = 0; i < n; ++i) rowPtrs[i] = mats[i].ptr<uint16_t>(y);
            uint16_t* outRow = output.ptr<uint16_t>(y);

            for (int x = 0; x < cols; ++x) {
                int vals[4][n]; // use int for sorting/safety
                for (int i = 0; i < n; ++i) {
                    const uint16_t* pix = rowPtrs[i] + x * ch; // element-per-pixel = ch (uint16_t)
                    for (int c = 0; c < ch; ++c) vals[c][i] = pix[c];
                }
                for (int c = 0; c < ch; ++c) {
		    /*
		      apply statistics here to weed bright outliers

		      1. calculcate mean intensity
		      2. standard deviation to get threshold
		      3. see what index the threshold appears at
		      4. divide that number by 2 instead of n to get the median
		     */

		    // sort values for this pixel component across images
                    std::sort(vals[c], vals[c] + n);

		    // calculate mean intensity for this channel
		    double sum = 0;
		    for(int z = 0 ; z < n ; ++z) {
		      sum += (double)vals[c][z];
		    }
		    double mean = sum / n; // mean intensity for this channel
		    
		    double varSum = 0.0;
		    for(int z = 0 ; z < n ; ++z) {
		      double d = (double)vals[c][z] - mean;
		      varSum += d * d;
		    }
		    double std = sqrt(varSum / n);
		    double threshold = mean + k * std; // our threshold

		    int maxIndex = 0;
		    for(int z = 0 ; z < n ; ++z) {
		      if((double)vals[c][z] < threshold) {
			maxIndex = z;
		      } else {
			break;
		      }
		    }
		    
                    outRow[x * ch + c] = static_cast<uint16_t>(vals[c][maxIndex / 2]);
                }
            }
        }
    } else {
        throw std::runtime_error("Unsupported element depth (only CV_8U and CV_16U implemented)");
    }

    return output;
}



@implementation ImageAligner


/*
  This ImageAligner replaces hugin's align_image_stack with in-process usage of opencv2
  it's faster and better at detecting stars using SIFT and ground using AKAZE.

  TODO:

   - cleanup alignment code (get rid of old method)
   - update calling code to deal with the situation as it is

 */

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

/***
 * Main alignment method. 
 *
 * Aligns array of 'frames' to 'special'.
 * The 'mask' is a binary mask with zero for the ground and non-zero for the sky
 * 
 * Returns an AlignmentResult with:
 *  - a list of properly aligned frames
 *  - a list of frames where alignment was not successful
 *
 * Uses different logic for sky and earth alignment, invertMask governs that. 
 */
+ (id)alignFrames:(Mat)special
           frames:(NSArray<NSValue *> *)frames
      matchMethod:(FeatureMatchMethod)matchMethod
             mask:(Mat)mask	// assumed to be zero for ground, non-zero for sky
     maxDeviation:(double)maxDeviation
maxCornerDeviation:(double)maxCornerDeviation
       invertMask:(BOOL)invertMask // true when processing ground, false for sky
     maxKeypoints:(int)maxKeypoints
 outlierThreshold:(double)k
{
    try {
	cv::setNumThreads(10);	// XXX make this a parameter?

        cv::Mat &specialMat = *(cv::Mat *)special;

	uint32_t logID = arc4random_uniform(1000);

	//Log_i(@"id %d: starting to align frames", logID);

        // Horizon mask (sky = nonzero, ground = 0)
        cv::Mat horizonMask;
        if (mask != NULL && !(*(cv::Mat *)mask).empty()) {
            // use passed in horizon mask
            horizonMask = *(cv::Mat *)mask;
        } else {
            // if no horizon mask is passed, assume a fully white mask (all pixels)
            horizonMask = cv::Mat(specialMat.size(), CV_8U, cv::Scalar(255));
        }

	horizonMask = toGray8U(horizonMask);
	
        if (invertMask) {
            // the mask inverted to apply to the ground instead of the sky
            cv::bitwise_not(horizonMask, horizonMask);
	    // for the ground, we make the horizon mask include the horizon,
	    // which leads to better keypoints down the road
	    horizonMask = createGradientMaskIntoSky(horizonMask, 100); // XXX hardcoded constant
	    //cv::imwrite("/tmp/horizonMask.png", horizonMask);
        }

        // Prepare grayscale special frame
        cv::Mat specialGray = toGray8UWithMask(specialMat, horizonMask, true);

        specialMat.release();
        
	cv::Mat detectionMask = horizonMask;

	if(!invertMask) {
	  // Build star mask for special frame
	  //Log_i(@"id %d: making star mask", logID);
	  detectionMask = makeStarMask(specialGray, /*dilateSize=*/30, /*thresholdVal=*/200);
	}

	//cv::imwrite("/tmp/detectionMask.png", detectionMask);
	
        // Detector and matcher

	// use SIFT for sky
        cv::Ptr<cv::SIFT> sift = cv::SIFT::create(maxKeypoints);

	// use AKAZE detector for ground
	cv::Ptr<cv::AKAZE> akaze = cv::AKAZE::create();

        //akaze->setDescriptorSize(486); // 4/4
        //        akaze->setDescriptorSize(256); // 4/4

	akaze->setThreshold(1e-5); // good results :) but slow :( 5/8

        //	akaze->setThreshold(1e-4);

	
        std::vector<cv::KeyPoint> kpSpecial;
        cv::Mat descSpecial;
	//Log_i(@"id %d: starting base SIFT detection", logID);

	// not used for sky, only for earth
	cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(4.0, cv::Size(8,8));

	if(invertMask) {
	  // ground
	  // Apply Contrast Limited Adaptive Histogram Equalization
	  cv::Mat specialProcessed;

	  clahe->apply(specialGray, specialProcessed);

	  //cv::imwrite("/tmp/clahe.png", specialProcessed);
	  
	  // apply gamma correction to brighten the shadows only
	  cv::Mat gammaCorrected;
	  specialProcessed.convertTo(specialProcessed, CV_32F, 1.0/255.0);
	  cv::pow(specialProcessed, 0.5, specialProcessed); // gamma < 1 brightens
	  specialProcessed.convertTo(specialProcessed, CV_8U, 255.0);
	  //cv::imwrite("/tmp/gamma.png", specialProcessed);
	  
	  akaze->detectAndCompute(specialProcessed, detectionMask, kpSpecial, descSpecial);
	} else {
	  // sky
	  sift->detectAndCompute(specialGray, detectionMask, kpSpecial, descSpecial);
	}

        kpSpecial.shrink_to_fit();
        
        specialGray.release();
        
	//Log_i(@"id %d: finished base SIFT detection", logID);

	std::vector<cv::Mat> aligned;
	std::vector<cv::Mat> failed;
	
	cv::BFMatcher matcher(cv::NORM_L2);

        cv::Mat frameGray, claheOut, gammaCorrected;
        
        for (NSUInteger idx = 0; idx < frames.count; idx++) {
	  cv::Mat &frame = *(cv::Mat *)frames[idx].pointerValue;
	  try {
	    //Log_i(@"id %d: neighbor %lu starting", logID, idx);
	    //cv::Ptr<cv::SIFT> sift = cv::SIFT::create(maxKeypoints);
	    frameGray = toGray8UWithMask(frame, horizonMask, true);

	    std::vector<cv::KeyPoint> kpFrame;
	    cv::Mat descFrame;

	    cv::Mat detectionMask = horizonMask;

	    if(!invertMask) {
	      // detection mask is a star mask for the sky
	      detectionMask = makeStarMask(frameGray, /*dilateSize=*/30, /*thresholdVal=*/200);
	    }

	    if(invertMask) {
	      // ground

	      // Apply Contrast Limited Adaptive Histogram Equalization
	      clahe->apply(frameGray, claheOut);

	      // apply gamma correction to brighten the shadows only
	      claheOut.convertTo(claheOut, CV_32F, 1.0/255.0);
	      cv::pow(claheOut, 0.5, claheOut); // gamma < 1 brightens
	      claheOut.convertTo(claheOut, CV_8U, 255.0);

	      // detect and compute on the processed mat with akaze
	      akaze->detectAndCompute(claheOut, detectionMask, kpFrame, descFrame);
	    } else {
	      
	      // sky
	      sift->detectAndCompute(frameGray, detectionMask, kpFrame, descFrame);
	    }
	    
            kpFrame.shrink_to_fit();
        
	    if (descFrame.empty() || descSpecial.empty()) {
	      Log_d(@"frame %lu is empty", idx);
	      failed.push_back(frame);
	      continue;
	    }

	    std::vector<cv::Point2f> ptsFrame, ptsSpecial;
	    std::vector<std::vector<cv::DMatch>> knnMatches;
	    double cutoff = 0;
	    double minDist = 0;
	    std::vector<cv::DMatch> matches;

	    // how do we match?
	    // three different methods available
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
	    Log_i(@"id %d: neighbor %lu ptsFrame.size() %zu", logID, idx, ptsFrame.size());
	    if (ptsFrame.size() >= 4) {
	      Log_i(@"id %d: neighbor %lu finding homography", logID, idx);
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

		if(acceptWarp) {
		  Log_i(@"id %d: neighbor %lu acceptWarp TRUE = (%f < %f) && (%f < %f)", logID, idx, deviation, maxDeviation, maxCornerDist, maxCornerDeviation);
		} else {
		  Log_w(@"id %d: neighbor %lu acceptWarp FALSE = (%f < %f) && (%f < %f)", logID, idx, deviation, maxDeviation, maxCornerDist, maxCornerDeviation);
		}
		if (acceptWarp) {
		  cv::warpPerspective(frame, warped, H, frame.size(),
				      cv::INTER_LINEAR, cv::BORDER_CONSTANT,
				      cv::Scalar(0,0,0,0));
		  //cv::imwrite("/tmp/warped_first_" + std::to_string(idx) + ".png", warped);
		} else {
		  warped = frame;
		}
	      } else {
		warped = frame;
	      }
            } else {
              warped = frame;
	    }

            frameGray.release();
            claheOut.release();
            gammaCorrected.release();

            if (warped.channels() == 4) {
              // really we want the alpha channel to see what parts of each warped
              // frame we should not use for good signal.
              // BUT need to figure out how to get cv::Mat images with alpha back
              // to PixelatedImages properly, that's busted :(
              // so for now, discard the alpha channel
	      cv::cvtColor(warped, warped, cv::COLOR_BGRA2BGR);
	    }

	    //	    cv::Mat *result = new cv::Mat(warped);

	    //cv::imwrite("/tmp/warped_" + std::to_string(idx) + ".png", warped);
	    if(acceptWarp) {
	      aligned.push_back(warped);
	    } else {
	      failed.push_back(frame);
	    }
	  } catch (const cv::Exception &e) {
	    Log_e(@"Error: %@", [NSString stringWithUTF8String:e.what()]);
	    failed.push_back(frame);
	  } catch (const std::exception &e) {
	    Log_e(@"Error: %@", [NSString stringWithUTF8String:e.what()]);
	    failed.push_back(frame);
	  } catch (...) {
	    Log_e(@"Unknown Error");
	    failed.push_back(frame);
	  }
	}

        cv::Mat *alignedResult = new cv::Mat(medianImageFromArray(aligned, k));
        cv::Mat *failedResult = new cv::Mat(medianImageFromArray(failed, k));
        
        AlignmentResult *resultObj = [AlignmentResult new];
	resultObj.aligned = [NSValue valueWithPointer:alignedResult];
	resultObj.numAligned = aligned.size();
	resultObj.failed  = [NSValue valueWithPointer:failedResult];
	resultObj.numFailed = failed.size();
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
