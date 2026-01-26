#import "AlignmentNeighborInfo.h"

@implementation AlignmentNeighborInfo


- (AlignmentNeighborInfo * _Nonnull)initWithFilename:(NSString * _Nonnull)filename
                                        maskFilename:(NSString * _Nullable)maskFilename
                                           keypoints:(OCVFeatureSet * _Nullable)keypoints
                                          frameIndex:(int)frameIndex
{
  self.filename = filename;
  self.maskFilename = maskFilename;
  self.frameIndex = frameIndex;
  self.keypoints = keypoints;
  return self;
}

@end

