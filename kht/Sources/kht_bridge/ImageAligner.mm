#import "ImageAligner.h"
#import "MatWrapper_Internal.h"
#import "ObjcImageCache.h"
#import "ObjcAlignmentStep.h"
#import "logging.h"
#import "OCVFeatureRequest.h"
#import "OCVFeatureSet.h"
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

void growBlack(cv::Mat &img, int pixels)
{
    // img should be CV_8UC1 with values 0 or 255

    // Create a structuring element (kernel)
    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE,
                                               cv::Size(2 * pixels + 1, 2 * pixels + 1),
                                               cv::Point(pixels, pixels));

    // Erode to expand black regions
    cv::erode(img, img, kernel);
}



// Median Merge Logic:
// merges the provided vector of cv::Mat images with median brightness per channel
// throws out 99% or more of airplane and satellite signal
// gives a pretty clear horizon
// k is the threshold used for weeding out bright pixels 1.2 is good
// smaller weeds out more bright pixels, larger weeds out less.
// It is good to weed out these bright pixels before taking the median
// as otherwise areas with lots of bright bad pixels in the same spot across
// multiple images can sometimes allow the bad pixels to show up at the median

template <typename T>
static inline T clamp_cast_int(int v) {
    if constexpr (std::is_same_v<T, uchar>) {
        return static_cast<uchar>(std::clamp(v, 0, 255));
    } else {
        return static_cast<uint16_t>(std::clamp(v, 0, 65535));
    }
}

// -----------------------------------------------------------------------------
// Core median logic applied to either CV_8U or CV_16U using templates
// -----------------------------------------------------------------------------
template <typename T>
static void medianMergeTyped(
    cv::Mat &output,
    const std::vector<MatWrapper*>& mats,
    double k,
    bool includeAll,
    int rows,
    int cols,
    int ch
) {
    const int n = static_cast<int>(mats.size());
    std::vector<int> vals(n);

    for (int y = 0; y < rows; ++y) {
        const T* rowPtrs[n];
        for (int i = 0; i < n; ++i)
          rowPtrs[i] = mats[i].mat.ptr<T>(y);

        T* outRow = output.ptr<T>(y);

        for (int x = 0; x < cols; ++x) {

            for (int c = 0; c < ch; ++c) {

                // gather values
                for (int i = 0; i < n; ++i) {
                    vals[i] = rowPtrs[i][x * ch + c];
                }

                // sort
                std::sort(vals.begin(), vals.end());

                // compute mean
                double sum = 0;
                for (int v : vals) sum += v;
                double mean = sum / n;

                // compute stddev
                double var = 0.0;
                for (int v : vals) {
                    double d = v - mean;
                    var += d * d;
                }
                double stddev = std::sqrt(var / n);

                double threshold = mean + k * stddev;

                // determine usable min/max indices
                int minIndex = 0;
                int maxIndex = n;

                if (!includeAll) {
                    for (int z = 0; z < n; ++z) {
                        int v = vals[z];

                        if (v == 0)
                            minIndex = z + 1;

                        if (v < threshold)
                            maxIndex = z;
                        else
                            break;
                    }
                }

                // choose median within the reduced range
                int idx = (minIndex + maxIndex) / 2;
                if (idx >= n) idx = n - 1;

                outRow[x * ch + c] = clamp_cast_int<T>(vals[idx]);
            }
        }
    }
}

