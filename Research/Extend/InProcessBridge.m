#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <stdatomic.h>

// Explicitly invoked research entry point. Loading this library runs no job.
// No signal handlers, swizzles, global model overrides, or persistent service.
typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef, CFStringRef, CFErrorRef *);

@interface NSObject (SpatialExtendResearch)
- (CIImage *)applyOutfill:(CIImage *)image context:(CIContext *)context
             orientation:(NSInteger)orientation expandLeft:(CGFloat)left
             expandRight:(CGFloat)right expandTop:(CGFloat)top
            expandBottom:(CGFloat)bottom useCaseIdentifier:(NSString *)useCase
       cancellationCheck:(BOOL (^)(void))cancellationCheck error:(NSError **)error;
@end

static atomic_bool running = false;

static NSString *sha256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString new];
    for (NSUInteger i=0; i<sizeof digest; i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}

static BOOL writeStatus(NSURL *directory, NSMutableDictionary *result,
                        NSString *status, NSString *message) {
    result[@"status"] = status;
    result[@"message"] = message;
    result[@"updatedAt"] = @([NSDate date].timeIntervalSince1970);
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
    BOOL saved = json && [json writeToURL:[directory URLByAppendingPathComponent:@"result.json"] options:NSDataWritingAtomic error:&error];
    if (!saved) NSLog(@"Spatial Extend research status write failed: %@", error);
    return saved;
}

static void runJob(NSURL *directory, NSDictionary *request, NSMutableDictionary *result, BOOL control) {
    @autoreleasepool {
        @try {
            SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
            CFErrorRef taskError = NULL;
            CFTypeRef value = task ? SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.modelmanager.inference"), &taskError) : NULL;
            BOOL entitled = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value);
            result[@"inferenceEntitlement"] = @(entitled);
            if (taskError) result[@"entitlementReadError"] = CFBridgingRelease(CFErrorCopyDescription(taskError));
            if (value) CFRelease(value);
            if (taskError) CFRelease(taskError);
            if (task) CFRelease(task);
            if (!entitled && !control) {
                writeStatus(directory, result, @"failed", @"The Photos host does not expose its inference entitlement in this execution context.");
                return;
            }

            NSURL *input = [directory URLByAppendingPathComponent:@"input.heic"];
            NSURL *output = [directory URLByAppendingPathComponent:@"expanded.png"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:output.path]) {
                writeStatus(directory, result, @"failed", @"Output already exists; refusing to overwrite it."); return;
            }
            NSError *error = nil;
            NSData *bytes = [NSData dataWithContentsOfURL:input options:0 error:&error];
            if (!bytes || ![sha256(bytes) isEqual:request[@"sourceSHA256"]]) {
                writeStatus(directory, result, @"failed", error.localizedDescription ?: @"Trip fixture hash does not match the prepared request."); return;
            }
            result[@"sourceSHA256"] = sha256(bytes);
            CIImage *source = [CIImage imageWithData:bytes options:@{
                kCIImageApplyOrientationProperty:@YES, kCIImageExpandToHDR:@NO, kCIImageToneMapHDRtoSDR:@YES
            }];
            if (!source) { writeStatus(directory, result, @"failed", @"Cannot decode the prepared Trip export."); return; }
            source = [source imageByApplyingTransform:CGAffineTransformMakeTranslation(-source.extent.origin.x, -source.extent.origin.y)];
            void *framework = dlopen("/System/Library/PrivateFrameworks/PhotoImaging.framework/Versions/A/PhotoImaging", RTLD_LAZY | RTLD_LOCAL);
            Class pipelineClass = NSClassFromString(@"PIOutfillPipeline");
            if (!framework || !pipelineClass) { writeStatus(directory, result, @"failed", @"Native Photos Extend framework is unavailable."); return; }

            CGColorSpaceRef working = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
            CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CIContext *context = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace:(__bridge id)working, kCIContextWorkingFormat:@(kCIFormatRGBAh)}];
            CGColorSpaceRelease(working);
            CGFloat border = ceil(source.extent.size.width / 6.0);
            result[@"originalWidth"] = @(source.extent.size.width);
            result[@"originalHeight"] = @(source.extent.size.height);
            result[@"left"] = @(border); result[@"right"] = @(border);
            result[@"top"] = @0; result[@"bottom"] = @0;
            result[@"pipeline"] = @"Photos Extend PIOutfillPipeline";
            NSDate *started = [NSDate date];
            NSURL *cancelFile = [directory URLByAppendingPathComponent:@"cancel"];
            if (!writeStatus(directory, result, @"generating", @"Calling native Extend inside the host process.")) { CGColorSpaceRelease(srgb); return; }
            CIImage *expanded = [[pipelineClass new] applyOutfill:source context:context orientation:1
                expandLeft:border expandRight:border expandTop:0 expandBottom:0
                useCaseIdentifier:nil cancellationCheck:^BOOL {
                    return -started.timeIntervalSinceNow > 300 || [[NSFileManager defaultManager] fileExistsAtPath:cancelFile.path];
                } error:&error];
            result[@"elapsedSeconds"] = @(-started.timeIntervalSinceNow);
            if (!expanded) {
                if (error) { result[@"errorDomain"] = error.domain; result[@"errorCode"] = @(error.code); }
                writeStatus(directory, result, @"failed", error.description ?: @"Extend returned no image.");
                CGColorSpaceRelease(srgb); return;
            }
            CGRect extent = expanded.extent;
            expanded = [expanded imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
            BOOL saved = [context writePNGRepresentationOfImage:expanded toURL:output format:kCIFormatRGBA8 colorSpace:srgb options:@{} error:&error];
            CGColorSpaceRelease(srgb);
            if (!saved) { writeStatus(directory, result, @"failed", error.description ?: @"PNG export failed."); return; }
            result[@"outputWidth"] = @(extent.size.width); result[@"outputHeight"] = @(extent.size.height);
            result[@"output"] = @"expanded.png";
            result[@"elapsedSeconds"] = @(-started.timeIntervalSinceNow);
            writeStatus(directory, result, @"complete", @"Native Extend returned an image and the separate PNG was saved.");
        } @catch (NSException *exception) {
            result[@"exception"] = exception.name;
            writeStatus(directory, result, @"failed", exception.reason ?: @"Native pipeline exception.");
        } @finally {
            atomic_store(&running, false);
        }
    }
}

