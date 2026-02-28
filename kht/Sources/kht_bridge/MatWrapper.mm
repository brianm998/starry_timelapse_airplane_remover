// MatWrapper.mm
#import "MatWrapper.h"
#import "MatWrapper_Internal.h"
#import "logging.h"
#import <Cocoa/Cocoa.h>
#import <opencv2/opencv.hpp>
#import <Foundation/Foundation.h>

extern void printMatInfo(const cv::Mat& mat, const std::string& name = "");

cv::Mat ensure8U(const cv::Mat& input) {
    // If already 8-bit unsigned, just return a copy
    if (input.depth() == CV_8U) {
        return input;
    }

    cv::Mat output;
    double minVal, maxVal;
    cv::minMaxLoc(input, &minVal, &maxVal);

    if (minVal == maxVal) {
        // Degenerate case: all pixels same → map to 0
        output = cv::Mat::zeros(input.size(), CV_MAKETYPE(CV_8U, input.channels()));
    } else {
        // Scale values to [0, 255]
        input.convertTo(
            output,
            CV_MAKETYPE(CV_8U, input.channels()),
            255.0 / (maxVal - minVal),   // scale
            -minVal * 255.0 / (maxVal - minVal) // shift
        );
    }

    return output;
}


static inline NSImage* NSImageFromCvMat(const cv::Mat& mat) {
  @try {
    try {
      cv::Mat clone;

      // Ensure 8-bit depth
      if (mat.depth() == CV_8U) {
        clone = mat;//.clone();
      } else {
        clone = ensure8U(mat);
      }

      CV_Assert(clone.depth() == CV_8U);
      CV_Assert(clone.channels() == 1 || clone.channels() == 3 || clone.channels() == 4);

      cv::Mat rgbaMat;

      // Convert into RGBA (CoreGraphics prefers RGBA or grayscale with alpha)
      switch (clone.channels()) {
      case 1:
        cv::cvtColor(clone, rgbaMat, cv::COLOR_GRAY2RGBA);
        break;
      case 3:
        cv::cvtColor(clone, rgbaMat, cv::COLOR_BGR2RGBA);
        break;
      case 4:
        cv::cvtColor(clone, rgbaMat, cv::COLOR_BGRA2RGBA);
        break;
      }

      int width  = rgbaMat.cols;
      int height = rgbaMat.rows;

      // Copy the pixel buffer so NSImage owns it
      NSData *data = [NSData dataWithBytes:rgbaMat.data length:rgbaMat.total() * rgbaMat.elemSize()];

      CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);

      CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
      CGBitmapInfo bitmapInfo = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault;

      CGImageRef cgImage = CGImageCreate(
					 width,
					 height,
					 8,                  // bits per component
					 32,                 // bits per pixel
					 rgbaMat.step[0],    // bytes per row
					 colorSpace,
					 bitmapInfo,
					 provider,
					 nullptr,
					 false,
					 kCGRenderingIntentDefault
					 );

      NSImage *image = [[NSImage alloc] initWithCGImage:cgImage
						   size:NSMakeSize(width, height)];

      CGImageRelease(cgImage);
      CGColorSpaceRelease(colorSpace);
      CGDataProviderRelease(provider);

      return image;
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}


@interface MatWrapper () {
    cv::Mat _mat;
}
@end

bool isROI(const cv::Mat& m) {
    return m.data != m.datastart;
}

bool matOwnsData(const cv::Mat& m) {
    return m.u != nullptr;
}

@implementation MatWrapper

static NSUInteger _totalBytes = 0;
static NSUInteger _totalInstances = 0;

+(NSUInteger) totalBytes {
  return _totalBytes;
}
+(NSUInteger) totalInstances {
  return _totalInstances;
}

+(void) setTotalInstances:(NSUInteger)totalInstances {
  _totalInstances = totalInstances;
}
+(void) setTotalBytes:(NSUInteger)totalBytes {
  _totalBytes = totalBytes;
}

- (NSArray<NSNumber *> *)homographyValues {
    if (_mat.empty() || _mat.rows != 3 || _mat.cols != 3 || _mat.type() != CV_64F) {
        return nil;
    }

    NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:9];

    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) {
            [values addObject:@(_mat.at<double>(r, c))];
        }
    }

    return values;
}


+ (instancetype)wrapperWithHomographyValues:(const double *)values {
    cv::Mat H(3, 3, CV_64F);

    for (int r = 0, i = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++, i++) {
            H.at<double>(r, c) = values[i];
        }
    }

    return [[MatWrapper alloc] initWithMat:H];
}

- (double)atDoubleRow:(int)row col:(int)col {
    return _mat.at<double>(row, col);
}

- (BOOL)ownsData {
  return matOwnsData(_mat);
}

-(MatWrapper *)clone {
  return [[MatWrapper alloc] initWithMat: _mat.clone()];
}

-(MatWrapper *)ensureEightBit {
  return [[MatWrapper alloc] initWithMat: ensure8U(_mat)];
}

