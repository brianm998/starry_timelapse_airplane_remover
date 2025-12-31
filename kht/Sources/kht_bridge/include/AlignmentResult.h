#import <Foundation/Foundation.h>
#import "FeatureMatchMethod.h"
#import "AlignmentNeighborInfo.h"
#import "AlignmentWarpInfo.h"
#import "MatWrapper.h"

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

