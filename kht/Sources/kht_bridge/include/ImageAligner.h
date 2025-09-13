#import <Foundation/Foundation.h>

#ifndef STAR_MAT_TYPEDEF
#define STAR_MAT_TYPEDEF
typedef void* Mat;
#endif

@interface AlignmentResult : NSObject
@property(nonatomic, strong) NSArray<NSValue *> *aligned;   // warped frames
@property(nonatomic, strong) NSArray<NSValue *> *failed;    // fallback/original frames
@end


@interface ImageAligner : NSObject

// align frames to special frame, with optional mask which shows where to get keypoints from
// 
+ (id)alignFrames:(Mat)special
	   frames:(NSArray<NSValue *> *)frames
	     mask:(Mat)mask	// XXX really should pass frameMasks here too
     maxDeviation:(double)maxDeviation
maxCornerDeviation:(double)maxCornerDeviation
       invertMask:(BOOL)invertMask
     maxKeypoints:(int)maxKeypoints;

+(Mat)createGradientMaskIntoSky:(Mat)binaryMask
	       gradientDistance:(int)gradientDistance;

+(Mat)createGradientMaskIntoGround:(Mat)binaryMask
		  gradientDistance:(int)gradientDistance;

@end