// -----------------------------------------------------------------------------
// Public entry point
// -----------------------------------------------------------------------------
MatWrapper* medianImageFromArray(const std::vector<MatWrapper*>& mats,
                                 double k,
                                 BOOL includeAll)
{
    if (mats.empty()) {
        Log_w(@"given empty mats, returning empty");
        return [[MatWrapper alloc] initWithMat:cv::Mat()];
    }

    const cv::Mat& first = mats[0].mat;
    const int rows = first.rows;
    const int cols = first.cols;
    const int ch   = first.channels();
    const int depth = first.depth();
    const int n     = (int)mats.size();

    // Validate dimensions/types
    for (int i = 1; i < n; ++i) {
        const cv::Mat& m = mats[i].mat;
        if (m.rows != rows || m.cols != cols || m.type() != first.type()) {
            throw std::runtime_error("All mats must have same size and type");
        }
    }
    if (ch != 1 && ch != 3 && ch != 4)
        throw std::runtime_error("Unsupported channel count");

    cv::Mat output(rows, cols, first.type());

    // Dispatch to correct typed implementation
    if (depth == CV_8U) {
        medianMergeTyped<uchar>(output, mats, k, includeAll, rows, cols, ch);
    }
    else if (depth == CV_16U) {
        medianMergeTyped<uint16_t>(output, mats, k, includeAll, rows, cols, ch);
    }
    else {
        throw std::runtime_error("Unsupported depth (only CV_8U and CV_16U supported)");
    }

    printMatInfo(output, "image align output");

    return [[MatWrapper alloc] initWithMat:output];
}


@implementation ImageAligner


+ (id)medianMergeFilenames:(NSArray<NSString*>*)filenames
          outlierThreshold:(double)k
                includeAll:(BOOL)includeAll
{
  NSMutableArray<MatWrapper*> * images = [[NSMutableArray<MatWrapper*> alloc] init];
  for(int i = 0 ; i < filenames.count ; i++) {
    [images addObject: [ObjcImageCache loadImage:filenames[i]]];
  }
  return [ImageAligner medianMerge:images outlierThreshold:k includeAll:includeAll];
}

+ (id)medianMergeImage:(MatWrapper*)image
         withFilenames:(NSArray<NSString*>*)filenames
      outlierThreshold:(double)k
            includeAll:(BOOL)includeAll;
{
  NSMutableArray<MatWrapper*> * images = [[NSMutableArray<MatWrapper*> alloc] init];
  [images addObject: image];
  for(int i = 0 ; i < filenames.count ; i++) {
    MatWrapper * image = [ObjcImageCache loadImage:filenames[i]];
    if(image != nil) {
      [images addObject: image];
    }
  }
  return [ImageAligner medianMerge:images
                  outlierThreshold: k
                        includeAll: includeAll];
}

// just median merges the frames without any alignment
+ (MatWrapper* _Nonnull)medianMerge:(NSArray<MatWrapper*>* _Nonnull)frames
 outlierThreshold:(double)k
       includeAll:(BOOL)includeAll
{
    std::vector<MatWrapper*> array;
    for (size_t i = 0; i < frames.count; ++i) {
      array.push_back(frames[i]);
    }
    return medianImageFromArray(array, k, includeAll);
}


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
        Log_e(@"Input image is empty!");
        return nil;
    }

    cv::Mat gray;
    if (src.channels() > 1) {
      // convert to grayscale
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

        cv::Mat test;
        
        // apply mask
        gray.copyTo(test, mask);
        
        // Apply scaling
        test.convertTo(tmp, CV_8U, scale, shift);

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
            tmp = gray;
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


// Helper: compute star mask from baseImage frame
static MatWrapper * makeStarMask(const cv::Mat &gray, int dilateSize = 3, int thresholdVal = 200) {
    cv::Mat mask, thresh;
    // Threshold for bright spots (stars)
    cv::threshold(gray, thresh, thresholdVal, 255, cv::THRESH_BINARY);
    // Dilate to give SIFT some gradients around stars
    if (dilateSize > 0) {
      cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE,
                                                 cv::Size(2*dilateSize+1,
                                                          2*dilateSize+1));
        cv::dilate(thresh, mask, kernel);
    } else {
        mask = thresh;
    }
    return [[MatWrapper alloc] initWithMat: mask];
}

