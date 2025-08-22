// PixelatedImageBridge.mm
#import <opencv2/opencv.hpp>
#import "PixelatedImageBridge.h"
#import "HorizonResult.h"

@implementation PixelatedImageBridge

/// Helper: safely wrap a cv::Mat into an NSImage
+ (NSImage *)imageFromMat:(const cv::Mat&)mat {
    // Ensure continuous memory
    cv::Mat owned = mat.isContinuous() ? mat : mat.clone();

    NSBitmapImageRep *outRep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:nil
                      pixelsWide:owned.cols
                      pixelsHigh:owned.rows
                   bitsPerSample:8
                 samplesPerPixel:1
                        hasAlpha:NO
                        isPlanar:NO
                  colorSpaceName:NSCalibratedWhiteColorSpace
                     bytesPerRow:owned.step
                    bitsPerPixel:8];

    // Copy data into Cocoa’s buffer
    memcpy([outRep bitmapData],
           owned.data,
           owned.total() * owned.elemSize());

    NSImage *outImage = [[NSImage alloc] initWithSize:NSMakeSize(owned.cols, owned.rows)];
    [outImage addRepresentation:outRep];
    return outImage;
}

+ (NSImage *)filterConnectedComponents:(NSImage *)image keepLargest:(NSInteger)n {
    // Convert NSImage -> cv::Mat (grayscale binary)
    CGImageRef cgRef = [image CGImageForProposedRect:nil context:nil hints:nil];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgRef];
    cv::Mat mat((int)rep.pixelsHigh,
                (int)rep.pixelsWide,
                CV_8UC1,
                (void *)rep.bitmapData,
                rep.bytesPerRow);

    // make copy for safer concurrency
    cv::Mat owned = mat.clone();
    
    // Connected components
    cv::Mat labels, stats, centroids;
    int nLabels = cv::connectedComponentsWithStats(owned, labels, stats, centroids, 8, CV_32S);

    // Collect areas
    std::vector<std::pair<int,int>> areas;
    for (int i = 1; i < nLabels; i++) { // skip background (0)
        int area = stats.at<int>(i, cv::CC_STAT_AREA);
        areas.emplace_back(area, i);
    }
    std::sort(areas.begin(), areas.end(), std::greater<>());
    
    // Keep only largest N
    std::set<int> keep;
    for (int i = 0; i < std::min<int>(n, areas.size()); i++) {
        keep.insert(areas[i].second);
    }

    // Build output mask
    cv::Mat filtered = cv::Mat::zeros(owned.size(), CV_8UC1);
    for (int y = 0; y < labels.rows; y++) {
        for (int x = 0; x < labels.cols; x++) {
            int lbl = labels.at<int>(y, x);
            if (keep.count(lbl)) {
                filtered.at<uchar>(y, x) = 255;
            }
        }
    }

    return [self imageFromMat:filtered];
}

// this is the last step in horizon detection, so it gives a HorizonResult  
+ (HorizonResult *)groundOnlyFrom:(NSImage *)image {
    // Convert NSImage → cv::Mat grayscale binary
    CGImageRef cgRef = [image CGImageForProposedRect:nil context:nil hints:nil];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgRef];
    cv::Mat mat((int)rep.pixelsHigh,
                (int)rep.pixelsWide,
                CV_8UC1,
                (void *)rep.bitmapData,
                rep.bytesPerRow);

    // make copy for safer concurrency
    cv::Mat owned = mat.clone();
    
    // Ensure binary (Otsu output should already be 0/255)
    cv::Mat bin;
    cv::threshold(owned, bin, 127, 255, cv::THRESH_BINARY);

    // Invert so ground = white (255)
    cv::Mat inv;
    cv::bitwise_not(bin, inv);

    // Connected components
    cv::Mat labels, stats, centroids;
    int nLabels = cv::connectedComponentsWithStats(inv, labels, stats, centroids, 8, CV_32S);

    // Collect all labels touching the bottom row
    std::set<int> bottomLabels;
    int bottomY = inv.rows - 1;
    for (int x = 0; x < labels.cols; x++) {
        int lbl = labels.at<int>(bottomY, x);
        if (lbl > 0) bottomLabels.insert(lbl);
    }

    // Build filtered mask: keep only bottom-connected components
    cv::Mat groundMask = cv::Mat::zeros(inv.size(), CV_8UC1);
    for (int y = 0; y < labels.rows; y++) {
        for (int x = 0; x < labels.cols; x++) {
            int lbl = labels.at<int>(y, x);
            if (bottomLabels.count(lbl)) {
                groundMask.at<uchar>(y, x) = 255;
            }
        }
    }

    // Invert back: ground = black (0), sky = white (255)
    cv::Mat finalMask;
    cv::bitwise_not(groundMask, finalMask);


    // find highest black pixel

    // Find coordinates of black pixels (ground)
    std::vector<cv::Point> blackPoints;
    cv::findNonZero(finalMask == 0, blackPoints);

    int highestBlackY = INT_MAX;

    // find highest black pixel
    for (const auto& p : blackPoints) {
      highestBlackY = std::min(highestBlackY, p.y); // topmost black pixel
    }

    // find lowest white pixel

    std::vector<cv::Point> whitePoints;
    cv::findNonZero(finalMask == 255, whitePoints);

    int lowestWhiteY = INT_MIN;
    for (const auto& p : whitePoints) {
      lowestWhiteY = std::max(lowestWhiteY, p.y); // lowest white pixel
    }

    return [[HorizonResult alloc] initWithImage: [self imageFromMat:finalMask]
				  highestBlackY: highestBlackY
				   lowestWhiteY: lowestWhiteY];
}

@end
