#import <opencv2/opencv.hpp>
#import "HorizonResult.h"

@implementation HorizonResult

- (instancetype)initWithImage:(NSImage *)image
		  horizonTopY:(NSInteger)horizonTopY
	       horizonBottomY:(NSInteger)horizonBottomY {
  self = [super init];
    if (self) {
        _image = image;
        _horizonTopY = horizonTopY;
        _horizonBottomY = horizonBottomY;
    }
    return self;
}

@end


// Converts NSImage to cv::Mat
// If forceRGBA is YES, always returns CV_8UC4
// Otherwise it returns whatever channel count the bitmap already has.
static cv::Mat cvMatFromNSImage(NSImage *image, BOOL forceRGBA) {
    CGImageRef cgRef = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgRef) {
        return cv::Mat(); // empty
    }
    
    size_t width  = CGImageGetWidth(cgRef);
    size_t height = CGImageGetHeight(cgRef);
    
    if (forceRGBA) {
        // Always create 4-channel RGBA bitmap
        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(NULL,
                                                     width,
                                                     height,
                                                     8,                       // bits per component
                                                     width * 4,               // bytes per row
                                                     colorSpace,
                                                     kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgRef);
        
        unsigned char *data = (unsigned char *)CGBitmapContextGetData(context);
        cv::Mat mat((int)height, (int)width, CV_8UC4, data);
        
        // Copy the data into a standalone cv::Mat (otherwise freed with CGContextRelease)
        cv::Mat matCopy = mat.clone();
        
        CGContextRelease(context);
        CGColorSpaceRelease(colorSpace);
        
        return matCopy;
    } else {
        // Let NSBitmapImageRep decide channel count
        NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] initWithCGImage:cgRef];
        NSInteger samplesPerPixel = [bitmapRep samplesPerPixel];
        NSInteger bitsPerSample   = [bitmapRep bitsPerSample];
        
        if (bitsPerSample != 8) {
            return cv::Mat();
        }
        
        int cvType;
        if (samplesPerPixel == 4) cvType = CV_8UC4;
        else if (samplesPerPixel == 3) cvType = CV_8UC3;
        else if (samplesPerPixel == 1) cvType = CV_8UC1;
        else return cv::Mat();
        
        cv::Mat mat((int)[bitmapRep pixelsHigh],
                    (int)[bitmapRep pixelsWide],
                    cvType,
                    (void *)[bitmapRep bitmapData],
                    [bitmapRep bytesPerRow]);
        
        return mat.clone(); // clone to own memory
    }
}

@implementation HorizonHelper

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



@end
