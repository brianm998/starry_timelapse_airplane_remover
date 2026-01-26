#import <Foundation/Foundation.h>
#import "FeatureMatchMethod.h"
#import "OCVFeatureSet.h"

// holds info about neighboring images to align
@interface AlignmentNeighborInfo : NSObject

@property(nonatomic, strong, nonnull) NSString * filename;
@property(nonatomic, strong, nullable) NSString * maskFilename;
@property(nonatomic, strong, nullable) OCVFeatureSet * keypoints;
@property(nonatomic, assign) int frameIndex;

- (instancetype _Nonnull)initWithFilename:(NSString * _Nonnull)filename
                             maskFilename:(NSString * _Nullable)maskFilename
                                keypoints:(OCVFeatureSet * _Nullable)keypoints
                               frameIndex:(int)frameIndex;

@end

