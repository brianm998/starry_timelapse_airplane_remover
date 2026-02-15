#import "OCVFeatureSet.h"

#import <opencv2/core.hpp>
#import <opencv2/features2d.hpp>

using namespace cv;

@interface OCVFeatureSet () {
@private
    std::vector<KeyPoint> _keypoints;
    Mat _descriptors;
}
@end

@implementation OCVFeatureSet

#pragma mark - Init

- (instancetype)init {
    self = [super init];
    if (self) {
        _keypoints.clear();
        _descriptors.release();
    }
    return self;
}

- (instancetype)initWithKeypoints:(const std::vector<cv::KeyPoint> &)keypoints
                      descriptors:(const cv::Mat &)descriptors
{
    self = [super init];
    if (self) {
        _keypoints = keypoints;      // copy
        _descriptors = descriptors;  // shallow ref-counted copy
    }
    return self;
}

- (instancetype)initWithFile:(NSString *)filename
                       error:(NSError **)error
{
    self = [self init];
    if (!self) { return nil; }

    BOOL isDirectory = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:filename
                                                       isDirectory:&isDirectory];
    
    if (!exists || isDirectory) {
      if (error) {
        *error = [NSError errorWithDomain:@"OCVFeatureSet"
                                     code:0
                                 userInfo:@{NSLocalizedDescriptionKey:
                                          @"Feature file does not exist"
                                            }];
      }
      return nil;
    }
    
    std::string path = filename.UTF8String;

    FileStorage fs(path, FileStorage::READ);
    if (!fs.isOpened()) {
        if (error) {
            *error = [NSError errorWithDomain:@"OCVFeatureSet"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"Failed to open feature file"
                                     }];
        }
        return nil;
    }

    fs["keypoints"] >> _keypoints;
    fs["descriptors"] >> _descriptors;

    fs.release();

    if (_keypoints.empty() || _descriptors.empty()) {
        if (error) {
            *error = [NSError errorWithDomain:@"OCVFeatureSet"
                                         code:2
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"Feature file contained no data"
                                     }];
        }
        return nil;
    }

    return self;
}

#pragma mark - Persistence

- (BOOL)writeToFile:(NSString *)filename
              error:(NSError **)error
{
    if (_keypoints.empty() || _descriptors.empty()) {
        if (error) {
            *error = [NSError errorWithDomain:@"OCVFeatureSet"
                                         code:3
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"No features to write"
                                     }];
        }
        return NO;
    }

    std::string path = filename.UTF8String;

    FileStorage fs(path, FileStorage::WRITE);
    if (!fs.isOpened()) {
        if (error) {
            *error = [NSError errorWithDomain:@"OCVFeatureSet"
                                         code:4
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"Failed to open file for writing"
                                     }];
        }
        return NO;
    }

    fs << "keypoints" << _keypoints;
    fs << "descriptors" << _descriptors;

    fs.release();
    return YES;
}

#pragma mark - Properties

- (NSInteger)keypointCount {
    return _keypoints.size();
}

- (NSInteger)descriptorRows {
    return _descriptors.rows;
}

- (NSInteger)descriptorCols {
    return _descriptors.cols;
}

- (int)descriptorType {
    return _descriptors.type();
}

- (std::vector<cv::KeyPoint> &)keypoints {
    return _keypoints;
}

- (cv::Mat &)descriptors {
    return _descriptors;
}

@end
