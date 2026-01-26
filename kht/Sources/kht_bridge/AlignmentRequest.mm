#import "AlignmentRequest.h"

@implementation AlignmentRequest

- (instancetype)initWithBaseImage:(MatWrapper * _Nonnull)baseImage
                    baseKeypoints:(OCVFeatureSet * _Nullable)baseKeypoints
                       frameIndex:(int)frameIndex // frame index of baseImage
                        neighbors:(NSArray<AlignmentNeighborInfo*> * _Nonnull)neighbors
                      matchMethod:(FeatureMatchMethod)matchMethod
                             mask:(MatWrapper * _Nullable)mask // assumed to be zero for ground, non-zero for sky
                    alignmentType:(AlignmentType)alignmentType
                     maxKeypoints:(int)maxKeypoints
                 writeDebugImages:(BOOL)writeDebugImages
           groundHorizonExtension:(int)groundHorizonExtension
              skyHorizonExtension:(int)skyHorizonExtension
              baseImageDilateSize:(int)baseImageDilateSize
          baseImageThresholdValue:(int)baseImageThresholdValue
               neighborDilateSize:(int)neighborDilateSize
           neighborThresholdValue:(int)neighborThresholdValue
                       homography:(NSDictionary<NSNumber *, MatWrapper *> *)homography
{
  self.baseImage = baseImage;
  self.baseKeypoints = baseKeypoints;
  self.frameIndex = frameIndex;
  self.neighbors = neighbors;
  self.matchMethod = matchMethod;
  self.mask = mask;
  self.alignmentType = alignmentType;
  self.maxKeypoints = maxKeypoints;
  self.writeDebugImages = writeDebugImages;
  self.skyHorizonExtension = skyHorizonExtension;
  self.groundHorizonExtension = groundHorizonExtension;
  self.baseImageDilateSize = baseImageDilateSize;
  self.baseImageThresholdValue = baseImageThresholdValue;
  self.neighborDilateSize = neighborDilateSize;
  self.neighborThresholdValue = neighborThresholdValue;
  self.homography = homography;
  return self;
}
@end


