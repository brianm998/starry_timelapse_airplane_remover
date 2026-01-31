#import "WarpedImageResult.h"
#import "MatWrapper_Internal.h"

@implementation WarpedImageResult

- (instancetype _Nonnull)initWithWarpedFrame:(nullable MatWrapper *)warpedFrame
                               warpedHorizon:(nullable MatWrapper *)warpedHorizon
{
    if ((self = [super init])) {
        _warpedFrame = warpedFrame;
        _warpedHorizon = warpedHorizon;
    }
    return self;
}

@end
