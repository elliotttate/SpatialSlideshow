#import <Foundation/Foundation.h>
#import <dlfcn.h>

// Owned-process control for library loading, async work, and failure reporting.
// Successful control execution is not successful Photos authorization.
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 3) { fprintf(stderr,"Usage: SpatialExtendBridgeHost bridge.dylib job-directory\n"); return 2; }
    // LLDB can queue its own expression at main, then resume this run loop.
    if (strcmp(argv[1], "--jit-wait") != 0) {
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library) { fprintf(stderr,"%s\n",dlerror()); return 3; }
        int (*start)(const char *) = dlsym(library,"SpatialExtendControl");
        if (!start) { fprintf(stderr,"Control entry missing\n"); return 3; }
        int code = start(argv[2]);
        if (code) { fprintf(stderr,"Entry rejected: %d\n",code); return code; }
    }
    NSURL *directory = [NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (deadline.timeIntervalSinceNow > 0) {
        @autoreleasepool {
            NSData *data = [NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:@"result.json"]];
            NSDictionary *result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([@[@"complete",@"failed"] containsObject:result[@"status"] ?: @""]) {
                fwrite(data.bytes,1,data.length,stdout); fputc('\n',stdout);
                return [result[@"status"] isEqual:@"complete"] ? 0 : 10;
            }
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    [NSData.data writeToURL:[directory URLByAppendingPathComponent:@"cancel"] atomically:YES];
    fprintf(stderr,"Control timed out; cancellation requested.\n"); return 11;
} }
