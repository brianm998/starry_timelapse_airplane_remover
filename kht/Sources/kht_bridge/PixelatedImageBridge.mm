#import "PixelatedImageBridge.h"


#include <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/highgui.hpp>



#include <memory>

extern void printMatInfo(const cv::Mat& mat, const std::string& name = "");


#define LogWithLocation(fmt, ...) \
    NSLog((@"[%s:%d] " fmt), __FILE__, __LINE__, ##__VA_ARGS__)

// PixelatedImageBridge.mm

#import <opencv2/imgcodecs/macosx.h>

#include <set>        // for std::set

#import "HorizonResult.h"

@implementation PixelatedImageBridge

+ (Mat)combineImage:(Mat)image1
               mask:(Mat)mask
         background:(Mat)image2
{
    @try {
      try {
	// Reinterpret the opaque Mat pointers back to cv::Mat references
	cv::Mat& mat1 = *reinterpret_cast<cv::Mat*>(image1);
	cv::Mat& matMask = *reinterpret_cast<cv::Mat*>(mask);
	cv::Mat& mat2 = *reinterpret_cast<cv::Mat*>(image2);

	// Safety check: ensure sizes match
	if (mat1.size() != mat2.size() || mat1.size() != matMask.size()) {
	  NSLog(@"combineWithMask: Input Mats must have the same size.");
	  return reinterpret_cast<Mat>(new cv::Mat()); // Return empty Mat
	}

	// Prepare output Mat
	cv::Mat result;
	result.create(mat1.size(), mat1.type());

	// Combine images using mask
	// Non-zero in mask -> mat1; zero in mask -> mat2
	mat1.copyTo(result, matMask);         // Fill masked region with mat1
	cv::bitwise_not(matMask, matMask);     // Invert mask to copy from mat2
	mat2.copyTo(result, matMask);         // Fill other region with mat2


	// make a new result on the heap XXX CLEAR THIS LATER WITH freeCvMat:
	cv::Mat* resultPtr = new cv::Mat(result);
	
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
// does this really work?
+ (Mat)maskRaisedBy:(Mat)image
	       mask:(Mat)mask
	     border:(int)borderAmount
{
  @try {
    try {
      //LogWithLocation(@"maskRaisedBy started\n");
      cv::Mat& mat = *reinterpret_cast<cv::Mat*>(image);
      cv::Mat& maskMat = *reinterpret_cast<cv::Mat*>(mask);

      // make copies for safer concurrency
      cv::Mat owned = mat.clone();
      cv::Mat ownedMask = maskMat.clone();
      
      CV_Assert(ownedMask.type() == CV_8UC1);
      CV_Assert(owned.rows == ownedMask.rows && owned.cols == ownedMask.cols);

      const int h = owned.rows;
      const int w = owned.cols;

      //LogWithLocation(@"Original size [%d, %d]\n", h, w);

      // --- Step 1: create keep mask (zeros in ownedMask are keep) ---
      cv::Mat keepMask = (ownedMask == 0);  // 255 = keep, 0 = masked

      // Debug: original keep mask maxY
      std::vector<cv::Point> origNonZero;
      cv::findNonZero(keepMask, origNonZero);
      int origMaxY = 0;
      for (auto &p : origNonZero) if (p.y > origMaxY) origMaxY = p.y;
      //LogWithLocation(@"Original keep mask maxY: %d\n", origMaxY);

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
      //LogWithLocation(@"Dilated keep mask maxY: %d\n", dilatedMaxY);

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

      //LogWithLocation("Masked size [%d, %d]\n", masked.rows, masked.cols);

      //LogWithLocation("maskRaisedBy done\n");

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

      cv::Mat &mat = *reinterpret_cast<cv::Mat*>(image);
      cv::Mat &maskMat = *reinterpret_cast<cv::Mat*>(mask);

      cv::Mat owned = mat.clone();
      cv::Mat ownedMask = maskMat.clone();
      if (owned.empty() || ownedMask.empty()) return image;

      if (ownedMask.size() != owned.size()) {
	cv::resize(ownedMask, ownedMask, owned.size(), 0, 0, cv::INTER_NEAREST);
      }

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

      return new cv::Mat(result.clone());
      
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

      cv::Mat &mat = *reinterpret_cast<cv::Mat*>(image);
      cv::Mat &maskMat = *reinterpret_cast<cv::Mat*>(mask);

      cv::Mat owned = mat.clone();
      cv::Mat ownedMask = maskMat.clone();
      if (owned.empty() || ownedMask.empty()) return image;

      // Ensure mask matches image size
      if (ownedMask.size() != owned.size()) {
	cv::resize(ownedMask, ownedMask, owned.size(), 0, 0, cv::INTER_NEAREST);
      }

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

      cv::Mat result = owned.clone();
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

      return new cv::Mat(result.clone());
      
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

      //LogWithLocation("maxBrightnessScaleForImage started\n");
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

      //LogWithLocation("maxBrightnessScaleForImage done\n");
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

      // Create a temporary header referencing the provided buffer
      cv::Mat tmp(height, width, type, buffer, bytesPerRow);

      // Clone into an owning mat and heap-allocate that one (caller must free)
      cv::Mat *mat = new cv::Mat(tmp.clone());
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
  try {
    cv::Mat *mat = reinterpret_cast<cv::Mat *>(matPtr);
    return [NSData dataWithBytes:mat->data length:mat->total() * mat->elemSize()];
  } catch (const cv::Exception &e) {
    LogWithLocation(@"OpenCV Exception: %s", e.what());
  }
  return NULL;
}

+ (int)matChannels:(Mat)matPtr {
    cv::Mat *mat = reinterpret_cast<cv::Mat *>(matPtr);
    return mat->channels();
}

+ (size_t)matElemSize:(Mat)matPtr {
    cv::Mat *mat = reinterpret_cast<cv::Mat *>(matPtr);
    return mat->elemSize();
}

+ (BOOL)matIsEmpty:(Mat)matPtr {
    cv::Mat *mat = reinterpret_cast<cv::Mat *>(matPtr);
    return mat->empty();
}

+ (size_t)matStep:(Mat)matPtr {
    cv::Mat *mat = reinterpret_cast<cv::Mat *>(matPtr);
    return mat->step;
}

+ (void)freeCvMat:(Mat)matPtr {
  if (!matPtr) return;
  cv::Mat *mat = reinterpret_cast<cv::Mat *>(matPtr);
  delete mat;
}

+ (Mat)subtractImage:(Mat)img2 fromImage:(Mat)img1 {
    // Step 1: Convert both images to grayscale if they are not already

  cv::Mat *img1Mat = reinterpret_cast<cv::Mat *>(img1);
  cv::Mat *img2Mat = reinterpret_cast<cv::Mat *>(img2);

  cv::Mat gray1, gray2;
    
    if (img1Mat->channels() == 1) {
        gray1 = img1Mat->clone();
    } else {
      cv::cvtColor(*img1Mat, gray1, cv::COLOR_BGR2GRAY);
    }

    if (img2Mat->channels() == 1) {
        gray2 = img2Mat->clone();
    } else {
        cv::cvtColor(*img2Mat, gray2, cv::COLOR_BGR2GRAY);
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
    printMatInfo(diffClipped, "result");

    cv::Mat* resultPtr = new cv::Mat(diffClipped);

    return resultPtr;
}



@end


