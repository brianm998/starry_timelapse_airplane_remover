// PixelatedImageBridge.mm
#import <opencv2/opencv.hpp>
#import "PixelatedImageBridge.h"

@implementation PixelatedImageBridge

+ (NSImage *)filterConnectedComponents:(NSImage *)image keepLargest:(NSInteger)n {
    // Convert NSImage -> cv::Mat (grayscale binary)
    CGImageRef cgRef = [image CGImageForProposedRect:nil context:nil hints:nil];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgRef];
    cv::Mat mat((int)rep.pixelsHigh,
                (int)rep.pixelsWide,
                CV_8UC1,
                (void *)rep.bitmapData,
                rep.bytesPerRow);

    // Connected components
    cv::Mat labels, stats, centroids;
    int nLabels = cv::connectedComponentsWithStats(mat, labels, stats, centroids, 8, CV_32S);

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
    cv::Mat filtered = cv::Mat::zeros(mat.size(), CV_8UC1);
    for (int y = 0; y < labels.rows; y++) {
        for (int x = 0; x < labels.cols; x++) {
            int lbl = labels.at<int>(y, x);
            if (keep.count(lbl)) {
                filtered.at<uchar>(y, x) = 255;
            }
        }
    }

    // Convert back to NSImage
    NSData *data = [NSData dataWithBytes:filtered.data length:filtered.total()];
    NSBitmapImageRep *outRep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:(unsigned char **)&filtered.data
                      pixelsWide:filtered.cols
                      pixelsHigh:filtered.rows
                   bitsPerSample:8
                 samplesPerPixel:1
                        hasAlpha:NO
                        isPlanar:NO
                  colorSpaceName:NSCalibratedWhiteColorSpace
                     bytesPerRow:filtered.step
                    bitsPerPixel:8];
    NSImage *outImage = [[NSImage alloc] initWithSize:NSMakeSize(filtered.cols, filtered.rows)];
    [outImage addRepresentation:outRep];
    return outImage;
}

// PixelatedImageBridge.mm
+ (NSImage *)groundOnlyFrom:(NSImage *)image {
    // Convert NSImage → cv::Mat grayscale binary
    CGImageRef cgRef = [image CGImageForProposedRect:nil context:nil hints:nil];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgRef];
    cv::Mat mat((int)rep.pixelsHigh,
                (int)rep.pixelsWide,
                CV_8UC1,
                (void *)rep.bitmapData,
                rep.bytesPerRow);

    // Ensure binary (Otsu output should already be 0/255)
    cv::Mat bin;
    cv::threshold(mat, bin, 127, 255, cv::THRESH_BINARY);

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

    // Convert back to NSImage
    NSBitmapImageRep *outRep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:(unsigned char **)&finalMask.data
                      pixelsWide:finalMask.cols
                      pixelsHigh:finalMask.rows
                   bitsPerSample:8
                 samplesPerPixel:1
                        hasAlpha:NO
                        isPlanar:NO
                  colorSpaceName:NSCalibratedWhiteColorSpace
                     bytesPerRow:finalMask.step
                    bitsPerPixel:8];
    NSImage *outImage = [[NSImage alloc] initWithSize:NSMakeSize(finalMask.cols, finalMask.rows)];
    [outImage addRepresentation:outRep];
    return outImage;
}

@end
