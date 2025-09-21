// MatWrapper.h
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface MatWrapper : NSObject

/// Dimensions
@property (nonatomic, readonly) NSInteger rows;
@property (nonatomic, readonly) NSInteger cols;
@property (nonatomic, readonly) NSInteger channels;

/// OpenCV type (CV_8UC3, CV_32F, etc.)
@property (nonatomic, readonly) int type;

@property (nonatomic, readonly) size_t step;      // bytes per row

/// Length of contiguous data buffer in bytes
@property (nonatomic, readonly) size_t dataLength;

@property (nonatomic, readonly) BOOL isEmpty;

/// Raw data pointer (optional, unsafe!)
@property (nonatomic, readonly) const void *dataPtr;

@property (nonatomic, readonly) size_t lengthInBytes;

@property (nonatomic, readonly) NSInteger bitsPerPixel;
@property (nonatomic, readonly) NSInteger bitsPerComponent;

@property (nonatomic, readonly) CGColorSpaceRef colorSpace;

@property (nonatomic, readonly) CGBitmapInfo bitmapInfo;

/// Debug info
- (NSString *)debugDescription;


/// Construct from a raw buffer without copying
- (instancetype)initWithWidth:(NSInteger)width
                       height:(NSInteger)height
                     channels:(NSInteger)channels
                         type:(int)cvType
                        bytesPerRow:(size_t)step
                           data:(void *)data
                    deallocator:(dispatch_block_t _Nullable)deallocator;

+ (int)cvTypeForBitsPerComponent:(int)bits componentsPerPixel:(int)components;

- (instancetype)initWithWidth:(NSInteger)width
                       height:(NSInteger)height
                    cvType:(int)cvType
                 bytesPerRow:(size_t)step
                        data:(void *)data
              takeOwnership:(BOOL)takeOwnership;

@end

NS_ASSUME_NONNULL_END
