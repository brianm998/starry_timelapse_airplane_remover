#import <Foundation/Foundation.h>
#import "MatWrapper.h"

typedef NS_ENUM(NSInteger, AlignmentStateObjC) {
    AlignmentStateObjCUnableToDetectKeypoints = 0,
    AlignmentStateObjCNotEnoughKeypoints      = 1,
    AlignmentStateObjCNoHomographyFound       = 2,
    AlignmentStateObjCHomographySuccess       = 3,
    AlignmentStateObjCUnknown                 = 4,
};

@interface AlignmentWarpInfo : NSObject

/// 3x3 homography matrix (CV_64F), nil if none computed
@property(nonatomic, strong, nullable) MatWrapper *homography;

/// L2 norm of (H - I)
@property(nonatomic, assign) double deviation;

/// Maximum corner displacement
@property(nonatomic, assign) double maxCornerDeviation;

/// YES if warp passed thresholds and was used
@property(nonatomic, assign) BOOL accepted;

// how many keypoints were found on the neighbor
@property(nonatomic, assign) int neighborKeyPoints;

// how many keypoints were found on the frame being processed
@property(nonatomic, assign) int frameKeyPoints;
                          
@property(nonatomic, assign) AlignmentStateObjC alignmentState;

/// Index into original frame array (optional but very useful)
@property(nonatomic, assign) NSUInteger frameIndex;

- (instancetype _Nonnull)initWithHomography:(nullable MatWrapper *)homography
                                  deviation:(double)deviation
                         maxCornerDeviation:(double)maxCornerDeviation
                                   accepted:(BOOL)accepted
                             alignmentState:(AlignmentStateObjC)alignmentState
                          neighborKeyPoints:(int)neighborKeyPoints
                             frameKeyPoints:(int)frameKeyPoints
                                 frameIndex:(NSUInteger)frameIndex;

@end
