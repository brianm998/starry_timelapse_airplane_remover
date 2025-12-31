#import <Foundation/Foundation.h>
#import "FeatureMatchMethod.h"
#import "AlignmentNeighborInfo.h"
#import "MatWrapper.h"

// Holds the request for alignment 

@interface AlignmentRequest : NSObject

@property(nonatomic, strong, nonnull) MatWrapper *special; // the frame being aligned to
@property(nonatomic, assign) int frameIndex;               // frame index of special
@property(nonatomic, strong, nonnull) NSArray<AlignmentNeighborInfo *> * neighbors;
@property(nonatomic, assign) FeatureMatchMethod matchMethod;
@property(nonatomic, strong, nullable) MatWrapper * mask; // assumed to be zero for ground, non-zero for sky

@property(nonatomic, assign) double maxDeviation;
@property(nonatomic, assign) double maxCornerDeviation;
@property(nonatomic, assign) BOOL invertMask;
@property(nonatomic, assign) int maxKeypoints;
@property(nonatomic, assign) double k;

- (instancetype _Nonnull)initWithSpecial:(MatWrapper * _Nonnull)special
                              frameIndex:(int)frameIndex // frame index of special
  
                               neighbors:(NSArray<AlignmentNeighborInfo*> * _Nonnull)neighbors
                             matchMethod:(FeatureMatchMethod)matchMethod
                                    mask:(MatWrapper * _Nullable)mask // assumed to be zero for ground, non-zero for sky
                            maxDeviation:(double)maxDeviation
                      maxCornerDeviation:(double)maxCornerDeviation
                              invertMask:(BOOL)invertMask
                            maxKeypoints:(int)maxKeypoints
                        outlierThreshold:(double)k;

@end

