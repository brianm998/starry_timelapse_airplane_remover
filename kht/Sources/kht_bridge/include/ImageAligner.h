#import <Foundation/Foundation.h>

#ifndef STAR_MAT_TYPEDEF
#define STAR_MAT_TYPEDEF
typedef void* Mat;
#endif

@interface ImageAligner : NSObject

// align frames to special frame, with optional mask which shows where to get keypoints from
// 
+ (id)alignFrames:(Mat)special
	   frames:(NSArray<NSValue *> *)frames
	     mask:(Mat)mask	// XXX really should pass frameMasks here too
     maxDeviation:(double)maxDeviation
       invertMask:(BOOL)invertMask
 invertBrightness:(BOOL)invertBrightness
     maxKeypoints:(int)maxKeypoints;

+ (id)alignFramesByMask:(Mat)mask
		   base:(Mat)special
		 frames:(NSArray<NSValue *> *)frames
	     frameMasks:(NSArray<NSValue *> *)frameMasks
	   maxKeypoints:(int)maxKeypoints;

+(Mat)createGradientMaskIntoSky:(Mat)binaryMask
	       gradientDistance:(int)gradientDistance;

+(Mat)createGradientMaskIntoGround:(Mat)binaryMask
		  gradientDistance:(int)gradientDistance;

@end
