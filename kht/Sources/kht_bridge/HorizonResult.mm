#import <opencv2/opencv.hpp>
#import "HorizonResult.h"

@implementation HorizonResult

- (instancetype)initWithImage:(NSImage *)image
                highestBlackY:(NSInteger)highestBlackY
                 lowestWhiteY:(NSInteger)lowestWhiteY {
    self = [super init];
    if (self) {
        _image = image;
        _highestBlackY = highestBlackY;
        _lowestWhiteY = lowestWhiteY;
    }
    return self;
}

@end


@implementation HorizonHelper

+ (HorizonResult *)horizonExtentsFromImage:(NSImage *)image {
    // Convert NSImage -> cv::Mat (example conversion, you may already have a helper for this)
    CGImageRef cgRef = [image CGImageForProposedRect:NULL context:nil hints:nil];
    NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] initWithCGImage:cgRef];
    NSInteger width  = [bitmapRep pixelsWide];
    NSInteger height = [bitmapRep pixelsHigh];

    cv::Mat mat((int)height, (int)width, CV_8UC4, (void *)[bitmapRep bitmapData], [bitmapRep bytesPerRow]);
    cv::Mat gray, binary;
    cv::cvtColor(mat, gray, cv::COLOR_RGBA2GRAY);
    cv::threshold(gray, binary, 128, 255, cv::THRESH_BINARY);

    // --- Find horizon extents ---
    int highestBlackY = -1;
    for (int y = 0; y < binary.rows; y++) {
        if (cv::countNonZero(binary.row(y) == 0) > 0) {
            highestBlackY = y;
            break;
        }
    }

    int lowestWhiteY = -1;
    for (int y = binary.rows - 1; y >= 0; y--) {
        if (cv::countNonZero(binary.row(y) == 255) > 0) {
            lowestWhiteY = y;
            break;
        }
    }

    HorizonResult *result = [[HorizonResult alloc] initWithImage:image
                                                   highestBlackY:highestBlackY
                                                    lowestWhiteY:lowestWhiteY];
    return result;
}

@end
