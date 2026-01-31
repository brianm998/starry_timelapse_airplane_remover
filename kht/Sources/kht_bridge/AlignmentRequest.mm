#import "AlignmentRequest.h"

@implementation AlignmentRequest

- (instancetype)initWithFrameIndex:(int)frameIndex // frame index of baseImage
                        neighbors:(NSArray<AlignmentNeighborInfo*> * _Nonnull)neighbors
                       homography:(NSDictionary<NSNumber *, MatWrapper *> *)homography
{
  self.frameIndex = frameIndex;
  self.neighbors = neighbors;
  self.homography = homography;
  return self;
}
@end


