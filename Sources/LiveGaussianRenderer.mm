#import "LiveGaussianRenderer.h"
#import "NativeGaussian.h"
#include "CameraMotion.h"
#include <limits>
#include <algorithm>

static NSString *const LiveGaussianErrorDomain = @"SpatialSlideshow.LiveGaussian";

static BOOL liveError(NSError **error, NSInteger code, NSString *operation, NSError *underlying = nil) {
    if (error) {
        NSMutableDictionary *details = [@{NSLocalizedDescriptionKey: operation} mutableCopy];
        if (underlying) details[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:LiveGaussianErrorDomain code:code userInfo:details];
    }
    return NO;
}

static BOOL validNumber(id value, double minimum, double maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return std::isfinite(number) && number >= minimum && number <= maximum;
}

static matrix_float4x4 liveLookAt(vector_float3 eye, vector_float3 target) {
    const vector_float3 back = simd_normalize(eye - target);
    const vector_float3 right = simd_normalize(simd_cross((vector_float3){0, -1, 0}, back));
    const vector_float3 up = simd_cross(back, right);
    return (matrix_float4x4){
        (vector_float4){right.x, up.x, back.x, 0},
        (vector_float4){right.y, up.y, back.y, 0},
        (vector_float4){right.z, up.z, back.z, 0},
        (vector_float4){-simd_dot(right, eye), -simd_dot(up, eye), -simd_dot(back, eye), 1}
    };
}

@implementation LiveGaussianScene {
    id<MTLDevice> _device;
    GSAsset *_asset;
    GSRenderer *_renderer;
    GSSorter *_sorter;
    GSRenderDescriptor *_renderDescriptor;
    GSSorterDescriptor *_sortDescriptor;
    NSArray<id<MTLBuffer>> *_buffers;
    id<MTLCommandQueue> _frameQueue;
    id<MTLTexture> _color[2];
    id<MTLTexture> _depth[2];
    matrix_float4x4 _view[2], _projection[2];
    NSUInteger _renderWidth, _renderHeight, _frameIndex;
    NSUInteger _gaussianCount, _byteCost;
    CGSize _sourceSize;
    float _focus, _travelDepth, _expansionPercent;
    CGColorSpaceRef _linear;
}

+ (BOOL)isAvailable {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Keep the library loaded while instances and encoded GPU work exist.
        void *library = dlopen("/System/Library/PrivateFrameworks/CoreRE3DGSFoundation.framework/CoreRE3DGSFoundation", RTLD_NOW | RTLD_LOCAL);
        available = library && NSClassFromString(@"GSAsset") && NSClassFromString(@"GSRenderer") &&
                    NSClassFromString(@"GSSorter") && NSClassFromString(@"GSRenderDescriptor") &&
                    NSClassFromString(@"GSSorterDescriptor");
    });
    return available;
}

- (NSUInteger)gaussianCount { return _gaussianCount; }
- (NSUInteger)byteCost { return _byteCost; }
- (CGSize)sourceSize { return _sourceSize; }
- (float)expansionPercent { return _expansionPercent; }

