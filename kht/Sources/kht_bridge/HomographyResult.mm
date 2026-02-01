#import "HomographyResult.h"

@implementation HomographyResult

-(HomographyResult* _Nonnull)initWithFrameIndex:(int)frameIndex
                                       warpInfo:(NSArray<AlignmentWarpInfo *> * _Nonnull)warpInfo
{
  self.frameIndex = frameIndex;
  self.warpInfo = warpInfo;
  return self;
}
@end

