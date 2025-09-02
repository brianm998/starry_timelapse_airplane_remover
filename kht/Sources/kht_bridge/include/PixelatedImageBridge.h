// PixelatedImageBridge.h
#pragma once

#import <Foundation/Foundation.h>

#ifndef STAR_MAT_TYPEDEF
#define STAR_MAT_TYPEDEF
typedef void* Mat;
#endif

#import "HorizonResult.h"

NS_ASSUME_NONNULL_BEGIN


@interface PixelatedImageBridge : NSObject

// combines two images with a mask
// non zero mask pixels get image1
//     zero mask pixels get image2
+ (Mat)combineImage:(Mat)image1
               mask:(Mat)mask
         background:(Mat)image2;

/// Takes an expected binary cv::Mat and makes it 8-bit grayscale,
// then and keeps N largest connected components, returning a cv::Mat
+ (Mat)filterConnectedComponents:(Mat)image keepLargest:(NSInteger)n;

// removes anything but the ground, and returns the Y boundaries of the horizon
+ (Mat)groundOnlyFrom:(Mat)image;

/// Returns the vertical horizon extents
+ (HorizonResult *)horizonExtentsFromImage:(Mat)image;

+(double)maxBrightnessScaleForImage:(Mat)image
			  maskImage:(Mat)mask;

+(Mat)brightenDarks:(Mat)image
	       mask:(Mat)mask
	     amount:(double)amount;

+(Mat)darkenDarks:(Mat)image
	       mask:(Mat)mask
	     amount:(double)amount;

+(Mat)maskRaisedBy:(Mat)image
              mask:(Mat)mask
            border:(int)amount;

/// Create a cv::Mat wrapper around raw pixel buffer (no copy)
+ (Mat)cvMatFromBuffer:(void *)bytes
		 width:(int)w
		height:(int)h
	      channels:(int)c
	bitsPerChannel:(int)bits
	   bytesPerRow:(int)bpr;

// helpers to read values from cv::Mat
+ (int)matChannels:(Mat)mat;
+ (size_t)matElemSize:(Mat)mat;
+ (size_t)matStep:(Mat)mat;

// make sure you call this to free any Mat returned anywhere here, they're all copies
// also make sure to free the Mat arguments passed in after creating them, they're in c++ world.
+ (void)freeCvMat:(Mat)mat;

// used when turning a Mat back into a PixelatedImage
+ (NSData *)dataFromCvMat:(Mat)matPtr;

@end


NS_ASSUME_NONNULL_END