// Internal init for ObjC++ usage
- (instancetype)initWithMat:(const cv::Mat&)mat {
  self = [super init];
  if(mat.empty()) {
    Log_w(@"init with empty mat");
  }
  if (self) {
      _mat = mat.clone();       // copy mat memory into new buffer for us to hold
  }

  NSUInteger count = _mat.step[0] * _mat.rows;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @synchronized([MatWrapper class]) {
        _totalBytes += count;
        _totalInstances += 1;
      }
    });
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

        NSUInteger count = _mat.step[0] * _mat.rows;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            @synchronized([MatWrapper class]) {
              _totalBytes += count;
              _totalInstances += 1;
            }
          });
    }
    return self;
}

- (void)dealloc {
  NSUInteger count = _mat.step[0] * _mat.rows;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @synchronized([MatWrapper class]) {
        _totalBytes -= count;
        _totalInstances -= 1;
      }
    });

  //Log_d(@"dealloc %@", [self debugDescription]);
}


/*

  Next steps:

  To use less ram at once:
   - move ImageCache into MatWrapper objc++ land
   - mirror image accessor code in objc
   - modify alignment code to take frame # of images, not real images
     use image accessor code to load them when necessary, only when we need them

  For more image usage visibility in the UI:
   * mirror ObjCLogging1 code to have a pair static callbacks for bytes allocated, dealloc
   * update this MatWrapper to call these methods in init and dealloc
   - update the LeftPanel in the UI to show active non cached images similar to cached ones
   - modify all objc++ code to use MatWrapper * instead of cv::Mat, so we can keep track of
     allocations better
    

 */

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
  if([self ownsData]) {
    return [NSString stringWithFormat:@"cv::Mat owns data %ldx%ld, ch=%ld, type=%d",
            (long)_mat.cols, (long)_mat.rows, (long)_mat.channels(), _mat.type()];
  } else {
    return [NSString stringWithFormat:@"cv::Mat refs data %ldx%ld, ch=%ld, type=%d",
            (long)_mat.cols, (long)_mat.rows, (long)_mat.channels(), _mat.type()];
  }
}


// Crop the top N pixels of an image, leaving just the bottom after crop
-(MatWrapper *) bottomCrop:(int) N {
    // Ensure N is within valid range

    int newHeight = self.mat.rows - N;
    if (newHeight <= 0) {
        Log_w(@"invalid newHeight %d", newHeight);
        // If cropping removes everything, return an empty Mat
        return [[MatWrapper alloc] initWithMat: cv::Mat()];
    }

    // Define the region of interest (ROI)
    cv::Rect roi(0, N, self.mat.cols, newHeight);

    // Crop using ROI
    // clone ensures a new Mat is returned
    return [[MatWrapper alloc] initWithMat: self.mat(roi).clone()]; 
}

- (MatWrapper *)addWhiteRowsOnTop:(int)rows {
    // Determine the fill color (white depends on type)
    cv::Scalar white;
    if (_mat.channels() == 1) {
        white = cv::Scalar(255); // grayscale white
    } else if (_mat.channels() == 3) {
        white = cv::Scalar(255, 255, 255); // BGR white
    } else if (_mat.channels() == 4) {
        white = cv::Scalar(255, 255, 255, 255); // BGRA white
    } else {
        // Default to single channel white
        white = cv::Scalar(255);
    }

    cv::Mat result;
    // Add rows on top: (top, bottom, left, right)
    copyMakeBorder(_mat, result, rows, 0, 0, 0, cv::BORDER_CONSTANT, white);

    return [[MatWrapper alloc] initWithMat: result];
}

- (NSArray<ObjcImageMatrixElement*>*)splitWithTileWidth:(int)tileWidth
                                             tileHeight:(int)tileHeight
                                         overlapPercent:(double)overlapPercent
{
    //Log_d(@"split into matrix");
    NSMutableArray<ObjcImageMatrixElement*>* results = [NSMutableArray array];

    int stepX = static_cast<int>(tileWidth  * (1.0 - overlapPercent));
    int stepY = static_cast<int>(tileHeight * (1.0 - overlapPercent));

    if (stepX <= 0 || stepY <= 0) {
        //NSLog(@"Invalid overlap: step becomes <= 0");
        return results;
    }

    for (int y = 0; y < _mat.rows; y += stepY) {
        for (int x = 0; x < _mat.cols; x += stepX) {
            int w = std::min(tileWidth,  _mat.cols - x);
            int h = std::min(tileHeight, _mat.rows - y);

            cv::Rect roi(x, y, w, h);
            cv::Mat subMat = _mat(roi).clone(); // clone so it owns its own data

            MatWrapper* wrapper = [[MatWrapper alloc] initWithMat:subMat];

            ObjcImageMatrixElement* elem = [[ObjcImageMatrixElement alloc] init];
            elem.x = x;
            elem.y = y;
            elem.width = w;
            elem.height = h;
            elem.image = wrapper;

            [results addObject:elem];
        }
    }

    //Log_d(@"split into matrix returning %lu results", [results count]);
    return results;
}



