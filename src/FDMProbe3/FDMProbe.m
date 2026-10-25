// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用

/* ============================================================
 * FDM v0.5 —— 授权验证 + 第一个业务实验
 *
 * 实验设计（一次注入，两个结果）：
 *
 *  ① 验证 Choicy 是否真的关掉了 ElleKit 注入
 *     → 重新数进程里的 TweakInject / libellekit 个数（期望 0）
 *
 *  ② ★ 第一个业务实验：服务端设置「本地覆盖」
 *     安卓版思路是往 MMKV 写 kv_settings_<key>；
 *     iOS 版服务端设置压成一个 blob，键名 app.ab.serverValues。
 *     ⇒ 我们劫持这一个键的 **读 + 写**，把 blob 里的指定项改成我们要的值。
 *
 *     可见验证标志（改两个，提高命中率）：
 *       deep_think_button_suffix        ""     → "·FDM"   （深思按钮上多出字样）
 *       show_new_chat_button_above_input false → true     （输入框上方多一个按钮）
 *
 * 安全铁律（吸取 v0.2/v0.3 崩溃教训）：
 *   ★ Hook 内不调任何宿主方法（只比对字符串、只做指针操作）
 *   ★ Hook 内不做文件 IO（只加计数，后台定时刷）
 *   ★ 重入保护
 *   ★ 只对"完全相等的 key"动手，其余原样放行
 *   ★ 只改这两个键的 value，其余字段一字不动
 *
 * 产出（Documents/）：
 *   fdm3.log             事件日志
 *   fdm3-images.txt      注入状态（★ 验证 Choicy）
 *   fdm3-blob-orig.bin   原始 blob
 *   fdm3-blob-mod.bin    改造后的 blob（★ 我们要投出去的东西）
 *   fdm3-hits.txt        命中统计
 * ============================================================ */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <mach-o/dyld.h>

#define BLOB_KEY  "app.ab.serverValues"

/* ---------------- 路径 & 日志 ---------------- */

static NSString *gDir = nil;
static NSString *P(NSString *n) { return [gDir stringByAppendingPathComponent:n]; }

static NSMutableArray<NSString *> *gBuf = nil;
static NSLock *gBufLock = nil;

static void Q(NSString *fmt, ...) {           /* 只进内存缓冲，不做 IO */
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        @try { [gBufLock lock]; if (gBuf.count < 20000) [gBuf addObject:s]; [gBufLock unlock]; }
        @catch (NSException *e) {}
    }
}
static void L(NSString *fmt, ...) {            /* 立即写（只在非 Hook 上下文用） */
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSLog(@"[FDM3] %@", s);
        @try {
            NSString *line = [NSString stringWithFormat:@"%@  %@\n", [NSDate date], s];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:P(@"fdm3.log")];
            if (!fh) {
                [[NSFileManager defaultManager] createFileAtPath:P(@"fdm3.log") contents:nil attributes:NULL];
                fh = [NSFileHandle fileHandleForWritingAtPath:P(@"fdm3.log")];
            }
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    }
}
static void FlushBuf(void) {                   /* 后台线程调用 */
    @autoreleasepool {
        NSArray *snap = nil;
        [gBufLock lock];
        if (gBuf.count) { snap = [gBuf copy]; [gBuf removeAllObjects]; }
        [gBufLock unlock];
        if (!snap.count) return;
        NSMutableString *m = [NSMutableString string];
        for (NSString *l in snap) [m appendFormat:@"%@  %@\n", [NSDate date], l];
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:P(@"fdm3.log")];
            if (!fh) {
                [[NSFileManager defaultManager] createFileAtPath:P(@"fdm3.log") contents:nil attributes:NULL];
                fh = [NSFileHandle fileHandleForWritingAtPath:P(@"fdm3.log")];
            }
            [fh seekToEndOfFile];
            [fh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    }
}
static void W(NSString *n, NSData *d) {
    @try { if (d) [d writeToFile:P(n) atomically:YES]; } @catch (NSException *e) {}
}

/* ---------------- 覆盖表 ---------------- */

static NSDictionary *gPatch = nil;      /* 要改的项：key -> 新 value（JSON 对象） */
static NSData *gModified = nil;         /* 最近一次改造结果（缓存） */
static NSData *gLastOrig = nil;         /* 对应的原始输入（用于判断是否需要重打） */
static NSUInteger gNWrite = 0, gNRead = 0, gNPatchOK = 0, gNPatchFail = 0;
static __thread int gDepth = 0;

static NSDictionary *DefaultPatch(void) {
    /* 可见验证标志：两个都改，提高命中率 */
    return @{
        @"deep_think_button_suffix"          : @"·FDM",
        @"show_new_chat_button_above_input"  : @YES,
    };
}

