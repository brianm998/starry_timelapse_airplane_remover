#import <Foundation/Foundation.h>
#import "FeatureMatchMethod.h"
#import "AlignmentType.h"
#import "AlignmentNeighborInfo.h"
#import "MatWrapper.h"

// Holds the request for alignment 

@interface AlignmentRequest : NSObject

@property(nonatomic, assign) int frameIndex;               // frame index of baseImage
@property(nonatomic, strong, nonnull) NSArray<AlignmentNeighborInfo *> * neighbors;
@property(nonatomic, strong, nullable) NSDictionary<NSNumber *, MatWrapper *> *homography;

- (instancetype _Nonnull)initWithFrameIndex:(int)frameIndex // frame index of baseImage
  
                                 neighbors:(NSArray<AlignmentNeighborInfo*> * _Nonnull)neighbors
                                homography:(NSDictionary<NSNumber *, MatWrapper *> * _Nullable)homography;

@end

