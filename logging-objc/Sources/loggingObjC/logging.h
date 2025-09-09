#import <Foundation/Foundation.h>

typedef void (^LogHandlerBlock)(NSString *message, NSString *level, NSString *file, NSString *function, int line);

FOUNDATION_EXPORT LogHandlerBlock GlobalStringHandler;

@interface ObjCLogging : NSObject
+(void)setHandler:(LogHandlerBlock)newHandler;
+(LogHandlerBlock)handler;
@end

#define Log_v(message, ...) ObjCLogging.handler([NSString stringWithFormat:message, ##__VA_ARGS__], @"verbose", @__FILE__,  [NSString stringWithUTF8String:__PRETTY_FUNCTION__], __LINE__)
#define Log_d(message, ...) ObjCLogging.handler([NSString stringWithFormat:message, ##__VA_ARGS__], @"debug", @__FILE__,  [NSString stringWithUTF8String:__PRETTY_FUNCTION__], __LINE__)
#define Log_i(message, ...) ObjCLogging.handler([NSString stringWithFormat:message, ##__VA_ARGS__], @"info", @__FILE__,  [NSString stringWithUTF8String:__PRETTY_FUNCTION__], __LINE__)
#define Log_w(message, ...) ObjCLogging.handler([NSString stringWithFormat:message, ##__VA_ARGS__], @"warn", @__FILE__,  [NSString stringWithUTF8String:__PRETTY_FUNCTION__], __LINE__)
#define Log_e(message, ...) ObjCLogging.handler([NSString stringWithFormat:message, ##__VA_ARGS__], @"error", @__FILE__,  [NSString stringWithUTF8String:__PRETTY_FUNCTION__], __LINE__)
