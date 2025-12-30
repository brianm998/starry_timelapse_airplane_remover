#import "AlignmentWarpInfo.h"
#import "MatWrapper_Internal.h"

@implementation AlignmentWarpInfo

- (instancetype)initWithHomography:(MatWrapper *)homography
                         deviation:(double)deviation
                maxCornerDeviation:(double)maxCornerDeviation
                          accepted:(BOOL)accepted
                        frameIndex:(NSUInteger)frameIndex
{
    if ((self = [super init])) {
        _homography = homography;
        _deviation = deviation;
        _maxCornerDeviation = maxCornerDeviation;
        _accepted = accepted;
        _frameIndex = frameIndex;
    }
    return self;
}

@end
