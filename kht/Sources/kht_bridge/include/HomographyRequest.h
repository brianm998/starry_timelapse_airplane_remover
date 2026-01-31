#import <Foundation/Foundation.h>
#import "FeatureMatchMethod.h"
#import "AlignmentType.h"
#import "AlignmentNeighborInfo.h"
#import "MatWrapper.h"

// Holds the request for alignment 

@interface HomographyRequest : NSObject

@property(nonatomic, strong, nullable) OCVFeatureSet *baseKeypoints; // keypoints for the base image
@property(nonatomic, assign) int frameIndex;               // frame index of baseImage
@property(nonatomic, strong, nonnull) NSArray<AlignmentNeighborInfo *> * neighbors;
@property(nonatomic, assign) FeatureMatchMethod matchMethod;
@property(nonatomic, strong, nullable) MatWrapper * mask; // assumed to be zero for ground, non-zero for sky

@property(nonatomic, assign) AlignmentType alignmentType;
@property(nonatomic, assign) BOOL writeDebugImages;
@property(nonatomic, assign) int maxKeypoints;


- (instancetype _Nonnull)initWithBaseKeypoints:(OCVFeatureSet * _Nullable)baseKeypoints
                                    frameIndex:(int)frameIndex // frame index of baseImage
                                     neighbors:(NSArray<AlignmentNeighborInfo*> * _Nonnull)neighbors
                                   matchMethod:(FeatureMatchMethod)matchMethod
                                          mask:(MatWrapper * _Nullable)mask // assumed to be zero for ground, non-zero for sky
                                 alignmentType:(AlignmentType)alignmentType
                                  maxKeypoints:(int)maxKeypoints
                              writeDebugImages:(BOOL)writeDebugImages;

@end

