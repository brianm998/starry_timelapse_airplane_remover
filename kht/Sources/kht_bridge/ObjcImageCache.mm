#import "ObjcImageCache.h"
#import "logging.h"

@implementation ObjcImageCache

static void (^_imageLoader)(NSString * _Nonnull filename, void (^ _Nonnull completion)(MatWrapper * _Nullable image)) = nil;

+ (void (^)(NSString * _Nonnull filename, void (^ _Nonnull completion)(MatWrapper * _Nullable image)))imageLoader {
  return _imageLoader;
}

+ (void)setImageLoader:(void (^)(NSString * _Nonnull filename, void (^ _Nonnull completion)(MatWrapper * _Nullable image)))imageLoader {
  _imageLoader = imageLoader;
}

+ (MatWrapper * _Nullable)loadImage:(NSString *)filename {
    __block MatWrapper *result = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    if(_imageLoader == nil) {
      Log_e(@"cannot load images with no loader");
      return nil;
    }
    
    _imageLoader(filename, ^(MatWrapper* image) {
        result = image;
        dispatch_semaphore_signal(sema);
      });

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    return result;
}
@end
