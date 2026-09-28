// Apple retains control of its registered model downloads. A normal Developer
// ID app may register its own expiring UAF subscription, but cannot force a
// foreground MobileAsset download with Apple's reserved entitlements.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>

@interface UAFAssetSetManager : NSObject
+ (id)sharedManager;
- (id)retrieveAssetSet:(NSString *)name usages:(NSDictionary *)usages;
- (void)subscribe:(NSString *)subscriber subscriptions:(NSArray *)subscriptions
             user:(id)user userInitiated:(BOOL)userInitiated
            queue:(dispatch_queue_t)queue completion:(void (^)(NSError *))completion;
- (void)unsubscribe:(NSString *)subscriber subscriptionNames:(NSArray *)names
              queue:(dispatch_queue_t)queue completion:(void (^)(NSError *))completion;
@end
@interface UAFAssetSetSubscription : NSObject
- (id)initWithName:(NSString *)name assetSets:(NSDictionary *)sets
      usageAliases:(NSDictionary *)aliases expires:(NSDate *)expires;
@end
@interface UAFAssetSet : NSObject
- (NSDictionary *)assets;
@end
@interface UAFAsset : NSObject
- (NSURL *)location;
@end

static NSString *const AssetRoot = @"/System/Library/AssetsV2";
static NSString *const Subscriber = @"local.photos-spatial-slideshow.model-setup";
static volatile sig_atomic_t Cancelled = 0;
static void cancelSetup(int signalNumber) { Cancelled = signalNumber; }

