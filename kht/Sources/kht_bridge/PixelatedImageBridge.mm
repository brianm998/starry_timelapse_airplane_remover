// PixelatedImageBridge.mm
#import <opencv2/opencv.hpp>
#import "PixelatedImageBridge.h"
#import "HorizonResult.h"

// Converts NSImage to cv::Mat
// If forceRGBA is YES, always returns CV_8UC4
// Otherwise it returns whatever channel count the bitmap already has.

static cv::Mat cvMatFromNSImage(NSImage *image, BOOL forceRGBA) {
    CGImageRef cgRef = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgRef) {
        NSLog(@"!cgRef");
        return cv::Mat();
    }
    
    size_t width  = CGImageGetWidth(cgRef);
    size_t height = CGImageGetHeight(cgRef);
    
    if (forceRGBA) {
        // Always create 4-channel RGBA bitmap (8-bit per channel)
        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(NULL,
                                                     width,
                                                     height,
                                                     8,
                                                     width * 4,
                                                     colorSpace,
                                                     kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgRef);
        
        unsigned char *data = (unsigned char *)CGBitmapContextGetData(context);
        cv::Mat mat((int)height, (int)width, CV_8UC4, data);
        cv::Mat matCopy = mat.clone();
        
        CGContextRelease(context);
        CGColorSpaceRelease(colorSpace);
        
        return matCopy;
    } else {
        // Use NSBitmapImageRep to preserve native depth
        NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] initWithCGImage:cgRef];
        NSInteger samplesPerPixel = [bitmapRep samplesPerPixel];
        NSInteger bitsPerSample   = [bitmapRep bitsPerSample];
        
        int cvType = -1;
        if (bitsPerSample == 8) {
            if (samplesPerPixel == 4) cvType = CV_8UC4;
            else if (samplesPerPixel == 3) cvType = CV_8UC3;
            else if (samplesPerPixel == 1) cvType = CV_8UC1;
        } else if (bitsPerSample == 16) {
            if (samplesPerPixel == 4) cvType = CV_16UC4;
            else if (samplesPerPixel == 3) cvType = CV_16UC3;
            else if (samplesPerPixel == 1) cvType = CV_16UC1;
        }
        
        if (cvType == -1) {
            NSLog(@"Unsupported bitsPerSample=%ld, samplesPerPixel=%ld",
                  (long)bitsPerSample, (long)samplesPerPixel);
            return cv::Mat();
        }
        
        cv::Mat mat((int)[bitmapRep pixelsHigh],
                    (int)[bitmapRep pixelsWide],
                    cvType,
                    (void *)[bitmapRep bitmapData],
                    [bitmapRep bytesPerRow]);
        
        return mat.clone(); // clone to own memory
    }
}

@implementation PixelatedImageBridge

+ (NSImage *)imageFromMat:(const cv::Mat&)mat {
    if (mat.empty()) {
        return nil;
    }
    
    // Ensure continuous memory
    cv::Mat owned = mat.isContinuous() ? mat : mat.clone();
    
    // Extract type info
    int depth = owned.depth();     // CV_8U, CV_16U, etc.
    int channels = owned.channels();
    
    NSInteger bitsPerSample;
    switch (depth) {
        case CV_8U:  bitsPerSample = 8;  break;
        case CV_16U: bitsPerSample = 16; break;
        default:
            NSLog(@"Unsupported Mat depth: %d", depth);
            return nil;
    }
    
    BOOL hasAlpha = (channels == 4);
    BOOL isGray   = (channels == 1);
    
    NSString *colorSpaceName;
    if (isGray) {
        colorSpaceName = NSCalibratedWhiteColorSpace;
    } else {
        colorSpaceName = NSCalibratedRGBColorSpace;
    }
    
    NSBitmapImageRep *outRep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:nil
                      pixelsWide:owned.cols
                      pixelsHigh:owned.rows
                   bitsPerSample:bitsPerSample
                 samplesPerPixel:channels
                        hasAlpha:hasAlpha
                        isPlanar:NO
                  colorSpaceName:colorSpaceName
                     bytesPerRow:owned.step
                    bitsPerPixel:bitsPerSample * channels];
    
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

    NSImage * ret = [PixelatedImageBridge imageFromMat:filtered];
    NSLog(@"XXX ret [%d, %d]", ret.size.width, ret.size.height);
    return ret;
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

    int horizonTopY = INT_MAX;

    // find highest black pixel
    for (const auto& p : blackPoints) {
      horizonTopY = std::min(horizonTopY, p.y); // topmost black pixel
    }

    // find lowest white pixel

    std::vector<cv::Point> whitePoints;
    cv::findNonZero(finalMask == 255, whitePoints);

    int horizonBottomY = INT_MIN;
    for (const auto& p : whitePoints) {
      horizonBottomY = std::max(horizonBottomY, p.y); // lowest white pixel
    }
    
    return [[HorizonResult alloc]
	     initWithImage: [PixelatedImageBridge imageFromMat:finalMask]
	       horizonTopY: horizonTopY
	     horizonBottomY: horizonBottomY];
}