static void LoadPatch(void) {
    @autoreleasepool {
        NSString *cfg = P(@"fdm-override.json");
        NSData *d = [NSData dataWithContentsOfFile:cfg];
        if (d) {
            id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([j isKindOfClass:[NSDictionary class]]) {
                gPatch = j;
                L(@"已加载自定义覆盖表 fdm-override.json（%lu 项）", (unsigned long)gPatch.count);
                return;
            }
            L(@"fdm-override.json 解析失败，用默认表");
        }
        gPatch = DefaultPatch();
        L(@"使用默认覆盖表（%lu 项）", (unsigned long)gPatch.count);
    }
}

/* ---------------- blob 改造 ----------------
 * 原始 blob 是「双层 JSON」：
 *   外层 = 一个 JSON 字符串字面量：  "{\"version\":93,...}"
 *   内层 = 真正的设置对象：          {"version":93,"settings":{...}}
 */

static NSData *PatchBlob(NSData *orig) {
    @autoreleasepool {
        if (!orig || orig.length < 16) return nil;
        @try {
            NSString *outer = [[NSString alloc] initWithData:orig encoding:NSUTF8StringEncoding];
            if (!outer) return nil;

            /* ① 解外层 */
            NSString *inner = nil;
            id step1 = [NSJSONSerialization JSONObjectWithData:[outer dataUsingEncoding:NSUTF8StringEncoding]
                                                       options:NSJSONReadingAllowFragments error:nil];
            if ([step1 isKindOfClass:[NSString class]]) {
                inner = step1;                      /* 典型：外层是字符串字面量 */
            } else if ([step1 isKindOfClass:[NSDictionary class]]) {
                inner = outer;                      /* 已经是对象文本，直接用 */
            } else {
                return nil;
            }

            /* ② 解内层 */
            id obj = [NSJSONSerialization JSONObjectWithData:[inner dataUsingEncoding:NSUTF8StringEncoding]
                                                     options:NSJSONReadingMutableContainers error:nil];
            if (![obj isKindOfClass:[NSDictionary class]]) return nil;

            NSMutableDictionary *root = obj;
            NSMutableDictionary *settings = root[@"settings"];
            if (![settings isKindOfClass:[NSDictionary class]]) return nil;

            /* ③ 打补丁 */
            NSUInteger okc = 0, failc = 0;
            for (NSString *k in gPatch) {
                id cur = settings[k];
                if ([cur isKindOfClass:[NSDictionary class]]) {
                    NSMutableDictionary *mm = [cur mutableCopy];
                    mm[@"value"] = gPatch[k];
                    settings[k] = mm;
                    okc++;
                } else {
                    failc++;
                }
            }
            root[@"settings"] = settings;
            gNPatchOK = okc; gNPatchFail = failc;

            /* ④ 重新编码（保持双层结构） */
            NSData *innerOut = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
            NSString *innerStr = [[NSString alloc] initWithData:innerOut encoding:NSUTF8StringEncoding];
            NSData *wrapped = [NSJSONSerialization dataWithJSONObject:innerStr
                                                              options:NSJSONWritingFragmentsAllowed
                                                                error:nil];
            return wrapped;
        } @catch (NSException *e) {
            return nil;
        }
    }
}

static BOOL IsBlobKey(id key) {
    if (!key) return NO;
    if (![key isKindOfClass:[NSString class]]) return NO;
    const char *c = ((NSString *)key).UTF8String;
    return c && strcmp(c, BLOB_KEY) == 0;
}

/* ---------------- MMKV 打桩 ---------------- */

static IMP o_setObject = NULL, o_setData = NULL;
static IMP o_objForKey = NULL, o_dataForKey = NULL;

/* 每次写入都确保补丁是最新的（blob 可能随登录/刷新而变化） */
static NSData *EnsurePatched(NSData *orig) {
    if (!orig) return nil;
    if (gLastOrig && gModified && [gLastOrig isEqualToData:orig]) return gModified;
    NSData *m = PatchBlob(orig);
    if (m) {
        gLastOrig = [orig copy];
        gModified = m;
        W(@"fdm3-blob-orig.bin", orig);
        W(@"fdm3-blob-mod.bin", m);
        Q(@"PATCH 原 %lu B → 改后 %lu B（patched %lu / failed %lu）",
          (unsigned long)orig.length, (unsigned long)m.length,
          (unsigned long)gNPatchOK, (unsigned long)gNPatchFail);
    }
    return m;
}

