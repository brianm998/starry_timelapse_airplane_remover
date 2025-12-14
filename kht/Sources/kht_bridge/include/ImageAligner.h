#import <Foundation/Foundation.h>
#import "MatWrapper.h"

// holds the results of trying to align N number of frames with another base image
// aligned is a per pixel median of all properly aligned frames
// failed is a per pixel median of all frames which were not able to be aligned
@interface AlignmentResult : NSObject
@property(nonatomic, strong, nullable) MatWrapper *alignedMat;   // warped frame
@property(nonatomic, assign) int numAligned;
@property(nonatomic, strong, nullable) MatWrapper *failedMat;    // fallback/original frame
@property(nonatomic, assign) int numFailed;
@property(nonatomic, strong, nullable) MatWrapper *horizonMask; // median merged horizonMask

-(AlignmentResult* _Nonnull)initWithAlignedMat:(nullable MatWrapper *)alignedMat
                                    numAligned:(int)numAligned
                                     failedMat:(nullable MatWrapper *)failedMat
                                     numFailed:(int)numFailed
                                   horizonMask:(nullable MatWrapper *)horizonMask;
@end


typedef NS_ENUM(NSInteger, FeatureMatchMethod) {
    FeatureMatchMethodBruteForce = 0,
    FeatureMatchMethodKNNLowes   = 1,
    FeatureMatchMethodFLANN      = 2
};

@interface ImageAligner : NSObject

+ (id)medianMergeImage:(MatWrapper*)image
         withFilenames:(NSArray<NSString*>*)filenames
      outlierThreshold:(double)k
            includeAll:(BOOL)includeAll;

+ (id)medianMergeFilenames:(NSArray<NSString*>*)filenames
          outlierThreshold:(double)k
                includeAll:(BOOL)includeAll;


// just median merges the frames without any alignment
+ (id)medianMerge:(NSArray<MatWrapper*>*)frames
 outlierThreshold:(double)k
       includeAll:(BOOL)includeAll;

// align frames to special frame, with optional mask which shows where to get keypoints from
// 
+ (id)alignFrames:(MatWrapper *)special
           frames:(NSArray<NSString *> *)frameFilenames
       frameMasks:(NSArray<NSString *> *)frameMaskFilenames
      matchMethod:(FeatureMatchMethod)matchMethod
             mask:(MatWrapper *)mask // assumed to be zero for ground, non-zero for sky
     maxDeviation:(double)maxDeviation
maxCornerDeviation:(double)maxCornerDeviation
       invertMask:(BOOL)invertMask
     maxKeypoints:(int)maxKeypoints
 outlierThreshold:(double)k;

+(MatWrapper *)createGradientMaskIntoSky:(MatWrapper*)binaryMask
                        gradientDistance:(int)gradientDistance;

+(MatWrapper *)createGradientMaskIntoGround:(MatWrapper*)binaryMask
                           gradientDistance:(int)gradientDistance;

@end
