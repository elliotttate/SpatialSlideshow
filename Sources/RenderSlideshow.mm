#import "NativeGaussian.h"
#import <AVFoundation/AVFoundation.h>
#include <algorithm>
#include "ExpansionMotion.h"

static void require(BOOL ok, NSError *error, NSString *operation) {
    if (!ok) { fprintf(stderr, "%s: %s\n", operation.UTF8String, error.description.UTF8String ?: "failed"); exit(1); }
}

static id<MTLBuffer> readBuffer(id<MTLDevice> device, NSString *root, NSString *name, NSUInteger expected = 0) {
    NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:[name stringByAppendingString:@".bin"]]];
    require(data.length > 0 && (!expected || data.length == expected), nil, [@"Invalid scene buffer: " stringByAppendingString:name]);
    return [device newBufferWithBytes:data.bytes length:data.length options:MTLResourceStorageModeShared];
}

static float readExpansionValue(NSString *root, NSString *key, double maximum) {
    NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"expansion.json"]];
    if (!data) return 0.f;
    id metadata = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    id value = [metadata isKindOfClass:[NSDictionary class]] ? metadata[key] : nil;
    if (!value) return 0.f;
    if ([value isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
        double percent = [value doubleValue];
        if (std::isfinite(percent) && std::floor(percent) == percent && percent >= 0)
            return (float)std::min(percent, maximum);
    }
    fprintf(stderr, "EXPANSION ignored invalid metadata in %s\n", root.fileSystemRepresentation);
    return 0.f;
}

// Model coordinates have +Y downward and +Z forward. The native renderer uses
// a right-handed camera and reverse Z (near=1, far=0).
static matrix_float4x4 lookAt(vector_float3 eye, vector_float3 target) {
    vector_float3 back = simd_normalize(eye - target);
    vector_float3 right = simd_normalize(simd_cross((vector_float3){0,-1,0}, back));
    vector_float3 up = simd_cross(back, right);
    return (matrix_float4x4){
        (vector_float4){right.x,up.x,back.x,0},
        (vector_float4){right.y,up.y,back.y,0},
        (vector_float4){right.z,up.z,back.z,0},
        (vector_float4){-simd_dot(right,eye),-simd_dot(up,eye),-simd_dot(back,eye),1}
    };
}

@interface SpatialScene : NSObject
@property GSAsset *asset;
@property GSSorter *sorter;
@property GSRenderer *renderer;
@property GSRenderDescriptor *renderDescriptor;
@property GSSorterDescriptor *sortDescriptor;
@property id<MTLTexture> color, depth;
@property float focus, travelDepth;
@property int width, height;
@property unsigned motionPattern;
@property vector_float2 projectionScale;
@property float expansionPercent, zoomOutPercent;
@end
@implementation SpatialScene
@end