/* 写：应用写 serverValues 时，把值换成我们改过的 */
static void my_setData(id self, SEL _cmd, id val, id key) {
    if (gDepth == 0 && IsBlobKey(key) && [val isKindOfClass:[NSData class]]) {
        gDepth++;
        gNWrite++;
        NSData *mod = EnsurePatched((NSData *)val);
        gDepth--;
        if (mod && o_setData) {
            ((void(*)(id,SEL,id,id))o_setData)(self, _cmd, mod, key);
            return;
        }
    }
    if (o_setData) ((void(*)(id,SEL,id,id))o_setData)(self, _cmd, val, key);
}

static void my_setObject(id self, SEL _cmd, id val, id key) {
    if (gDepth == 0 && IsBlobKey(key)) {
        gDepth++;
        gNWrite++;
        NSData *mod = [val isKindOfClass:[NSData class]] ? EnsurePatched((NSData *)val) : nil;
        gDepth--;
        if (mod) {
            ((void(*)(id,SEL,id,id))o_setObject)(self, _cmd, mod, key);
            return;
        }
    }
    if (o_setObject) ((void(*)(id,SEL,id,id))o_setObject)(self, _cmd, val, key);
}

/* 读：应用读 serverValues 时，给改过的版本 */
static id my_dataForKey(id self, SEL _cmd, id key) {
    if (gDepth == 0 && IsBlobKey(key) && gModified) {
        gDepth++; gNRead++; gDepth--;
        return gModified;
    }
    return o_dataForKey ? ((id(*)(id,SEL,id))o_dataForKey)(self, _cmd, key) : nil;
}
static id my_objForKey(id self, SEL _cmd, id key) {
    if (gDepth == 0 && IsBlobKey(key) && gModified) {
        gDepth++; gNRead++; gDepth--;
        return gModified;
    }
    return o_objForKey ? ((id(*)(id,SEL,id))o_objForKey)(self, _cmd, key) : nil;
}

static IMP SwapInst(Class C, const char *sel, IMP imp) {
    if (!C) return NULL;
    @try {
        Method m = class_getInstanceMethod(C, sel_registerName(sel));
        if (!m) return NULL;
        IMP old = method_getImplementation(m);
        method_setImplementation(m, imp);
        return old;
    } @catch (NSException *e) { return NULL; }
}

static BOOL HookMMKV(void) {
    Class C = objc_getClass("MMKV");
    if (!C) { L(@"!! MMKV 类未加载"); return NO; }
    o_setData    = SwapInst(C, "setData:forKey:",   (IMP)my_setData);
    o_setObject  = SwapInst(C, "setObject:forKey:", (IMP)my_setObject);
    o_dataForKey = SwapInst(C, "dataForKey:",       (IMP)my_dataForKey);
    o_objForKey  = SwapInst(C, "objectForKey:",     (IMP)my_objForKey);
    L(@"MMKV 已挂钩：setData=%p setObject=%p dataForKey=%p objectForKey=%p",
      o_setData, o_setObject, o_dataForKey, o_objForKey);
    return (o_setData || o_setObject);
}

/* ---------------- 注入状态（验证 Choicy） ---------------- */

static void DumpImages(void) {
    @autoreleasepool {
        NSMutableString *o = [NSMutableString string];
        int n = _dyld_image_count();
        [o appendFormat:@"# 已加载镜像 %d 个  %@\n", n, [NSDate date]];
        int tInject = 0, ellekit = 0, ours = 0;
        [o appendString:@"\n## 越狱/注入 相关：\n"];
        for (int i = 0; i < n; i++) {
            const char *nm = _dyld_get_image_name(i);
            if (!nm) continue;
            if (strstr(nm, "TweakInject")) { tInject++; [o appendFormat:@"  TweakInject  %s\n", nm]; }
            else if (strstr(nm, "libellekit")) { ellekit++; [o appendFormat:@"  ellekit      %s\n", nm]; }
            else if (strstr(nm, "FDMProbe")) { ours++; [o appendFormat:@"  ★我们        %s\n", nm]; }
            else if (strstr(nm, "Substrate") || strstr(nm, "substitute") ||
                     strstr(nm, "libhooker") || strstr(nm, "frida") || strstr(nm, "Cycript"))
                [o appendFormat:@"  其它         %s\n", nm];
        }
        [o appendFormat:@"\n## 统计：TweakInject=%d  ellekit=%d  我们=%d\n", tInject, ellekit, ours];
        if (tInject == 0 && ellekit == 0) [o appendString:@"\n✅ Choicy 生效：进程里没有 ElleKit 注入\n"];
        else [o appendString:@"\n⚠️ 仍有 ElleKit 注入（Choicy 未生效或未覆盖本 App）\n"];
        W(@"fdm3-images.txt", [o dataUsingEncoding:NSUTF8StringEncoding]);
        L(@"注入状态：TweakInject=%d ellekit=%d 我们=%d", tInject, ellekit, ours);
    }
}

/* ---------------- 只读诊断（哪种取值方式有效） ---------------- */

