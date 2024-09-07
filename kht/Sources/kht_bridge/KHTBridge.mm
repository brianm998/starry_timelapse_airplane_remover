
#import "../kht/include/kht.hpp"
#import "include/KHTBridge.h"
#include <opencv2/imgproc.hpp>
#include <opencv2/highgui.hpp>
#include <opencv2/imgcodecs/macosx.h>
#import <math.h>

@implementation KHTBridgeLine

@end

@implementation KHTBridge

+(NSArray *) translate:(NSImage*)image {
  // return value for run_kht below
  kht::ListOfLines lineList = kht::ListOfLines();

  cv::Mat im, eightBit, canny;

  // convert for processing
  NSImageToMat(image, im);

  std::int32_t height = im.rows, width = im.cols;

  // convert to eight bit
  im.convertTo(eightBit,CV_8U);
 
  // run canny edge detection
  cv::Canny(eightBit, canny, 80, 200);

  // run the c++ Kernel Hough Transform code, with results in lineList
  kht::run_kht(lineList, canny.ptr(), width, height);

  // translate the KHT line list into ObjC land
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
