#import <Foundation/Foundation.h>
__attribute__((constructor)) static void fdm_init(void) {
    NSLog(@"[FDM] hello dylib loaded OK");
}
