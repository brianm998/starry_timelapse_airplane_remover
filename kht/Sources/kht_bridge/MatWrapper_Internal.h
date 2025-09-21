// MatWrapper_Internal.h
#import "MatWrapper.h"
#import <opencv2/opencv.hpp>

@interface MatWrapper ()

/// Designated initializer for C++ code
- (instancetype)initWithMat:(const cv::Mat&)mat;

/// Access underlying cv::Mat
@property (nonatomic, readonly) cv::Mat& mat;

@end
