#import "AlignmentWarpInfo.h"
#import "MatWrapper_Internal.h"

@implementation AlignmentWarpInfo

- (instancetype)initWithHomography:(MatWrapper *)homography
                         deviation:(double)deviation
                    alignmentState:(AlignmentStateObjC)alignmentState
                        frameIndex:(NSInteger)frameIndex
{
    if ((self = [super init])) {
        _homography = homography;
        _deviation = deviation;
        _frameIndex = frameIndex;
        _alignmentState = alignmentState;
    }
    return self;
}

- (instancetype _Nonnull)initForNoWarpWithFrameIndex:(NSInteger)frameIndex {
    if ((self = [super init])) {
        _homography = nil;
        _deviation = 0;
        _frameIndex = frameIndex;
        _alignmentState = AlignmentStateObjCNoAlignment;
    }
    return self;
}

@end