static int beginJob(const char *jobPath, BOOL control) {
    @autoreleasepool {
        if (!jobPath || jobPath[0] != '/') return 2;
        NSString *path = [[NSString stringWithUTF8String:jobPath] stringByResolvingSymlinksInPath];
        NSString *processName = NSProcessInfo.processInfo.processName;
        uint32_t capacity = 0; _NSGetExecutablePath(NULL, &capacity);
        char *buffer = calloc(capacity, 1); _NSGetExecutablePath(buffer, &capacity);
        NSString *executable = [[NSString stringWithUTF8String:buffer] stringByResolvingSymlinksInPath]; free(buffer);
        BOOL originalPhotos = [executable isEqual:@"/System/Applications/Photos.app/Contents/MacOS/Photos"];
        if (control ? ![processName isEqual:@"SpatialExtendBridgeHost"] : !originalPhotos) return 3;
        NSURL *directory = [NSURL fileURLWithPath:path isDirectory:YES];
        NSData *data = [NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:@"request.json"]];
        NSDictionary *request = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![request isKindOfClass:NSDictionary.class] || ![request[@"album"] isEqual:@"Trip"] ||
            ![request[@"schema"] isEqual:@1] || ![request[@"sourceSHA256"] isKindOfClass:NSString.class]) return 4;
        if (atomic_exchange(&running, true)) return 5;
        NSMutableDictionary *result = [@{@"schema":@1, @"album":@"Trip", @"pid":@(NSProcessInfo.processInfo.processIdentifier),
            @"executable":executable, @"bundleIdentifier":NSBundle.mainBundle.bundleIdentifier ?: NSNull.null,
            @"control":@(control), @"originalPhotos":@(originalPhotos)} mutableCopy];
        if (!writeStatus(directory, result, @"queued", @"Research job accepted; waiting for the host to resume.")) { atomic_store(&running,false); return 6; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ runJob(directory, request, result, control); });
        return 0;
    }
}

__attribute__((visibility("default"))) int SpatialExtendStart(const char *jobPath) { return beginJob(jobPath, NO); }
__attribute__((visibility("default"))) int SpatialExtendControl(const char *jobPath) { return beginJob(jobPath, YES); }
