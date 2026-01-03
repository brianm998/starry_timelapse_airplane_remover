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

@property(nonatomic, assign) AlignmentType alignmentType;
@property(nonatomic, assign) BOOL writeDebugImages;
@property(nonatomic, assign) int maxKeypoints;
@property(nonatomic, assign) int groundHorizonExtension;
@property(nonatomic, assign) int skyHorizonExtension;
@property(nonatomic, assign) int baseImageDilateSize;
@property(nonatomic, assign) int baseImageThresholdValue;
@property(nonatomic, assign) int neighborDilateSize;
@property(nonatomic, assign) int neighborThresholdValue;
@property(nonatomic, strong, nullable) NSDictionary<NSNumber *, MatWrapper *> *homography;

- (instancetype _Nonnull)initWithBaseImage:(MatWrapper * _Nonnull)baseImage
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
                                homography:(NSDictionary<NSNumber *, MatWrapper *> * _Nullable)homography;

@end

