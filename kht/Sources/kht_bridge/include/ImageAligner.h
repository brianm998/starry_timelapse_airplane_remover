#import <Foundation/Foundation.h>

#ifndef STAR_MAT_TYPEDEF
#define STAR_MAT_TYPEDEF
typedef void* Mat;
#endif

@interface AlignmentResult : NSObject
@property(nonatomic, strong) NSValue *aligned;   // warped frame
@property(nonatomic, assign) int numAligned;
@property(nonatomic, strong) NSValue *failed;    // fallback/original frame
@property(nonatomic, assign) int numFailed;
@end


typedef NS_ENUM(NSInteger, FeatureMatchMethod) {
    FeatureMatchMethodBruteForce = 0,
    FeatureMatchMethodKNNLowes   = 1,
    FeatureMatchMethodFLANN      = 2
};

@interface ImageAligner : NSObject

// align frames to special frame, with optional mask which shows where to get keypoints from
// 
+ (id)alignFrames:(Mat)special
	   frames:(NSArray<NSValue *> *)frames
      matchMethod:(FeatureMatchMethod)matchMethod
	     mask:(Mat)mask	// XXX really should pass frameMasks here too
     maxDeviation:(double)maxDeviation
maxCornerDeviation:(double)maxCornerDeviation
       invertMask:(BOOL)invertMask
     maxKeypoints:(int)maxKeypoints
 outlierThreshold:(double)k;

+(Mat)createGradientMaskIntoSky:(Mat)binaryMask
	       gradientDistance:(int)gradientDistance;

+(Mat)createGradientMaskIntoGround:(Mat)binaryMask
		  gradientDistance:(int)gradientDistance;

@end
