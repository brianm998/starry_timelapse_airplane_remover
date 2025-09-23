// BufferHolder.h
#import <Foundation/Foundation.h>
#import "MatWrapper.h"

@interface BufferHolder : NSObject

@property (nonatomic, readonly) void *buffer;
@property (nonatomic, readonly) NSUInteger length;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) NSUInteger components;
@property (nonatomic, readonly) NSUInteger bitsPerComponent;

// allocates and owns a new buffer
- (instancetype)initWithWidth:(NSUInteger)width
		       height:(NSUInteger)height
		   components:(NSInteger)components
	     bitsPerComponent:(NSUInteger)bitsPerComponent;

// copies and owns an existing buffer
- (instancetype)initWithCopiedBuffer:(const void *)buffer
                               width:(NSUInteger)width
                              height:(NSUInteger)height
                          components:(NSInteger)components
                    bitsPerComponent:(NSUInteger)bitsPerComponent;

- (uint8_t *)asUInt8;
- (uint16_t *)asUInt16;
- (uint32_t *)asUInt32;
- (MatWrapper *)mat;

@end
