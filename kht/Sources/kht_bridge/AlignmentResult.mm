#import "AlignmentResult.h"

@implementation AlignmentResult

-(AlignmentResult* _Nonnull)initWithAlignedMat:(nullable MatWrapper *)alignedMat
                                  alignedWarps:(NSArray<AlignmentWarpInfo *> *)alignedWarps
                                     failedMat:(nullable MatWrapper *)failedMat
                                   failedWarps:(NSArray<AlignmentWarpInfo *> *)failedWarps
                                   horizonMask:(nullable MatWrapper *)horizonMask
{
  self.alignedMat = alignedMat;
  self.alignedWarps = alignedWarps;
  self.failedMat = failedMat;
  self.failedWarps = failedWarps;
  self.horizonMask = horizonMask;
  return self;
}
@end