+ (HorizonResult *)horizonExtentsFromImage:(NSImage *)image {
    cv::Mat mat = cvMatFromNSImage(image, YES);
    if (mat.empty()) {
        return nil;
    }
    
    cv::Mat gray, binary;
    cv::cvtColor(mat, gray, cv::COLOR_RGBA2GRAY);
    cv::threshold(gray, binary, 128, 255, cv::THRESH_BINARY);
    
    // --- Find horizon extents ---
    int horizonTopY = -1;
    for (int y = 0; y < binary.rows; y++) {
        if (cv::countNonZero(binary.row(y) == 0) > 0) {
            horizonTopY = y;
            break;
        }
    }
    
    int horizonBottomY = -1;
    for (int y = binary.rows - 1; y >= 0; y--) {
        if (cv::countNonZero(binary.row(y) == 255) > 0) {
            horizonBottomY = y;
            break;
        }
    }
    
    HorizonResult *result = [[HorizonResult alloc] initWithImage:image
                                                    horizonTopY:horizonTopY
                                                 horizonBottomY:horizonBottomY];
    return result;
}
+(NSImage *)brightenDarks:(NSImage *)image
                     mask:(NSImage *)mask
                   amount:(double)amount
{
    cv::Mat mat = cvMatFromNSImage(image, NO);
    cv::Mat maskMat = cvMatFromNSImage(mask, NO);
    if (mat.empty() || maskMat.empty()) {
        NSLog(@"brightenDarks: empty mat or mask");
        return image;
    }

    // --- Build a proper binary 8-bit mask (255 = brighten, 0 = keep original) ---
    if (maskMat.size() != mat.size()) {
        cv::resize(maskMat, maskMat, mat.size(), 0, 0, cv::INTER_NEAREST);
    }
    cv::Mat maskGray;
    if (maskMat.channels() == 4)      cv::cvtColor(maskMat, maskGray, cv::COLOR_BGRA2GRAY);
    else if (maskMat.channels() == 3) cv::cvtColor(maskMat, maskGray, cv::COLOR_BGR2GRAY);
    else                              maskGray = maskMat;

    cv::Mat binMask;
    cv::threshold(maskGray, binMask, 128, 255, cv::THRESH_BINARY);
    CV_Assert(binMask.type() == CV_8UC1);

    // Invert so 255 = brighten, 0 = leave alone
    cv::Mat invMask;
    cv::bitwise_not(binMask, invMask);

    // --- Scale factor in fixed-point integer math ---
    double scale = 1.0 + amount;
    scale = std::max(0.0, scale);

    // Fixed-point scale (Q15 style: multiply then shift)
    int factor = (int)std::round(scale * 32768.0);  // 1.0 == 32768

    // --- Result starts as original (bit-for-bit preserved) ---
    cv::Mat result = mat.clone();

    // Apply scaling only where invMask==255
    for (int y = 0; y < mat.rows; y++) {
        const uint16_t* src = mat.ptr<uint16_t>(y);
        uint16_t* dst       = result.ptr<uint16_t>(y);
        const uchar* m      = invMask.ptr<uchar>(y);

        for (int x = 0; x < mat.cols * mat.channels(); x++) {
            if (m[x / mat.channels()] == 255) {
                // scale with saturation
                uint32_t val = ((uint32_t)src[x] * factor) >> 15;
                dst[x] = (val > 65535) ? 65535 : (uint16_t)val;
            }
        }
    }
    cv::imwrite("/tmp/result.png", result);

    return [PixelatedImageBridge imageFromMat:result];
}

