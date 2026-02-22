// PixelatedImageBridge.h
#pragma once

#import <Foundation/Foundation.h>
#import "MatWrapper.h"

#import "HorizonResult.h"

NS_ASSUME_NONNULL_BEGIN


@interface PixelatedImageBridge : NSObject

+ (MatWrapper *)cannyEdgeDetect:(MatWrapper *)img
                   minThreshold:(double)minThreshold
                   maxThreshold:(double)maxThreshold
                  useL2Gradient:(BOOL)useL2Gradient;

+ (MatWrapper *)shiftImageUp:(MatWrapper *) input
                 shiftPixels:(int)shiftPixels;

+ (MatWrapper *)bitwiseAnd:(MatWrapper *)img withImage:(MatWrapper *)img1;

+ (MatWrapper *)bitwiseOr:(MatWrapper *)img withImage:(MatWrapper *)img1;

+ (MatWrapper *)bitwiseNot:(MatWrapper *)img;

// new horizon detection attempt
+ (MatWrapper *)detectHorizon:(MatWrapper *)img;

+ (MatWrapper *)subtractImage:(MatWrapper *)img1 fromImage:(MatWrapper *)img2;

// combines two images with a mask
// non zero mask pixels get image1
//     zero mask pixels get image2
+ (MatWrapper *)combineImage:(MatWrapper *)image1
			mask:(MatWrapper *)mask
		  background:(MatWrapper *)image2;

/// Takes an expected binary cv::Mat and makes it 8-bit grayscale,
// then and keeps N largest connected components, returning a cv::Mat
+ (MatWrapper *)filterConnectedComponents:(MatWrapper *)image keepLargest:(NSInteger)n;

// removes all dark components not touching the ground
+ (MatWrapper *)groundOnlyFrom:(MatWrapper *)image;

// removes all light components not touching the sky
+ (MatWrapper *)skyOnlyFrom:(MatWrapper *)image;

+ (MatWrapper *)shrinkDarkRegions:(MatWrapper *)img by:(int)radius;
+ (MatWrapper *)growDarkRegions:(MatWrapper *)img by:(int)radius;

/// Returns the vertical horizon extents
+ (HorizonResult *)horizonExtentsFromImage:(MatWrapper *)image;

+(double)maxBrightnessScaleForImage:(MatWrapper *)image
			  maskImage:(MatWrapper *)mask;

+(MatWrapper *)brightenDarks:(MatWrapper *)image
			mask:(MatWrapper *)mask
		      amount:(double)amount;

+(MatWrapper *)darkenDarks:(MatWrapper *)image
		      mask:(MatWrapper *)mask
		    amount:(double)amount;

+(MatWrapper *)maskRaisedBy:(MatWrapper *)image
		       mask:(MatWrapper *)mask
		     border:(int)amount;

/// Dynamic programming horizon tracing.
/// Finds the optimal left-to-right path through the image that follows
/// strong horizontal edges (Sobel vertical gradient + Canny edges).
/// Returns a binary mask: white (255) above the horizon, black (0) below.
///
/// @param img           Source image (grayscale or color)
/// @param cannyMin      Canny edge detection minimum threshold
/// @param cannyMax      Canny edge detection maximum threshold
/// @param useL2Gradient Use L2 gradient for Canny
/// @param smoothnessLambda Penalty per pixel of vertical displacement between adjacent columns (higher = smoother horizon)
/// @param sobelWeight   Weight for Sobel vertical gradient in the cost function
/// @param cannyWeight   Weight for Canny edge presence in the cost function
/// @param searchTopFraction  Fraction from top of image where horizon search starts (0.0 - 1.0)
/// @param searchBottomFraction Fraction from top where horizon search ends (0.0 - 1.0)
+ (nullable MatWrapper *)dpHorizonMask:(MatWrapper *)img
                              cannyMin:(double)cannyMin
                              cannyMax:(double)cannyMax
                         useL2Gradient:(BOOL)useL2Gradient
                     smoothnessLambda:(double)smoothnessLambda
                          sobelWeight:(double)sobelWeight
                          cannyWeight:(double)cannyWeight
                    searchTopFraction:(double)searchTopFraction
                 searchBottomFraction:(double)searchBottomFraction;

@end


NS_ASSUME_NONNULL_END
