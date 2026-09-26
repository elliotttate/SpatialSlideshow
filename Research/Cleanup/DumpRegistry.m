#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <ptrauth.h>

int main(void) {
  @autoreleasepool {
    void *handle = dlopen("/System/Library/PrivateFrameworks/PhotoImaging.framework/PhotoImaging",RTLD_NOW);
    for (NSString *name in @[@"NUMLModelRegistry", @"PIObjectRemoval", @"PIGANCleanupPipeline", @"NUMLModelLoadOptions", @"MLModelConfiguration"]) {
      Class cls = NSClassFromString(name); if (!cls) continue;
      printf("CLASS %s\n",name.UTF8String);
      for (int isMeta=0; isMeta<2; isMeta++) {
        unsigned count=0; Method *methods = class_copyMethodList(isMeta ? object_getClass(cls):cls,&count);
        for (unsigned i=0;i<count;i++) {
          SEL sel=method_getName(methods[i]); NSString *method=NSStringFromSelector(sel);
          if ([name isEqualToString:@"MLModelConfiguration"] && ![method localizedCaseInsensitiveContainsString:@"program"] && ![method localizedCaseInsensitiveContainsString:@"E5"] && ![method localizedCaseInsensitiveContainsString:@"special"] && ![method localizedCaseInsensitiveContainsString:@"directory"]) continue;
          IMP imp=method_getImplementation(methods[i]); void *ptr=ptrauth_strip((void *)imp,ptrauth_key_function_pointer); Dl_info info={}; dladdr(ptr,&info);
          printf(" %c %s | %s | offset0x%lx | %s\n",isMeta?'+':'-',sel_getName(sel),method_getTypeEncoding(methods[i]),(unsigned long)((char *)ptr-(char *)info.dli_fbase),info.dli_fname);
        }
        free(methods);
      }
    }
    for (const char **symbol=(const char *[]){"PIModelKeyInpaint","PIModelKeyRefinement",NULL};*symbol;symbol++) {
      NSString *__unsafe_unretained *value=(NSString *__unsafe_unretained *)dlsym(handle,*symbol);
      if (value) NSLog(@"KEY %s %@",*symbol,*value);
    }
  }
}
