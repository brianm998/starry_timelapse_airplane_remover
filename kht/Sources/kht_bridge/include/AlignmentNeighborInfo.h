#import <Foundation/Foundation.h>
#import "FeatureMatchMethod.h"

// holds info about neighboring images to align
@interface AlignmentNeighborInfo : NSObject

@property(nonatomic, strong, nonnull) NSString * filename;
@property(nonatomic, strong, nullable) NSString * maskFilename;
@property(nonatomic, assign) int frameIndex;

- (instancetype _Nonnull)initWithFilename:(NSString * _Nonnull)filename
                             maskFilename:(NSString * _Nullable)maskFilename
                               frameIndex:(int)frameIndex;

@end

