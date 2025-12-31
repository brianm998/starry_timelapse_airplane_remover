#import <Foundation/Foundation.h>
#import "MatWrapper.h"

@interface ObjcImageCache : NSObject

@property (class, nonatomic, copy, nullable)
    void (^imageLoader)(NSString * _Nonnull filename, void (^ _Nonnull completion)(MatWrapper * _Nullable image));
                                   
+ (MatWrapper * _Nullable)loadImage:(NSString * _Nonnull)filename;
@end



/*

  Make one of these for setting AlignmentState from the FrameProcessingState

  make it so that the ImageAligner can update the state more often to see what is
  taking up so much ram sometimes


 */
