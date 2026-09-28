#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

/// Apple's Gaussian renderer over an already prepared Reframe scene directory.
/// Initialize on a worker queue; encode frames serially on one Metal command
/// queue, allowing at most two submitted command buffers to remain in flight.
/// Encode a given scene instance only once in each command buffer.
@interface LiveGaussianScene : NSObject
+ (BOOL)isAvailable;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable instancetype)initWithURL:(NSURL *)url
                             device:(id<MTLDevice>)device
                              error:(NSError * _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER;

@property(nonatomic, readonly) NSUInteger gaussianCount;
/// Input buffer bytes, excluding private renderer allocations and render targets.
@property(nonatomic, readonly) NSUInteger byteCost;
@property(nonatomic, readonly) CGSize sourceSize;
@property(nonatomic, readonly) float expansionPercent;

/// Does not commit or wait for commandBuffer. Composite the returned image with
/// Core Image into that same command buffer before submitting it. progress is
/// normalized 0...1, strength is 0...4, and zoomOut is a percentage (0...40).
/// The caller-supplied zoomOut overrides any cached scene sidecar allowance.
- (nullable CIImage *)encodeFrameWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                            width:(NSUInteger)width
                                           height:(NSUInteger)height
                                              fit:(BOOL)fit
                                          pattern:(NSUInteger)pattern
                                         progress:(float)progress
                                         strength:(float)strength
                                          zoomOut:(float)zoomOut
                                            error:(NSError * _Nullable * _Nullable)error;

/// Optional camera offset for paused exploration, normalized to -1...1 on each
/// axis. Zero preserves the slideshow camera exactly. This does not change or
/// regenerate the cached scene.
- (nullable CIImage *)encodeFrameWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                            width:(NSUInteger)width
                                           height:(NSUInteger)height
                                              fit:(BOOL)fit
                                          pattern:(NSUInteger)pattern
                                         progress:(float)progress
                                         strength:(float)strength
                                          zoomOut:(float)zoomOut
                                          manualX:(float)manualX
                                          manualY:(float)manualY
                                            error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
