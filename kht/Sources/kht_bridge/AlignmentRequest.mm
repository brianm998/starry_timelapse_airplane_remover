#import "AlignmentRequest.h"

@implementation AlignmentRequest

- (instancetype)initWithBaseImage:(MatWrapper * _Nonnull)baseImage
                       frameIndex:(int)frameIndex // frame index of baseImage
                        neighbors:(NSArray<AlignmentNeighborInfo*> * _Nonnull)neighbors
                      matchMethod:(FeatureMatchMethod)matchMethod
                             mask:(MatWrapper * _Nullable)mask // assumed to be zero for ground, non-zero for sky
                     maxDeviation:(double)maxDeviation
               maxCornerDeviation:(double)maxCornerDeviation
                    alignmentType:(AlignmentType)alignmentType
                     maxKeypoints:(int)maxKeypoints
                 outlierThreshold:(double)k
                 writeDebugImages:(BOOL)writeDebugImages
{

  self.baseImage = baseImage;

  self.frameIndex = frameIndex;
  self.neighbors = neighbors;
  self.matchMethod = matchMethod;
  self.mask = mask;

  self.maxDeviation = maxDeviation;
  self.maxCornerDeviation = maxCornerDeviation;
  self.alignmentType = alignmentType;
  self.maxKeypoints = maxKeypoints;
  self.k = k;
  self.writeDebugImages = writeDebugImages;

  return self;
}
@end