- (instancetype)initWithURL:(NSURL *)url device:(id<MTLDevice>)device error:(NSError **)error {
    if (!(self = [super init])) return nil;
    @try {
        if (![url isFileURL] || !device || ![LiveGaussianScene isAvailable]) {
            liveError(error, 1, @"The Apple Gaussian renderer or Metal device is unavailable.");
            return nil;
        }
        _device = device;
        NSError *detail = nil;
        NSData *manifestData = [NSData dataWithContentsOfURL:[url URLByAppendingPathComponent:@"scene.json"] options:0 error:&detail];
        id manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&detail] : nil;
        if (![manifest isKindOfClass:NSDictionary.class] ||
            !validNumber(manifest[@"width"], 1, 131072) || !validNumber(manifest[@"height"], 1, 131072)) {
            liveError(error, 2, @"The cached Gaussian scene has an invalid image size or manifest.", detail);
            return nil;
        }
        _sourceSize = CGSizeMake([manifest[@"width"] doubleValue], [manifest[@"height"] doubleValue]);

        NSURL *expansionURL = [url URLByAppendingPathComponent:@"expansion.json"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:expansionURL.path]) {
            NSData *data = [NSData dataWithContentsOfURL:expansionURL options:0 error:&detail];
            id expansion = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&detail] : nil;
            id amount = [expansion isKindOfClass:NSDictionary.class] ? expansion[@"percent_per_edge"] : nil;
            if (![expansion isKindOfClass:NSDictionary.class] || (amount && !validNumber(amount, 0, 20))) {
                liveError(error, 3, @"The cached scene's expansion metadata is invalid.", detail);
                return nil;
            }
            _expansionPercent = [amount floatValue];
        }

        // Derive the splat count from half-precision opacity and require every
        // companion buffer to contain precisely that many packed elements.
        NSData *alphas = [NSData dataWithContentsOfURL:[url URLByAppendingPathComponent:@"alphas.bin"]
                                             options:NSDataReadingMappedIfSafe error:&detail];
        if (!alphas.length || alphas.length % sizeof(__fp16) || alphas.length > device.maxBufferLength) {
            liveError(error, 4, @"The cached scene has an invalid opacity buffer.", detail);
            return nil;
        }
        _gaussianCount = alphas.length / sizeof(__fp16);
        if (_gaussianCount > std::numeric_limits<unsigned>::max() || _gaussianCount > device.maxBufferLength / 8) {
            liveError(error, 4, @"The cached scene is too large for this GPU.");
            return nil;
        }
        NSMutableArray<id<MTLBuffer>> *buffers = [NSMutableArray new];
        NSArray<NSString *> *names = @[@"alphas", @"positions", @"scales", @"rotations", @"colors"];
        const NSUInteger strides[] = {2, 6, 6, 8, 6};
        for (NSUInteger i = 0; i < names.count; ++i) {
            NSString *name = names[i];
            NSData *data = i == 0 ? alphas : [NSData dataWithContentsOfURL:[url URLByAppendingPathComponent:[name stringByAppendingString:@".bin"]]
                                                                 options:NSDataReadingMappedIfSafe error:&detail];
            if (data.length != _gaussianCount * strides[i]) {
                liveError(error, 4, [NSString stringWithFormat:@"The cached scene has an incomplete %@ buffer.", name], detail);
                return nil;
            }
            // Non-finite half values can poison covariance/sorting kernels.
            const __fp16 *values = static_cast<const __fp16 *>(data.bytes);
            for (NSUInteger j = 0; j < data.length / sizeof(__fp16); ++j) {
                if (!std::isfinite(static_cast<float>(values[j]))) {
                    liveError(error, 4, [NSString stringWithFormat:@"The cached scene contains an invalid %@ value.", name]);
                    return nil;
                }
            }
            id<MTLBuffer> buffer = [device newBufferWithBytes:data.bytes length:data.length options:MTLResourceStorageModeShared];
            if (!buffer) {
                liveError(error, 5, @"There is not enough GPU memory to load this Gaussian scene.");
                return nil;
            }
            buffer.label = [@"Spatial live " stringByAppendingString:name];
            [buffers addObject:buffer];
            _byteCost += data.length;
        }
        _buffers = buffers;
        _linear = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
        if (!_linear) {
            liveError(error, 5, @"The renderer could not create its working color space.");
            return nil;
        }
        _asset = [NSClassFromString(@"GSAsset") new];
        _asset.numGaussians = (unsigned)_gaussianCount;
        _asset.numFeatures = 3;
        _asset.maxCoeff = 1;
        _asset.activationScale = 0;
        _asset.activationOpacity = 0;
        _asset.maxFrames = 1;
        _asset.modelMatrix = matrix_identity_float4x4;
        _asset.cgColorSpace = _linear;
        [_asset setAlphas:buffers[0] withFormat:MTLAttributeFormatHalf stride:2 offset:0];
        [_asset setCoords:buffers[1] withFormat:MTLAttributeFormatHalf3 stride:6 offset:0];
        [_asset setScales:buffers[2] withFormat:MTLAttributeFormatHalf3 stride:6 offset:0];
        [_asset setRots:buffers[3] withFormat:MTLAttributeFormatHalf4 stride:8 offset:0];
        [_asset setFeatures:buffers[4] withFormat:MTLAttributeFormatHalf3 stride:6 offset:0];

        // Use the same robust foreground focus as the video renderer, rather
        // than letting a distant patch of sky dictate the camera translation.
        const auto positions = static_cast<const __fp16 *>(buffers[1].contents);
        const NSUInteger grid = (NSUInteger)std::sqrt(_gaussianCount / 2);
        if (grid < 8) {
            liveError(error, 4, @"The cached scene has too few Gaussian points.");
            return nil;
        }
        std::vector<float> depths;
        for (NSUInteger y = grid * 3 / 8; y < grid * 5 / 8; y += 4)
            for (NSUInteger x = grid * 3 / 8; x < grid * 5 / 8; x += 4) {
                float z = positions[(y * grid + x) * 3 + 2];
                if (z > .01f) depths.push_back(z);
            }
        if (depths.empty()) {
            liveError(error, 4, @"The cached scene has no valid center depth.");
            return nil;
        }
        auto median = depths.begin() + depths.size() / 2;
        std::nth_element(depths.begin(), median, depths.end());
        const float centerDepth = *median;
        depths.clear();
        for (NSUInteger y = grid / 10; y < grid * 9 / 10; y += 4)
            for (NSUInteger x = grid / 10; x < grid * 9 / 10; x += 4) {
                float z = positions[(y * grid + x) * 3 + 2];
                if (z > .01f) depths.push_back(z);
            }
        if (depths.empty()) {
            liveError(error, 4, @"The cached scene has no valid foreground depth.");
            return nil;
        }
        auto foreground = depths.begin() + depths.size() / 5;
        std::nth_element(depths.begin(), foreground, depths.end());
        _focus = std::min(centerDepth, *foreground * 1.5f);
        _travelDepth = std::min(_focus, *foreground);

        id<MTLCommandQueue> preparationQueue = [device newCommandQueue];
        id<MTLCommandBuffer> preparation = [preparationQueue commandBuffer];
        if (!preparation || ![_asset computeCovariancesWith:preparation error:&detail] ||
            ![_asset prepareWithCommandBuffer:preparation error:&detail]) {
            liveError(error, 6, @"Apple's renderer could not prepare the Gaussian scene.", detail);
            return nil;
        }
        // Only loading waits for the GPU. Draws below never block for completion.
        [preparation commit];
        [preparation waitUntilCompleted];
        if (preparation.status != MTLCommandBufferStatusCompleted) {
            liveError(error, 6, @"GPU preparation of the Gaussian scene failed.", preparation.error);
            return nil;
        }
        _renderer = [(GSRenderer *)[NSClassFromString(@"GSRenderer") alloc] initWithDevice:device
                                    colorPixelFormat:MTLPixelFormatRGBA16Float depthPixelFormat:MTLPixelFormatDepth32Float error:&detail];
        _sorter = [(GSSorter *)[NSClassFromString(@"GSSorter") alloc] initWithDevice:device forAssets:@[_asset] error:&detail];
        _sortDescriptor = [NSClassFromString(@"GSSorterDescriptor") new];
        _renderDescriptor = [(GSRenderDescriptor *)[NSClassFromString(@"GSRenderDescriptor") alloc] initForMaxCameras:1];
        if (!_renderer || !_sorter || !_sortDescriptor || !_renderDescriptor || !_renderDescriptor.viewports) {
            liveError(error, 6, @"Apple's Gaussian renderer could not be initialized.", detail);
            return nil;
        }
        _sortDescriptor.cullingMode = 0;
        _renderDescriptor.degree = 0;
    } @catch (NSException *exception) {
        liveError(error, 7, [NSString stringWithFormat:@"Apple's Gaussian renderer could not load this scene: %@", exception.reason ?: exception.name]);
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_linear) CGColorSpaceRelease(_linear);
}

