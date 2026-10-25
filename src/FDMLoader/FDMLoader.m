// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用

/* ============================================================
 * FDMLoader.m - hot-reload loader (TrollFools injects ONLY this)
 *
 * ⚠️ CRITICAL: never touch Foundation/ObjC inside a dylib constructor.
 *    During dyld::runInitializers the ObjC runtime is not fully up;
 *    even [NSString stringWithFormat:] with %@ can crash (SIGSEGV in
 *    objc_opt_respondsToSelector / _NSDescriptionWithStringProxyFunc).
 *
 *    So: the constructor ONLY schedules a delayed block. All real work
 *    (logging, path lookup, dlopen) happens 2s later on the main queue.
 * ============================================================ */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <pthread.h>

/* ⚠️ 必须是 NSString 字面量，不能用 C 字符串。
 *   曾经的 bug：LLog(@"%@", "fdm-hot.dylib") 把 char* 当 NSObject，
 *   objc_opt_respondsToSelector 解引用裸指针 → SIGSEGV。 */
static NSString *const kHotName = @"fdm-hot.dylib";
static NSString *const kLogName = @"fdm-loader.log";

static NSString *LoaderDocs(void) {
    static NSString *d = nil;
    if (!d) {
        NSArray *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
        d = [a firstObject] ?: NSTemporaryDirectory();
    }
    return d;
}

static void LLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSLog(@"[FDMLoader] %@", s);
        @try {
            NSString *p = [LoaderDocs() stringByAppendingPathComponent:kLogName];
            NSString *line = [NSString stringWithFormat:@"%@  %@\n", [NSDate date], s];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (!fh) {
                [[NSFileManager defaultManager] createFileAtPath:p contents:nil attributes:NULL];
                fh = [NSFileHandle fileHandleForWritingAtPath:p];
            }
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    }
}

/* ---------- 真正的初始化（安全阶段才跑） ---------- */
static void fdm_loader_real_init(void) {
    @autoreleasepool {
        LLog(@"==========================================");
        LLog(@"FDMLoader real init  pid=%d", (int)getpid());
        LLog(@"Documents = %@", LoaderDocs());

        /* ★ 依次尝试多个路径 —— iOS 沙盒只允许从特定位置 mmap 可执行代码。
         *   Documents 被挡（sandbox blocked mmap），所以要试其它位置。 */
        NSArray<NSString *> *candidates = @[
            [LoaderDocs() stringByAppendingPathComponent:kHotName],   /* App Documents（通常被挡） */
            [@"/var/jb/usr/lib" stringByAppendingPathComponent:kHotName],   /* 越狱 bootstrap */
            [@"/var/tmp" stringByAppendingPathComponent:kHotName],
            [@"/var/mobile/Media" stringByAppendingPathComponent:kHotName],
            [@"/var/mobile/Documents" stringByAppendingPathComponent:kHotName],
        ];

        void *h = NULL;
        NSString *usedPath = nil;
        NSFileManager *fm = [NSFileManager defaultManager];

        for (NSString *p in candidates) {
            if (![fm fileExistsAtPath:p]) {
                LLog(@"  - 跳过（不存在）: %@", p);
                continue;
            }
            NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
            LLog(@"  尝试: %@ (%llu B)", p, [a fileSize]);

            dlerror();
            void *hh = dlopen(p.UTF8String, RTLD_NOW | RTLD_GLOBAL);
            if (hh) {
                h = hh;
                usedPath = p;
                break;
            }
            const char *err = dlerror();
            NSString *errS = err ? [NSString stringWithUTF8String:err] : @"(unknown)";
            /* 只打印关键原因，避免刷屏 */
            if ([errS rangeOfString:@"sandbox blocked mmap"].location != NSNotFound)
                LLog(@"    ❌ 沙盒禁止 mmap");
            else if ([errS rangeOfString:@"no suitable image"].location != NSNotFound)
                LLog(@"    ❌ 架构/签名不匹配");
            else
                LLog(@"    ❌ %@", errS.length > 160 ? [errS substringToIndex:160] : errS);
        }

        if (!h) {
            LLog(@"❌ 所有候选路径都失败 —— hot 逻辑未加载");
            LLog(@"========== FDMLoader end ==========");
            return;
        }

        LLog(@"✅ dlopen 成功: %@  handle=%p", usedPath, h);

        typedef void (*FDMHotEntry)(void);
        FDMHotEntry entry = (FDMHotEntry)dlsym(h, "FDMHotEntry");
        if (entry) {
            LLog(@"调用 FDMHotEntry()...");
            @try { entry(); } @catch (NSException *e) {
                LLog(@"FDMHotEntry 异常: %@", e.reason);
            }
        } else {
            LLog(@"(hot.dylib 无 FDMHotEntry，依赖构造函数)");
        }
        LLog(@"========== FDMLoader end ==========");
    }
}

/* ---------- 构造函数：只调度，不做事 ---------- */
__attribute__((constructor))
static void fdm_loader_init(void) {
    /* 这里绝对不碰 Foundation / ObjC / NSLog —— 只注册延迟块 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        fdm_loader_real_init();
    });
}