static SpatialScene *loadScene(NSString *root, id<MTLDevice> device, id<MTLCommandQueue> queue, int width, int height, unsigned pattern, float strength) {
    NSError *error = nil;
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"scene.json"]] options:0 error:&error];
    require(manifest != nil, error, @"Read scene manifest");
    float sourceWidth = [manifest[@"width"] floatValue], sourceHeight = [manifest[@"height"] floatValue];
    require(sourceWidth > 0 && sourceHeight > 0, nil, @"Invalid image size");
    SpatialScene *scene = [SpatialScene new];
    bool fit = getenv("SPATIAL_FRAMING") && strcmp(getenv("SPATIAL_FRAMING"),"fit") == 0;
    float fittedScale = std::min(width/sourceWidth, height/sourceHeight);
    scene.width = fit ? std::max(1,(int)round(sourceWidth*fittedScale)) : width;
    scene.height = fit ? std::max(1,(int)round(sourceHeight*fittedScale)) : height;
    scene.motionPattern = pattern;
    scene.expansionPercent = readExpansionValue(root, @"percent_per_edge", 20.0);
    scene.zoomOutPercent = readExpansionValue(root, @"zoom_out_percent", 40.0);
    float aspect = sourceWidth/sourceHeight, outputAspect = (float)scene.width/scene.height;
    scene.projectionScale = (vector_float2){MAX(1.f,aspect/outputAspect),MAX(1.f,outputAspect/aspect)};
    GSAsset *asset = (GSAsset *)[NSClassFromString(@"GSAsset") new];
    require(asset != nil, nil, @"Apple Gaussian framework unavailable");
    id<MTLBuffer> alphas = readBuffer(device, root, @"alphas");
    NSUInteger count = alphas.length / sizeof(__fp16);
    id<MTLBuffer> coords = readBuffer(device,root,@"positions",count*6);
    id<MTLBuffer> scales = readBuffer(device,root,@"scales",count*6);
    id<MTLBuffer> rots = readBuffer(device,root,@"rotations",count*8);
    id<MTLBuffer> colors = readBuffer(device,root,@"colors",count*6);
    asset.numGaussians = (unsigned)count; asset.numFeatures = 3; asset.maxCoeff = 1;
    asset.activationScale = 0; asset.activationOpacity = 0; asset.maxFrames = 1;
    asset.modelMatrix = matrix_identity_float4x4;
    CGColorSpaceRef linear = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
    asset.cgColorSpace = linear; CGColorSpaceRelease(linear);
    [asset setCoords:coords withFormat:MTLAttributeFormatHalf3 stride:6 offset:0];
    [asset setScales:scales withFormat:MTLAttributeFormatHalf3 stride:6 offset:0];
    [asset setRots:rots withFormat:MTLAttributeFormatHalf4 stride:8 offset:0];
    [asset setFeatures:colors withFormat:MTLAttributeFormatHalf3 stride:6 offset:0];
    [asset setAlphas:alphas withFormat:MTLAttributeFormatHalf stride:2 offset:0];
    // A center patch can be distant fog/sky even when people are nearby and
    // off-center. Bound both the focus and camera travel by foreground depth.
    auto positions = (const __fp16 *)coords.contents;
    std::vector<float> depths;
    unsigned grid = (unsigned)std::sqrt(count/2);
    for (unsigned y=grid*3/8; y<grid*5/8; y+=4)
        for (unsigned x=grid*3/8; x<grid*5/8; x+=4) {
            float z=positions[(y*grid+x)*3+2];
            if (std::isfinite(z) && z > .01f) depths.push_back(z);
        }
    require(!depths.empty(),nil,@"Invalid scene depth");
    std::nth_element(depths.begin(),depths.begin()+depths.size()/2,depths.end());
    float centerDepth=depths[depths.size()/2];
    depths.clear();
    for (unsigned y=grid/10; y<grid*9/10; y+=4)
        for (unsigned x=grid/10; x<grid*9/10; x+=4) {
            float z=positions[(y*grid+x)*3+2];
            if (std::isfinite(z) && z > .01f) depths.push_back(z);
        }
    require(!depths.empty(),nil,@"Invalid foreground depth");
    auto foreground=depths.begin()+depths.size()/5;
    std::nth_element(depths.begin(),foreground,depths.end());
    scene.focus=std::min(centerDepth,*foreground*1.5f);
    scene.travelDepth=std::min(scene.focus,*foreground);
    id<MTLCommandBuffer> preparation = [queue commandBuffer];
    require([asset computeCovariancesWith:preparation error:&error],error,@"Compute Gaussian covariances");
    require([asset prepareWithCommandBuffer:preparation error:&error],error,@"Prepare scene");
    [preparation commit]; [preparation waitUntilCompleted];
    require(preparation.status == MTLCommandBufferStatusCompleted,preparation.error,@"Prepare GPU buffers");
    scene.asset=asset;
    scene.renderer=[(GSRenderer *)[NSClassFromString(@"GSRenderer") alloc] initWithDevice:device colorPixelFormat:MTLPixelFormatRGBA16Float depthPixelFormat:MTLPixelFormatDepth32Float error:&error];
    require(scene.renderer!=nil,error,@"Create renderer");
    scene.sorter=[(GSSorter *)[NSClassFromString(@"GSSorter") alloc] initWithDevice:device forAssets:@[asset] error:&error];
    require(scene.sorter!=nil,error,@"Create sorter");
    scene.sortDescriptor=[NSClassFromString(@"GSSorterDescriptor") new];
    scene.sortDescriptor.cullingMode=0;
    scene.renderDescriptor=[(GSRenderDescriptor *)[NSClassFromString(@"GSRenderDescriptor") alloc] initForMaxCameras:1];
    scene.renderDescriptor.degree=0;
    // setViewports: takes ownership of its argument; write through the getter.
    scene.renderDescriptor.viewports[0]=(MTLViewport){0,0,(double)scene.width,(double)scene.height,0,1};
    auto texture=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:scene.width height:scene.height mipmapped:NO];
    texture.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    scene.color=[device newTextureWithDescriptor:texture];
    texture.pixelFormat=MTLPixelFormatDepth32Float;
    scene.depth=[device newTextureWithDescriptor:texture];
    printf("SCENE %s %u splats %dx%d center %.3f focus %.3f travel-depth %.3f pattern %u framing %s\n",root.lastPathComponent.UTF8String,(unsigned)count,scene.width,scene.height,centerDepth,scene.focus,scene.travelDepth,pattern,fit ? "fit" : "fill");
    if (scene.expansionPercent > 0) {
        const auto range = spatial::expansionMotionRange(pattern, strength, scene.expansionPercent, scene.zoomOutPercent);
        printf("EXPANSION %.0f%% per-edge strength %.3f travel-scale %.3f travel-depth %.3f -> %.3f zoom %.4f..%.4f pattern %u allowance %.0f%%\n",
               scene.expansionPercent, strength, range.travelScale, scene.travelDepth,
               scene.travelDepth * range.travelScale, range.minZoom, range.maxZoom, pattern, scene.zoomOutPercent);
    }
    return scene;
}

