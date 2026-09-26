#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreImage/CoreImage.h>
#import <simd/simd.h>
#import <dlfcn.h>
#include <vector>
#include <cmath>
@interface GSAsset:NSObject
@property unsigned numGaussians,numFeatures,maxCoeff,activationScale,activationOpacity;
@property BOOL rawDiffuseColor;
@property unsigned defaultPrepareOptions,maxFrames;
-(BOOL)computeCentroids;
@property matrix_float4x4 modelMatrix,defaultViewMatrix;
@property matrix_float3x3 defaultIntrinsics;
@property vector_uint2 defaultImageSize;
@property CGColorSpaceRef cgColorSpace;
@property(readonly) NSString *descriptionJSON;
-(void)setCoords:(id)b withFormat:(NSUInteger)f stride:(NSUInteger)s offset:(NSUInteger)o;
-(void)setScales:(id)b withFormat:(NSUInteger)f stride:(NSUInteger)s offset:(NSUInteger)o;
-(void)setRots:(id)b withFormat:(NSUInteger)f stride:(NSUInteger)s offset:(NSUInteger)o;
-(void)setFeatures:(id)b withFormat:(NSUInteger)f stride:(NSUInteger)s offset:(NSUInteger)o;
-(void)setAlphas:(id)b withFormat:(NSUInteger)f stride:(NSUInteger)s offset:(NSUInteger)o;
-(BOOL)prepareWithCommandBuffer:(id)b error:(NSError**)e;
-(BOOL)computeCovariancesWith:(id)b error:(NSError**)e;
@end
@interface GSRenderDescriptor:NSObject
-(instancetype)initForMaxCameras:(unsigned)c;
@property matrix_float4x4 *viewMatrices,*projectionMatrices;
@property MTLViewport *viewports;
@property unsigned degree,primitiveType,blendingOrder,blendingPipeline,depthMode,alphaMode,maskType;
@property float alphaConstant,powerThreshold,saturationThreshold,sigmaFloor;
@end
@interface GSSorterDescriptor:NSObject
@property unsigned sortingMode,sortingHardware,sortingAlgorithm,cullingMode;
@end
@interface GSSorter:NSObject
-(instancetype)initWithDevice:(id)d forAssets:(NSArray*)a error:(NSError**)e;
-(BOOL)encodeSorting:(id)b forAssets:(NSArray*)a sorterDescriptor:(id)s renderDescriptor:(id)r error:(NSError**)e;
@end
@interface GSRenderer:NSObject
-(void)updateViewMatrices:(const matrix_float4x4*)m;
-(instancetype)initWithDevice:(id)d colorPixelFormat:(NSUInteger)c depthPixelFormat:(NSUInteger)p error:(NSError**)e;
-(id)createRenderPassDescriptorForColorTarget:(id)c depthTarget:(id)d rasterizationRateMap:(id)m error:(NSError**)e;
-(BOOL)encodeSplatting:(id)b withSorter:(id)s renderPassDescriptor:(id)p renderDescriptor:(id)r error:(NSError**)e;
@end
