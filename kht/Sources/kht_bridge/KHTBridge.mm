
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

  //printf("im.elemSize %zu channels %d type %d\n", im.elemSize(), im.channels(), im.type());

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

    if (i < 4) {
      printf("line %d theta %f rho %f\n", i, theta, rho);
    }
    
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
    bridgeLine.count = line.votes;

    [ret addObject: bridgeLine];
  }
  return ret;
}

@end
