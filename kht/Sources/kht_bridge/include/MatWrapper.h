// MatWrapper.h
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "ObjcImageMatrixElement.h"

NS_ASSUME_NONNULL_BEGIN

@class ObjcImageMatrixElement;

@interface MatWrapper : NSObject

@property (class, atomic, assign) NSUInteger totalBytes;
@property (class, atomic, assign) NSUInteger totalInstances;

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

- (void)writeTo:(NSString*)filename;

/// Debug info
- (NSString *)debugDescription;

+ (int)cvTypeForBitsPerComponent:(int)bits componentsPerPixel:(int)components;

+ (nullable MatWrapper*)loadFromFilename:(NSString*)filename;

// removes N rows of pixels from the top of the image
-(MatWrapper *) bottomCrop:(int) N;

-(void)saveJpegWithQuality:(NSUInteger)quality filename:(NSString*)filename;

-(NSImage*)nsImage;

-(MatWrapper *)clone;

-(MatWrapper *)downScaleTo:(NSUInteger)width height:(NSUInteger)height;

-(MatWrapper *)ensureEightBit;

- (MatWrapper *)addWhiteRowsOnTop:(int)rows;

- (BOOL)ownsData;

- (double)atDoubleRow:(int)row col:(int)col;


- (NSArray<ObjcImageMatrixElement*>*)splitWithTileWidth:(int)tileWidth
                                             tileHeight:(int)tileHeight
                                         overlapPercent:(double)overlapPercent;

+ (MatWrapper*)combineFromMatrixElements:(NSArray<ObjcImageMatrixElement*>*)elements;

/// Returns 9 doubles (row-major) if this is a 3x3 CV_64F matrix
/// Returns nil otherwise
- (nullable NSArray<NSNumber *> *)homographyValues;

+ (instancetype)wrapperWithHomographyValues:(const double *)values;

- (instancetype)initWithWidth:(NSInteger)width
                       height:(NSInteger)height
                       cvType:(int)cvType
                  bytesPerRow:(size_t)step
                         data:(void *)data
                takeOwnership:(BOOL)takeOwnership;

@end

NS_ASSUME_NONNULL_END
