#import <Foundation/Foundation.h>
#import <opencv2/core.hpp>
#import "MatWrapper_Internal.h"
#import "BufferHolder.h"
#import "logging.h"

@implementation BufferHolder

/*
  Next steps:

   - make it so that in swift we can construct this, and access it with swift code
   - make an optional BufferHolder var in PixelatedImage, and a constructor there
     which takes a BufferHolder and holds that with the MatWrapper given.
   - change where we construct [UInt8] or [UInt16] and use BufferHolders instead.

 */

- (instancetype)initWithWidth:(NSUInteger)width
		       height:(NSUInteger)height
		   components:(NSInteger)components
	     bitsPerComponent:(NSUInteger)bitsPerComponent
{
    self = [super init];
    if (self) {
        NSUInteger totalLength = width*height*components*bitsPerComponent/8;
        _width = width;
	_bitsPerComponent = bitsPerComponent;
        _height = height;
        _components = components;
        _length = totalLength;
        _buffer = malloc(totalLength);
        if (!_buffer && totalLength > 0) {
            // malloc failed
            return nil;
        }
	// set it all to zero
	memset(_buffer, 0, totalLength);
	Log_d(@"init with width %d height %d bitsPerComponent %lu", width, height, bitsPerComponent);
    }
    return self;
}


- (instancetype)initWithCopiedBuffer:(const void *)buffer
                               width:(NSUInteger)width
                              height:(NSUInteger)height
                          components:(NSInteger)components
                    bitsPerComponent:(NSUInteger)bitsPerComponent
{
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _components = components;
        _bitsPerComponent = bitsPerComponent;
        _length = width * height * components * (bitsPerComponent / 8);

        _buffer = malloc(_length);
        if (_buffer && buffer) {
            memcpy(_buffer, buffer, _length);
        }
	Log_d(@"init with width %d height %d bitsPerComponent %lu", width, height, bitsPerComponent);
    }
    return self;
}

- (void)dealloc {
    if (_buffer) {
        free(_buffer);
        _buffer = NULL;
    }
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (uint8_t *)asUInt8 {
    return (uint8_t *)_buffer;
}

- (uint16_t *)asUInt16 {
    return (uint16_t *)_buffer;
}

- (uint32_t *)asUInt32 {
    return (uint32_t *)_buffer;
}

- (MatWrapper *)mat {
  Log_d(@"FUCKING width %d height %d", _width, _height);
  if(_bitsPerComponent == 8) {
    if(_components == 1) {
      cv::Mat img(_height, _width, CV_8UC1, _buffer);
      return [[MatWrapper alloc] initWithMat: img];
    } else if (_components == 3) {
      cv::Mat img(_height, _width, CV_8UC3, _buffer);
      return [[MatWrapper alloc] initWithMat: img];
    } else if (_components == 4) {
      cv::Mat img(_height, _width, CV_8UC4, _buffer);
      return [[MatWrapper alloc] initWithMat: img];
    } else {
      Log_w(@"cannot create mat with one 8 bits per components and %lu components", _components);
    }
  } else if(_bitsPerComponent == 16) {
    if(_components == 1) {
      cv::Mat img(_height, _width, CV_16UC1, _buffer);
      return [[MatWrapper alloc] initWithMat: img];
    } else if (_components == 3) {
      cv::Mat img(_height, _width, CV_16UC3, _buffer);
      return [[MatWrapper alloc] initWithMat: img];
    } else if (_components == 4) {
      cv::Mat img(_height, _width, CV_16UC4, _buffer);
      return [[MatWrapper alloc] initWithMat: img];
    } else {
      Log_w(@"cannot create mat with one 16 bits per components and %lu components", _components);
    }
  } else if(_bitsPerComponent == 32) {
    if(_components == 1) {
      cv::Mat img(_height, _width, CV_32SC1, _buffer);
      return [[MatWrapper alloc] initWithMat: img];
    } else if (_components == 3) {
      cv::Mat img(_height, _width, CV_32SC3, _buffer);
      return [[MatWrapper alloc] initWithMat: img];
    } else if (_components == 4) {
      cv::Mat img(_height, _width, CV_32SC4, _buffer);
      return [[MatWrapper alloc] initWithMat: img];
    } else {
      Log_w(@"cannot create mat with one 32 bits per components and %lu components", _components);
    }
  } else {
    Log_w(@"cannot create mat with components %lu and bitsPerComponent %lu",
	  _components, _bitsPerComponent);
  }
  return nil;
}


@end
