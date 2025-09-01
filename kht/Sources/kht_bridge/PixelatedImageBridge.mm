#import "PixelatedImageBridge.h"


#include <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/highgui.hpp>



#include <memory>


#define LogWithLocation(fmt, ...) \
    NSLog((@"[%s:%d] " fmt), __FILE__, __LINE__, ##__VA_ARGS__)

// PixelatedImageBridge.mm

#import <opencv2/imgcodecs/macosx.h>

#include <set>        // for std::set

#import "HorizonResult.h"

@implementation PixelatedImageBridge

+ (Mat)filterConnectedComponents:(Mat)image keepLargest:(NSInteger)n {
    @try {
      try {
	// reinterpret as pointer
	cv::Mat* matPtr = reinterpret_cast<cv::Mat*>(image);

	// now work with references
	cv::Mat& mat = *matPtr;

	// make copy for safer concurrency
	cv::Mat owned = mat.clone();
    
	// If your conversion gives 3/4 channels, force it to grayscale
	if (owned.channels() > 1) {
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

	// make a new result on the heap XXX CLEAR THIS LATER WITH freeCvMat:
	cv::Mat* resultPtr = new cv::Mat(filtered);

	//delete matPtr;
	LogWithLocation(@"filterConnectedComponents done\n");
    
	return resultPtr;
      } catch (const cv::Exception &e) {
	LogWithLocation(@"OpenCV Exception: %s", e.what());
      }
    } @catch (NSException *exception) {
      LogWithLocation(@"Objective-C Exception: %@", exception);
    }
    return nil;
}

// this is the last step in horizon detection
+ (Mat)groundOnlyFrom:(Mat)image {
  @try {
    try {
      LogWithLocation(@"groundOnlyFrom started\n");
      // reinterpret as pointer
      cv::Mat* matPtr = reinterpret_cast<cv::Mat*>(image);

      // now work with references
      cv::Mat& mat = *matPtr;

      // make copy for safer concurrency
      cv::Mat owned = mat.clone();
    
      // If your conversion gives 3/4 channels, force it to grayscale
      if (owned.channels() > 1) {
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

      // make a new result on the heap XXX CLEAR THIS LATER WITH freeCvMat:
      cv::Mat* resultPtr = new cv::Mat(finalMask.clone());

      //delete matPtr;
      LogWithLocation(@"groundOnlyFrom done\n");
    
      return resultPtr;
    } catch (const cv::Exception &e) {
      LogWithLocation(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    LogWithLocation(@"Objective-C Exception: %@", exception);
  }
  return nil;    
}


+ (HorizonResult *)horizonExtentsFromImage:(Mat)image {
  @try {
    try {
      LogWithLocation(@"horizonExtentsFromImage started\n");
      // reinterpret as pointer
      cv::Mat* matPtr = reinterpret_cast<cv::Mat*>(image);

      // now work with references
      cv::Mat& mat = *matPtr;

      // make copy for safer concurrency
      cv::Mat owned = mat.clone();
      
      if (owned.empty()) {
        return nil;
      }

      cv::Mat gray, binary;
    
      // If not already grayscale, convert
      if (owned.channels() == 3) {
	cv::cvtColor(owned, gray, cv::COLOR_BGR2GRAY);
      } else if (owned.channels() == 4) {
	cv::cvtColor(owned, gray, cv::COLOR_BGRA2GRAY);
      } else if (owned.channels() == 1) {
	gray = owned; // already grayscale
      } else {
	LogWithLocation(@"Unsupported channel count: %d", owned.channels());
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
      LogWithLocation(@"horizonExtentsFromImage done\n");
      
      return [[HorizonResult alloc]
	       initWithHorizonTopY: horizonTopY
		    horizonBottomY: horizonBottomY];
    } catch (const cv::Exception &e) {
      LogWithLocation(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    LogWithLocation(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

// shifts mask up by borderAmount pixels and crops the image with it
+ (Mat)maskRaisedBy:(Mat)image
	       mask:(Mat)mask
	     border:(int)borderAmount
{
  @try {
    try {
      LogWithLocation(@"maskRaisedBy started\n");
      cv::Mat& mat = *reinterpret_cast<cv::Mat*>(image);
      cv::Mat& maskMat = *reinterpret_cast<cv::Mat*>(mask);

      // make copies for safer concurrency
      cv::Mat owned = mat.clone();
      cv::Mat ownedMask = maskMat.clone();
      
      CV_Assert(ownedMask.type() == CV_8UC1);
      CV_Assert(owned.rows == ownedMask.rows && owned.cols == ownedMask.cols);

      const int h = owned.rows;
      const int w = owned.cols;

      LogWithLocation(@"Original size [%d, %d]\n", h, w);

      // --- Step 1: create keep mask (zeros in ownedMask are keep) ---
      cv::Mat keepMask = (ownedMask == 0);  // 255 = keep, 0 = masked

      // Debug: original keep mask maxY
      std::vector<cv::Point> origNonZero;
      cv::findNonZero(keepMask, origNonZero);
      int origMaxY = 0;
      for (auto &p : origNonZero) if (p.y > origMaxY) origMaxY = p.y;
      LogWithLocation(@"Original keep mask maxY: %d\n", origMaxY);

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
      LogWithLocation(@"Dilated keep mask maxY: %d\n", dilatedMaxY);

      // --- Step 3: apply mask to image ---
      cv::Mat masked = owned.clone();
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

      LogWithLocation("Masked size [%d, %d]\n", masked.rows, masked.cols);

      LogWithLocation("maskRaisedBy done\n");

      // --- Step 4: return full-size masked image ---
      return new cv::Mat(masked);
    } catch (const cv::Exception &e) {
      LogWithLocation(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    LogWithLocation(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

+(Mat)brightenDarks:(Mat)image
	       mask:(Mat)mask
	     amount:(double)amount
{
  @try {
    try {
      LogWithLocation("brighten darks starting\n");

      // reinterpret as pointer
      cv::Mat* matPtr = reinterpret_cast<cv::Mat*>(image);
      cv::Mat* maskPtr = reinterpret_cast<cv::Mat*>(mask);

      // now work with references
      cv::Mat& mat = *matPtr;
      cv::Mat& maskMat = *maskPtr;

      // make copies for safer concurrency
      cv::Mat owned = mat.clone();
      cv::Mat ownedMask = maskMat.clone();
      
      //    cv::Mat mat = (cv::Mat)image
      //    cv::Mat maskMat = (cv::Mat)mask
      if (owned.empty() || ownedMask.empty()) {
        LogWithLocation(@"brightenDarks: empty mat or mask");
        return image;
      }

      // --- Build a proper binary 8-bit mask (255 = brighten, 0 = keep original) ---
      if (ownedMask.size() != owned.size()) {
        cv::resize(ownedMask, ownedMask, owned.size(), 0, 0, cv::INTER_NEAREST);
      }
      cv::Mat maskGray;
      if (ownedMask.channels() == 4)      cv::cvtColor(ownedMask, maskGray, cv::COLOR_BGRA2GRAY);
      else if (ownedMask.channels() == 3) cv::cvtColor(ownedMask, maskGray, cv::COLOR_BGR2GRAY);
      else                              maskGray = ownedMask;

      cv::Mat binMask;
      cv::threshold(maskGray, binMask, 128, 255, cv::THRESH_BINARY);
      CV_Assert(binMask.type() == CV_8UC1);

      // Invert so 255 = brighten, 0 = leave alone
      cv::Mat invMask;
      cv::bitwise_not(binMask, invMask);

      // --- Scale factor in fixed-point integer math ---
      double scale = 1.0 + amount;

      //LogWithLocation("bright scale %lf\n", scale);
      scale = std::max(0.0, scale);

      // Fixed-point scale (Q15 style: multiply then shift)
      int factor = (int)std::round(scale/* * 32768.0*/);  // 1.0 == 32768
      //int factor = (int)std::round(scale * 32768.0);  // 1.0 == 32768

      // --- Result starts as original (bit-for-bit preserved) ---
      cv::Mat result = owned.clone();

      // Apply scaling only where invMask==255
      for (int y = 0; y < owned.rows; y++) {
        const uint16_t* src = owned.ptr<uint16_t>(y);
        uint16_t* dst       = result.ptr<uint16_t>(y);
        const uchar* m      = invMask.ptr<uchar>(y);

        for (int x = 0; x < owned.cols * owned.channels(); x++) {
	  if (m[x / owned.channels()] == 255) {
	    // scale with saturation
	    uint32_t val = (uint32_t)src[x] * factor;
	    if (x%100 == 0) {
	      //		Log.d("at x \(x), val \(val) factor \(factor) src[\(x)] \(src[x])")
	    }
	    dst[x] = (val > 65535) ? 65535 : (uint16_t)val;
	  }
        }
      }

      //cv::imwrite("/tmp/result.png", result);

      // make a new result on the heap XXX CLEAR THIS LATER WITH freeCvMat:
      cv::Mat* resultPtr = new cv::Mat(result.clone());
      LogWithLocation("brighten darks returning\n");

      return resultPtr;
    } catch (const cv::Exception &e) {
      LogWithLocation(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    LogWithLocation(@"Objective-C Exception: %@", exception);
  }
  return nil;
}



+(Mat)darkenDarks:(Mat)image
	     mask:(Mat)mask
	   amount:(double)amount
{
  @try {
    try {
      LogWithLocation("darken darks start\n");
      // reinterpret as pointer
      cv::Mat* matPtr = reinterpret_cast<cv::Mat*>(image);
      cv::Mat* maskPtr = reinterpret_cast<cv::Mat*>(mask);

      // now work with references
      cv::Mat& mat = *matPtr;
      cv::Mat& maskMat = *maskPtr;

      // make copies for safer concurrency
      cv::Mat owned = mat.clone();
      cv::Mat ownedMask = maskMat.clone();
      
      if (owned.empty() || ownedMask.empty()) {
        LogWithLocation(@"brightenDarks: empty mat or mask");
        return image;
      }

      // --- Build a proper binary 8-bit mask (255 = brighten, 0 = keep original) ---
      if (ownedMask.size() != owned.size()) {
        cv::resize(ownedMask, ownedMask, owned.size(), 0, 0, cv::INTER_NEAREST);
      }
      cv::Mat maskGray;
      if (ownedMask.channels() == 4)      cv::cvtColor(ownedMask, maskGray, cv::COLOR_BGRA2GRAY);
      else if (ownedMask.channels() == 3) cv::cvtColor(ownedMask, maskGray, cv::COLOR_BGR2GRAY);
      else                              maskGray = ownedMask;

      cv::Mat binMask;
      cv::threshold(maskGray, binMask, 128, 255, cv::THRESH_BINARY);
      CV_Assert(binMask.type() == CV_8UC1);

      // Invert so 255 = brighten, 0 = leave alone
      cv::Mat invMask;
      cv::bitwise_not(binMask, invMask);

      // --- Scale factor in fixed-point integer math ---
      double scale = 1.0 + amount;
      scale = std::max(0.0, scale);

      //LogWithLocation("dark scale %lf\n", scale);
    
      // Fixed-point scale (Q15 style: multiply then shift)
      int factor = (int)std::round(scale/* * 32768.0*/);  // 1.0 == 32768
    
      // --- Result starts as original (bit-for-bit preserved) ---
      cv::Mat result = owned.clone();

      // Apply scaling only where invMask==255
      for (int y = 0; y < owned.rows; y++) {
        const uint16_t* src = owned.ptr<uint16_t>(y);
        uint16_t* dst       = result.ptr<uint16_t>(y);
        const uchar* m      = invMask.ptr<uchar>(y);

        for (int x = 0; x < owned.cols * owned.channels(); x++) {
	  if (m[x / owned.channels()] == 255) {
	    // scale with saturation
	    uint32_t val = (uint32_t)src[x] / factor;
	    if (x%10000 == 0) {
	      //LogWithLocation("at x %d, val %d factor %d src[%d] %d\n", x, val, factor, x, src[x]);
	    }
		
	    dst[x] = (val > 65535) ? 65535 : (uint16_t)val;
	  }
        }
      }

      //cv::imwrite("/tmp/result.png", result);

      // make a new result on the heap XXX CLEAR THIS LATER WITH freeCvMat:
      cv::Mat* resultPtr = new cv::Mat(result.clone());
      //LogWithLocation("darken darks returning\n");

      return resultPtr;
    } catch (const cv::Exception &e) {
      LogWithLocation(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    LogWithLocation(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

+(double)maxBrightnessScaleForImage:(Mat)image
			  maskImage:(Mat)mask
{
  @try {
    try {

      LogWithLocation("maxBrightnessScaleForImage started\n");
      // reinterpret as pointer
      cv::Mat* matPtr = reinterpret_cast<cv::Mat*>(image);
      cv::Mat* maskPtr = reinterpret_cast<cv::Mat*>(mask);

      // now work with references
      cv::Mat& mat = *matPtr;
      cv::Mat& maskMat = *maskPtr;
    
      // make copies for safer concurrency
      cv::Mat owned = mat.clone();
      cv::Mat ownedMask = maskMat.clone();
      
      CV_Assert(owned.size() == ownedMask.size());
    
      // If your conversion gives 3/4 channels, force it to grayscale
      if (ownedMask.channels() > 1) {
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

      LogWithLocation("maxBrightnessScaleForImage done\n");
      return maxAllowed / maxValOverall;
    } catch (const cv::Exception &e) {
      LogWithLocation(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    LogWithLocation(@"Objective-C Exception: %@", exception);
  }
  return 1;
}

+ (Mat)cvMatFromBuffer:(void *)buffer
                 width:(int)width
                height:(int)height
              channels:(int)channels
	bitsPerChannel:(int)bitsPerChannel
	   bytesPerRow:(int)bytesPerRow
{
  @try {
    try {
      int type = 0;
      switch (bitsPerChannel) {
      case 8:  type = CV_8UC(channels); break;
      case 16: type = CV_16UC(channels); break;
      case 32: type = CV_32SC(channels); break;
      default: return nullptr;
      }

      LogWithLocation(@"width %d, height %d, channels %d, bitsPerChannel %d bytesPerRow %d\n",
		      width, height, channels, bitsPerChannel, bytesPerRow);
      
      // free this with freeCvMat some time later
      cv::Mat *mat = new cv::Mat(height, width, type, buffer, bytesPerRow);
      return (Mat)mat;
    } catch (const cv::Exception &e) {
      LogWithLocation(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    LogWithLocation(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

+ (NSData *)dataFromCvMat:(Mat)matPtr {
    cv::Mat *mat = reinterpret_cast<cv::Mat *>(matPtr);
    return [NSData dataWithBytes:mat->data length:mat->total() * mat->elemSize()];
}

+ (int)matChannels:(Mat)matPtr {
    cv::Mat *mat = reinterpret_cast<cv::Mat *>(matPtr);
    return mat->channels();
}

+ (size_t)matElemSize:(Mat)matPtr {
    cv::Mat *mat = reinterpret_cast<cv::Mat *>(matPtr);
    return mat->elemSize();
}

+ (size_t)matStep:(Mat)matPtr {
    cv::Mat *mat = reinterpret_cast<cv::Mat *>(matPtr);
    return mat->step;
}

+ (void)freeCvMat:(Mat)matPtr {
    cv::Mat *mat = reinterpret_cast<cv::Mat *>(matPtr);
    //delete mat;
    // XXX deal with memory after it works XXX
}

@end


