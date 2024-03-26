
#import "../kht/include/kht.hpp"
#import "include/KHTBridge.h"
#include <opencv2/imgproc.hpp>
#include <opencv2/highgui.hpp>
#include <opencv2/imgcodecs/macosx.h>
#import <math.h>

@implementation KHTBridgeLine

@end

@implementation KHTBridge

+(NSArray *) translate:(NSImage*)image
	clusterMinSize:(int)clusterMinSize
   clusterMinDeviation:(double)clusterMinDeviation
		 delta:(double)delta
       kernelMinHeight:(double)kernelMinHeight
	       nSigmas:(double)nSigmas
{
  kht::ListOfLines lineList = kht::ListOfLines();

  cv::Mat im, bw, eightBit;

  NSImageToMat(image, im);

  // XXX add a check on type to make sure this is necessary
  im.convertTo(eightBit,CV_8U);

  // canny edge detection
  cv::Canny(eightBit, bw, 80, 200);
  
  // run the c++ Kernel Hough Transform code, results in lineList
  kht::run_kht(lineList,
	       bw.ptr(),
	       image.size.width,
	       image.size.height,
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

    // these lines are setup with the origin at the image center
    
    KHTBridgeLine * bridgeLine = [[KHTBridgeLine alloc] init];
    bridgeLine.rho = rho;
    bridgeLine.theta = theta;
    bridgeLine.votes = line.votes;

    [ret addObject: bridgeLine];
  }
  return ret;
}

@end


@implementation ObjC

+ (BOOL)catchException:(void (NS_NOESCAPE ^)(NSError **))tryBlock error:(NSError **)error {
    @try {
        tryBlock(error);
        return error == NULL || *error == nil;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:exception.name code:-1 userInfo:@{
                NSUnderlyingErrorKey: exception,
                NSLocalizedDescriptionKey: exception.reason,
                @"CallStackSymbols": exception.callStackSymbols
            }];
        }
        return NO;
    }
}

@end
