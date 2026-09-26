#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
@interface MXIScene : NSObject
@property(readonly) NSUInteger vertexCount;
@property(readonly) NSUInteger triangleCount;
@property(readonly) NSDictionary *attributes;
@property(readonly) float verticalFOV;
@property(readonly) float aspectRatio;
@property(readonly) id<MTLBuffer> vertexPositions;
@property(readonly) id<MTLBuffer> vertexUVs;
@property(readonly) id<MTLBuffer> triangleIndices;
@property(readonly) id<MTLTexture> colorTexture;
- (BOOL)writeToURL:(NSURL *)url error:(NSError **)error;
@end
@interface GSAsset : NSObject
@end
