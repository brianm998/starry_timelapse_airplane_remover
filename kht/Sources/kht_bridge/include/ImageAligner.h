#import <Foundation/Foundation.h>
#import "FeatureMatchMethod.h"
#import "AlignmentNeighborInfo.h"
#import "AlignmentRequest.h"
#import "AlignmentResult.h"
#import "MatWrapper.h"
#import "ObjcAlignmentStep.h"

typedef void (^ImageAlignerUpdateBlock)(int frameIndex, AlignmentType alignmentType, ObjCAlignmentStep alignmentStep, int neighborNumber);

#define SET_FRAME_STATE(request, alignmentStep, neighborNumber) handler(request.frameIndex, request.alignmentType, alignmentStep, neighborNumber)

@interface ImageAligner : NSObject

+ (id _Nonnull)medianMergeImage:(MatWrapper* _Nonnull)image
                  withFilenames:(NSArray<NSString*>* _Nonnull)filenames
               outlierThreshold:(double)k
                     includeAll:(BOOL)includeAll;

+ (id _Nonnull)medianMergeFilenames:(NSArray<NSString*>* _Nonnull)filenames
                   outlierThreshold:(double)k
                         includeAll:(BOOL)includeAll;


// just median merges the frames without any alignment
+ (MatWrapper* _Nonnull)medianMerge:(NSArray<MatWrapper*>* _Nonnull)frames
                   outlierThreshold:(double)k
                         includeAll:(BOOL)includeAll;

// align frames to special frame, with optional mask which shows where to get keypoints from

// main alignment method
+ (id _Nullable)alignWithRequest:(AlignmentRequest * _Nonnull)request
                         handler:(ImageAlignerUpdateBlock _Nonnull)handler;

// doesn't compute homography, expects it
+ (id _Nullable)alignWithExistingHomographyRequest:(AlignmentRequest * _Nonnull)request;

+(MatWrapper * _Nonnull)createGradientMaskIntoSky:(MatWrapper* _Nonnull)binaryMask
                                 gradientDistance:(int)gradientDistance;

+(MatWrapper * _Nonnull)createGradientMaskIntoGround:(MatWrapper* _Nonnull)binaryMask
                                    gradientDistance:(int)gradientDistance;

@end
