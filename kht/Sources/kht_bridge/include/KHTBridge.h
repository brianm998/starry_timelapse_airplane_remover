#import <Foundation/Foundation.h>


@interface KHTBridgeLine : NSObject
@property (nonatomic) double theta;
@property (nonatomic) double rho;
@property (nonatomic) int votes;
@end

@interface KHTBridge : NSObject
+(NSArray *) translate:(NSImage*)image;
@end



@interface ObjC : NSObject

+ (BOOL)catchException:(void (NS_NOESCAPE ^)(NSError **))tryBlock error:(NSError **)error NS_REFINED_FOR_SWIFT;

@end
