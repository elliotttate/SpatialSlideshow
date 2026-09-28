#define APPLE_MODEL_SETUP_NO_MAIN
#import "../Sources/AppleModelSetup.m"

static int checks = 0;
static void expect(BOOL condition, NSString *label) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL %s\n", label.UTF8String); exit(1); }
    printf("PASS %s\n", label.UTF8String);
}
static NSURL *model(NSURL *root, NSString *name, BOOL complete) {
    NSURL *url = [root URLByAppendingPathComponent:name isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:NULL];
    [@"synthetic descriptor" writeToURL:[url URLByAppendingPathComponent:@"coremldata.bin"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (complete) [NSFileManager.defaultManager createDirectoryAtURL:[url URLByAppendingPathComponent:@"model.specialization.bundle"] withIntermediateDirectories:YES attributes:nil error:NULL];
    return url;
}
int main(void) { @autoreleasepool {
    NSURL *temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"AppleModelSetupTest-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:temporary withIntermediateDirectories:YES attributes:nil error:NULL];
    @try {
        NSDictionary *missing = checkModels(@"reframe", temporary.path, NO);
        expect(![missing[@"ready"] boolValue] && [missing[@"status"] isEqual:@"missing"], @"New user with no model directory gets a missing state, not a crash");
        expect([missing[@"message"] containsString:@"Open Photos"], @"Missing Reframe explains the required Photos setup");
        expect(![missing[@"foreground_download_authorized"] boolValue], @"Does not claim entitlement-restricted download capability");
        NSURL *spatial = [temporary URLByAppendingPathComponent:@"com_apple_MobileAsset_UAF_Photos_SpatialPhotosRelive/purpose_auto"];
        NSURL *jointRoot = [spatial URLByAppendingPathComponent:@"joint-current.asset/.AssetData"];
        NSURL *fovRoot = [spatial URLByAppendingPathComponent:@"fov-current.asset/.AssetData"];
        NSURL *joint = model(jointRoot, @"future_joint_predictor_any_version.mlmodelc", YES);
        expect(![checkModels(@"reframe", temporary.path, NO)[@"ready"] boolValue], @"Partial model pair is not considered ready");
        NSURL *fov = model(fovRoot, @"future_fov_any_version.mlmodelc", NO);
        expect(![checkModels(@"reframe", temporary.path, NO)[@"ready"] boolValue], @"Unfinished model without specialization bundle is rejected");
        model(fovRoot, fov.lastPathComponent, YES);
        NSDictionary *ready = checkModels(@"reframe", temporary.path, NO);
        expect([ready[@"ready"] boolValue], @"Discovers model pairs without hardcoded versions or asset hashes");
        expect([[NSURL fileURLWithPath:ready[@"models"][@"joint"]].URLByResolvingSymlinksInPath isEqual:joint.URLByResolvingSymlinksInPath] && [[NSURL fileURLWithPath:ready[@"models"][@"fov"]].URLByResolvingSymlinksInPath isEqual:fov.URLByResolvingSymlinksInPath], @"Returns exact validated model paths");
        model([spatial URLByAppendingPathComponent:@"joint-old.asset/.AssetData"], @"old_joint_predictor.mlmodelc", YES);
        NSDictionary *ambiguous = checkModels(@"reframe", temporary.path, NO);
        expect([ambiguous[@"status"] isEqual:@"ambiguous"] && ![ambiguous[@"ready"] boolValue], @"Fallback refuses to mix model versions when multiple are installed");
        NSDictionary *selected = statusForRoots(@"reframe", @[jointRoot, fovRoot], @"active_registered_set");
        expect([selected[@"ready"] boolValue], @"Active registered set remains usable with old assets present");
        NSURL *cleanup = [temporary URLByAppendingPathComponent:@"com_apple_MobileAsset_UAF_Photos_MagicCleanup/purpose_auto/new.asset/.AssetData"];
        model(cleanup, @"inpainting.mlmodelc", YES);
        expect(![checkModels(@"cleanup", temporary.path, NO)[@"ready"] boolValue], @"Incomplete Clean Up pair is rejected");
        model(cleanup, @"refinement.mlmodelc", YES);
        NSDictionary *cleanupStatus = checkModels(@"cleanup", temporary.path, NO);
        expect([cleanupStatus[@"ready"] boolValue] && [[NSURL fileURLWithPath:cleanupStatus[@"models"][@"root"] isDirectory:YES].URLByResolvingSymlinksInPath isEqual:cleanup.URLByResolvingSymlinksInPath], @"Clean Up pair resolves together");
        NSURL *second = [cleanup URLByDeletingLastPathComponent];
        second = [[second URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"old.asset/.AssetData"];
        model(second, @"inpainting.mlmodelc", YES); model(second, @"refinement.mlmodelc", YES);
        expect([checkModels(@"cleanup", temporary.path, NO)[@"status"] isEqual:@"ambiguous"], @"Clean Up fallback refuses arbitrary model-version selection");
        expect([setupInstructions(@"cleanup") containsString:@"turn off Expand Photo Edges"], @"Optional Clean Up failure offers a usable non-expansion choice");
        expect([NSJSONSerialization isValidJSONObject:ready] && [NSJSONSerialization isValidJSONObject:missing], @"Ready and missing results both have stable JSON output");
        printf("%d Apple model setup checks passed (synthetic files only).\n", checks);
    } @finally {
        [NSFileManager.defaultManager removeItemAtURL:temporary error:NULL];
    }
    return 0;
} }