- (CIImage *)encodeFrameWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                   width:(NSUInteger)width height:(NSUInteger)height fit:(BOOL)fit
                                 pattern:(NSUInteger)pattern progress:(float)progress strength:(float)strength
                                 zoomOut:(float)zoomOut error:(NSError **)error {
    return [self encodeFrameWithCommandBuffer:commandBuffer width:width height:height fit:fit
        pattern:pattern progress:progress strength:strength zoomOut:zoomOut manualX:0 manualY:0 error:error];
}

- (CIImage *)encodeFrameWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                   width:(NSUInteger)width height:(NSUInteger)height fit:(BOOL)fit
                                 pattern:(NSUInteger)pattern progress:(float)progress strength:(float)strength
                                 zoomOut:(float)zoomOut manualX:(float)manualX manualY:(float)manualY error:(NSError **)error {
    @try {
        if (!commandBuffer || commandBuffer.commandQueue.device != _device ||
            commandBuffer.status >= MTLCommandBufferStatusCommitted || !width || !height || width > 8192 || height > 8192 ||
            !std::isfinite(progress) || !std::isfinite(strength) || !std::isfinite(zoomOut) ||
            !std::isfinite(manualX) || !std::isfinite(manualY)) {
            liveError(error, 8, @"The live renderer received invalid frame settings or a Metal command buffer from another device.");
            return nil;
        }
        if (_frameQueue && _frameQueue != commandBuffer.commandQueue) {
            liveError(error, 8, @"A Gaussian scene must render its frames on a single Metal command queue.");
            return nil;
        }
        _frameQueue = commandBuffer.commandQueue;
        const double scale = std::min(width / _sourceSize.width, height / _sourceSize.height);
        NSUInteger renderWidth = fit ? std::max((NSUInteger)1, (NSUInteger)std::round(_sourceSize.width * scale)) : width;
        NSUInteger renderHeight = fit ? std::max((NSUInteger)1, (NSUInteger)std::round(_sourceSize.height * scale)) : height;
        if (_renderWidth != renderWidth || _renderHeight != renderHeight) {
            id<MTLTexture> colors[2], depths[2];
            auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                               width:renderWidth height:renderHeight mipmapped:NO];
            descriptor.storageMode = MTLStorageModePrivate;
            descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            for (NSUInteger index = 0; index < 2; ++index) {
                descriptor.pixelFormat = MTLPixelFormatRGBA16Float;
                colors[index] = [_device newTextureWithDescriptor:descriptor];
                descriptor.pixelFormat = MTLPixelFormatDepth32Float;
                depths[index] = [_device newTextureWithDescriptor:descriptor];
                if (!colors[index] || !depths[index]) {
                    liveError(error, 5, @"There is not enough GPU memory for the requested live rendering resolution.");
                    return nil;
                }
            }
            // Metal retains previous targets in their submitted command buffers.
            for (NSUInteger index = 0; index < 2; ++index) {
                _color[index] = colors[index];
                _depth[index] = depths[index];
            }
            _renderWidth = renderWidth;
            _renderHeight = renderHeight;
        }
        const float aspect = _sourceSize.width / _sourceSize.height;
        const float outputAspect = (float)renderWidth / renderHeight;
        const vector_float2 projectionScale = {std::max(1.f, aspect / outputAspect), std::max(1.f, outputAspect / aspect)};
        auto motion = spatial::cameraMotion((unsigned)(pattern % 6), progress, _travelDepth, strength, _expansionPercent, zoomOut);
        // Keep inspection near the source viewpoint. The same bound applies
        // regardless of pointer speed, key repeat or scene depth.
        motion.eye.x += std::clamp(manualX, -1.f, 1.f) * .09f * _travelDepth;
        motion.eye.y += std::clamp(manualY, -1.f, 1.f) * .09f * _travelDepth;
        const NSUInteger index = _frameIndex++ % 2;
        // Keep matrix storage alive until this slot's command has finished.
        // The caller admits at most two command buffers, so revisiting a slot
        // cannot race its preceding frame's GPU work.
        matrix_float4x4 &view = _view[index];
        matrix_float4x4 &projection = _projection[index];
        view = liveLookAt(motion.eye, (vector_float3){0, 0, _focus});
        projection = {};
        projection.columns[0].x = motion.zoom * projectionScale.x;
        projection.columns[1].y = motion.zoom * projectionScale.y;
        constexpr float near = .01f, far = 10000.f;
        projection.columns[2].z = near / (far - near);
        projection.columns[2].w = -1;
        projection.columns[3].z = near * far / (far - near);
        // The private viewport setter takes ownership, so write its allocation.
        _renderDescriptor.viewports[0] = (MTLViewport){0, 0, (double)renderWidth, (double)renderHeight, 0, 1};
        _renderDescriptor.viewMatrices = &view;
        _renderDescriptor.projectionMatrices = &projection;
        [_renderer updateViewMatrices:&view];
        NSError *detail = nil;
        if (![_sorter encodeSorting:commandBuffer forAssets:@[_asset] sorterDescriptor:_sortDescriptor renderDescriptor:_renderDescriptor error:&detail]) {
            liveError(error, 9, @"Apple's renderer could not sort this Gaussian frame.", detail);
            return nil;
        }
        MTLRenderPassDescriptor *pass = [_renderer createRenderPassDescriptorForColorTarget:_color[index] depthTarget:_depth[index]
                                                                      rasterizationRateMap:nil error:&detail];
        if (!pass || ![_renderer encodeSplatting:commandBuffer withSorter:_sorter renderPassDescriptor:pass renderDescriptor:_renderDescriptor error:&detail]) {
            liveError(error, 9, @"Apple's renderer could not draw this Gaussian frame.", detail);
            return nil;
        }
        CIImage *image = [CIImage imageWithMTLTexture:_color[index] options:@{kCIImageColorSpace: (__bridge id)_linear}];
        if (!image) {
            liveError(error, 9, @"The Gaussian frame could not be passed to the display compositor.");
            return nil;
        }
        // Match RenderSlideshow's model-to-Core-Image orientation and letterbox.
        image = [image imageByApplyingTransform:CGAffineTransformMake(1, 0, 0, -1, 0, renderHeight)];
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(((double)width - renderWidth) / 2., ((double)height - renderHeight) / 2.)];
        CIImage *black = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0]] imageByCroppingToRect:CGRectMake(0, 0, width, height)];
        // Metal retains encoded buffers/textures; keep their private owning
        // objects and matrix storage alive too when the player swaps scenes.
        [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> completed) { (void)[self gaussianCount]; }];
        return [[image imageByCompositingOverImage:black] imageByCroppingToRect:black.extent];
    } @catch (NSException *exception) {
        liveError(error, 7, [NSString stringWithFormat:@"Apple's Gaussian renderer could not draw this frame: %@", exception.reason ?: exception.name]);
        return nil;
    }
}
@end
