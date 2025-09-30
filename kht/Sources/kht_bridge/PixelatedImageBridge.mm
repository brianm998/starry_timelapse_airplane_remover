#import "PixelatedImageBridge.h"
#import "MatWrapper_Internal.h"

#import "logging.h"

#include <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/highgui.hpp>



#include <memory>

extern void printMatInfo(const cv::Mat& mat, const std::string& name = "");

// PixelatedImageBridge.mm

#import <opencv2/imgcodecs/macosx.h>

#include <set>        // for std::set

#import "HorizonResult.h"

@implementation PixelatedImageBridge

+ (MatWrapper *)combineImage:(MatWrapper *)image1
			mask:(MatWrapper *)mask
		  background:(MatWrapper *)image2
{
    @try {
      try {
	Log_d(@"check");
	cv::Mat mat1 = image1.mat;
	cv::Mat mat2 = image2.mat;
	cv::Mat matMask = mask.mat;

	// Safety check: ensure sizes match
	if (mat1.size() != mat2.size() || mat1.size() != matMask.size()) {
	  Log_e(@"combineWithMask: Input Mats must have the same size. mat1.size [%d, %d] matw.size [%d, %d] matMask.size [%d, %d]", mat1.size().width, mat1.size().height, mat2.size().width, mat2.size().height, matMask.size().width, matMask.size().height);
	  return nil;
	}

	// Prepare output Mat
	cv::Mat result;
	result.create(mat1.size(), mat1.type());

	// Combine images using mask
	// Non-zero in mask -> mat1; zero in mask -> mat2
	mat1.copyTo(result, matMask);         // Fill masked region with mat1
	cv::bitwise_not(matMask, matMask);     // Invert mask to copy from mat2
	mat2.copyTo(result, matMask);         // Fill other region with mat2
	printMatInfo(result, "result");
	Log_d(@"check");

	MatWrapper * ret = [[MatWrapper alloc] initWithMat: result];
	
	Log_d(@"checked");

	return ret;
      } catch (const cv::Exception &e) {
	Log_e(@"OpenCV Exception: %s", e.what());
      }
    } @catch (NSException *exception) {
      Log_e(@"Objective-C Exception: %@", exception);
    }
    return nil;
    
}


+ (MatWrapper *)filterConnectedComponents:(MatWrapper *)image keepLargest:(NSInteger)n {
    @try {
      try {
	// now work with references
	cv::Mat& mat = image.mat;

	// make copy for safer concurrency
	cv::Mat owned = mat;         // only clone below if we mutate
    
	// If your conversion gives 3/4 channels, force it to grayscale
	if (owned.channels() > 1) {
      owned = mat.clone();      // clone becvause we mutate here
	  cv::cvtColor(owned, owned, cv::COLOR_BGR2GRAY);
	}
    
	// Connected components
	cv::Mat labels, stats, centroids;
	int nLabels = cv::connectedComponentsWithStats(owned, labels, stats, centroids, 8, CV_32S);

	// Collect areas
	std::vector<std::pair<int,int>> areas;
	for (int i = 1; i < nLabels; i++) { // skip background (0)
	  int area = stats.at<int>(i, cv::CC_STAT_AREA);
	  areas.emplace_back(area, i);
	}
	std::sort(areas.begin(), areas.end(), std::greater<>());
    
	// Keep only largest N
	std::set<int> keep;
	for (int i = 0; i < std::min<int>(n, areas.size()); i++) {
	  keep.insert(areas[i].second);
	}

	// Build output mask
	cv::Mat filtered = cv::Mat::zeros(owned.size(), CV_8UC1);
	for (int y = 0; y < labels.rows; y++) {
	  for (int x = 0; x < labels.cols; x++) {
            int lbl = labels.at<int>(y, x);
            if (keep.count(lbl)) {
	      filtered.at<uchar>(y, x) = 255;
            }
	  }
	}

	return [[MatWrapper alloc] initWithMat: filtered];
      } catch (const cv::Exception &e) {
	Log_e(@"OpenCV Exception: %s", e.what());
      }
    } @catch (NSException *exception) {
      Log_e(@"Objective-C Exception: %@", exception);
    }
    return nil;
}

