// PixelatedImageBridge.h
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PixelatedImageBridge : NSObject

/// Takes a binary 8-bit grayscale NSImage and keeps N largest connected components.
+ (NSImage *)filterConnectedComponents:(NSImage *)image keepLargest:(NSInteger)n;

// removes anything but the ground
+ (NSImage *)groundOnlyFrom:(NSImage *)image;
@end

NS_ASSUME_NONNULL_END
