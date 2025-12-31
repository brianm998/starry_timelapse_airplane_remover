#import "AlignmentWarpInfo.h"
#import "MatWrapper_Internal.h"

@implementation AlignmentWarpInfo

- (instancetype)initWithHomography:(MatWrapper *)homography
                         deviation:(double)deviation
                maxCornerDeviation:(double)maxCornerDeviation
                          accepted:(BOOL)accepted
                    alignmentState:(AlignmentStateObjC)alignmentState
                 neighborKeyPoints:(int)neighborKeyPoints
                    frameKeyPoints:(int)frameKeyPoints
                        frameIndex:(NSUInteger)frameIndex
{
    if ((self = [super init])) {
        _homography = homography;
        _deviation = deviation;
        _maxCornerDeviation = maxCornerDeviation;
        _accepted = accepted;
        _frameIndex = frameIndex;
        _alignmentState = alignmentState;
        _neighborKeyPoints = neighborKeyPoints;
        _frameKeyPoints = frameKeyPoints;
    }
    return self;
}

- (instancetype _Nonnull)initForNoWarpWithFrameIndex:(NSUInteger)frameIndex {
    if ((self = [super init])) {
        _homography = nil;
        _deviation = 0;
        _maxCornerDeviation = 0;
        _accepted = true;
        _frameIndex = frameIndex;
        _alignmentState = AlignmentStateObjCNoAlignment;
        _neighborKeyPoints = 0;
        _frameKeyPoints = 0;
    }
    return self;
}

@end