// this is the last step in horizon detection
+ (MatWrapper *)groundOnlyFrom:(MatWrapper *)image {
  @try {
    try {
      Log_d(@"groundOnlyFrom started");

      cv::Mat mat = image.mat;

      // make copy for safer concurrency
      cv::Mat owned = mat;
    
      // If your conversion gives 3/4 channels, force it to grayscale
      if (owned.channels() > 1) {
        owned = mat.clone();
        cv::cvtColor(owned, owned, cv::COLOR_BGR2GRAY);
      }
    
      // Ensure binary (Otsu output should already be 0/255)
      cv::Mat bin;
      cv::threshold(owned, bin, 127, 255, cv::THRESH_BINARY);

      // Invert so ground = white (255)
      cv::Mat inv;
      cv::bitwise_not(bin, inv);

      // Connected components
      cv::Mat labels, stats, centroids;
      int nLabels = cv::connectedComponentsWithStats(inv, labels, stats, centroids, 8, CV_32S);

      // Collect all labels touching the bottom row
      std::set<int> bottomLabels;
      int bottomY = inv.rows - 1;
      for (int x = 0; x < labels.cols; x++) {
        int lbl = labels.at<int>(bottomY, x);
        if (lbl > 0) bottomLabels.insert(lbl);
      }

      // Build filtered mask: keep only bottom-connected components
      cv::Mat groundMask = cv::Mat::zeros(inv.size(), CV_8UC1);
      for (int y = 0; y < labels.rows; y++) {
        for (int x = 0; x < labels.cols; x++) {
	  int lbl = labels.at<int>(y, x);
	  if (bottomLabels.count(lbl)) {
	    groundMask.at<uchar>(y, x) = 255;
	  }
        }
      }

      // Invert back: ground = black (0), sky = white (255)
      cv::Mat finalMask;
      cv::bitwise_not(groundMask, finalMask);


      // find highest black pixel

      // Find coordinates of black pixels (ground)
      std::vector<cv::Point> blackPoints;
      cv::findNonZero(finalMask == 0, blackPoints);

      int horizonTopY = INT_MAX;

      // find highest black pixel
      for (const auto& p : blackPoints) {
	horizonTopY = std::min(horizonTopY, p.y); // topmost black pixel
      }

      // find lowest white pixel

      std::vector<cv::Point> whitePoints;
      cv::findNonZero(finalMask == 255, whitePoints);

      int horizonBottomY = INT_MIN;
      for (const auto& p : whitePoints) {
	horizonBottomY = std::max(horizonBottomY, p.y); // lowest white pixel
      }

      return [[MatWrapper alloc] initWithMat: finalMask]; // XXX was cloned

    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;    
}


+ (HorizonResult *)horizonExtentsFromImage:(MatWrapper *)image {
  @try {
    try {
      Log_d(@"horizonExtentsFromImage started");

      cv::Mat mat = image.mat;

      if (mat.empty()) {
        Log_d(@"mat was empty :(");
        return nil;
      }
      
      cv::Mat owned = mat; 

      cv::Mat gray, binary;
    
      // If not already grayscale, convert
      if (owned.channels() == 3) {
        cv::cvtColor(owned, gray, cv::COLOR_BGR2GRAY);
      } else if (owned.channels() == 4) {
        cv::cvtColor(owned, gray, cv::COLOR_BGRA2GRAY);
      } else if (owned.channels() == 1) {
        gray = owned; // already grayscale
      } else {
        Log_d(@"Unsupported channel count: %d", owned.channels());
        return nil;
      }

      cv::threshold(gray, binary, 128, 255, cv::THRESH_BINARY);
    
      // --- Find horizon extents ---
      int horizonTopY = -1;
      for (int y = 0; y < binary.rows; y++) {
        if (cv::countNonZero(binary.row(y) == 0) > 0) {
          horizonTopY = y;
          break;
        }
      }
    
      int horizonBottomY = -1;
      for (int y = binary.rows - 1; y >= 0; y--) {
        if (cv::countNonZero(binary.row(y) == 255) > 0) {
          horizonBottomY = y;
          break;
        }
      }

      //delete matPtr;
      Log_d(@"horizonExtentsFromImage done");
      
      return [[HorizonResult alloc]
               initWithHorizonTopY: horizonTopY
                    horizonBottomY: horizonBottomY];
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

// shifts mask up by borderAmount pixels and crops the image with it
// does this really work?
+ (MatWrapper *)maskRaisedBy:(MatWrapper *)image
                        mask:(MatWrapper *)mask
                      border:(int)borderAmount
{
  @try {
    try {
      //Log_d(@"maskRaisedBy started");
      cv::Mat mat = image.mat;
      cv::Mat maskMat = mask.mat;

      // make copies for safer concurrency
      cv::Mat owned = mat;//.clone();
        cv::Mat ownedMask = maskMat;//.clone();
      
      CV_Assert(ownedMask.type() == CV_8UC1);
      CV_Assert(owned.rows == ownedMask.rows && owned.cols == ownedMask.cols);

      const int h = owned.rows;
      const int w = owned.cols;

      //Log_d(@"Original size [%d, %d]", h, w);

      // --- Step 1: create keep mask (zeros in ownedMask are keep) ---
      cv::Mat keepMask = (ownedMask == 0);  // 255 = keep, 0 = masked

      // Debug: original keep mask maxY
      std::vector<cv::Point> origNonZero;
      cv::findNonZero(keepMask, origNonZero);
      int origMaxY = 0;
      for (auto &p : origNonZero) if (p.y > origMaxY) origMaxY = p.y;
      //Log_d(@"Original keep mask maxY: %d", origMaxY);

      // --- Step 2: shift keep area upward by borderAmount ---
      cv::Mat dilatedMask = cv::Mat::zeros(keepMask.size(), keepMask.type());
      int shift = std::min(borderAmount, keepMask.rows);

      // Copy rows from keepMask into dilatedMask, shifted upward
      keepMask.rowRange(shift, keepMask.rows)
	.copyTo(dilatedMask.rowRange(0, keepMask.rows - shift));

      // Copy bottom 'shift' rows unchanged to preserve original bottom
      keepMask.rowRange(keepMask.rows - shift, keepMask.rows)
	.copyTo(dilatedMask.rowRange(keepMask.rows - shift, keepMask.rows));

      // Debug: dilated mask maxY
      std::vector<cv::Point> dilatedNonZero;
      cv::findNonZero(dilatedMask, dilatedNonZero);
      int dilatedMaxY = 0;
      for (auto &p : dilatedNonZero) if (p.y > dilatedMaxY) dilatedMaxY = p.y;
      //Log_d(@"Dilated keep mask maxY: %d", dilatedMaxY);

      // --- Step 3: apply mask to image ---
      cv::Mat masked = owned.clone(); // must clone so we can mutate
      cv::Scalar whiteScalar;
      switch (owned.depth()) {
      case CV_8U:  whiteScalar = cv::Scalar(255); break;
      case CV_16U: whiteScalar = cv::Scalar(65535); break;
      case CV_32S: whiteScalar = cv::Scalar(std::numeric_limits<int>::max()); break;
      default: CV_Error(cv::Error::StsUnsupportedFormat, "Unsupported depth");
      }
      if (owned.channels() > 1) whiteScalar = cv::Scalar::all(whiteScalar[0]);

      masked.setTo(whiteScalar, dilatedMask == 0);

      // --- Step 3a: restore bottom 'borderAmount' rows from original image ---
      if (borderAmount > 0) {
        int bottomRows = std::min(borderAmount, h);
        owned.rowRange(h - bottomRows, h).copyTo(masked.rowRange(h - bottomRows, h));
      }

      //Log_d("Masked size [%d, %d]", masked.rows, masked.cols);

      //Log_d("maskRaisedBy done");

      // --- Step 4: return full-size masked image ---
      return [[MatWrapper alloc] initWithMat:masked];
      
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

+(MatWrapper *)brightenDarks:(MatWrapper *)image
                        mask:(MatWrapper *)mask
                      amount:(double)amount
{
  @try {
    try {
      cv::Mat mat = image.mat;
      cv::Mat maskMat = mask.mat;

      cv::Mat owned = mat;//.clone();
      cv::Mat ownedMask = maskMat;//.clone();
      if (owned.empty() || ownedMask.empty()) return image;

      //if (ownedMask.size() != owned.size()) {
        //cv::resize(ownedMask, ownedMask, owned.size(), 0, 0, cv::INTER_NEAREST);
      //}

      cv::Mat maskGray;
      if (ownedMask.channels() > 1)
        cv::cvtColor(ownedMask, maskGray, cv::COLOR_BGR2GRAY);
      else
        maskGray = ownedMask;

      cv::Mat binMask;
      cv::threshold(maskGray, binMask, 128, 255, cv::THRESH_BINARY);

      double factor = 1.0 + amount;
      factor = std::max(0.0001, factor); // prevent divide by zero

      cv::Mat result = owned.clone();
      for (int y = 0; y < owned.rows; y++) {
        const uint16_t* src = owned.ptr<uint16_t>(y);
        uint16_t* dst = result.ptr<uint16_t>(y);
        const uchar* m = binMask.ptr<uchar>(y);

        for (int x = 0; x < owned.cols * owned.channels(); x++) {
          if (m[x / owned.channels()] == 255) {
            dst[x] = cv::saturate_cast<uint16_t>(src[x] / factor);
          }
        }
      }

      return [[MatWrapper alloc] initWithMat: result];
      
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}



+(MatWrapper *)darkenDarks:(MatWrapper *)image
		      mask:(MatWrapper *)mask
		    amount:(double)amount
{
  @try {
    try {

      cv::Mat mat = image.mat;
      cv::Mat maskMat = mask.mat;

      cv::Mat owned = mat;//.clone();
      cv::Mat ownedMask = maskMat;//.clone();
      if (owned.empty() || ownedMask.empty()) return image;

      // Ensure mask matches image size
      //if (ownedMask.size() != owned.size()) {
      //cv::resize(ownedMask, ownedMask, owned.size(), 0, 0, cv::INTER_NEAREST);
      //}

      // Get binary mask: 255 = modify, 0 = keep
      cv::Mat maskGray;
      if (ownedMask.channels() > 1)
        cv::cvtColor(ownedMask, maskGray, cv::COLOR_BGR2GRAY);
      else
        maskGray = ownedMask;

      cv::Mat binMask;
      cv::threshold(maskGray, binMask, 128, 255, cv::THRESH_BINARY);

      double factor = 1.0 + amount;
      factor = std::max(0.0, factor);

      cv::Mat result = owned.clone(); // clone so we can mutate
      for (int y = 0; y < owned.rows; y++) {
        const uint16_t* src = owned.ptr<uint16_t>(y);
        uint16_t* dst = result.ptr<uint16_t>(y);
        const uchar* m = binMask.ptr<uchar>(y);

        for (int x = 0; x < owned.cols * owned.channels(); x++) {
          if (m[x / owned.channels()] == 255) {
            dst[x] = cv::saturate_cast<uint16_t>(src[x] * factor);
          }
        }
      }

      return [[MatWrapper alloc] initWithMat: result];
      
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

+(double)maxBrightnessScaleForImage:(MatWrapper *)image
                          maskImage:(MatWrapper *)mask
{
  @try {
    try {

      // now work with references
      cv::Mat mat = image.mat;
      cv::Mat maskMat = mask.mat;
    
      // make copies for safer concurrency
      cv::Mat owned = mat;//.clone();
      cv::Mat ownedMask = maskMat;//.clone();
      
      CV_Assert(owned.size() == ownedMask.size());
    
      // If your conversion gives 3/4 channels, force it to grayscale
      if (ownedMask.channels() > 1) {
        ownedMask = maskMat.clone();
        cv::cvtColor(ownedMask, ownedMask, cv::COLOR_BGR2GRAY);
      }

      // ownedMask is 0 for ground, 255 for sky → we want ground.
      cv::Mat groundMask;
      cv::bitwise_not(ownedMask, groundMask);

      // Just to be safe, enforce type
      CV_Assert(groundMask.type() == CV_8UC1);

      // Split into channels
      std::vector<cv::Mat> chans;
      cv::split(owned, chans);

      // Track maximum across all channels in the ground region
      double maxValOverall = 0.0;

      for (auto &ch : chans) {
        double minVal, maxVal;
        cv::minMaxLoc(ch, &minVal, &maxVal, nullptr, nullptr, groundMask);
        maxValOverall = std::max(maxValOverall, maxVal);
      }

      if (maxValOverall <= 0.0) {
        return 1.0; // avoid divide-by-zero
      }

      // Figure out max representable value based on depth
      double maxAllowed = 255.0;
      switch (owned.depth()) {
      case CV_8U:  maxAllowed = 255.0;   break;
      case CV_16U: maxAllowed = 65535.0; break;
      case CV_32F: maxAllowed = 1.0;     break;  // assuming normalized floats
      default:     maxAllowed = 255.0;   break;  // fallback
      }

      //Log_d("maxBrightnessScaleForImage done");
      return maxAllowed / maxValOverall;
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return 1;
}

+ (MatWrapper *)subtractImage:(MatWrapper *)img2 fromImage:(MatWrapper *)img1 {

  @try {
    try {
  
      // Step 1: Convert both images to grayscale if they are not already

      cv::Mat img1Mat = img1.mat;
      cv::Mat img2Mat = img2.mat;

      printMatInfo(img1Mat, "img1");
      printMatInfo(img2Mat, "img2");

      cv::Mat gray1, gray2;
    
      if (img1Mat.channels() == 1) {
        gray1 = img1Mat.clone();
      } else {
        cv::cvtColor(img1Mat, gray1, cv::COLOR_BGR2GRAY);
      }

      if (img2Mat.channels() == 1) {
        gray2 = img2Mat.clone();
      } else {
        cv::cvtColor(img2Mat, gray2, cv::COLOR_BGR2GRAY);
      }

      // Step 2: Determine the higher bit depth between the two images
      int depth1 = gray1.depth();
      int depth2 = gray2.depth();
      int targetDepth = std::max(depth1, depth2);

      // Map OpenCV depth constants to corresponding CV types
      int cvTargetType;
      switch (targetDepth) {
      case CV_8U:  cvTargetType = CV_8U; break;
      case CV_8S:  cvTargetType = CV_8S; break;
      case CV_16U: cvTargetType = CV_16U; break;
      case CV_16S: cvTargetType = CV_16S; break;
      case CV_32S: cvTargetType = CV_32S; break;
      case CV_32F: cvTargetType = CV_32F; break;
      case CV_64F: cvTargetType = CV_64F; break;
      default:     cvTargetType = CV_32F; break;
      }

      // Step 3: Convert both images to the target depth for subtraction
      cv::Mat gray1f, gray2f;
      gray1.convertTo(gray1f, cvTargetType);
      gray2.convertTo(gray2f, cvTargetType);

      // Step 4: Subtract img2 from img1
      cv::Mat diff;
    
      cv::subtract(gray1f, gray2f, diff);
    
      // Step 5: Clip negative values to zero
      cv::Mat diffClipped;
      cv::max(diff, 0, diffClipped);
    
      return [[MatWrapper alloc] initWithMat: diffClipped];
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}



@end


