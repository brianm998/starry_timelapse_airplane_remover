
#import "../kht/include/kht.hpp"
#import "include/KHTBridge.h"
#import <math.h>

@implementation KHTBridgeLine

@end

@implementation KHTBridge

+(NSArray *) translate:(uint16*)image
		 width:(int)width
		height:(int)height
	clusterMinSize:(int)clusterMinSize
   clusterMinDeviation:(double)clusterMinDeviation
		 delta:(double)delta
       kernelMinHeight:(double)kernelMinHeight
	       nSigmas:(double)nSigmas
{
  kht::ListOfLines lineList = kht::ListOfLines();

  kht::run_kht(lineList,
	       image,
	       height,
	       width,
	       clusterMinSize,
	       clusterMinDeviation,
	       delta, 
	       kernelMinHeight,
	       nSigmas);

  NSMutableArray * ret = [[NSMutableArray alloc] init];
  
  for(int i = 0 ; i < lineList.size() ; i++) {
    kht::Line line = lineList[i];

    double rho = line.rho;
    double theta = line.theta;

    // make all rho positive
    if(rho < 0) {
      // if negative, flip rho and theta to make it positive
      rho = -rho;
      theta = fmod(theta + 180, 360);
    }

    // these lines are setup with the origin centered on the image
    
    KHTBridgeLine * bridgeLine = [[KHTBridgeLine alloc] init];
    bridgeLine.rho = rho;
    bridgeLine.theta = theta;
    bridgeLine.count = line.votes;

    [ret addObject: bridgeLine];
  }
  return ret;
}

@end
