#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// A simple container for horizon analysis results.
@interface HorizonResult : NSObject

@property (nonatomic, strong) NSImage *image;
@property (nonatomic, assign) NSInteger highestBlackY;
@property (nonatomic, assign) NSInteger lowestWhiteY;

/// Convenience initializer
- (instancetype)initWithImage:(NSImage *)image
                highestBlackY:(NSInteger)highestBlackY
                 lowestWhiteY:(NSInteger)lowestWhiteY;

@end

/// Horizon helper class (Objective-C bridge to OpenCV)
@interface HorizonHelper : NSObject

/// Returns the processed NSImage along with horizon extents
+ (HorizonResult *)horizonExtentsFromImage:(NSImage *)image;

@end

NS_ASSUME_NONNULL_END
