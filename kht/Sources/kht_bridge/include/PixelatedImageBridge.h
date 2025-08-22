// PixelatedImageBridge.h
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "HorizonResult.h"

NS_ASSUME_NONNULL_BEGIN

@interface PixelatedImageBridge : NSObject

/// Takes a binary 8-bit grayscale NSImage and keeps N largest connected components.
+ (NSImage *)filterConnectedComponents:(NSImage *)image keepLargest:(NSInteger)n;

// removes anything but the ground, and returns the Y boundaries of the horizon
+ (HorizonResult *)groundOnlyFrom:(NSImage *)image;
@end

NS_ASSUME_NONNULL_END
