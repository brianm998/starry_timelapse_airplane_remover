#import <Foundation/Foundation.h>
#import "MatWrapper.h"

@interface AlignmentWarpInfo : NSObject

/// 3x3 homography matrix (CV_64F), nil if none computed
@property(nonatomic, strong, nullable) MatWrapper *homography;

/// L2 norm of (H - I)
@property(nonatomic, assign) double deviation;

/// Maximum corner displacement
@property(nonatomic, assign) double maxCornerDeviation;

/// YES if warp passed thresholds and was used
@property(nonatomic, assign) BOOL accepted;

/// Index into original frame array (optional but very useful)
@property(nonatomic, assign) NSUInteger frameIndex;

- (instancetype _Nonnull)initWithHomography:(nullable MatWrapper *)homography
                                  deviation:(double)deviation
                         maxCornerDeviation:(double)maxCornerDeviation
                                   accepted:(BOOL)accepted
                                 frameIndex:(NSUInteger)frameIndex;

@end
