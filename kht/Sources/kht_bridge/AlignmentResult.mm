#import "AlignmentResult.h"

@implementation AlignmentResult

-(AlignmentResult* _Nonnull)initWithAlignedMat:(nullable MatWrapper *)alignedMat
                                     failedMat:(nullable MatWrapper *)failedMat
                                   horizonMask:(nullable MatWrapper *)horizonMask
{
  self.alignedMat = alignedMat;
  self.failedMat = failedMat;
  self.horizonMask = horizonMask;
  return self;
}
@end