static CIImage *renderFrame(SpatialScene *scene, id<MTLCommandQueue> queue, float progress, float strength, int width, int height, CGColorSpaceRef linear) {
    float t = std::clamp(progress,0.f,1.f);
    float eased = t*t*(3-2*t), sweep = 2*eased-1;
    float arch = sinf(t*M_PI);
    // All paths operate in the actual predicted 3D scene. Scale translation by
    // foreground depth so distant sky cannot produce excessive camera travel.
    vector_float3 offset;
    switch(scene.motionPattern % 6) {
        case 0: offset={ .065f*sweep, .018f*arch, .015f*arch}; break; // left to right
        case 1: offset={-.065f*sweep,-.018f*arch, .015f*arch}; break; // right to left
        case 2: offset={ .020f*sweep,-.010f*sweep,-.015f+.045f*eased}; break; // push in
        case 3: offset={-.020f*sweep, .012f*sweep, .030f-.050f*eased}; break; // pull back
        case 4: offset={ .045f*sweep, .028f*sweep, .010f*arch}; break; // diagonal
        default:offset={ .012f*arch, .045f*sweep, .012f*arch}; break; // vertical
    }
    vector_float3 eye = offset * scene.travelDepth * strength;
    float zoom=1.06f;
    // Leave the established camera arithmetic untouched for ordinary scenes.
    // Expansion is opt-in per scene; no sidecar means identical old motion.
    if (scene.expansionPercent > 0.f) {
        const auto motion = spatial::expansionMotion(scene.motionPattern, progress, strength, scene.expansionPercent, scene.zoomOutPercent);
        eye *= motion.travelScale;
        zoom = motion.zoom;
    }
    matrix_float4x4 view = lookAt(eye,(vector_float3){0,0,scene.focus});
    matrix_float4x4 projection = {};
    // The predictor's square canonical rays span [-1,1] on both axes. Restore
    // source aspect with the viewport; predicted focal length is metadata here.
    projection.columns[0].x=zoom*scene.projectionScale.x; projection.columns[1].y=zoom*scene.projectionScale.y;
    float near=.01f,far=10000.f;
    projection.columns[2].z=near/(far-near); projection.columns[2].w=-1;
    projection.columns[3].z=near*far/(far-near);
    scene.renderDescriptor.viewMatrices=&view; scene.renderDescriptor.projectionMatrices=&projection;
    [scene.renderer updateViewMatrices:&view];
    NSError *error=nil;
    id<MTLCommandBuffer> command=[queue commandBuffer];
    require([scene.sorter encodeSorting:command forAssets:@[scene.asset] sorterDescriptor:scene.sortDescriptor renderDescriptor:scene.renderDescriptor error:&error],error,@"Sort scene");
    MTLRenderPassDescriptor *pass=[scene.renderer createRenderPassDescriptorForColorTarget:scene.color depthTarget:scene.depth rasterizationRateMap:nil error:&error];
    require(pass!=nil,error,@"Create render pass");
    // Keep Apple's intermediate attachments and reverse-Z depth clear intact.
    require([scene.renderer encodeSplatting:command withSorter:scene.sorter renderPassDescriptor:pass renderDescriptor:scene.renderDescriptor error:&error],error,@"Render scene");
    [command commit]; [command waitUntilCompleted];
    require(command.status==MTLCommandBufferStatusCompleted,command.error,@"Render GPU frame");
    CIImage *image=[CIImage imageWithMTLTexture:scene.color options:@{kCIImageColorSpace:(__bridge id)linear}];
    image=[image imageByApplyingTransform:CGAffineTransformMake(1,0,0,-1,0,scene.height)];
    image=[image imageByApplyingTransform:CGAffineTransformMakeTranslation((width-scene.width)/2.,(height-scene.height)/2.)];
    CIImage *background=[[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0]] imageByCroppingToRect:CGRectMake(0,0,width,height)];
    return [[image imageByCompositingOverImage:background] imageByCroppingToRect:background.extent];
}

