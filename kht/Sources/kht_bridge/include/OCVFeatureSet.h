#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
#import <opencv2/core.hpp>
#import <opencv2/features2d.hpp>
#include <vector>
#endif

NS_ASSUME_NONNULL_BEGIN

@interface OCVFeatureSet : NSObject <NSCopying>

#pragma mark - Construction

/// Empty feature set
- (instancetype)init;

/// Construct from existing OpenCV data (Objective-C++ only)
#ifdef __cplusplus
- (instancetype)initWithKeypoints:(const std::vector<cv::KeyPoint> &)keypoints
                      descriptors:(const cv::Mat &)descriptors;
#endif

#pragma mark - Metadata (Swift-safe)

@property (nonatomic, readonly) NSInteger keypointCount;
@property (nonatomic, readonly) NSInteger descriptorRows;
@property (nonatomic, readonly) NSInteger descriptorCols;
@property (nonatomic, readonly) int descriptorType;

/// Load from file (YAML / XML / JSON)
- (nullable instancetype)initWithFile:(NSString *)filename
                                 error:(NSError **)error;

/// Write to file
- (BOOL)writeToFile:(NSString *)filename
              error:(NSError **)error;

#pragma mark - OpenCV Access (Objective-C++ only)

#ifdef __cplusplus
@property (nonatomic, readonly) std::vector<cv::KeyPoint> &keypoints;
@property (nonatomic, readonly) cv::Mat &descriptors;
#endif

@end

NS_ASSUME_NONNULL_END
