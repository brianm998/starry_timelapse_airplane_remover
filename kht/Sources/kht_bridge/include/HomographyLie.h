#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HomographyLie : NSObject

/// Converts a 3x3 homography (row-major, length 9) to an 8D log-space vector
+ (NSArray<NSNumber *> *)logHomography:(NSArray<NSNumber *> *)homography;

/// Converts an 8D log-space vector back to a 3x3 homography (row-major, length 9)
+ (NSArray<NSNumber *> *)expHomography:(NSArray<NSNumber *> *)vector;

@end

NS_ASSUME_NONNULL_END
