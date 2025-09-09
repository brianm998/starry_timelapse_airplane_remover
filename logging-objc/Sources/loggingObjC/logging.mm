#import "logging.h"

@implementation ObjCLogging

static LogHandlerBlock handler = nil;

+(void)setHandler:(LogHandlerBlock)newHandler {
  handler = newHandler;
}

+(LogHandlerBlock)handler { return handler; }
@end

// Declare a function to set the global handler
//void setGlobalObjCLogHandler(StringHandlerBlock handler);

// Define the global variable
//StringHandlerBlock global_objc_log_handler = nil;

// Define the setter function
//void setGlobalObjCLogHandler(StringHandlerBlock handler) {
//    global_objc_log_handler = [handler copy]; // copy block to heap
//}

