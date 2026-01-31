#import "HomographyRequest.h"

@implementation HomographyRequest

- (instancetype)initWithBaseImage:(MatWrapper * _Nonnull)baseImage
                    baseKeypoints:(OCVFeatureSet * _Nullable)baseKeypoints
                       frameIndex:(int)frameIndex // frame index of baseImage
                        neighbors:(NSArray<AlignmentNeighborInfo*> * _Nonnull)neighbors
                      matchMethod:(FeatureMatchMethod)matchMethod
                             mask:(MatWrapper * _Nullable)mask // assumed to be zero for ground, non-zero for sky
                    alignmentType:(AlignmentType)alignmentType
                     maxKeypoints:(int)maxKeypoints
                 writeDebugImages:(BOOL)writeDebugImages

{
  self.frameIndex = frameIndex;
  self.neighbors = neighbors;
  self.mask = mask;
  self.alignmentType = alignmentType;
  self.maxKeypoints = maxKeypoints;
  self.writeDebugImages = writeDebugImages;
  return self;
}
@end