// Reassemble method (Objective-C++)
+ (MatWrapper*)combineFromMatrixElements:(NSArray<ObjcImageMatrixElement*>*)elements {
    NSAssert(elements.count > 0, @"Matrix must contain at least one element");

    // 1. Determine output dimensions
    int maxX = 0, maxY = 0;
    for (ObjcImageMatrixElement* elem in elements) {
        maxX = std::max(maxX, elem.x + elem.width);
        maxY = std::max(maxY, elem.y + elem.height);
    }

    Log_d(@"maxX %d, maxy %d", maxX, maxY);
    
    // 2. Assume all tiles share the same type and channels
    cv::Mat first = elements[0].image.mat;
    int type = first.type();
    int channels = first.channels();

    // 3. Allocate output buffer (zeros initially)
    cv::Mat combined(maxY, maxX, type, cv::Scalar::all(0));

    // 4. Copy each tile into its location
    for (ObjcImageMatrixElement* elem in elements) {
        const cv::Mat& tile = elem.image.mat;
        CV_Assert(tile.type() == type);
        CV_Assert(tile.rows == elem.height && tile.cols == elem.width);

        // Region of interest in destination
        cv::Rect roi(elem.x, elem.y, elem.width, elem.height);
        cv::Mat destROI = combined(roi);

        // Copy tile into output
        tile.copyTo(destROI);
    }

    return [[MatWrapper alloc] initWithMat:combined];
}

// quality 0..100
-(void)saveJpegWithQuality:(NSUInteger)quality filename:(NSString*)filename {
  cv::Mat eightBit = ensure8U(_mat);
  std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, static_cast<int>(quality)};
  cv::imwrite(std::string([filename UTF8String]), eightBit, params);
}

-(MatWrapper *)downScaleTo:(NSUInteger)width height:(NSUInteger)height {
  @try {
    try {
      cv::Mat output;
      cv::resize(_mat, output, cv::Size(width, height), 0, 0, cv::INTER_AREA);
      return [[MatWrapper alloc] initWithMat: output]; // returns a new Mat
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

- (BOOL)is16Bits {
  return _mat.depth() == CV_16U;
}

- (MatWrapper *)ensure16Bits {
  if(_mat.depth() != CV_16U) {
    cv::Mat img16;
    _mat.convertTo(img16, CV_16U, 256.0);
    return [[MatWrapper alloc] initWithMat: img16];
  } else {
    return self;
  }
}

- (BOOL)is8Bits {
  return _mat.depth() == CV_8U;
}

- (MatWrapper *)ensure8Bits {
  if(_mat.depth() != CV_8U) {
    cv::Mat img8;
    _mat.convertTo(img8, CV_8U, 1.0/256.0);
    return [[MatWrapper alloc] initWithMat: img8];
  } else {
    return self;
  }
}

+ (nullable MatWrapper*)loadFromFilename:(NSString*)filename {
  @try {
    try {
      cv::Mat img = cv::imread(std::string([filename UTF8String]), cv::IMREAD_UNCHANGED);
      if (img.empty()) {
        Log_w(@"Failed to load image from filename %@", filename);
        return nil;
      } else {
        Log_d(@"Loaded from filename %@", filename);
      }

      return [[MatWrapper alloc] initWithMat: img];
    } catch (const cv::Exception &e) {
      Log_e(@"OpenCV Exception: %s", e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"Objective-C Exception: %@", exception);
  }
  return nil;
}

- (void)writeTo:(NSString*)filename {
  @try {
    try {
      Log_e(@"writeTo: %@", filename);

      std::string fname([filename UTF8String]);

      // ---- Extract extension ----
      std::string extension;
      std::string base;

      size_t dotPos = fname.find_last_of('.');
      if (dotPos != std::string::npos && dotPos > fname.find_last_of("/\\")) {
        extension = fname.substr(dotPos + 1);   // without the dot
        base = fname.substr(0, dotPos);
      } else {
        // No extension found
        extension = "";
        base = fname;
      }

      // ---- Construct temp filename ----
      std::string tmp;
      if (!extension.empty()) {
        tmp = base + ".tmp." + extension;
      } else {
        tmp = fname + ".tmp";
      }

      if (_mat.empty()) {
        Log_w(@"not writing empty mat to %@", filename);
        return;
      }

      // ---- Write file ----
      cv::imwrite(tmp, _mat);

      // ---- Ensure data hits disk ----
      int fd = open(tmp.c_str(), O_RDONLY);
      if (fd >= 0) {
        fsync(fd);
        close(fd);
      } else {
        Log_e(@"writeTo: failed to open temp file for fsync: %@", filename);
      }

      // ---- Atomic rename ----
      if (rename(tmp.c_str(), fname.c_str()) != 0) {
        Log_e(@"writeTo: rename failed for %@", filename);
      }

    } catch (const cv::Exception &e) {
      Log_e(@"writeTo: %@ OpenCV Exception: %s", filename, e.what());
    }
  } @catch (NSException *exception) {
    Log_e(@"writeTo: %@ Objective-C Exception: %@", filename, exception);
  }
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
          _mat = cv::Mat((int)height, (int)width, cvType, data, step);//.clone()/*XXX*/;
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

-(NSImage*)nsImage {
    return NSImageFromCvMat(_mat);
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
