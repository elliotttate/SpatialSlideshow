#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
int main(int argc, const char **argv) { @autoreleasepool {
  for (int i=1; i<argc; i++) {
    NSString *path=[NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%s.framework/Versions/A/%s",argv[i],argv[i]];
    void *h=dlopen(path.UTF8String,RTLD_LAZY|RTLD_LOCAL);
    printf("LOAD %s: %s\n",argv[i],h?"OK":dlerror());
    if (!h) continue;
    unsigned int count=0; const char **names=objc_copyClassNamesForImage(path.UTF8String,&count);
    for (unsigned int j=0;j<count;j++) {
      Class cls=objc_getClass(names[j]); printf("CLASS %s : %s\n",names[j],class_getName(class_getSuperclass(cls)));
      for (int k=0;k<2;k++) {
        unsigned int n=0; Method *ms=class_copyMethodList(k?object_getClass(cls):cls,&n);
        for (unsigned int m=0;m<n;m++) printf(" %c %s | %s\n",k?'+':'-',sel_getName(method_getName(ms[m])),method_getTypeEncoding(ms[m]));
        free(ms);
      }
    }
    free(names);
  }
} return 0; }
