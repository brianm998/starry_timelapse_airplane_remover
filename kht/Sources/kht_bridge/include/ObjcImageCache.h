#import <Foundation/Foundation.h>
#import "MatWrapper.h"

@interface ObjcImageCache : NSObject

@property (class, nonatomic, copy, nullable)
    void (^imageLoader)(NSString * _Nonnull filename, void (^ _Nonnull completion)(MatWrapper * _Nullable image));
                                   
+ (MatWrapper * _Nullable)loadImage:(NSString * _Nonnull)filename;
@end
