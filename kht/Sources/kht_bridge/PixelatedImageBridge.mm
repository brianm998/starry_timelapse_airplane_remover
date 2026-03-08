#import "PixelatedImageBridge.h"
#import "MatWrapper_Internal.h"
#import "MatWrapper.h"

#import "logging.h"

#include <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/highgui.hpp>



#include <memory>

extern void printMatInfo(const cv::Mat& mat, const std::string& name = "");
extern cv::Mat ensure8U(const cv::Mat& input);

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

        cv::Mat matMaskThreshold;
        // threshold mask so all values are 0 or 0xFF
        cv::threshold(matMask,
                      matMaskThreshold,
                      128, // mid
                      255,
                      cv::THRESH_BINARY);

        cv::Mat mat1_3;      // will hold the 3-channel result
        cv::Mat mat2_3;      // will hold the 3-channel result

        // force images to be three channel
        cv::cvtColor(mat1, mat1_3, cv::COLOR_BGRA2BGR);
        cv::cvtColor(mat2, mat2_3, cv::COLOR_BGRA2BGR);
        
        // Combine images using mask
        // Non-zero in mask -> mat1; zero in mask -> mat2
        mat1_3.copyTo(result, matMaskThreshold); // Fill masked region with mat1
        cv::bitwise_not(matMaskThreshold, matMaskThreshold); // Invert mask to copy from mat2
        mat2_3.copyTo(result, matMaskThreshold); // Fill other region with mat2

        MatWrapper * ret = [[MatWrapper alloc] initWithMat: result];

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
      //Log_d(@"groundOnlyFrom started");

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