/*
+(NSImage *)brightenDarks:(NSImage *)image
                     mask:(NSImage *)mask
                   amount:(double)amount
{
    cv::Mat mat = cvMatFromNSImage(image, NO);
    cv::Mat maskMat = cvMatFromNSImage(mask, NO);
    if (mat.empty() || maskMat.empty()) {
        NSLog(@"brightenDarks: empty mat or mask");
        return image;
    }

    // --- Build a proper binary 8-bit mask (255 = keep original, 0 = brighten) ---
    if (maskMat.size() != mat.size()) {
        cv::resize(maskMat, maskMat, mat.size(), 0, 0, cv::INTER_NEAREST);
    }
    cv::Mat maskGray;
    if (maskMat.channels() == 4)      cv::cvtColor(maskMat, maskGray, cv::COLOR_BGRA2GRAY);
    else if (maskMat.channels() == 3) cv::cvtColor(maskMat, maskGray, cv::COLOR_BGR2GRAY);
    else                              maskGray = maskMat;

    cv::Mat binMask;                               // CV_8UC1, 0/255
    cv::threshold(maskGray, binMask, 128, 255, cv::THRESH_BINARY);
    CV_Assert(binMask.type() == CV_8UC1);

    // Invert: 255 where we want to brighten
    cv::Mat invMask;
    cv::bitwise_not(binMask, invMask);
    CV_Assert(invMask.type() == CV_8UC1);

    // XXX testing
    // XXX testing
    // XXX testing
    //cv::imwrite("/tmp/binMask.png", binMask);
    //cv::imwrite("/tmp/invMask.png", invMask);
    // XXX testing
    // XXX testing
    // XXX testing
    
    // --- Multiply (scale) only the dark region (mask==0) ---
    // Do the math in float to preserve fraction, then convert back with saturation.
    double scale = 1.0 + amount;               // e.g. amount=0.2 → +20%
    scale = std::max(0.0, scale);              // avoid negative/NaN scales

    cv::Mat mat32, bright32;
    mat.convertTo(mat32, CV_32F);              // promote

    // Per-channel scalar (don’t touch alpha)
    cv::Scalar s(1,1,1,1);
    if (mat.channels() == 1)      s = cv::Scalar(scale);
    else if (mat.channels() == 3) s = cv::Scalar(scale, scale, scale);
    else if (mat.channels() == 4) s = cv::Scalar(scale, scale, scale, 1.0);

    cv::multiply(mat32, s, bright32);          // no mask arg in OpenCV2

    cv::Mat brightened;
    bright32.convertTo(brightened, mat.type()); // back to original depth (saturates)

    // Compose: start from original, then overwrite only where invMask==255
    cv::Mat result = mat.clone();
    brightened.copyTo(result, invMask);

    return [PixelatedImageBridge imageFromMat:result];
}
*/
+(double)maxBrightnessScaleForImage:(NSImage *)image
			  maskImage:(NSImage *)mask
{
    cv::Mat mat = cvMatFromNSImage(image, NO);
    cv::Mat maskMat = cvMatFromNSImage(mask, NO);

    NSLog(@"image size %d x %d, mat size: %d x %d, channels=%d, depth=%d", image.size.width, image.size.height,
	  mat.cols, mat.rows, mat.channels(), mat.depth());
    NSLog(@"mask size: %d x %d, channels=%d, depth=%d",
	  maskMat.cols, maskMat.rows, maskMat.channels(), maskMat.depth());
    
    CV_Assert(mat.size() == maskMat.size());
    
    // If your conversion gives 3/4 channels, force it to grayscale
    if (maskMat.channels() > 1) {
      cv::cvtColor(maskMat, maskMat, cv::COLOR_BGR2GRAY);
    }

    // maskMat is 0 for ground, 255 for sky → we want ground.
    cv::Mat groundMask;
    cv::bitwise_not(maskMat, groundMask);

    // Just to be safe, enforce type
    CV_Assert(groundMask.type() == CV_8UC1);

    // Split into channels
    std::vector<cv::Mat> chans;
    cv::split(mat, chans);

    // Track maximum across all channels in the ground region
    double maxValOverall = 0.0;

    for (auto &ch : chans) {
      double minVal, maxVal;
      cv::minMaxLoc(ch, &minVal, &maxVal, nullptr, nullptr, groundMask);
      maxValOverall = std::max(maxValOverall, maxVal);
    }

    if (maxValOverall <= 0.0) {
        return 1.0; // avoid divide-by-zero
    }

    // Figure out max representable value based on depth
    double maxAllowed = 255.0;
    switch (mat.depth()) {
        case CV_8U:  maxAllowed = 255.0;   break;
        case CV_16U: maxAllowed = 65535.0; break;
        case CV_32F: maxAllowed = 1.0;     break;  // assuming normalized floats
        default:     maxAllowed = 255.0;   break;  // fallback
    }

    return maxAllowed / maxValOverall;
}

@end

