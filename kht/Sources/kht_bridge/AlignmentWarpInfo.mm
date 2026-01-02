#import "AlignmentWarpInfo.h"
#import "MatWrapper_Internal.h"

@implementation AlignmentWarpInfo

- (instancetype)initWithHomography:(MatWrapper *)homography
                       warpedFrame:(nullable MatWrapper *)warpedFrame
                     warpedHorizon:(nullable MatWrapper *)warpedHorizon
                         deviation:(double)deviation
                maxCornerDeviation:(double)maxCornerDeviation
                    alignmentState:(AlignmentStateObjC)alignmentState
                 neighborKeyPoints:(int)neighborKeyPoints
                    frameKeyPoints:(int)frameKeyPoints
                        frameIndex:(NSUInteger)frameIndex
{
    if ((self = [super init])) {
        _homography = homography;
        _warpedFrame = warpedFrame;
        _warpedHorizon = warpedHorizon;
        _deviation = deviation;
        _maxCornerDeviation = maxCornerDeviation;
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
        _warpedFrame = nil;
        _deviation = 0;
        _maxCornerDeviation = 0;
        _frameIndex = frameIndex;
        _alignmentState = AlignmentStateObjCNoAlignment;
        _neighborKeyPoints = 0;
        _frameKeyPoints = 0;
    }
    return self;
}

@end
