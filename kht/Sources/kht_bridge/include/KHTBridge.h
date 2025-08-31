
#pragma once
#import <Foundation/Foundation.h>

#ifndef STAR_MAT_TYPEDEF
#define STAR_MAT_TYPEDEF
typedef void* Mat;
#endif

#import "PixelatedImageBridge.h"
#import "HorizonResult.h"

@interface KHTBridgeLine : NSObject
@property (nonatomic) double theta;
@property (nonatomic) double rho;
@property (nonatomic) int votes;
@end

@interface KHTBridge : NSObject
+(NSArray *) translate:(Mat)image;
@end



@interface ObjC : NSObject

+ (BOOL)catchException:(void (NS_NOESCAPE ^)(NSError **))tryBlock error:(NSError **)error NS_REFINED_FOR_SWIFT;

@end
