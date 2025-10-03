#import "ImageAligner.h"
#import "MatWrapper_Internal.h"
#import "logging.h"
#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/features2d.hpp>
#import <opencv2/calib3d.hpp>
#include <opencv2/opencv.hpp>
#include <iostream>


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
MatWrapper * medianImageFromArray(const std::vector<MatWrapper *>& mats, double k) {
  if (mats.empty()) {
    Log_w(@"given empty mats, returning one too :(");
    return [[MatWrapper alloc] initWithMat: cv::Mat()];
  }

    // grab first image to read its characteristics
    MatWrapper * first = mats[0];

    // image height
    int rows = first.mat.rows;

    // image width
    int cols = first.mat.cols;

    // channels per pixel
    int ch   = first.mat.channels();

    // size of each channel
    int depth = first.mat.depth();

    // how many incoming images we're dealing with
    int n    = static_cast<int>(mats.size());

    // basic validation
    for (int i = 1; i < n; ++i) {
      if (mats[i].mat.rows != rows || mats[i].mat.cols != cols || mats[i].mat.type() != first.mat.type()) {
            throw std::runtime_error("All mats must have same size and type");
        }
    }
    if (ch != 1 && ch != 3 && ch != 4) {
        throw std::runtime_error("Unsupported channel count");
    }

    cv::Mat output(rows, cols, first.mat.type());

    if (depth == CV_8U) {
        // 8-bit per channel
        for (int y = 0; y < rows; ++y) {
            const uchar* rowPtrs[n];
            for (int i = 0; i < n; ++i) rowPtrs[i] = mats[i].mat.ptr<uchar>(y);
            uchar* outRow = output.ptr<uchar>(y);

            for (int x = 0; x < cols; ++x) {
                int vals[4][n]; // up to 4 channels, up to n mats
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
		    int minIndex = 0;
		    for(int z = 0 ; z < n ; ++z) {
		      char value = vals[c][z];
		      if(value == 0) {
			minIndex = z + 1;
		      }

		      if((double)vals[c][z] < threshold) {
			maxIndex = z;
		      } else {
			break;
		      }
		    }
		    int index = (minIndex+maxIndex)/2;
		    if(index >= n) { index = n - 1; }
                    outRow[x * ch + c] = static_cast<uchar>(vals[c][index]);
                }
            }
        }
    } else if (depth == CV_16U) {
        // 16-bit per channel
        for (int y = 0; y < rows; ++y) {
            const uint16_t* rowPtrs[n];
            for (int i = 0; i < n; ++i) rowPtrs[i] = mats[i].mat.ptr<uint16_t>(y);
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
		    int minIndex = 0;
		    // throw out pixels with value zero at the bottom
		    // throw out pixels with too much statistal variation at the top
		    for(int z = 0 ; z < n ; ++z) {
		      uint16_t value = vals[c][z];
		      if(value == 0) {
			minIndex = z + 1;
		      }
		      if((double)value < threshold) {
			maxIndex = z;
		      } else {
			break;
		      }
		    }

		    // choose the median between the given bounds
		    int index = (minIndex+maxIndex)/2;

		    // make sure we don't overrun
		    if(index >= n) { index = n - 1; }

		    // actual set the output pixel to the given value
                    outRow[x * ch + c] = static_cast<uint16_t>(vals[c][index]);
                }
            }
        }
    } else {
        throw std::runtime_error("Unsupported element depth (only CV_8U and CV_16U implemented)");
    }

  if(output.empty()) {
    Log_w(@"empty mat");
  }
    printMatInfo(output, "image align output");
    
    return [[MatWrapper alloc] initWithMat: output];
}