int main(int argc, const char **argv) { @autoreleasepool {
    setbuf(stdout,nullptr);
    if(argc<6){fprintf(stderr,"Usage: RenderSlideshow output.mp4 seconds-per-photo motion-strength WIDTHxHEIGHT scene-dir...\n");return 2;}
    NSString *output=@(argv[1]); float duration=atof(argv[2]), strength=atof(argv[3]); int width=0,height=0;
    int longEdge=0;
    if(sscanf(argv[4],"source:%d",&longEdge)==1) {
        require(argc==6 && longEdge>=256 && longEdge<=3840,nil,@"Source aspect requires one photo and a 256–3840 pixel long edge");
        NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[@(argv[5]) stringByAppendingPathComponent:@"scene.json"]] options:0 error:nil];
        float sourceWidth=[manifest[@"width"] floatValue], sourceHeight=[manifest[@"height"] floatValue];
        require(sourceWidth>0 && sourceHeight>0,nil,@"Read source dimensions");
        float scale=longEdge/std::max(sourceWidth,sourceHeight);
        width=std::max(256,(int)round(sourceWidth*scale/2)*2); height=std::max(256,(int)round(sourceHeight*scale/2)*2);
    } else if(sscanf(argv[4],"%dx%d",&width,&height)!=2)width=height=atoi(argv[4]);
    require(duration>=2 && duration<=60 && strength>=0 && strength<=2 && width>=256 && height>=256 && width<=3840 && height<=3840 && width%2==0 && height%2==0,nil,@"Invalid slideshow settings");
    require(![[NSFileManager defaultManager] fileExistsAtPath:output],nil,@"Output already exists");
    require(dlopen("/System/Library/PrivateFrameworks/CoreRE3DGSFoundation.framework/CoreRE3DGSFoundation",RTLD_NOW)!=nullptr,nil,@"Load Apple renderer");
    id<MTLDevice> device=MTLCreateSystemDefaultDevice(); require(device!=nil,nil,@"Metal unavailable");
    id<MTLCommandQueue> queue=[device newCommandQueue];
    NSMutableArray<NSString *> *paths=[NSMutableArray new]; for(int i=5;i<argc;i++)[paths addObject:@(argv[i])];
    // Keep only the current and incoming scene resident.
    NSMutableDictionary<NSNumber *,SpatialScene *> *scenes=[NSMutableDictionary new];
    NSError *error=nil;
    AVAssetWriter *writer=[[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:output] fileType:AVFileTypeMPEG4 error:&error];
    require(writer!=nil,error,@"Create movie");
    // Preserve roughly the same compression quality when the user selects 4K.
    int bitrate=(int)std::clamp(12000000.0*width*height/(1920.0*1080),6000000.0,64000000.0);
    NSDictionary *videoColors=@{AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,
                               AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,
                               AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2};
    AVAssetWriterInput *input=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{AVVideoCodecKey:AVVideoCodecTypeH264,AVVideoWidthKey:@(width),AVVideoHeightKey:@(height),AVVideoColorPropertiesKey:videoColors,AVVideoCompressionPropertiesKey:@{AVVideoAverageBitRateKey:@(bitrate),AVVideoExpectedSourceFrameRateKey:@30}}];
    printf("ENCODE %dx%d bitrate %d\n",width,height,bitrate);
    AVAssetWriterInputPixelBufferAdaptor *adaptor=[AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(id)kCVPixelBufferWidthKey:@(width),(id)kCVPixelBufferHeightKey:@(height),(id)kCVPixelBufferIOSurfacePropertiesKey:@{}}];
    require([writer canAddInput:input],nil,@"Movie format unsupported"); [writer addInput:input];
    require([writer startWriting],writer.error,@"Start export"); [writer startSessionAtSourceTime:kCMTimeZero];
    // Derive the RGB encoding from the exact video tags. Core Media's 709
    // transfer differs from the display-oriented kCGColorSpaceITUR_709 profile;
    // using that profile here makes AVPlayer playback visibly lighter.
    NSDictionary *bufferColors=@{(id)kCVImageBufferColorPrimariesKey:(id)kCVImageBufferColorPrimaries_ITU_R_709_2,
                                 (id)kCVImageBufferTransferFunctionKey:(id)kCVImageBufferTransferFunction_ITU_R_709_2,
                                 (id)kCVImageBufferYCbCrMatrixKey:(id)kCVImageBufferYCbCrMatrix_ITU_R_709_2};
    CGColorSpaceRef linear=CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB),srgb=CGColorSpaceCreateWithName(kCGColorSpaceSRGB),rec709=CVImageBufferCreateColorSpaceFromAttachments((__bridge CFDictionaryRef)bufferColors);
    require(rec709!=nil,nil,@"Create video color space");
    CIContext *context=[CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace:(__bridge id)linear}];
    const int fps=30;
    const float transition=std::clamp(getenv("SPATIAL_TRANSITION") ? (float)atof(getenv("SPATIAL_TRANSITION")) : .8f,0.f,std::min(2.f,duration/3));
    const float step=duration-transition;
    unsigned patternBase = getenv("SPATIAL_MOTION_PATTERN") ? (unsigned)atoi(getenv("SPATIAL_MOTION_PATTERN")) % 6 : 0;
    bool variety = !getenv("SPATIAL_MOTION_VARIETY") || strcmp(getenv("SPATIAL_MOTION_VARIETY"),"0") != 0;
    int frames=(int)round((paths.count*duration-(paths.count-1)*transition)*fps);
    NSString *evidence=[output.stringByDeletingPathExtension stringByAppendingString:@"-frames"];
    [[NSFileManager defaultManager] createDirectoryAtPath:evidence withIntermediateDirectories:YES attributes:nil error:nil];
    for(int frame=0;frame<frames;frame++) { @autoreleasepool {
        float time=frame/(float)fps;
        int index=MIN((int)paths.count-1,(int)(time/step));
        float local=time-index*step;
        for(NSNumber *key in [scenes.allKeys copy]) if(key.intValue<index-1 || key.intValue>index)[scenes removeObjectForKey:key];
        if(!scenes[@(index)])scenes[@(index)]=loadScene(paths[index],device,queue,width,height,(patternBase+(variety ? index : 0))%6,strength);
        CIImage *image=renderFrame(scenes[@(index)],queue,local/duration,strength,width,height,linear);
        if(index>0 && local<transition){
            if(!scenes[@(index-1)])scenes[@(index-1)]=loadScene(paths[index-1],device,queue,width,height,(patternBase+(variety ? index-1 : 0))%6,strength);
            CIImage *previous=renderFrame(scenes[@(index-1)],queue,(step+local)/duration,strength,width,height,linear);
            float mix=local/transition;mix=mix*mix*(3-2*mix);
            image=[previous imageByApplyingFilter:@"CIDissolveTransition" withInputParameters:@{kCIInputTargetImageKey:image,kCIInputTimeKey:@(mix)}];
        }
        while(!input.readyForMoreMediaData){require(writer.status==AVAssetWriterStatusWriting,writer.error,@"Movie encoder");[NSThread sleepForTimeInterval:.002];}
        CVPixelBufferRef buffer=nullptr;
        require(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,adaptor.pixelBufferPool,&buffer)==kCVReturnSuccess,nil,@"Allocate video frame");
        // Convert actual pixels to the same encoding declared in the movie.
        [context render:image toCVPixelBuffer:buffer bounds:CGRectMake(0,0,width,height) colorSpace:rec709];
        CVBufferSetAttachment(buffer,kCVImageBufferCGColorSpaceKey,rec709,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachments(buffer,(__bridge CFDictionaryRef)bufferColors,kCVAttachmentMode_ShouldPropagate);
        require([adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(frame,fps)],writer.error,@"Append video frame");
        CVPixelBufferRelease(buffer);
        if(!getenv("SPATIAL_NO_STILLS") && (frame==0 || frame==frames-1 || frame==fps*2 || frame==(int)(step*fps)+fps*2)){
            NSString *path=[evidence stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%04d.png",frame]];
            require([context writePNGRepresentationOfImage:image toURL:[NSURL fileURLWithPath:path] format:kCIFormatRGBA8 colorSpace:srgb options:@{} error:&error],error,@"Save preview");
        }
        if(frame%30==0)printf("RENDER %d %d\n",frame,frames);
    }}
    [input markAsFinished];dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{dispatch_semaphore_signal(done);}];
    dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
    require(writer.status==AVAssetWriterStatusCompleted,writer.error,@"Finish movie");
    CGColorSpaceRelease(linear);CGColorSpaceRelease(srgb);CGColorSpaceRelease(rec709);
    printf("MOVIE %s %d frames %.2f seconds\n",output.UTF8String,frames,frames/(float)fps);
    return 0;
}}
