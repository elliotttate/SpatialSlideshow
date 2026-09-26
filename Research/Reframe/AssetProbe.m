#import <Foundation/Foundation.h>
#import <dlfcn.h>
@interface MAAssetQuery : NSObject
- (id)initWithType:(NSString *)type andPurpose:(NSString *)purpose;
- (NSInteger)queryMetaDataSync;
- (NSArray *)results;
@end
@interface MAAsset : NSObject
- (NSURL *)getLocalUrl;
- (NSURL *)getLocalFileUrl;
- (NSString *)assetId;
@end
int main(void) { @autoreleasepool {
    setbuf(stdout, NULL);
    dlopen("/System/Library/PrivateFrameworks/MobileAsset.framework/MobileAsset", RTLD_NOW);
    MAAssetQuery *query = [[NSClassFromString(@"MAAssetQuery") alloc] initWithType:@"com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive" andPurpose:@"auto"];
    NSInteger status = [query queryMetaDataSync];
    printf("QUERY %ld\n", (long)status);
    for (MAAsset *asset in [query results]) {
        printf("ASSET %s local=%s file=%s\n", [[asset assetId] UTF8String], [[[asset getLocalUrl] description] UTF8String], [[[asset getLocalFileUrl] description] UTF8String]);
    }
    return status == 0 ? 0 : 1;
} }
