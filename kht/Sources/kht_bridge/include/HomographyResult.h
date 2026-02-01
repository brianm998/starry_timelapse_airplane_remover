#import <Foundation/Foundation.h>
#import "AlignmentWarpInfo.h"

// holds the homography of neighbor frames to the frame being processed
@interface HomographyResult : NSObject

/// Warp metadata
@property(nonatomic, strong) NSArray<AlignmentWarpInfo *> * _Nonnull warpInfo;

@property(nonatomic, assign) int frameIndex;               // frame index of baseImage

-(HomographyResult* _Nonnull)initWithFrameIndex:(int)frameIndex
                                       warpInfo:(NSArray<AlignmentWarpInfo *> * _Nonnull)warpInfo;
@end

