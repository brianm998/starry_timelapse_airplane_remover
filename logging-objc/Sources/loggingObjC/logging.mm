#import "logging.h"

@implementation ObjCLogging

static LogHandlerBlock handler = nil;

+(void)setHandler:(LogHandlerBlock)newHandler {
  handler = newHandler ? [newHandler copy] : nil;
}

+(LogHandlerBlock)handler { return handler; }
@end
