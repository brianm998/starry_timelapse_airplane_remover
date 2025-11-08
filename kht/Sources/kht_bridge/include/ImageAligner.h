#import <Foundation/Foundation.h>
#import "MatWrapper.h"

@interface AlignmentResult : NSObject
@property(nonatomic, strong) MatWrapper *aligned;   // warped frame
@property(nonatomic, assign) int numAligned;
@property(nonatomic, strong) MatWrapper *failed;    // fallback/original frame
@property(nonatomic, assign) int numFailed;
@end


typedef NS_ENUM(NSInteger, FeatureMatchMethod) {
    FeatureMatchMethodBruteForce = 0,
    FeatureMatchMethodKNNLowes   = 1,
    FeatureMatchMethodFLANN      = 2
};

@interface ImageAligner : NSObject


+ (id)medianMergeFilenames:(NSArray<NSString*>*)filenames
 outlierThreshold:(double)k;


// just median merges the frames without any alignment
+ (id)medianMerge:(NSArray<MatWrapper*>*)frames
 outlierThreshold:(double)k;

// align frames to special frame, with optional mask which shows where to get keypoints from
// 
+ (id)alignFrames:(MatWrapper *)special
           frames:(NSArray<NSString *> *)frameFilenames
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