static NSString *assetType(NSString *kind) {
    return [@"com.apple.MobileAsset.UAF.Photos." stringByAppendingString:
            [kind isEqual:@"reframe"] ? @"SpatialPhotosRelive" : @"MagicCleanup"];
}
static NSDictionary *usages(NSString *kind) {
    if ([kind isEqual:@"reframe"]) return @{
        @"com.apple.photos.spatialphotosrelive.main.generic": @"ENABLED",
        @"com.apple.photos.spatialphotosrelive.fov.main.generic": @"ENABLED"
    };
    return @{@"com.apple.fm.photos.genedit.magiccleanup.generic": @"ENABLED"};
}
static NSString *setupInstructions(NSString *kind) {
    if ([kind isEqual:@"reframe"]) return @"Open Photos and use its spatial-photo feature on a photo, then allow Photos to finish downloading its models and retry. Spatial Slideshow needs Apple's installed Reframe models; this macOS build does not authorize third-party apps to force their download.";
    return @"Open Photos, edit a photo, select Clean Up, and allow its model download to finish, then retry. If Clean Up is unavailable, check Apple Intelligence availability in System Settings, or turn off Expand Photo Edges. This macOS build does not authorize third-party apps to force the Apple model download.";
}
static BOOL readableModel(NSURL *url) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL directory = NO;
    if (![fm fileExistsAtPath:url.path isDirectory:&directory] || !directory) return NO;
    NSURL *descriptor = [url URLByAppendingPathComponent:@"coremldata.bin"];
    NSDictionary *attributes = [fm attributesOfItemAtPath:descriptor.path error:nil];
    return [fm isReadableFileAtPath:descriptor.path] && [attributes[NSFileSize] unsignedLongLongValue] > 0 &&
        [fm isReadableFileAtPath:[url URLByAppendingPathComponent:@"model.specialization.bundle"].path];
}
static NSArray<NSURL *> *modelsIn(NSURL *root) {
    NSArray *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:nil];
    NSPredicate *filter = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
        return [url.pathExtension isEqual:@"mlmodelc"] && readableModel(url);
    }];
    return [contents filteredArrayUsingPredicate:filter] ?: @[];
}
static NSDictionary *statusForRoots(NSString *kind, NSArray<NSURL *> *roots, NSString *resolution) {
    NSMutableArray<NSURL *> *joint = [NSMutableArray array], *fov = [NSMutableArray array], *cleanup = [NSMutableArray array];
    for (NSURL *root in roots) {
        if ([kind isEqual:@"cleanup"]) {
            if (readableModel([root URLByAppendingPathComponent:@"inpainting.mlmodelc"]) &&
                readableModel([root URLByAppendingPathComponent:@"refinement.mlmodelc"])) [cleanup addObject:root];
        } else {
            for (NSURL *model in modelsIn(root)) {
                if ([model.lastPathComponent containsString:@"joint_predictor"]) [joint addObject:model];
                if ([model.lastPathComponent containsString:@"fov_"]) [fov addObject:model];
            }
        }
    }
    BOOL reframe = [kind isEqual:@"reframe"];
    BOOL ready = reframe ? joint.count == 1 && fov.count == 1 : cleanup.count == 1;
    BOOL ambiguous = reframe ? joint.count > 1 || fov.count > 1 : cleanup.count > 1;
    NSString *message = ready ? @"Apple Photos models are installed and readable." :
        ambiguous ? [@"Several Apple model versions are installed and macOS did not resolve one active version. " stringByAppendingString:setupInstructions(kind)] :
        [@"Required Apple Photos models are missing, incomplete, or unreadable. " stringByAppendingString:setupInstructions(kind)];
    NSDictionary *paths = !ready ? @{} : reframe ? @{@"joint": joint[0].path, @"fov": fov[0].path} : @{@"root": cleanup[0].path};
    return @{@"schema": @1, @"kind": kind, @"ready": @(ready), @"status": ready ? @"ready" : ambiguous ? @"ambiguous" : @"missing",
             @"message": message, @"models": paths, @"resolution": resolution,
             @"foreground_download_authorized": @NO, @"setup_instructions": setupInstructions(kind)};
}
static id manager(void) {
    static id value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (dlopen("/System/Library/PrivateFrameworks/UnifiedAssetFramework.framework/UnifiedAssetFramework", RTLD_NOW)) {
            Class cls = NSClassFromString(@"UAFAssetSetManager");
            if ([cls respondsToSelector:@selector(sharedManager)]) value = [cls sharedManager];
        }
    });
    return value;
}
static NSDictionary *checkModels(NSString *kind, NSString *assetsRoot, BOOL useUAF) {
    // UAF chooses the active atomic model set. Never pick a random or newest
    // asset directory: model updates may leave older registered versions here.
    if (useUAF) {
        @try {
            id service = manager();
            if ([service respondsToSelector:@selector(retrieveAssetSet:usages:)]) {
                UAFAssetSet *set = [service retrieveAssetSet:assetType(kind) usages:usages(kind)];
                NSMutableArray *roots = [NSMutableArray array];
                for (NSString *name in usages(kind)) {
                    UAFAsset *asset = [set assets][name];
                    NSURL *location = [asset respondsToSelector:@selector(location)] ? asset.location : nil;
                    // The resolver is system-owned; still require registered
                    // system assets rather than an arbitrary executable path.
                    if (location.isFileURL && [location.path hasPrefix:[AssetRoot stringByAppendingString:@"/"]]) [roots addObject:location];
                }
                NSDictionary *resolved = statusForRoots(kind, roots, @"active_registered_set");
                if ([resolved[@"ready"] boolValue]) return resolved;
            }
        } @catch (NSException *exception) { /* Different private API: safe discovery fallback. */ }
    }
    NSString *directory = [[assetType(kind) stringByReplacingOccurrencesOfString:@"." withString:@"_"] stringByAppendingPathComponent:@"purpose_auto"];
    NSURL *root = [NSURL fileURLWithPath:[assetsRoot stringByAppendingPathComponent:directory] isDirectory:YES];
    NSMutableArray *roots = [NSMutableArray array];
    for (NSURL *asset in [NSFileManager.defaultManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:nil]) {
        if ([asset.pathExtension isEqual:@"asset"]) [roots addObject:[asset URLByAppendingPathComponent:@".AssetData" isDirectory:YES]];
    }
    return statusForRoots(kind, roots, @"unique_installed_models");
}
static void writeStatus(NSDictionary *status) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingSortedKeys error:nil];
    if (data) { fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout); }
}
static BOOL waitFor(dispatch_semaphore_t done, NSTimeInterval seconds) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + seconds;
    while (!Cancelled && NSProcessInfo.processInfo.systemUptime < deadline) {
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) == 0) return YES;
    }
    return NO;
}
static NSDictionary *ensureModels(NSString *kind, NSTimeInterval timeout) {
    NSDictionary *initial = checkModels(kind, AssetRoot, YES);
    if ([initial[@"ready"] boolValue]) return initial;
    id service = manager();
    Class subscriptionClass = NSClassFromString(@"UAFAssetSetSubscription");
    if (![service respondsToSelector:@selector(subscribe:subscriptions:user:userInitiated:queue:completion:)] ||
        ![service respondsToSelector:@selector(unsubscribe:subscriptionNames:queue:completion:)] ||
        ![subscriptionClass instancesRespondToSelector:@selector(initWithName:assetSets:usageAliases:expires:)]) return initial;

    NSString *name = [kind stringByAppendingFormat:@"-%@", NSUUID.UUID.UUIDString];
    // Own subscriber only; never impersonate Photos or alter its subscription.
    // Expiration also bounds cleanup if the helper is force-terminated.
    id subscription = [[subscriptionClass alloc] initWithName:name assetSets:@{assetType(kind): usages(kind)}
                                                usageAliases:@{} expires:[NSDate dateWithTimeIntervalSinceNow:timeout + 60]];
    __block NSError *subscriptionError;
    dispatch_semaphore_t subscribed = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    fprintf(stderr, "SETUP Asking macOS to prepare the Apple Photos models…\n");
    [service subscribe:Subscriber subscriptions:@[subscription] user:nil userInitiated:YES queue:queue completion:^(NSError *error) {
        subscriptionError = error;
        dispatch_semaphore_signal(subscribed);
    }];
    BOOL accepted = waitFor(subscribed, 5) && !subscriptionError;
    NSMutableDictionary *result = [initial mutableCopy];
    if (accepted) {
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
        while (!Cancelled && NSProcessInfo.processInfo.systemUptime < deadline) {
            result = [checkModels(kind, AssetRoot, YES) mutableCopy];
            if ([result[@"ready"] boolValue]) break;
            fprintf(stderr, "SETUP Waiting for macOS model preparation; Photos may need to finish setup…\n");
            for (int i = 0; i < 20 && !Cancelled; i++) usleep(100000);
        }
    }
    dispatch_semaphore_t unsubscribed = dispatch_semaphore_create(0);
    [service unsubscribe:Subscriber subscriptionNames:@[name] queue:queue completion:^(NSError *error) {
        dispatch_semaphore_signal(unsubscribed);
    }];
    waitFor(unsubscribed, 3);
    result[@"subscription_requested"] = @YES;
    result[@"subscription_accepted"] = @(accepted);
    if (Cancelled) { result[@"ready"] = @NO; result[@"status"] = @"cancelled"; result[@"message"] = @"Apple model setup was cancelled."; }
    else if (![result[@"ready"] boolValue]) {
        result[@"status"] = @"action_required";
        result[@"message"] = [(accepted ? @"macOS accepted the model request, but the models are not ready yet. " : @"macOS could not prepare the required Apple models automatically. ") stringByAppendingString:setupInstructions(kind)];
    }
    return result;
}

