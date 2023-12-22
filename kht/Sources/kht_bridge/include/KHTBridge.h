#import <Foundation/Foundation.h>


@interface KHTBridgeLine : NSObject
@property (nonatomic) double theta;
@property (nonatomic) double rho;
@property (nonatomic) int count;
@end

@interface KHTBridge : NSObject
+(NSArray *) translate:(NSImage*)image
		 width:(int)width
		height:(int)height
	clusterMinSize:(int)clusterMinSize
   clusterMinDeviation:(double)clusterMinDeviation
		 delta:(double)delta
       kernelMinHeight:(double)kernelMinHeight
	       nSigmas:(double)nSigmas;

@end
