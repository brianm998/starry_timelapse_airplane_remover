#import "HomographyResult.h"

@implementation HomographyResult

-(HomographyResult* _Nonnull)initWithWarpInfo:(NSArray<AlignmentWarpInfo *> * _Nonnull)warpInfo
{
  self.warpInfo = warpInfo;
  return self;
}
@end

