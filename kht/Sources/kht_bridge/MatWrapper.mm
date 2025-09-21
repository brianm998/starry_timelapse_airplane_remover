// MatWrapper.mm
#import "MatWrapper.h"
#import "MatWrapper_Internal.h"

@interface MatWrapper () {
    cv::Mat _mat;
}
@end

@implementation MatWrapper

// Internal init for ObjC++ usage
- (instancetype)initWithMat:(const cv::Mat&)mat {
    self = [super init];
    if (self) {
        _mat = mat; // shallow copy (refcount increment)
    }
    return self;
}

// Zero-copy initializer from external memory (Swift buffer)
- (instancetype)initWithWidth:(NSInteger)width
                       height:(NSInteger)height
                     channels:(NSInteger)channels
                         type:(int)cvType
                    bytesPerRow:(size_t)step
                           data:(void *)data
{
    self = [super init];
    if (self) {
        _mat = cv::Mat((int)height, (int)width, cvType, data, step);
        // Do NOT attempt to touch internal cv::Mat allocator
    }
    return self;
}


- (NSInteger)rows     { return _mat.rows; }
- (NSInteger)cols     { return _mat.cols; }
- (NSInteger)channels { return _mat.channels(); }
- (int)type           { return _mat.type(); }
- (size_t)dataLength  { return _mat.total() * _mat.elemSize(); }
- (size_t)step        { return _mat.step; }
- (const void *)dataPtr { return _mat.data; }
- (BOOL)isEmpty { return _mat.empty(); }
- (size_t)lengthInBytes {
    return _mat.total() * _mat.elemSize();
}
- (NSString *)debugDescription {
    return [NSString stringWithFormat:@"cv::Mat %ldx%ld, ch=%ld, type=%d",
            (long)_mat.cols, (long)_mat.rows, (long)_mat.channels(), _mat.type()];
}

- (instancetype)initWithWidth:(NSInteger)width
                       height:(NSInteger)height
                        cvType:(int)cvType
                   bytesPerRow:(size_t)step
                          data:(void *)data
                takeOwnership:(BOOL)takeOwnership
{
    self = [super init];
    if (self) {
        if (takeOwnership) {
            // cv::Mat will free memory when destroyed
            _mat = cv::Mat((int)height, (int)width, cvType, data, step).clone(); 
        } else {
            // just wrap external memory (zero-copy)
            _mat = cv::Mat((int)height, (int)width, cvType, data, step);
        }
    }
    return self;
}


- (CGColorSpaceRef)colorSpace {
    if (_mat.channels() == 1) {
        return CGColorSpaceCreateDeviceGray();
    } else {
        return CGColorSpaceCreateDeviceRGB();
    }
}

- (CGBitmapInfo)bitmapInfo {
    int depth = _mat.depth();
    int channels = _mat.channels();

    if (depth == CV_8U) {
        if (channels == 1) {
            return kCGImageAlphaNone | kCGBitmapByteOrderDefault;
        } else if (channels == 3) {
            return kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault;
        } else if (channels == 4) {
            return kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault;
        }
    } else if (depth == CV_16U) {
        return kCGImageAlphaNone | kCGBitmapByteOrder16Little;
    }
    return kCGBitmapByteOrderDefault;
}

- (NSInteger)bitsPerPixel {
    return static_cast<NSInteger>(_mat.elemSize() * 8);
}

- (NSInteger)bitsPerComponent {
    return static_cast<NSInteger>(_mat.elemSize1() * 8);
}


/// The helper that Swift will call (safe — implemented here using CV_* macros)
+ (int)cvTypeForBitsPerComponent:(int)bits componentsPerPixel:(int)components {
    // Common mapping. Extend if you need more combinations.
    if (bits == 8) {
        if (components == 1) return CV_8UC1;
        if (components == 3) return CV_8UC3;
        if (components == 4) return CV_8UC4;
    } else if (bits == 16) {
        if (components == 1) return CV_16UC1;
        if (components == 3) return CV_16UC3;
        if (components == 4) return CV_16UC4;
    } else if (bits == 32) {
        if (components == 1) return CV_32FC1; // example for floats
        // add others as needed
    }
    return -1; // unsupported
}

@end