static void Diagnose(void) {
    @autoreleasepool {
        id inst = nil;
        Class C = objc_getClass("MMKV");
        if (!C) return;
        Method m = class_getClassMethod(C, sel_registerName("defaultMMKV"));
        if (!m) return;
        inst = ((id(*)(id,SEL))method_getImplementation(m))((id)C, sel_registerName("defaultMMKV"));
        if (!inst) { L(@"诊断：拿不到 defaultMMKV"); return; }

        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"# 取值方式诊断 %@\n", [NSDate date]];
        SEL ak = sel_registerName("allKeys");
        Method am = class_getInstanceMethod([inst class], ak);
        if (!am) { W(@"fdm3-diag.txt", [o dataUsingEncoding:NSUTF8StringEncoding]); return; }
        NSArray *keys = ((id(*)(id,SEL))method_getImplementation(am))(inst, ak);
        [o appendFormat:@"# %lu 个键\n\n", (unsigned long)keys.count];

        const char *sels[] = {"objectForKey:", "dataForKey:", "stringForKey:", "boolForKey:", NULL};
        for (id k in keys) {
            [o appendFormat:@"%@\n", k];
            for (int i = 0; sels[i]; i++) {
                Method mm = class_getInstanceMethod([inst class], sel_registerName(sels[i]));
                if (!mm) { [o appendFormat:@"   %-16s (无此方法)\n", sels[i]]; continue; }
                id r = nil;
                @try { r = ((id(*)(id,SEL,id))method_getImplementation(mm))(inst, sel_registerName(sels[i]), k); }
                @catch (NSException *e) {}
                NSString *rs;
                if (!r) rs = @"(nil)";
                else if ([r isKindOfClass:[NSData class]])
                    rs = [NSString stringWithFormat:@"<NSData %lu B>", (unsigned long)[(NSData*)r length]];
                else if ([r isKindOfClass:[NSString class]]) {
                    NSString *t = r;
                    rs = [NSString stringWithFormat:@"\"%@\"", t.length > 60 ? [t substringToIndex:60] : t];
                } else rs = [NSString stringWithFormat:@"<%@ %@>", [r class], r];
                [o appendFormat:@"   %-16s = %@\n", sels[i], rs];
            }
        }
        W(@"fdm3-diag.txt", [o dataUsingEncoding:NSUTF8StringEncoding]);
        L(@"取值诊断完成 → fdm3-diag.txt");
    }
}

static void DumpHits(void) {
    @autoreleasepool {
        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"# 命中统计 %@\n", [NSDate date]];
        [o appendFormat:@"写 serverValues 次数 : %lu\n", (unsigned long)gNWrite];
        [o appendFormat:@"读 serverValues 次数 : %lu\n", (unsigned long)gNRead];
        [o appendFormat:@"blob 已改造        : %@\n", gModified ? @"是" : @"否"];
        [o appendFormat:@"patch 命中/失败    : %lu / %lu\n", (unsigned long)gNPatchOK, (unsigned long)gNPatchFail];
        [o appendFormat:@"覆盖表             : %@\n", gPatch];
        W(@"fdm3-hits.txt", [o dataUsingEncoding:NSUTF8StringEncoding]);
    }
}

/* ---------------- 入口 ---------------- */

__attribute__((constructor))
static void fdm5_init(void) {
    @autoreleasepool {
        NSArray *ds = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        gDir = [ds firstObject] ?: NSTemporaryDirectory();
        gBufLock = [NSLock new];
        gBuf = [NSMutableArray array];

        L(@"==================================================");
        L(@"FDM v0.5（覆盖实验版）已加载  pid=%d  build=%s %s",
          (int)getpid(), __DATE__, __TIME__);
        L(@"Documents=%@", gDir);

        LoadPatch();

        /* 每 2 秒刷缓冲 */
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 2ull*NSEC_PER_SEC),
                                  2ull*NSEC_PER_SEC, 1ull*NSEC_PER_SEC);
        dispatch_source_set_event_handler(t, ^{ FlushBuf(); });
        dispatch_resume(t);

        /* 立刻挂钩（早于一切业务） */
        HookMMKV();

        /* 3 秒后补挂 + 注入状态 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool { HookMMKV(); DumpImages(); }
        });

        /* 12 秒后诊断取值方式 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12*NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            Diagnose();
        });

        /* 40 / 80 秒记两次命中 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40*NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            DumpHits(); L(@"40s 小结：写 %lu / 读 %lu / 改造 %@",
                          (unsigned long)gNWrite, (unsigned long)gNRead, gModified ? @"成功" : @"未触发");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80*NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            DumpHits(); FlushBuf(); L(@"=== v0.5 结束 ===");
        });
    }
}
