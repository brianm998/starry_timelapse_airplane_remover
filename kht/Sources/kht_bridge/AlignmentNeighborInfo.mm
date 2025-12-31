#import "AlignmentNeighborInfo.h"

@implementation AlignmentNeighborInfo


- (AlignmentNeighborInfo * _Nonnull)initWithFilename:(NSString * _Nonnull)filename
                                        maskFilename:(NSString * _Nullable)maskFilename
                                          frameIndex:(int)frameIndex
{
  self.filename = filename;
  self.maskFilename = maskFilename;
  self.frameIndex = frameIndex;
  return self;
}

@end

