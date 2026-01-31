#import <Foundation/Foundation.h>
#import "AlignmentWarpInfo.h"

// holds the homography of neighbor frames to the frame being processed
@interface HomographyResult : NSObject

/// Warp metadata
@property(nonatomic, strong) NSArray<AlignmentWarpInfo *> * _Nonnull warpInfo;

-(HomographyResult* _Nonnull)initWithWarpInfo:(NSArray<AlignmentWarpInfo *> * _Nonnull)warpInfo;
@end

