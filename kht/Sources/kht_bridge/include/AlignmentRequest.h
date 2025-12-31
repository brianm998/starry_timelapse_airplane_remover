#import <Foundation/Foundation.h>
#import "FeatureMatchMethod.h"
#import "AlignmentType.h"
#import "AlignmentNeighborInfo.h"
#import "MatWrapper.h"

// Holds the request for alignment 

@interface AlignmentRequest : NSObject

@property(nonatomic, strong, nonnull) MatWrapper *baseImage; // the frame being aligned to
@property(nonatomic, assign) int frameIndex;               // frame index of baseImage
@property(nonatomic, strong, nonnull) NSArray<AlignmentNeighborInfo *> * neighbors;
@property(nonatomic, assign) FeatureMatchMethod matchMethod;
@property(nonatomic, strong, nullable) MatWrapper * mask; // assumed to be zero for ground, non-zero for sky

@property(nonatomic, assign) double maxDeviation;
@property(nonatomic, assign) double maxCornerDeviation;
@property(nonatomic, assign) AlignmentType alignmentType;
@property(nonatomic, assign) BOOL writeDebugImages;
@property(nonatomic, assign) int maxKeypoints;
@property(nonatomic, assign) double k;

- (instancetype _Nonnull)initWithBaseImage:(MatWrapper * _Nonnull)baseImage
                                frameIndex:(int)frameIndex // frame index of baseImage
  
                                 neighbors:(NSArray<AlignmentNeighborInfo*> * _Nonnull)neighbors
                               matchMethod:(FeatureMatchMethod)matchMethod
                                      mask:(MatWrapper * _Nullable)mask // assumed to be zero for ground, non-zero for sky
                              maxDeviation:(double)maxDeviation
                        maxCornerDeviation:(double)maxCornerDeviation
                             alignmentType:(AlignmentType)alignmentType
                              maxKeypoints:(int)maxKeypoints
                          outlierThreshold:(double)k
                          writeDebugImages:(BOOL)writeDebugImages;

@end