// a reverse of groundOnlyFrom
+ (MatWrapper *)skyOnlyFrom:(MatWrapper *)image {
  @try {
    try {
      //Log_d(@"groundOnlyFrom started");

      cv::Mat mat = image.mat;

      // make copy for safer concurrency
      cv::Mat owned = mat;
    
      // If your conversion gives 3/4 channels, force it to grayscale
      if (owned.channels() > 1) {
        owned = mat.clone();
        cv::cvtColor(owned, owned, cv::COLOR_BGR2GRAY);
      }
    
      // Ensure binary
      cv::Mat bin;
      cv::threshold(owned, bin, 127, 255, cv::THRESH_BINARY);

      // Connected components
      cv::Mat labels, stats, centroids;
      int nLabels = cv::connectedComponentsWithStats(bin, labels, stats, centroids, 8, CV_32S);

      // Collect all labels touching the top row
      std::set<int> topLabels;
      int topY = 0;
      for (int x = 0; x < labels.cols; x++) {
        int lbl = labels.at<int>(topY, x);
        if (lbl > 0) topLabels.insert(lbl);
      }

      // Build filtered mask: keep only top-connected components
      cv::Mat skyMask = cv::Mat::zeros(bin.size(), CV_8UC1);
      for (int y = 0; y < labels.rows; y++) {
        for (int x = 0; x < labels.cols; x++) {
          int lbl = labels.at<int>(y, x);
          if (topLabels.count(lbl)) {
            skyMask.at<uchar>(y, x) = 255;
          }
        }
      }

      return [[MatWrapper alloc] initWithMat: skyMask]; // XXX was cloned

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
      //Log_d(@"horizonExtentsFromImage started");

      cv::Mat mat = image.mat;

      if (mat.empty()) {
        Log_w(@"mat was empty :(");
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
        Log_w(@"Unsupported channel count: %d", owned.channels());
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
      //Log_d(@"horizonExtentsFromImage done");
      
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

      //printMatInfo(img1Mat, "img1");
      //printMatInfo(img2Mat, "img2");

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

+ (MatWrapper *)shiftImageUp:(MatWrapper *) input
                 shiftPixels:(int)shiftPixels
{
  @try {
    try {
      // Ensure a positive shift
      if (shiftPixels <= 0)
        return input;

      cv::Mat src = input.mat;
  
      // Limit shift so it never exceeds the image height
      int shift = std::min(shiftPixels, src.rows);

      // Create destination Mat of same size/type
      cv::Mat dst(src.size(), src.type());

      // Region that will be filled with the shifted image
      // dst[0 : rows-shift] = src[shift : rows]
      cv::Mat dstTop    = dst.rowRange(0, src.rows - shift);
      cv::Mat srcBottom = src.rowRange(shift, src.rows);
      srcBottom.copyTo(dstTop);

      // Fill the bottom 'shift' rows with the last existing row of src
      cv::Mat lastRow = src.row(src.rows - 1);
      for (int r = src.rows - shift; r < src.rows; r++) {
        lastRow.copyTo(dst.row(r));
      }

      return [[MatWrapper alloc] initWithMat: dst];
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

+ (MatWrapper *)cannyEdgeDetect:(MatWrapper *)img
                   minThreshold:(double)minThreshold
                   maxThreshold:(double)maxThreshold
                  useL2Gradient:(BOOL)useL2Gradient
{
  @try {
    try {
      cv::Mat input = img.mat;
  
      cv::Mat gray;
      if (input.channels() == 3)
        cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
      else
        gray = input.clone();
      
      // 1. Otsu threshold
      cv::Mat otsuMask;
      
      gray = ensure8U(gray);
      
      // 2. Canny edge detection
      cv::Mat edges;
      cv::Canny(gray,
                edges,
                minThreshold,
                maxThreshold,
                3,              // Sobel kernel size for finding image gradients
                useL2Gradient); // gradient magnitude equation
      
      return [[MatWrapper alloc] initWithMat: edges];
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

// this is not finished
+ (MatWrapper *)detectHorizon:(MatWrapper *)img {

  @try {
    try {
      cv::Mat input = img.mat;
  
      cv::Mat gray;
      if (input.channels() == 3)
        cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
      else
        gray = input.clone();

      // 1. Otsu threshold
      cv::Mat otsuMask;

      gray = ensure8U(gray);

      // 2. Canny edge detection
      cv::Mat edges;
      // good 
      //cv::Canny(gray, edges, 50, 150);

      // testing
      cv::Canny(gray, edges, 30, 150);

      // too much noise 
      //cv::Canny(gray, edges, 10, 150);
      

      
      Log_d(@"FUCK");
      /*
      // 3. Combine — weight edges more near Otsu boundary
      cv::Mat combined;
      cv::bitwise_or(otsuMask, edges, combined);

      // 4. Collapse vertically to find strongest transition row
      cv::Mat rowSum;
      cv::reduce(combined, rowSum, 1, cv::REDUCE_AVG);

      // 5. Smooth and find max gradient (horizon estimate)
      cv::Mat rowSumFloat;
      rowSum.convertTo(rowSumFloat, CV_32F);
      cv::GaussianBlur(rowSumFloat, rowSumFloat, cv::Size(1, 15), 0);

      double minVal, maxVal;
      int minIdx[2], maxIdx[2];
      cv::minMaxIdx(rowSumFloat, &minVal, &maxVal, minIdx, maxIdx);

      int horizonY = maxIdx[0];  // Row with strongest transition

      // 6. Optional: refine horizon locally (fit curve across columns)
      // You can repeat reduce() in small vertical windows around horizonY
      // to track ridge lines in more complex terrain.
      */
      return [[MatWrapper alloc] initWithMat: edges];
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

+ (MatWrapper *)bitwiseAnd:(MatWrapper *)img withImage:(MatWrapper *)img1 { 

  @try {
    try {
      cv::Mat input = img.mat;
      cv::Mat input1 = img1.mat;
      cv::Mat gray;
      if (input.channels() == 3)
        cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
      else
        gray = input;

      cv::Mat gray1;
      if (input1.channels() == 3)
        cv::cvtColor(input1, gray1, cv::COLOR_BGR2GRAY);
      else
        gray1 = input1;

      cv::Mat output;
      cv::bitwise_and(gray, gray1, output);

      return [[MatWrapper alloc] initWithMat: output];
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;

}

+ (MatWrapper *)bitwiseOr:(MatWrapper *)img withImage:(MatWrapper *)img1 {

  @try {
    try {
      cv::Mat input = img.mat;
      cv::Mat input1 = img1.mat;
      cv::Mat gray;
      if (input.channels() == 3)
        cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
      else
        gray = input;

      cv::Mat gray1;
      if (input1.channels() == 3)
        cv::cvtColor(input1, gray1, cv::COLOR_BGR2GRAY);
      else
        gray1 = input1;

      cv::Mat output;
      cv::bitwise_or(gray, gray1, output);

      return [[MatWrapper alloc] initWithMat: output];
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;

}

+ (MatWrapper *)bitwiseNot:(MatWrapper *)img {

  @try {
    try {
      cv::Mat input = img.mat;

      cv::Mat gray;
      if (input.channels() == 3)
        cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
      else
        gray = input;

      cv::Mat output;
      cv::bitwise_not(gray, output);

      return [[MatWrapper alloc] initWithMat: output];
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

/// Shrink dark regions (0-valued pixels) inward by `radius` pixels.
+ (MatWrapper *)shrinkDarkRegions:(MatWrapper *)img by:(int)radius {
  @try {
    try {
      cv::Mat binaryImage = img.mat;
  
      CV_Assert(binaryImage.type() == CV_8UC1);

      cv::Mat result;
      int kernelSize = 2 * radius + 1;
      cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(kernelSize, kernelSize));

      // Invert so dark becomes bright, erode bright areas to shrink them, then invert back.
      cv::Mat inverted;
      cv::bitwise_not(binaryImage, inverted);
      cv::erode(inverted, inverted, kernel);
      cv::bitwise_not(inverted, result);

      return [[MatWrapper alloc] initWithMat: result];
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

/// Expand dark regions (0-valued pixels) outward by `radius` pixels.
+ (MatWrapper *)growDarkRegions:(MatWrapper *)img by:(int)radius {
  @try {
    try {
      cv::Mat binaryImage = img.mat;
      //cv::Mat shrinkDarkRegions(const cv::Mat &binaryImage, int radius) {
      CV_Assert(binaryImage.type() == CV_8UC1);

      cv::Mat result;
      int kernelSize = 2 * radius + 1;
      cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(kernelSize, kernelSize));

      // Invert so dark becomes bright, dilate bright areas to expand them, then invert back.
      cv::Mat inverted;
      cv::bitwise_not(binaryImage, inverted);
      cv::dilate(inverted, inverted, kernel);
      cv::bitwise_not(inverted, result);

      return [[MatWrapper alloc] initWithMat: result];
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}


/// Dynamic programming horizon tracing.
/// Finds an optimal left-to-right path through the image that follows
/// strong horizontal edges using Sobel vertical gradients and Canny edges.
/// Returns a binary mask: white (255) = sky (above path), black (0) = ground (below path).
+ (MatWrapper *)dpHorizonMask:(MatWrapper *)img
                     cannyMin:(double)cannyMin
                     cannyMax:(double)cannyMax
                useL2Gradient:(BOOL)useL2Gradient
            smoothnessLambda:(double)smoothnessLambda
                 sobelWeight:(double)sobelWeight
                 cannyWeight:(double)cannyWeight
           searchTopFraction:(double)searchTopFraction
        searchBottomFraction:(double)searchBottomFraction
{
  @try {
    try {
      cv::Mat input = img.mat;

      // Convert to grayscale
      cv::Mat gray;
      if (input.channels() == 4)
        cv::cvtColor(input, gray, cv::COLOR_BGRA2GRAY);
      else if (input.channels() == 3)
        cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
      else
        gray = input.clone();

      gray = ensure8U(gray);

      int rows = gray.rows;
      int cols = gray.cols;
      if (rows < 2 || cols < 2) {
        Log_e(@"dpHorizonMask: image too small (%dx%d)", cols, rows);
        return nil;
      }

      // Compute the search band (the vertical region where the horizon could be)
      int searchTop = std::max(0, (int)(rows * searchTopFraction));
      int searchBottom = std::min(rows - 1, (int)(rows * searchBottomFraction));
      int bandHeight = searchBottom - searchTop + 1;
      if (bandHeight < 2) {
        Log_e(@"dpHorizonMask: search band too small (top=%d, bottom=%d)", searchTop, searchBottom);
        return nil;
      }

      // --- Step 1: Compute Sobel vertical gradient magnitude ---
      // The absolute vertical gradient highlights horizontal edges
      // (transitions from sky to ground or vice versa)
      cv::Mat sobelY;
      cv::Sobel(gray, sobelY, CV_32F, 0, 1, 3); // dy, kernel size 3
      cv::Mat absSobelY;
      cv::convertScaleAbs(sobelY, absSobelY); // back to 8-bit absolute

      // Normalize to [0, 1] range for cost computation
      cv::Mat sobelNorm;
      absSobelY.convertTo(sobelNorm, CV_32F, 1.0 / 255.0);

      // --- Step 2: Compute Canny edges ---
      cv::Mat edges;
      cv::Canny(gray, edges, cannyMin, cannyMax, 3, useL2Gradient);

      // Normalize Canny to [0, 1]
      cv::Mat cannyNorm;
      edges.convertTo(cannyNorm, CV_32F, 1.0 / 255.0);

      // --- Step 3: Build cost image (lower cost = more likely horizon) ---
      // Cost = baseCost - sobelWeight * |Sobel_y| - cannyWeight * Canny
      // We want the DP to find the minimum-cost path, attracted to strong
      // gradients and edges.
      double baseCost = 1.0;
      cv::Mat costImage(rows, cols, CV_32F);
      for (int y = 0; y < rows; y++) {
        float *costRow = costImage.ptr<float>(y);
        const float *sobelRow = sobelNorm.ptr<float>(y);
        const float *cannyRow = cannyNorm.ptr<float>(y);
        for (int x = 0; x < cols; x++) {
          double cost = baseCost - sobelWeight * sobelRow[x] - cannyWeight * cannyRow[x];
          // Clamp to a small positive value to avoid negative costs
          costRow[x] = (float)std::max(0.01, cost);
        }
      }

      // Add penalty for being outside the search band.
      // Pixels outside the expected horizon region get very high cost.
      for (int y = 0; y < rows; y++) {
        if (y < searchTop || y > searchBottom) {
          float *costRow = costImage.ptr<float>(y);
          for (int x = 0; x < cols; x++) {
            costRow[x] = 100.0f; // very high cost, effectively excluded
          }
        }
      }

      // --- Step 4: Dynamic programming (left to right) ---
      // DP[x][y] = minimum cost to reach pixel (x, y) from the left edge.
      // Transition from column x-1 to column x incurs a smoothness penalty
      // proportional to the vertical displacement |y - y'|.
      //
      // This is equivalent to seam carving but applied horizontally.
      // For efficiency, we use the O(n) distance transform trick:
      // process top-to-bottom and bottom-to-top in each column.

      // Allocate DP state.
      // We only need two columns of DP values (previous and current),
      // but we need the full backtrack table for the backtrace.
      std::vector<float> dpPrev(bandHeight, 0);
      std::vector<float> dpCurr(bandHeight, 0);
      std::vector<std::vector<int>> backtrack(cols, std::vector<int>(bandHeight, 0));

      // Initialize first column
      for (int by = 0; by < bandHeight; by++) {
        dpPrev[by] = costImage.at<float>(searchTop + by, 0);
        backtrack[0][by] = by;
      }

      // Reusable buffers for the two-pass approach
      std::vector<float> bestFromAbove(bandHeight);
      std::vector<int> bestIdxFromAbove(bandHeight);
      std::vector<float> bestFromBelow(bandHeight);
      std::vector<int> bestIdxFromBelow(bandHeight);

      // Fill DP table column by column
      float lambda = (float)smoothnessLambda;
      for (int x = 1; x < cols; x++) {
        // For each row in this column, find the minimum (dpPrev[y'] + lambda * |y - y'|)
        // This can be done in O(bandHeight) using two passes:
        // Pass 1: top-to-bottom, propagating the minimum cost downward
        // Pass 2: bottom-to-top, propagating the minimum cost upward

        // Top-down pass
        bestFromAbove[0] = dpPrev[0];
        bestIdxFromAbove[0] = 0;
        for (int by = 1; by < bandHeight; by++) {
          float candidate = dpPrev[by];
          float propagated = bestFromAbove[by-1] + lambda;
          if (candidate <= propagated) {
            bestFromAbove[by] = candidate;
            bestIdxFromAbove[by] = by;
          } else {
            bestFromAbove[by] = propagated;
            bestIdxFromAbove[by] = bestIdxFromAbove[by-1];
          }
        }

        // Bottom-up pass
        bestFromBelow[bandHeight-1] = dpPrev[bandHeight-1];
        bestIdxFromBelow[bandHeight-1] = bandHeight-1;
        for (int by = bandHeight - 2; by >= 0; by--) {
          float candidate = dpPrev[by];
          float propagated = bestFromBelow[by+1] + lambda;
          if (candidate <= propagated) {
            bestFromBelow[by] = candidate;
            bestIdxFromBelow[by] = by;
          } else {
            bestFromBelow[by] = propagated;
            bestIdxFromBelow[by] = bestIdxFromBelow[by+1];
          }
        }

        // Combine: take the min of the two passes.
        // bestFromAbove[by] already includes the smoothness cost from the
        // best source row to by. Same for bestFromBelow[by].
        for (int by = 0; by < bandHeight; by++) {
          float localCost = costImage.at<float>(searchTop + by, x);

          if (bestFromAbove[by] <= bestFromBelow[by]) {
            dpCurr[by] = localCost + bestFromAbove[by];
            backtrack[x][by] = bestIdxFromAbove[by];
          } else {
            dpCurr[by] = localCost + bestFromBelow[by];
            backtrack[x][by] = bestIdxFromBelow[by];
          }
        }

        // Swap current and previous for next iteration
        std::swap(dpPrev, dpCurr);
      }

      // After the loop, dpPrev holds the last column's values

      // --- Step 5: Backtrace to find the optimal path ---
      std::vector<int> horizonPath(cols);

      // Find the minimum cost in the last column
      int bestEndY = 0;
      float bestEndCost = dpPrev[0];
      for (int by = 1; by < bandHeight; by++) {
        if (dpPrev[by] < bestEndCost) {
          bestEndCost = dpPrev[by];
          bestEndY = by;
        }
      }
      horizonPath[cols-1] = searchTop + bestEndY;

      // Backtrace
      int currentBy = bestEndY;
      for (int x = cols - 2; x >= 0; x--) {
        currentBy = backtrack[x+1][currentBy];
        horizonPath[x] = searchTop + currentBy;
      }

      // --- Step 6: Generate binary mask ---
      // White (255) above the horizon path = sky
      // Black (0) at and below the horizon path = ground
      cv::Mat mask = cv::Mat::zeros(rows, cols, CV_8UC1);
      for (int x = 0; x < cols; x++) {
        int horizY = horizonPath[x];
        // Fill sky (above horizon) with white
        for (int y = 0; y < horizY; y++) {
          mask.at<uchar>(y, x) = 255;
        }
        // Everything at horizY and below stays black (ground)
      }

      return [[MatWrapper alloc] initWithMat: mask];
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception in dpHorizonMask: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception in dpHorizonMask: %@", exception);
  }
  return nil;
}

+ (nullable MatWrapper *)warpImage:(MatWrapper *)image
                    withHomography:(MatWrapper *)homography {
    @try {
        try {
            cv::Mat warped;
            cv::warpPerspective(image.mat,
                                warped,
                                homography.mat,
                                image.mat.size(),
                                cv::INTER_LINEAR,
                                cv::BORDER_CONSTANT,
                                cv::Scalar(0, 0, 0, 0));
            return [[MatWrapper alloc] initWithMat:warped];
        } catch (const cv::Exception &e) {
            Log_e(@"warpImage: cv exception: %s", e.what());
        }
    } @catch (NSException *ex) {
        Log_e(@"warpImage: exception: %@", ex);
    }
    return nil;
}

+ (nullable MatWrapper *)absDiffGrayscale:(MatWrapper *)image1
                                withImage:(MatWrapper *)image2 {
    @try {
        try {
            cv::Mat gray1, gray2;
            // Convert both to 8-bit grayscale
            cv::Mat src1 = ensure8U(image1.mat);
            cv::Mat src2 = ensure8U(image2.mat);
            if (src1.channels() == 1) {
                gray1 = src1;
            } else if (src1.channels() == 4) {
                cv::cvtColor(src1, gray1, cv::COLOR_BGRA2GRAY);
            } else if (src1.channels() == 3) {
                cv::cvtColor(src1, gray1, cv::COLOR_BGR2GRAY);
            } else {
                return nil;
            }
            if (src2.channels() == 1) {
                gray2 = src2;
            } else if (src2.channels() == 4) {
                cv::cvtColor(src2, gray2, cv::COLOR_BGRA2GRAY);
            } else if (src2.channels() == 3) {
                cv::cvtColor(src2, gray2, cv::COLOR_BGR2GRAY);
            } else {
                return nil;
            }
            cv::Mat diff;
            cv::absdiff(gray1, gray2, diff);
            return [[MatWrapper alloc] initWithMat:diff];
        } catch (const cv::Exception &e) {
            Log_e(@"absDiffGrayscale: cv exception: %s", e.what());
        }
    } @catch (NSException *ex) {
        Log_e(@"absDiffGrayscale: exception: %@", ex);
    }
    return nil;
}

+ (nullable MatWrapper *)warpHorizonMask:(MatWrapper *)mask
                          withHomography:(MatWrapper *)homography {
    @try {
        try {
            cv::Mat warped;
            // INTER_NEAREST preserves binary 0/255 values.
            // BORDER_CONSTANT with Scalar(255,255,255,255) fills out-of-bounds
            // regions with white (sky) so warp borders are not confused with ground.
            cv::warpPerspective(mask.mat, warped, homography.mat,
                                mask.mat.size(),
                                cv::INTER_NEAREST,
                                cv::BORDER_CONSTANT,
                                cv::Scalar(255, 255, 255, 255));
            return [[MatWrapper alloc] initWithMat:warped];
        } catch (const cv::Exception &e) {
            Log_e(@"warpHorizonMask: cv exception: %s", e.what());
        }
    } @catch (NSException *ex) {
        Log_e(@"warpHorizonMask: exception: %@", ex);
    }
    return nil;
}

+ (nullable MatWrapper *)meanOfImages:(NSArray<MatWrapper *> *)images {
    if (images.count == 0) return nil;
    @try {
        try {
            const cv::Mat &first = images[0].mat;
            cv::Mat accum = cv::Mat::zeros(first.size(), CV_32F);
            for (MatWrapper *img in images) {
                cv::Mat f;
                img.mat.convertTo(f, CV_32F);
                accum += f;
            }
            accum /= (float)images.count;
            cv::Mat result;
            accum.convertTo(result, CV_8U);
            return [[MatWrapper alloc] initWithMat:result];
        } catch (const cv::Exception &e) {
            Log_e(@"meanOfImages: cv exception: %s", e.what());
        }
    } @catch (NSException *ex) {
        Log_e(@"meanOfImages: exception: %@", ex);
    }
    return nil;
}

+ (MatWrapper *)binaryHorizonMaskWithWidth:(int)width
                                    height:(int)height
                                  horizonY:(NSArray<id> *)horizonY {
    cv::Mat mask(height, width, CV_8UC1, cv::Scalar(255)); // start all-white (sky)
    for (int x = 0; x < width && x < (int)horizonY.count; x++) {
        id val = horizonY[x];
        if ([val isKindOfClass:[NSNull class]]) continue;
        int y = [(NSNumber *)val intValue];
        if (y < 0) y = 0;
        if (y > height) y = height;
        // Set rows [y, height) to black (ground)
        for (int row = y; row < height; row++) {
            mask.at<uchar>(row, x) = 0;
        }
    }
    return [[MatWrapper alloc] initWithMat:mask];
}

@end