// tries to match the base mat from the aligned mats
// preserves too much bad signal, but does keep clouds in the right place
cv::Mat matchingImageFromArray(const cv::Mat & baseMat, const std::vector<cv::Mat>& mats, double k) {
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

    if (baseMat.rows != rows || baseMat.cols != cols || baseMat.type() != first.type()) {
      throw std::runtime_error("base mat must be the same size as the first vector mat");
    }
    
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
            for (int i = 0; i < n; ++i) {
	      rowPtrs[i] = mats[i].ptr<uchar>(y);
	    }
            uchar* outRow = output.ptr<uchar>(y);
            const uchar* baseRow = baseMat.ptr<uchar>(y);

            for (int x = 0; x < cols; ++x) {
                int vals[4][n]; // up to 4 channels, up to n mats
                for (int i = 0; i < n; ++i) {
                    const uchar* pix = rowPtrs[i] + x * ch; // bytes-per-pixel = ch * 1
                    for (int c = 0; c < ch; ++c) vals[c][i] = pix[c];
                }
                for (int c = 0; c < ch; ++c) {
                    std::sort(vals[c], vals[c] + n);

		    // sort values for this pixel component across images
                    std::sort(vals[c], vals[c] + n);

		    uchar baseValue = *(baseRow + x * ch);
		    /*
		      find the value which is closest to the base, and use that
		     */
		    int best_index = 0;
		    uchar best_value = 0;
		    uchar best_diff = 0xFF;
		      
		    for(int z = 0 ; z < n ; ++z) {
		      uchar diff = abs(baseValue - vals[c][z]);
		      if(diff < best_diff) {
			best_index = z;
			best_value = vals[c][z];
			best_diff = diff;
		      }
		    }
		    
                    outRow[x * ch + c] = static_cast<uchar>(vals[c][best_index]);
                }
            }
        }
    } else if (depth == CV_16U) {
        // 16-bit per channel
        for (int y = 0; y < rows; ++y) {
            const uint16_t* rowPtrs[n];
            for (int i = 0; i < n; ++i) {
	      rowPtrs[i] = mats[i].ptr<uint16_t>(y);
	    }
            uint16_t* outRow = output.ptr<uint16_t>(y);
            const uint16_t* baseRow = baseMat.ptr<uint16_t>(y);

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

		    uint16_t baseValue = *(baseRow + x * ch);
		    /*
		      find the value which is closest to the base, and use that
		     */
		    int best_index = 0;
		    uint16_t best_value = 0;
		    uint16_t best_diff = 0xFFFF;
		      
		    for(int z = 0 ; z < n ; ++z) {
		      uint16_t diff = abs(baseValue - vals[c][z]);
		      if(diff < best_diff) {
			best_index = z;
			best_value = vals[c][z];
			best_diff = diff;
		      }
		    }
		    
                    outRow[x * ch + c] = static_cast<uint16_t>(vals[c][best_index]);
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
  also nicely combines the aligned images weeding out bad signals
 */

// gradients into the zero area of the mask
MatWrapper * createGradientMask(const cv::Mat &binaryMask, int gradientDistance) {
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

    return [[MatWrapper alloc] initWithMat: output];
}

// gradients into the non-zero area of the sky
MatWrapper * createGradientMaskIntoSky(const cv::Mat &binaryMask, int gradientDistance) {
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

    return [[MatWrapper alloc] initWithMat: output];
}



// Convert image to 8-bit grayscale, normalize only within mask area
MatWrapper * toGray8UWithMask(const cv::Mat& src, const cv::Mat& mask, bool normalize = true) {
    if (src.empty()) {
        throw std::runtime_error("Input image is empty!");
    }

    cv::Mat gray;
    if (src.channels() > 1) {
      cv::cvtColor(src, gray, cv::COLOR_BGR2GRAY);
    } else {
      gray = src.clone(); // this clone is necessary as we mutate gray later in this method
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
            tmp = gray;//.clone(); // we should be able to get rid of this clone as we own grey
        }
    }

    // Convert to grayscale if needed
    if (tmp.channels() > 1) {
        cv::cvtColor(tmp, tmp, cv::COLOR_BGR2GRAY);
    }

    return [[MatWrapper alloc] initWithMat: tmp];
}

// Convert any depth image to 8-bit grayscale for SIFT
MatWrapper * toGray8U(MatWrapper * src) {
    if (src.mat.empty()) {
        throw std::runtime_error("Input image is empty!");
    }

    cv::Mat tmp;
    // Handle 16-bit
    if (src.mat.depth() == CV_16U) {
        src.mat.convertTo(tmp, CV_8U, 1.0 / 256.0);
    }
    // Handle 32-bit float/int
    else if (src.mat.depth() != CV_8U) {
        double minVal, maxVal;
        cv::minMaxLoc(src.mat, &minVal, &maxVal);
        double scale = maxVal > 0 ? 255.0 / maxVal : 1.0;
        src.mat.convertTo(tmp, CV_8U, scale);
    }
    else {
      // should probably keep this clone as we _might_ mutate tmp below 
      tmp = src.mat.clone();
    }

    // Convert to grayscale if needed
    if (tmp.channels() > 1) {
        cv::cvtColor(tmp, tmp, cv::COLOR_BGR2GRAY);
    }

    return [[MatWrapper alloc] initWithMat: tmp];
}

+(MatWrapper *)createGradientMaskIntoSky:(MatWrapper*)binaryMask
			gradientDistance:(int)gradientDistance
{
  return createGradientMaskIntoSky(binaryMask.mat, gradientDistance);
}

+(MatWrapper *)createGradientMaskIntoGround:(MatWrapper*)binaryMask
			   gradientDistance:(int)gradientDistance
{
  return createGradientMask(binaryMask.mat, gradientDistance);
}


// Helper: compute star mask from special frame
static MatWrapper * makeStarMask(const cv::Mat &gray, int dilateSize = 3, int thresholdVal = 200) {
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
    return [[MatWrapper alloc] initWithMat: mask];
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
+ (id)alignFrames:(MatWrapper *)special
           frames:(NSArray<MatWrapper *> *)frames
      matchMethod:(FeatureMatchMethod)matchMethod
             mask:(MatWrapper *)mask // assumed to be zero for ground, non-zero for sky
     maxDeviation:(double)maxDeviation
maxCornerDeviation:(double)maxCornerDeviation
       invertMask:(BOOL)invertMask // true when processing ground, false for sky
     maxKeypoints:(int)maxKeypoints
 outlierThreshold:(double)k
{
  try {
    // how far vertically to extend the horizon mask when inverted
    int horizonExtension = 100; // XXX make this a parameter?

    // how many threads opencv can use
    cv::setNumThreads(36);    // XXX make this a parameter?

    // random logID
    uint32_t logID = arc4random_uniform(1000);

    // Horizon mask (sky = nonzero, ground = 0)
    MatWrapper * horizonMask;
    if (mask != NULL && !mask.mat.empty()) {
      // use passed in horizon mask
      horizonMask = mask;
    } else {
      // if no horizon mask is passed, assume a fully white mask (all pixels)
      horizonMask = [[MatWrapper alloc]
                      initWithMat:cv::Mat(special.mat.size(), CV_8U, cv::Scalar(255))];
    }

    horizonMask = toGray8U(horizonMask);

    if (invertMask) {
      // invert the mask to apply to the ground instead of the sky
      cv::bitwise_not(horizonMask.mat, horizonMask.mat);

      // for the ground, we make the horizon mask include a bit above the horizon,
      // which leads to better keypoints down the road
      horizonMask = createGradientMaskIntoSky(horizonMask.mat, horizonExtension);
    }

    // Prepare grayscale special frame with the horizon mask
    MatWrapper * specialGray = toGray8UWithMask(special.mat, horizonMask.mat, true);

    // default to deteting with the horizon mask as is
    MatWrapper * detectionMask = horizonMask;

    if (!invertMask) {
      // Build star mask for special frame when doing sky
      // the star mask restricts keypoint detection to near bright spots in the sky

      // dilate further to expand keypoint detection area
      // threshold is 0..0xFF for what is considered bright
      detectionMask = makeStarMask(specialGray.mat,
                                   /*dilateSize=*/30,
                                   /*thresholdVal=*/200);
    }

    // Detector and matcher (we'll compute kpSpecial & descSpecial once, reused read-only)
    std::vector<cv::KeyPoint> kpSpecial;
    cv::Mat descSpecial;

    // first detect keypoints in the special frame we're aligning to
    if (invertMask) {
      // not used for sky, only for earth
      cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(4.0, cv::Size(8,8));
	  
      // ground: create a processed special image for detection
      // apply extra processing to pull up dark details to help
      // find more keypoints in the dark ground 
           cv::Mat specialProcessed;

      // Apply Contrast Limited Adaptive Histogram Equalization
      clahe->apply(specialGray.mat, specialProcessed);

      // apply gamma correction to brighten the shadows only
      specialProcessed.convertTo(specialProcessed, CV_32F, 1.0/255.0);
      cv::pow(specialProcessed, 0.5, specialProcessed);
      specialProcessed.convertTo(specialProcessed, CV_8U, 255.0);

      cv::Ptr<cv::AKAZE> akazeBase = cv::AKAZE::create();
      akazeBase->setThreshold(1e-5);

      // run advanced kaze to detect and compute keypoints in the ground
      akazeBase->detectAndCompute(specialProcessed,
                                  detectionMask.mat,
                                  kpSpecial,
                                  descSpecial);
    } else {
      // sky: use SIFT
      cv::Ptr<cv::SIFT> siftBase = cv::SIFT::create(maxKeypoints);
      siftBase->detectAndCompute(specialGray.mat,
                                 detectionMask.mat,
                                 kpSpecial,
                                 descSpecial);
    }

    kpSpecial.shrink_to_fit();

    // Preallocate per-index result storage to avoid push_back from many threads
    const size_t n = frames.count;
    std::vector<MatWrapper *> resultMats(n);       // will hold warped (success) or original (failure)
    std::vector<char>    resultSuccess(n, 0); // 1 if accepted warp, 0 otherwise

	Log_i(@"%d, about to align in parallel", invertMask);
	
    // We will run the heavy loop in parallel with OpenCV
    // for some reason this doesn't seem to really end up in parallel, not sure why
    cv::parallel_for_(cv::Range(0, (int)n), [&](const cv::Range &range) {
	    
	    static thread_local cv::Ptr<cv::SIFT> sift;
	    static thread_local cv::Ptr<cv::AKAZE> akaze;
	    static thread_local cv::Ptr<cv::CLAHE> clahe;
			    
        for (int ii = range.start; ii < range.end; ++ii) {
          NSUInteger idx = (NSUInteger)ii;
          try {
            Log_i(@"%d top", invertMask);
            // grab the frame as a cv::Mat (read-only access)
            MatWrapper * frame = frames[idx];
            Log_i(@"%d check", invertMask);

            // make a gray 8 bit image for detection
            MatWrapper * frameGray = toGray8UWithMask(frame.mat, horizonMask.mat, true);

            std::vector<cv::KeyPoint> kpFrame;
            cv::Mat descFrame;

            MatWrapper * localDetectionMask = horizonMask;

            Log_i(@"%d check", invertMask);
            if (!invertMask) {
              // detection mask is a star mask for the sky
              localDetectionMask = makeStarMask(frameGray.mat, /*dilateSize=*/30, /*thresholdVal=*/200);
            }

            // create local detector/matcher/clahe instances so they are thread-local
            Log_i(@"%d check", invertMask);
            if (invertMask) {
              // ground: AKAZE + CLAHE + gamma
              if(!clahe) clahe = cv::createCLAHE(4.0, cv::Size(8,8));
              cv::Mat claheOut;
              clahe->apply(frameGray.mat, claheOut);
              claheOut.convertTo(claheOut, CV_32F, 1.0/255.0);
              cv::pow(claheOut, 0.5, claheOut);
              claheOut.convertTo(claheOut, CV_8U, 255.0);

              if(!akaze) akaze = cv::AKAZE::create();
              akaze->setThreshold(1e-5);
              akaze->detectAndCompute(claheOut, localDetectionMask.mat, kpFrame, descFrame);
            } else {
              // sky: SIFT
              if(!sift) sift = cv::SIFT::create(maxKeypoints);
              sift->detectAndCompute(frameGray.mat, localDetectionMask.mat, kpFrame, descFrame);
            }
            Log_i(@"%d check", invertMask);

		    // if we got nothing, then fail fast
            if (descFrame.empty() || descSpecial.empty()) {
              // failed early: no descriptors
              resultSuccess[idx] = 0;
              resultMats[idx] = frame;
              continue;
            }

		    // we have keypoints to match between the special frame
		    // and the special frame we're iterating on
	    
            std::vector<cv::Point2f> ptsFrame, ptsSpecial;
            std::vector<std::vector<cv::DMatch>> knnMatches;
            std::vector<cv::DMatch> matches;
            double cutoff = 0;
            double minDist = 0;
		    // local matcher (thread-local)
		    cv::BFMatcher matcher(cv::NORM_L2);
		    
		    // how do we match between the two sets of keypoints?
		    // three different methods are available
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
                  if (m1.distance < 0.75 * m2.distance) {
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
            Log_i(@"%d check", invertMask);

		    // after matching the keypoints between the special frame and
		    // the alignment frame we're iterating over, we next need to
		    // check how good a fit we got from the match.
		    // only accept the warp if it's between provided boundaries
		    // otherwise widly off erroneous matches can creep in

		    // innocent until proven guilty
            bool acceptWarp = FALSE;
            cv::Mat warped;

            // need at least four points
            if (ptsFrame.size() >= 4) {

              // find homography between the matched keypoints 
                cv::Mat H = cv::findHomography(ptsFrame, ptsSpecial, cv::RANSAC, 10);
              if (!H.empty() && H.type() != CV_32F && H.type() != CV_64F) {
                H.convertTo(H, CV_64F);
              }

              if (!H.empty() && H.rows == 3 && H.cols == 3) {
			    // Check warp quality with two checks

			    // first check is simple, max deviation
                cv::Mat I = cv::Mat::eye(3, 3, H.type());
                double deviation = cv::norm(H - I, cv::NORM_L2);

			    // second check makes sure all four corners aren't very far away
			    // we're aligning images from a timelapse video here, so even with
			    // a moving camera we shouldn't need very much frame to frame adjustement
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

			    // accept the warp only if our values are within range
                acceptWarp = (deviation < maxDeviation) &&
                  (maxCornerDist < maxCornerDeviation);

                if (acceptWarp) {
                  // if we accept the warp, then actually warp
                  // this frame to fit the special image
                  cv::warpPerspective(frame.mat, warped, H, frame.mat.size(),
                                      cv::INTER_LINEAR, cv::BORDER_CONSTANT,
                                      cv::Scalar(0,0,0,0));
                }
              }
            }

            if (acceptWarp) {
              if (warped.channels() == 4) {
                // force no alpha (still necessary?)
                cv::cvtColor(warped, warped, cv::COLOR_BGRA2BGR);
              }
              resultSuccess[idx] = 1;
              resultMats[idx] = [[MatWrapper alloc] initWithMat: warped];
              if(warped.empty()) {
                Log_w(@"warped is empty");
              }
            } else {
              resultSuccess[idx] = 0;
              resultMats[idx] = frame;
              if(frame.mat.empty()) {
                Log_w(@"frame is empty");
              }
            }

          } catch (const cv::Exception &e) {
            Log_e(@"Error: %@", [NSString stringWithUTF8String:e.what()]);
            // On exception mark as failed and store original
            resultSuccess[idx] = 0;
            resultMats[idx] = frames[idx];
          } catch (const std::exception &e) {
            Log_e(@"Error: %@", [NSString stringWithUTF8String:e.what()]);
            resultSuccess[idx] = 0;
            resultMats[idx] = frames[idx];
          } catch (...) {
            Log_e(@"Unknown Error");
            resultSuccess[idx] = 0;
            resultMats[idx] = frames[idx];
          }
        }
      });

    // Gather aligned and failed in the same shape as original function
    std::vector<MatWrapper*> aligned;
    std::vector<MatWrapper*> failed;
    aligned.reserve(n);
    failed.reserve(n);

    for (size_t i = 0; i < n; ++i) {
      if(resultMats[i].mat.empty()) {
        Log_w(@"FUCK");
      }
      if (resultSuccess[i]) {
        aligned.push_back(resultMats[i]);
      } else {
        failed.push_back(resultMats[i]);
      }
    }

    // use median merges
    MatWrapper * alignedResult = medianImageFromArray(aligned, k);
    MatWrapper * failedResult = medianImageFromArray(failed, k);

	if(alignedResult.mat.empty()) {
	  Log_w(@"alignedResult is empty");
	}
	if(failedResult.mat.empty()) {
	  Log_w(@"failedResult is empty");
	}
	
    AlignmentResult *resultObj = [AlignmentResult new];
    resultObj.aligned = alignedResult;
    resultObj.numAligned = aligned.size();
    resultObj.failed = failedResult;
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