#ifndef APPLE_MODEL_SETUP_NO_MAIN
int main(int argc, const char *argv[]) { @autoreleasepool {
    setbuf(stdout, NULL); setbuf(stderr, NULL);
    if (argc < 3 || argc > 4 || (strcmp(argv[1], "--check") && strcmp(argv[1], "--ensure")) ||
        (strcmp(argv[2], "reframe") && strcmp(argv[2], "cleanup"))) {
        fputs("Usage: AppleModelSetup --check|--ensure reframe|cleanup [timeout-seconds]\n", stderr); return 2;
    }
    NSTimeInterval timeout = argc == 4 ? strtod(argv[3], NULL) : 30;
    if (!isfinite(timeout) || timeout < 1 || timeout > 120) { fputs("Timeout must be between 1 and 120 seconds.\n", stderr); return 2; }
    signal(SIGTERM, cancelSetup); signal(SIGINT, cancelSetup);
    // Private synchronous resolvers must not keep the parent waiting forever.
    alarm((unsigned int)ceil(timeout) + 15);
    @try {
        NSString *kind = [NSString stringWithUTF8String:argv[2]];
        NSDictionary *result = strcmp(argv[1], "--ensure") == 0 ? ensureModels(kind, timeout) : checkModels(kind, AssetRoot, YES);
        writeStatus(result);
        // --check successfully reports both ready and missing states as JSON.
        // --ensure's nonzero result is actionable rather than a claimed setup.
        BOOL failed = strcmp(argv[1], "--ensure") == 0 && ![result[@"ready"] boolValue];
        if (failed) fprintf(stderr, "ERROR: %s\n", [result[@"message"] UTF8String]);
        return failed ? 3 : 0;
    } @catch (NSException *exception) {
        writeStatus(@{@"schema": @1, @"ready": @NO, @"status": @"unsupported", @"message": @"This macOS version does not support automatic Apple model setup. Open the relevant feature in Photos and retry."});
        return 3;
    }
} }
#endif
