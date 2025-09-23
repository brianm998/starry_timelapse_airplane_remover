#import <Foundation/Foundation.h>
#import "MatWrapper.h"

NS_ASSUME_NONNULL_BEGIN

@class MatWrapper;

@interface ObjcImageMatrixElement : NSObject

@property(nonatomic, assign) int x;
@property(nonatomic, assign) int y;
@property(nonatomic, assign) int width;
@property(nonatomic, assign) int height;
@property(nonatomic, strong) MatWrapper* image;

@end

NS_ASSUME_NONNULL_END
