#import <Foundation/Foundation.h>
#import "MatWrapper.h"

@interface WarpedImageResult : NSObject

/// Warped frame if warping is possible at all
@property(nonatomic, strong, nullable) MatWrapper *warpedFrame;

/// Warped frame if warping is possible at all
@property(nonatomic, strong, nullable) MatWrapper *warpedHorizon;

- (instancetype _Nonnull)initWithWarpedFrame:(nullable MatWrapper *)warpedFrame
                               warpedHorizon:(nullable MatWrapper *)warpedHorizon;

@end
