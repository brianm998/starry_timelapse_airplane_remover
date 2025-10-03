#import "HorizonResult.h"

@implementation HorizonResult

- (instancetype)initWithHorizonTopY:(NSInteger)horizonTopY
                     horizonBottomY:(NSInteger)horizonBottomY
{
  self = [super init];
    if (self) {
        _horizonTopY = horizonTopY;
        _horizonBottomY = horizonBottomY;
    }
    return self;
}

@end


