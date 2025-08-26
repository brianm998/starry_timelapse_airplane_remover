// PixelatedImageBridge.h
#pragma once

#import <Foundation/Foundation.h>

#import "HorizonResult.h"

NS_ASSUME_NONNULL_BEGIN

typedef void* Mat;

@interface PixelatedImageBridge : NSObject

/// Takes a binary 8-bit grayscale NSImage and keeps N largest connected components.
+ (NSImage *)filterConnectedComponents:(NSImage *)image keepLargest:(NSInteger)n;

// removes anything but the ground, and returns the Y boundaries of the horizon
+ (HorizonResult *)groundOnlyFrom:(NSImage *)image;

/// Returns the processed NSImage along with horizon extents
+ (HorizonResult *)horizonExtentsFromImage:(NSImage *)image;

+(double)maxBrightnessScaleForImage:(NSImage *)image
			  maskImage:(NSImage *)mask;

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

+ (int)matChannels:(Mat)mat;
+ (size_t)matElemSize:(Mat)mat;
+ (size_t)matStep:(Mat)mat;

+ (void)freeCvMat:(Mat)mat;

+ (NSData *)dataFromCvMat:(Mat)matPtr;

@end


NS_ASSUME_NONNULL_END
