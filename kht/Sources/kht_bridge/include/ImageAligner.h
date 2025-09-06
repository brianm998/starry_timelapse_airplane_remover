#import <Foundation/Foundation.h>

#ifndef STAR_MAT_TYPEDEF
#define STAR_MAT_TYPEDEF
typedef void* Mat;
#endif

@interface ImageAligner : NSObject

+ (NSArray<NSValue *> *)alignFrames:(Mat)special
			     frames:(NSArray<NSValue *> *)frames
			       mask:(Mat)mask
                         invertMask:(BOOL)invertMask
		   invertBrightness:(BOOL)invertBrightness
		       maxKeypoints:(int)maxKeypoints;

@end
