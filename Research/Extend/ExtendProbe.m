#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <signal.h>
#import <objc/message.h>
#import <string.h>
#import <errno.h>

// Runtime bridge to the same production outpainting pipeline used by Photos Extend.
// The service's normal policy, environment, and guardrails remain in effect.
@interface NSObject (PhotosExtend)
- (CIImage *)applyOutfill:(CIImage *)image context:(CIContext *)context
             orientation:(NSInteger)orientation expandLeft:(CGFloat)left
             expandRight:(CGFloat)right expandTop:(CGFloat)top
            expandBottom:(CGFloat)bottom useCaseIdentifier:(NSString *)useCase
       cancellationCheck:(BOOL (^)(void))cancellationCheck error:(NSError **)error;
@end

static volatile sig_atomic_t cancelled = 0;
static void cancelRun(int signalNumber) { cancelled = 1; }

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 3 && argc != 4) { fprintf(stderr, "Usage: ExtendProbe Trip-export output.png [1024|2048|3072|4096]\n"); return 2; }
    if ([[NSFileManager defaultManager] fileExistsAtPath:@(argv[2])]) {
        fprintf(stderr, "Output already exists; choose a new path.\n"); return 2;
    }
    signal(SIGINT, cancelRun); signal(SIGTERM, cancelRun);
    void *framework = dlopen("/System/Library/PrivateFrameworks/PhotoImaging.framework/Versions/A/PhotoImaging", RTLD_LAZY | RTLD_LOCAL);
    Class pipelineClass = NSClassFromString(@"PIOutfillPipeline");
    if (!framework || !pipelineClass) { fprintf(stderr, "Photos Extend pipeline unavailable\n"); return 3; }
    if (argc == 4) {
        char *end = NULL;
        errno = 0;
        long resolution = strtol(argv[3], &end, 10);
        if (errno || !end || *end || (resolution != 1024 && resolution != 2048 && resolution != 3072 && resolution != 4096)) { fprintf(stderr, "Invalid model resolution\n"); return 2; }
        typedef void (__attribute__((swiftcall)) *ResolutionSetter)(uint64_t, uint8_t);
        void *pgs = dlopen("/System/Library/PrivateFrameworks/PhotosGenerativeServices.framework/Versions/A/PhotosGenerativeServices", RTLD_LAZY | RTLD_LOCAL);
        if (!pgs) { fprintf(stderr, "PhotosGenerativeServices unavailable\n"); return 3; }
        ResolutionSetter setter = (ResolutionSetter)dlsym(pgs, "$s24PhotosGenerativeServices19OutpaintADMPipelineV23modelResolutionOverride12CoreGraphics7CGFloatVSgvsZ");
        if (!setter) { fprintf(stderr, "Native model resolution override missing\n"); return 3; }
        id settings = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"PIGlobalSettings"), sel_registerName("globalSettings"));
        NSInteger existing = ((NSInteger (*)(id, SEL))objc_msgSend)(settings, sel_registerName("outfillModelResolution"));
        fprintf(stderr, "Existing per-process model resolution: %ld\n", (long)existing);
        if (existing > 0) { fprintf(stderr, "Existing PhotoImaging override would replace this test; aborting without changing preferences\n"); return 3; }
        // IDA + native arm64 disassembly verifies Optional<CGFloat> uses raw bits
        // in x0 and the nil tag in x1. The exported setter changes this process only.
        double value = (double)resolution;
        uint64_t bits; memcpy(&bits, &value, sizeof bits);
        setter(bits, 0);
        fprintf(stderr, "Native OutpaintADMPipeline modelResolutionOverride: %ld\n", resolution);
    }
    NSURL *input = [NSURL fileURLWithPath:@(argv[1])];
    NSURL *output = [NSURL fileURLWithPath:@(argv[2])];
    CIImage *source = [CIImage imageWithContentsOfURL:input options:@{
        kCIImageApplyOrientationProperty:@YES,
        kCIImageExpandToHDR:@NO,
        kCIImageToneMapHDRtoSDR:@YES
    }];
    if (!source) { fprintf(stderr, "Cannot decode input\n"); return 4; }
    source = [source imageByApplyingTransform:CGAffineTransformMakeTranslation(-source.extent.origin.x, -source.extent.origin.y)];
    CGColorSpaceRef working = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CIContext *context = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace:(__bridge id)working, kCIContextWorkingFormat:@(kCIFormatRGBAh)}];
    // Horizontal native Extend baseline: a 4:3 input becomes 16:9.
    CGFloat border = ceil(source.extent.size.width / 6.0);
    NSDate *started = NSDate.date;
    fprintf(stderr, "Photos Extend: %.0fx%.0f, left/right %.0f px; production Photos use case\n", source.extent.size.width, source.extent.size.height, border);
    NSError *error = nil;
    NSObject *pipeline = [pipelineClass new];
    CIImage *expanded = [pipeline applyOutfill:source context:context orientation:1
        expandLeft:border expandRight:border expandTop:0 expandBottom:0
        useCaseIdentifier:nil cancellationCheck:^BOOL {
            return cancelled || -started.timeIntervalSinceNow > 300;
        } error:&error];
    if (!expanded) {
        fprintf(stderr, "Photos Extend failed after %.1fs: %s\n", -started.timeIntervalSinceNow, error.description.UTF8String);
        fprintf(stderr, "This probe calls the native Extend service, not the app's local Clean Up model. An Operation not permitted error may require inspecting modelmanagerd's entitlement diagnostic.\n");
        CGColorSpaceRelease(working); CGColorSpaceRelease(srgb); return 5;
    }
    CGRect extent = expanded.extent;
    fprintf(stderr, "Expanded extent %s after %.1fs\n", NSStringFromRect(NSRectFromCGRect(extent)).UTF8String, -started.timeIntervalSinceNow);
    expanded = [expanded imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
    BOOL saved = [context writePNGRepresentationOfImage:expanded toURL:output format:kCIFormatRGBA8 colorSpace:srgb options:@{} error:&error];
    CGColorSpaceRelease(working); CGColorSpaceRelease(srgb);
    if (!saved) { fprintf(stderr, "Save failed: %s\n", error.description.UTF8String); return 6; }
    NSDictionary *metadata = @{@"pipeline":@"Photos Extend PIOutfillPipeline", @"useCase":@"VisualGeneration.PhotosEdit.Outfill.1p", @"originalWidth":@(source.extent.size.width), @"originalHeight":@(source.extent.size.height), @"left":@(border), @"right":@(border), @"top":@0, @"bottom":@0, @"outputWidth":@(extent.size.width), @"outputHeight":@(extent.size.height), @"elapsedSeconds":@(-started.timeIntervalSinceNow)};
    NSData *json = [NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToURL:[output URLByAppendingPathExtension:@"json"] atomically:YES];
    return 0;
} }
