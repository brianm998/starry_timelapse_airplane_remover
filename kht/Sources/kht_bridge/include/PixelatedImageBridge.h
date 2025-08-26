// PixelatedImageBridge.h
#pragma once

#import <Foundation/Foundation.h>

#import "HorizonResult.h"

NS_ASSUME_NONNULL_BEGIN

typedef void* Mat;

@interface PixelatedImageBridge : NSObject

/// Takes a binary 8-bit grayscale NSImage and keeps N largest connected components.
+ (Mat)filterConnectedComponents:(Mat)image keepLargest:(NSInteger)n;

// removes anything but the ground, and returns the Y boundaries of the horizon
+ (HorizonResult *)groundOnlyFrom:(NSImage *)image;

/// Returns the processed NSImage along with horizon extents
+ (HorizonResult *)horizonExtentsFromImage:(NSImage *)image;

+(double)maxBrightnessScaleForImage:(Mat)image
			  maskImage:(Mat)mask;

+(Mat)brightenDarks:(Mat)image
	       mask:(Mat)mask
	     amount:(double)amount;

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

+ (NSData *)dataFromCvMat:(Mat)matPtr;

@end


NS_ASSUME_NONNULL_END
