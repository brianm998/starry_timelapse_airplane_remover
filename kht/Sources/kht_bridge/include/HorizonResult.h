#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// A simple container for horizon analysis results.
@interface HorizonResult : NSObject

@property (nonatomic, strong) NSImage *image;
@property (nonatomic, assign) NSInteger horizonTopY;
@property (nonatomic, assign) NSInteger horizonBottomY;

/// Convenience initializer
- (instancetype)initWithImage:(NSImage *)image
		  horizonTopY:(NSInteger)horizonTopY
	       horizonBottomY:(NSInteger)horizonBottomY;

@end


NS_ASSUME_NONNULL_END
