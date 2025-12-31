#import "AlignmentRequest.h"

@implementation AlignmentRequest

- (instancetype)initWithBaseImage:(MatWrapper * _Nonnull)baseImage
                       frameIndex:(int)frameIndex // frame index of baseImage
                        neighbors:(NSArray<AlignmentNeighborInfo*> * _Nonnull)neighbors
                      matchMethod:(FeatureMatchMethod)matchMethod
                             mask:(MatWrapper * _Nullable)mask // assumed to be zero for ground, non-zero for sky
                     maxDeviation:(double)maxDeviation
               maxCornerDeviation:(double)maxCornerDeviation
                       invertMask:(BOOL)invertMask
                     maxKeypoints:(int)maxKeypoints
                 outlierThreshold:(double)k
{

  self.baseImage = baseImage;

  self.frameIndex = frameIndex;
  self.neighbors = neighbors;
  self.matchMethod = matchMethod;
  self.mask = mask;

  self.maxDeviation = maxDeviation;
  self.maxCornerDeviation = maxCornerDeviation;
  self.invertMask = invertMask;
  self.maxKeypoints = maxKeypoints;
  self.k = k;

  return self;
}
@end


