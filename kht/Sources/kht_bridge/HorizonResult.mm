#import <opencv2/opencv.hpp>
#import "HorizonResult.h"

@implementation HorizonResult

- (instancetype)initWithImage:(NSImage *)image
		  horizonTopY:(NSInteger)horizonTopY
	       horizonBottomY:(NSInteger)horizonBottomY {
  self = [super init];
    if (self) {
        _image = image;
        _horizonTopY = horizonTopY;
        _horizonBottomY = horizonBottomY;
    }
    return self;
}

@end


