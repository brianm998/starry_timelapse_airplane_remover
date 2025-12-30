#import <Foundation/Foundation.h>
#import "AlignmentWarpInfo.h"
#import "MatWrapper.h"

// holds the results of trying to align N number of frames with another base image
// aligned is a per pixel median of all properly aligned frames
// failed is a per pixel median of all frames which were not able to be aligned
@interface AlignmentResult : NSObject
@property(nonatomic, strong, nullable) MatWrapper *alignedMat;   // warped frame

@property(nonatomic, strong, nullable) MatWrapper *failedMat;    // fallback/original frame

@property(nonatomic, strong, nullable) MatWrapper *horizonMask; // median merged horizonMask
/// Warp metadata
@property(nonatomic, strong) NSArray<AlignmentWarpInfo *> * _Nonnull alignedWarps;
@property(nonatomic, strong) NSArray<AlignmentWarpInfo *> * _Nonnull failedWarps;


-(AlignmentResult* _Nonnull)initWithAlignedMat:(nullable MatWrapper *)alignedMat
                                  alignedWarps:(NSArray<AlignmentWarpInfo *> * _Nonnull)alignedWarps
                                     failedMat:(nullable MatWrapper *)failedMat
                                   failedWarps:(NSArray<AlignmentWarpInfo *> * _Nonnull)failedWarps
                                   horizonMask:(nullable MatWrapper *)horizonMask;
@end


typedef NS_ENUM(NSInteger, FeatureMatchMethod) {
    FeatureMatchMethodBruteForce = 0,
    FeatureMatchMethodKNNLowes   = 1,
    FeatureMatchMethodFLANN      = 2
};

@interface ImageAligner : NSObject

+ (id _Nonnull)medianMergeImage:(MatWrapper* _Nonnull)image
                  withFilenames:(NSArray<NSString*>* _Nonnull)filenames
               outlierThreshold:(double)k
                     includeAll:(BOOL)includeAll;

+ (id _Nonnull)medianMergeFilenames:(NSArray<NSString*>* _Nonnull)filenames
                   outlierThreshold:(double)k
                         includeAll:(BOOL)includeAll;


// just median merges the frames without any alignment
+ (id _Nonnull)medianMerge:(NSArray<MatWrapper*>* _Nonnull)frames
          outlierThreshold:(double)k
                includeAll:(BOOL)includeAll;

// align frames to special frame, with optional mask which shows where to get keypoints from
// 
+ (id _Nullable)alignFrames:(MatWrapper * _Nonnull)special
                     frames:(NSArray<NSString *> * _Nonnull)frameFilenames
                 frameMasks:(NSArray<NSString *> * _Nonnull)frameMaskFilenames
                matchMethod:(FeatureMatchMethod)matchMethod
                       mask:(MatWrapper * _Nullable)mask // assumed to be zero for ground, non-zero for sky
     maxDeviation:(double)maxDeviation
maxCornerDeviation:(double)maxCornerDeviation
       invertMask:(BOOL)invertMask
     maxKeypoints:(int)maxKeypoints
 outlierThreshold:(double)k;

+(MatWrapper * _Nonnull)createGradientMaskIntoSky:(MatWrapper* _Nonnull)binaryMask
                                 gradientDistance:(int)gradientDistance;

+(MatWrapper * _Nonnull)createGradientMaskIntoGround:(MatWrapper* _Nonnull)binaryMask
                                    gradientDistance:(int)gradientDistance;

@end
