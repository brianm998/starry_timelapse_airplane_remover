#import <Foundation/Foundation.h>
#import "MatWrapper.h"

typedef NS_ENUM(NSInteger, AlignmentStateObjC) {
    AlignmentStateObjCUnableToDetectKeypoints = 0,
    AlignmentStateObjCNotEnoughKeypoints      = 1,
    AlignmentStateObjCNoHomographyFound       = 2,
    AlignmentStateObjCHomographySuccess       = 3,
    AlignmentStateObjCUsedExistingHomography  = 4,
    AlignmentStateObjCNoAlignment             = 5,
    AlignmentStateObjCUnknown                 = 6,
};

@interface AlignmentWarpInfo : NSObject

/// 3x3 homography matrix (CV_64F), nil if none computed
@property(nonatomic, strong, nullable) MatWrapper *homography;

/// L2 norm of (H - I)
@property(nonatomic, assign) double deviation;

@property(nonatomic, assign) AlignmentStateObjC alignmentState;

/// Index into original frame array (optional but very useful)
@property(nonatomic, assign) NSUInteger frameIndex;

- (instancetype _Nonnull)initWithHomography:(nullable MatWrapper *)homography
                                  deviation:(double)deviation
                             alignmentState:(AlignmentStateObjC)alignmentState
                                 frameIndex:(NSUInteger)frameIndex;

- (instancetype _Nonnull)initForNoWarpWithFrameIndex:(NSUInteger)frameIndex;


@end
