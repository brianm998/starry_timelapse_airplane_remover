#import "logging.h"

@implementation ObjCLogging

static LogHandlerBlock handler = nil;

+(void)setHandler:(LogHandlerBlock)newHandler {
  handler = newHandler;
}

+(LogHandlerBlock)handler { return handler; }
@end
