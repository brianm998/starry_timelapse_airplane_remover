#import <Foundation/Foundation.h>
#import "AlignmentWarpInfo.h"
#import "MatWrapper.h"

typedef NS_ENUM(NSInteger, FeatureMatchMethod) {
    FeatureMatchMethodBruteForce = 0,
    FeatureMatchMethodKNNLowes   = 1,
    FeatureMatchMethodFLANN      = 2
};

@interface AlignmentNeighborInfo : NSObject

@property(nonatomic, strong, nonnull) NSString * filename;
@property(nonatomic, strong, nullable) NSString * maskFilename;
@property(nonatomic, assign) int frameIndex;

- (instancetype _Nonnull)initWithFilename:(NSString * _Nonnull)filename
                             maskFilename:(NSString * _Nullable)maskFilename
                               frameIndex:(int)frameIndex;

@end

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



// holds the results of trying to align N number of frames with another base image
// aligned is a per pixel median of all properly aligned frames
// failed is a per pixel median of all frames which were not able to be aligned
@interface AlignmentResult : NSObject
@property(nonatomic, strong, nullable) MatWrapper *alignedMat;   // warped frame

@property(nonatomic, strong, nullable) MatWrapper *failedMat;    // fallback/original frame

@property(nonatomic, strong, nullable) MatWrapper *horizonMask; // median merged horizonMask
/// Warp metadata
@property(nonatomic, strong) NSArray<AlignmentWarpInfo *> * _Nonnull alignedWarps;
@property(nonatomic, strong) NSArray<AlignmentWarpInfo *> * _Nonnull failedWarps;


-(AlignmentResult* _Nonnull)initWithAlignedMat:(nullable MatWrapper *)alignedMat
                                  alignedWarps:(NSArray<AlignmentWarpInfo *> * _Nonnull)alignedWarps
                                     failedMat:(nullable MatWrapper *)failedMat
                                   failedWarps:(NSArray<AlignmentWarpInfo *> * _Nonnull)failedWarps
                                   horizonMask:(nullable MatWrapper *)horizonMask;
@end


@interface ImageAligner : NSObject

+ (id _Nonnull)medianMergeImage:(MatWrapper* _Nonnull)image
                  withFilenames:(NSArray<NSString*>* _Nonnull)filenames
               outlierThreshold:(double)k
                     includeAll:(BOOL)includeAll;

+ (id _Nonnull)medianMergeFilenames:(NSArray<NSString*>* _Nonnull)filenames
                   outlierThreshold:(double)k
                         includeAll:(BOOL)includeAll;


// just median merges the frames without any alignment
+ (id _Nonnull)medianMerge:(NSArray<MatWrapper*>* _Nonnull)frames
          outlierThreshold:(double)k
                includeAll:(BOOL)includeAll;

// align frames to special frame, with optional mask which shows where to get keypoints from

// main alignment method
+ (id _Nullable)alignWithRequest:(AlignmentRequest * _Nonnull)request;

+(MatWrapper * _Nonnull)createGradientMaskIntoSky:(MatWrapper* _Nonnull)binaryMask
                                 gradientDistance:(int)gradientDistance;

+(MatWrapper * _Nonnull)createGradientMaskIntoGround:(MatWrapper* _Nonnull)binaryMask
                                    gradientDistance:(int)gradientDistance;

@end
