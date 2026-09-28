#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <unistd.h>
typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);
int main(void) { @autoreleasepool {
 SecTaskRef task=SecTaskCreateFromSelf(kCFAllocatorDefault);
 CFErrorRef error=NULL;
 CFTypeRef value=task?SecTaskCopyValueForEntitlement(task,CFSTR("com.apple.modelmanager.inference"),&error):NULL;
 NSString *errorDescription=error?CFBridgingRelease(CFErrorCopyDescription(error)):nil;
 NSDictionary *result=@{@"started":@YES,@"pid":@(getpid()),@"entitlement":@"com.apple.modelmanager.inference",@"value":value?(__bridge id)value:NSNull.null,@"error":errorDescription?:NSNull.null};
 NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
 fwrite(data.bytes,1,data.length,stdout); fputc('\n',stdout);
 if(value)CFRelease(value);if(error)CFRelease(error);if(task)CFRelease(task);
 } return 0;}