/***
 * Main alignment method. 
 *
 * Aligns array of 'neighbors' to 'baseImage'.
 * The 'mask' is a binary mask with zero for the ground and non-zero for the sky
 * 
 * Returns NSMutableArray<AlignmentWarpInfo *> *warps
 *
 * returns string errors when there is a problem, or maybe nil
 *
 * Uses different logic for sky and earth alignment, alignmentType governs that.
 */
/*

  Faster rewrite:

   Right now, the vast majority of time is spent in keypoint detection.
   The app is computing keypoints on each frame N times, where N is the number of neighbors.
   This is slow and redundant.

   Faster would be to compute keypoints for all frames once, and keep that information
   available after computation, both in ram and in flash.

   Then alignment is split into more different phases:
     - first find sky (and maybe earth) keypoints for all frames, saving this data
     - then have a process which tries to match keypoints and produce a homography
     - then go through again and do our current second pass to fix bad homography
   
 */
+ (id _Nullable)alignWithRequest:(AlignmentRequest * _Nonnull)request
                         handler:(ImageAlignerUpdateBlock)handler
{
  @try {
    try {
      uint32_t logID = request.frameIndex;

      SET_FRAME_STATE(request, ObjCAlignmentStepStart, 0);

      if(request.homography != nil) {
        // use passed homography
        return [ImageAligner alignWithExistingHomographyRequest:request];
      }
      
      // Horizon mask (sky = nonzero, ground = 0)
      MatWrapper * horizonMask;
      if (request.mask != NULL && !request.mask.mat.empty()) {
        // use passed in horizon mask
        horizonMask = request.mask;
      } else {
        // if no horizon mask is passed, assume a fully white mask (all pixels)
        horizonMask = [[MatWrapper alloc]
                        initWithMat:cv::Mat(request.baseImage.mat.size(), CV_8U, cv::Scalar(255))];
      }

      //cv::imwrite("/tmp/horizon_start.tiff", horizonMask.mat);

      horizonMask = toGray8U(horizonMask);

      if (request.alignmentType == AlignmentTypeEarth) {
        // invert the mask to apply to the ground instead of the sky
        cv::bitwise_not(horizonMask.mat, horizonMask.mat);

        // for the ground, we make the horizon mask include a bit above the horizon,
        // which leads to better keypoints down the road
        horizonMask = createGradientMaskIntoSky(horizonMask.mat,
                                                request.groundHorizonExtension);
      }
      
      // Detector and matcher
      if (request == nil || request.baseKeypoints == nil) {
        return @"not given keypoints on base frame";
      }
      
      std::vector<cv::KeyPoint> kpBaseImage = request.baseKeypoints.keypoints;
      cv::Mat descBaseImage = request.baseKeypoints.descriptors;

      // Preallocate per-index result storage to avoid push_back from many threads
      const size_t n = request.neighbors.count;

      // holds warp information
      std::vector<AlignmentWarpInfo *> warpInfos(n, nullptr);

      static thread_local cv::Ptr<cv::SIFT> sift;
      static thread_local cv::Ptr<cv::AKAZE> akaze;
      static thread_local cv::Ptr<cv::CLAHE> clahe;
			    
      for (int ii = 0 ; ii < n; ++ii) {
        SET_FRAME_STATE(request, ObjCAlignmentStepLoadingNeighbor, ii);

        MatWrapper* preloadedFrame = [ObjcImageCache loadImage:request.neighbors[ii].filename];
        MatWrapper* preloadedMask = nil;
        if (request.neighbors[ii].maskFilename != nil) {
          preloadedMask = [ObjcImageCache loadImage:request.neighbors[ii].maskFilename];
        }

            
        SET_FRAME_STATE(request, ObjCAlignmentStepNeighborKeypointDetection, ii);
            
        NSUInteger idx = (NSUInteger)ii;
        //Log_i(@"frame %d %d top", logID, ii);
        MatWrapper * neighbor = preloadedFrame;
        if (neighbor == nil) {
          //Log_e(@"%d neighbor is nil", logID);
          continue;
        }
        MatWrapper * neighborHorizon = 0;
        if (preloadedMask != nil) {
          neighborHorizon = preloadedMask;
        }
        try {
          //Log_i(@"frame %d %d loaded", logID, ii);

          // make a gray 8 bit image for detection

          cv::Mat horizon = horizonMask.mat; // XXX is this the right horizon mask?

          //cv::imwrite("/tmp/horizon_a_" + std::to_string(idx) + ".tiff", horizon);

          if (request.alignmentType == AlignmentTypeSky) {
            horizon = horizon.clone();
            // attempt to exclude the horizon from the sky area
            // so key points are not detected there 
            growBlack(horizon, request.skyHorizonExtension);
          }

          //cv::imwrite("/tmp/horizon_b_" + std::to_string(idx) + ".tiff", horizon);

          //Log_i(@"frame %d %d to gray check", logID, ii);

          std::vector<cv::KeyPoint> kpNeighbor = request.neighbors[ii].keypoints.keypoints;
          cv::Mat descNeighbor = request.neighbors[ii].keypoints.descriptors;

          // if we got nothing, then fail fast
          if (/*kpNeighbor == nil || descNeighbor == nil || */descNeighbor.empty() || descBaseImage.empty()) {
            // failed early: no descriptors
            CFRetain((__bridge CFTypeRef)neighbor);
            Log_e(@"frame %d descNeighbor or descBaseImage is empty", logID);

            AlignmentWarpInfo *info =
              [[AlignmentWarpInfo alloc]
                    initWithHomography:nil
                           warpedFrame:nil
                         warpedHorizon:nil
                             deviation:0
                        alignmentState:AlignmentStateObjCUnableToDetectKeypoints
                            frameIndex:request.neighbors[idx].frameIndex];

            warpInfos[idx] = info;
            CFRetain((__bridge CFTypeRef)info);
              
            continue;
          }

          SET_FRAME_STATE(request, ObjCAlignmentStepNeighborKeypointMatch, ii);
              
          // we have keypoints to match between the baseImage frame
          // and the neighbor frame we're iterating on
	    
          std::vector<cv::Point2f> ptsNeighbor, ptsBaseImage;
          std::vector<std::vector<cv::DMatch>> knnMatches;
          std::vector<cv::DMatch> matches;
          double cutoff = 0;
          double minDist = 0;
          // local matcher (thread-local)
          cv::BFMatcher matcher(cv::NORM_L2);
		    
          // how do we match between the two sets of keypoints?
          // three different methods are available
          switch (request.matchMethod) {
          case FeatureMatchMethodBruteForce:
            // brute force method
		      
            matcher.match(descNeighbor, descBaseImage, matches);

            minDist = std::numeric_limits<double>::max();
            for (auto &m : matches) {
              minDist = std::min(minDist, (double)m.distance);
            }
            cutoff = std::max(2 * minDist, 30.0);

            for (auto &m : matches) {
              if (m.distance <= cutoff) {
                ptsNeighbor.push_back(kpNeighbor[m.queryIdx].pt);
                ptsBaseImage.push_back(kpBaseImage[m.trainIdx].pt);
              }
            }
            break;
			

          case FeatureMatchMethodKNNLowes:
            // kNN + Lowe's Ratio Test

            matcher.knnMatch(descNeighbor, descBaseImage, knnMatches, 2);
            for (size_t i = 0; i < knnMatches.size(); i++) {
              if (knnMatches[i].size() == 2) {
                const cv::DMatch &m1 = knnMatches[i][0];
                const cv::DMatch &m2 = knnMatches[i][1];
                if (m1.distance < 0.75 * m2.distance) {
                  ptsNeighbor.push_back(kpNeighbor[m1.queryIdx].pt);
                  ptsBaseImage.push_back(kpBaseImage[m1.trainIdx].pt);
                }
              }
            }
            break;

			
          case FeatureMatchMethodFLANN:
            // FLANN based matcher
            // Convert to CV_32F because FLANN requires float descriptors
            cv::Mat descNeighbor32f, descBaseImage32f;
            descNeighbor.convertTo(descNeighbor32f, CV_32F);
            descBaseImage.convertTo(descBaseImage32f, CV_32F);
            cv::FlannBasedMatcher flann;
            flann.knnMatch(descNeighbor32f, descBaseImage32f, knnMatches, 2);
            for (size_t i = 0; i < knnMatches.size(); i++) {
              if (knnMatches[i].size() == 2) {
                const cv::DMatch &m1 = knnMatches[i][0];
                const cv::DMatch &m2 = knnMatches[i][1];
                if (m1.distance < 0.75 * m2.distance) {
                  ptsNeighbor.push_back(kpNeighbor[m1.queryIdx].pt);
                  ptsBaseImage.push_back(kpBaseImage[m1.trainIdx].pt);
                }
              }
            }
            break;
          }
          //Log_i(@"frame %d %d matcher check", logID, ii);

          // after matching the keypoints between the baseImage frame and
          // the neibhgor frame we're iterating over, we next need to
          // check how good a fit we got from the match.
          // only accept the warp if it's between provided boundaries
          // otherwise widly off erroneous matches can creep in

          // innocent until proven guilty
          bool acceptWarp = FALSE;
          cv::Mat warped;
          cv::Mat warpedHorizon;

          // need at least four points
          if (ptsNeighbor.size() >= 4) {

            SET_FRAME_STATE(request, ObjCAlignmentStepAligningNeighbor, ii);
                
            //Log_d(@"frame %d has $zu control points", logID, ptsNeighbor.size());
            // find homography between the matched keypoints 
                 cv::Mat H = cv::findHomography(ptsNeighbor, ptsBaseImage, cv::RANSAC, 10);
            if (!H.empty() && H.type() != CV_32F && H.type() != CV_64F) {
              H.convertTo(H, CV_64F);
            }

            // save alignment warp info for this neighbor
            MatWrapper *HWrapper = nil;
            if (!H.empty()) {
              HWrapper = [[MatWrapper alloc] initWithMat:H];
            }

            if (!H.empty() && H.rows == 3 && H.cols == 3) {
              // Check warp quality with two checks

              // check max deviation
              cv::Mat I = cv::Mat::eye(3, 3, H.type());
              double deviation = cv::norm(H - I, cv::NORM_L2);

              // if we accept the warp, then actually warp
              // this frame to fit the baseImage image
              //Log_i(@"frame %d %d accepting warp deviation %lf maxDeviation %lf maxCornerDist %lf maxCornerDeviation %lf", logID, ii, deviation, maxDeviation, maxCornerDist, maxCornerDeviation);
              //Log_i(@"frame %d %d accepting warp and warping", logID, ii);
              cv::warpPerspective(neighbor.mat, // the input to warp
                                  warped, // the warped output
                                  H, // the homography to warp with
                                  neighbor.mat.size(),
                                  cv::INTER_LINEAR,
                                  cv::BORDER_CONSTANT,
                                  cv::Scalar(0,0,0,0));


              //cv::imwrite("/tmp/warped_first_" + std::to_string(idx) + ".tiff", warped);

              if (neighborHorizon != NULL) {
                // warp horizon with same homography as ground
                //Log_i(@"frame %d %d accepting warp and warping horizon", logID, ii);
                cv::warpPerspective(neighborHorizon.mat, warpedHorizon, H,
                                    neighborHorizon.mat.size(),
                                    cv::INTER_LINEAR, cv::BORDER_CONSTANT,
                                    cv::Scalar(0,0,0,0));

                // threshold so all values are 0 or 0xFF
                cv::threshold(warpedHorizon,
                              warpedHorizon,
                              128, // mid
                              255,
                              cv::THRESH_BINARY);
              }

              // keep track of warp info 
                   AlignmentWarpInfo *info =
                   [[AlignmentWarpInfo alloc]
                         initWithHomography:HWrapper
                                warpedFrame:[[MatWrapper alloc] initWithMat: warped]
                              warpedHorizon:neighborHorizon == NULL ? nil : [[MatWrapper alloc] initWithMat: warpedHorizon]
                                  deviation:deviation
                             alignmentState:AlignmentStateObjCHomographySuccess
                                 frameIndex:request.neighbors[idx].frameIndex];

              warpInfos[idx] = info;
              CFRetain((__bridge CFTypeRef)info);

            } else {
              // no homography found
              AlignmentWarpInfo *info =
                [[AlignmentWarpInfo alloc]
                      initWithHomography:nil
                             warpedFrame:nil
                           warpedHorizon:nil
                               deviation:0
                          alignmentState:AlignmentStateObjCNoHomographyFound
                              frameIndex:request.neighbors[idx].frameIndex];

              warpInfos[idx] = info;
              CFRetain((__bridge CFTypeRef)info);
            }
          } else {
            // not enough points
            AlignmentWarpInfo *info =
              [[AlignmentWarpInfo alloc]
                    initWithHomography:nil
                           warpedFrame:nil
                         warpedHorizon:nil
                             deviation:0
                        alignmentState:AlignmentStateObjCNotEnoughKeypoints
                            frameIndex:request.neighbors[idx].frameIndex];

            warpInfos[idx] = info;
            CFRetain((__bridge CFTypeRef)info);
          }

        } catch (const cv::Exception &e) {
          Log_e(@"frame %d Error: %@", logID, [NSString stringWithUTF8String:e.what()]);
          // On exception mark as failed and store original
          CFRetain((__bridge CFTypeRef)neighbor);
        } catch (const std::exception &e) {
          Log_e(@"frame %d Error: %@", logID, [NSString stringWithUTF8String:e.what()]);
          CFRetain((__bridge CFTypeRef)neighbor);
        } catch (...) {
          Log_e(@"frame %d Unknown Error", logID);
          CFRetain((__bridge CFTypeRef)neighbor);
        }
      }

      // done processing neighbor frames
      
      SET_FRAME_STATE(request, ObjCAlignmentStepComplete, 0);
          
      NSMutableArray<AlignmentWarpInfo *> *warps = [NSMutableArray array];
      for (size_t i = 0; i < n; ++i) {
        if (warpInfos[i]) [warps addObject:warpInfos[i]];
      }
      
      // CFRelease temporary objects
      for (size_t i = 0; i < n; ++i) {
        if (warpInfos[i]) {
          CFRelease((__bridge CFTypeRef)warpInfos[i]);
          warpInfos[i] = nullptr;
        }
      }

      return warps;

    } catch (const cv::Exception &e) {
      Log_e(@"Error: %@", [NSString stringWithUTF8String:e.what()]);
      return [NSString stringWithUTF8String:e.what()];
    } catch (const std::exception &e) {
      Log_e(@"Error: %@", [NSString stringWithUTF8String:e.what()]);
      return [NSString stringWithUTF8String:e.what()];
    } catch (...) {
      Log_e(@"Unknown Error");
      return @"Unknown Exception";
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
    return [NSString stringWithFormat:@"Objective-C Exception: %@", exception];
  }
}

// runs on a single frame, returning a OCVFeatureSet upon success,
// which contains keypoints and descriptors that are later used
// to find homography between frames
+ (id _Nullable)findFeatures:(OCVFeatureRequest * _Nonnull)request {
  @try {
    try {
      // how many threads opencv can use
      //    cv::setNumThreads(36);    // XXX make this a parameter?

      uint32_t logID = request.frameIndex;
      
      // Horizon mask (sky = nonzero, ground = 0)
      MatWrapper * horizonMask;
      if (request.mask != NULL && !request.mask.mat.empty()) {
        // use passed in horizon mask
        horizonMask = request.mask;
      } else {
        // if no horizon mask is passed, assume a fully white mask (all pixels)
        horizonMask = [[MatWrapper alloc]
                        initWithMat:cv::Mat(request.baseImage.mat.size(),
                                            CV_8U,
                                            cv::Scalar(255))];
      }

      //cv::imwrite("/tmp/horizon_start.tiff", horizonMask.mat);

      horizonMask = toGray8U(horizonMask);

      if (request.alignmentType == AlignmentTypeEarth) {
        // invert the mask to apply to the ground instead of the sky
        cv::bitwise_not(horizonMask.mat, horizonMask.mat);

        // for the ground, we make the horizon mask include a bit above the horizon,
        // which leads to better keypoints down the road
        horizonMask = createGradientMaskIntoSky(horizonMask.mat,
                                                request.groundHorizonExtension);
      }
      
      // Prepare grayscale baseImage frame with the horizon mask
      MatWrapper * baseImageGray = toGray8UWithMask(request.baseImage.mat,
                                                    horizonMask.mat,
                                                    true);
    
      if(request.writeDebugImages) {
        if(request.alignmentType == AlignmentTypeEarth) {
          cv::imwrite("/tmp/baseImage_gray_earth_frame_" +
                      std::to_string(request.frameIndex) + ".tiff",
                      baseImageGray.mat);
        } else {
          cv::imwrite("/tmp/baseImage_gray_sky_frame_" +
                      std::to_string(request.frameIndex) +
                      ".tiff",
                      baseImageGray.mat);
        }
      }
    
      // default to detecting with the horizon mask as is
      MatWrapper * detectionMask = horizonMask;

      if (request.alignmentType == AlignmentTypeSky) {
        // Build star mask for baseImage frame when doing sky
        // the star mask restricts keypoint detection to near bright spots in the sky

        // dilate further to expand keypoint detection area
        // threshold is 0..0xFF for what is considered bright
        detectionMask = makeStarMask(baseImageGray.mat,
                                     request.baseImageDilateSize,
                                     request.baseImageDilateSize);
      }

      // Detector and matcher
      std::vector<cv::KeyPoint> keypoints;
      cv::Mat descriptors;

      // detect keypoints
      if (request.alignmentType == AlignmentTypeEarth) {
        // not used for sky, only for earth
        cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(4.0, cv::Size(8,8));
	  
        // ground: create a processed baseImage image for detection
        // apply extra processing to pull up dark details to help
        // find more keypoints in the dark ground 
             cv::Mat baseImageProcessed;

        // Apply Contrast Limited Adaptive Histogram Equalization
        clahe->apply(baseImageGray.mat, baseImageProcessed);

        // apply gamma correction to brighten the shadows only
        baseImageProcessed.convertTo(baseImageProcessed, CV_32F, 1.0/255.0);
        cv::pow(baseImageProcessed, 0.5, baseImageProcessed);
        baseImageProcessed.convertTo(baseImageProcessed, CV_8U, 255.0);

        cv::Ptr<cv::AKAZE> akazeBase = cv::AKAZE::create();
        akazeBase->setThreshold(1e-5);

        // run advanced kaze to detect and compute keypoints in the ground
        akazeBase->detectAndCompute(baseImageProcessed,
                                    detectionMask.mat,
                                    keypoints,
                                    descriptors);
      } else {
        // sky: use SIFT
        
        cv::Ptr<cv::SIFT> siftBase = cv::SIFT::create(request.maxKeypoints);
        siftBase->detectAndCompute(baseImageGray.mat,
                                   detectionMask.mat,
                                   keypoints,
                                   descriptors);
      }

      if(request.writeDebugImages) {
        // save detectionMask.mat if desired
        if(request.alignmentType == AlignmentTypeEarth) {
          cv::imwrite("/tmp/detectionMask_earth_frame_" +
                      std::to_string(request.frameIndex) +
                      ".tiff",
                      detectionMask.mat);
        } else {
          cv::imwrite("/tmp/detectionMask_sky_frame_" +
                      std::to_string(request.frameIndex) +
                      ".tiff",
                      detectionMask.mat);
        }
      }
    
      detectionMask.mat.release();
      detectionMask = nil;        // done with these, allow deallocation
      baseImageGray.mat.release();
      baseImageGray = nil;
    
      keypoints.shrink_to_fit();

      return [[OCVFeatureSet alloc] initWithKeypoints:keypoints
                                          descriptors:descriptors];

    } catch (const cv::Exception &e) {
      Log_e(@"Error: %@", [NSString stringWithUTF8String:e.what()]);
      return [NSString stringWithUTF8String:e.what()];
    } catch (const std::exception &e) {
      Log_e(@"Error: %@", [NSString stringWithUTF8String:e.what()]);
      return [NSString stringWithUTF8String:e.what()];
    } catch (...) {
      Log_e(@"Unknown Error");
      return @"Unknown Exception";
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
    return [NSString stringWithFormat:@"Objective-C Exception: %@", exception];
  }
}

// just warps with the given homography 
+ (id _Nullable)alignWithExistingHomographyRequest:(AlignmentRequest * _Nonnull)request {
  @try {
    try {
      NSMutableArray<AlignmentWarpInfo *> *warps = [NSMutableArray array];
      const size_t n = request.neighbors.count;
      for (size_t i = 0; i < n; ++i) {
        MatWrapper * neighbor = [ObjcImageCache loadImage:request.neighbors[i].filename];
        int offset = request.neighbors[i].frameIndex - request.frameIndex;
        cv::Mat H;
        cv::Mat warped;
        cv::Mat warpedMask;
        NSNumber * key = [NSNumber numberWithInt: offset];
        if([request.homography objectForKey: key] != nil) {
            MatWrapper * homography = [request.homography objectForKey: key];
            cv::warpPerspective(neighbor.mat, // the input to warp
                                warped, // the warped output
                                homography.mat, // the homography to warp with
                                neighbor.mat.size(),
                                cv::INTER_LINEAR,
                                cv::BORDER_CONSTANT,
                                cv::Scalar(0,0,0,0));


            NSString * maskFilename = request.neighbors[i].maskFilename;
            if(maskFilename != nil) {
              MatWrapper * mask = [ObjcImageCache loadImage:maskFilename];
              cv::warpPerspective(mask.mat, // the input to warp
                                  warpedMask, // the warped output
                                  homography.mat, // the homography to warp with
                                  mask.mat.size(),
                                  cv::INTER_LINEAR,
                                  cv::BORDER_CONSTANT,
                                  cv::Scalar(0,0,0,0));
            }

            // check max deviation
            cv::Mat I = cv::Mat::eye(3, 3, homography.mat.type());
            double deviation = cv::norm(homography.mat - I, cv::NORM_L2);
            
            AlignmentWarpInfo *info =
              [[AlignmentWarpInfo alloc]
                         initWithHomography:homography
                                warpedFrame:[[MatWrapper alloc] initWithMat: warped]
                              warpedHorizon:maskFilename == nil ? nil : [[MatWrapper alloc] initWithMat: warpedMask]
                                  deviation:deviation
                             alignmentState:AlignmentStateObjCUsedExistingHomography
                                 frameIndex:request.neighbors[i].frameIndex];

            [warps addObject:info];
          }
      }

      return warps;

    } catch (const cv::Exception &e) {
      Log_e(@"Error: %@", [NSString stringWithUTF8String:e.what()]);
      return [NSString stringWithUTF8String:e.what()];
    } catch (const std::exception &e) {
      Log_e(@"Error: %@", [NSString stringWithUTF8String:e.what()]);
      return [NSString stringWithUTF8String:e.what()];
    } catch (...) {
      Log_e(@"Unknown Error");
      return @"Unknown Exception";
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
    return [NSString stringWithFormat:@"Objective-C Exception: %@", exception];
  }
}

@end
