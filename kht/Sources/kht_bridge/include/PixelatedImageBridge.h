// PixelatedImageBridge.h
#pragma once

#import <Foundation/Foundation.h>

#import "HorizonResult.h"

NS_ASSUME_NONNULL_BEGIN

@interface PixelatedImageBridge : NSObject

/// Takes a binary 8-bit grayscale NSImage and keeps N largest connected components.
+ (NSImage *)filterConnectedComponents:(NSImage *)image keepLargest:(NSInteger)n;

// removes anything but the ground, and returns the Y boundaries of the horizon
+ (HorizonResult *)groundOnlyFrom:(NSImage *)image;

/// Returns the processed NSImage along with horizon extents
+ (HorizonResult *)horizonExtentsFromImage:(NSImage *)image;

+(double)maxBrightnessScaleForImage:(NSImage *)image
			  maskImage:(NSImage *)mask;

+(NSImage *)brightenDarks:(NSImage *)image
		     mask:(NSImage *)mask
		   amount:(double)amount;



/// Create a cv::Mat wrapper around raw pixel buffer (no copy)
+ (void*)cvMatFromBuffer:(void *)bytes
                     width:(int)w
                    height:(int)h
                  channels:(int)c
            bitsPerChannel:(int)bits
              bytesPerRow:(int)bpr;

/// Copy cv::Mat contents into a newly allocated NSData
+ (NSData *)dataFromCvMat:(const void*)mat;


@end


NS_ASSUME_NONNULL_END
