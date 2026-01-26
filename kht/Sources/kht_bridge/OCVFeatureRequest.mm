#import "OCVFeatureRequest.h"

@implementation OCVFeatureRequest

- (instancetype)initWithBaseImage:(MatWrapper * _Nonnull)baseImage
                       frameIndex:(int)frameIndex // frame index of baseImage
                      matchMethod:(FeatureMatchMethod)matchMethod
                             mask:(MatWrapper * _Nullable)mask // assumed to be zero for ground, non-zero for sky
                    alignmentType:(AlignmentType)alignmentType
                     maxKeypoints:(int)maxKeypoints
                 writeDebugImages:(BOOL)writeDebugImages
           groundHorizonExtension:(int)groundHorizonExtension
              baseImageDilateSize:(int)baseImageDilateSize
          baseImageThresholdValue:(int)baseImageThresholdValue
{
  self.baseImage = baseImage;
  self.frameIndex = frameIndex;
  self.matchMethod = matchMethod;
  self.mask = mask;
  self.alignmentType = alignmentType;
  self.maxKeypoints = maxKeypoints;
  self.writeDebugImages = writeDebugImages;
  self.groundHorizonExtension = groundHorizonExtension;
  self.baseImageDilateSize = baseImageDilateSize;
  self.baseImageThresholdValue = baseImageThresholdValue;
  return self;
}
@end


