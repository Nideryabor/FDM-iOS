// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用

/* ============================================================
 * FDM 探针 v0.3 —— 修 v0.2 崩溃 + 深挖
 *
 * v0.2 崩溃复盘：
 *   1) my_* 里调 MMKVID(self) → [self mmapID]（宿主方法），在 MMKV 锁内又碰 MMKV
 *   2) mmkvWithID: 被调 11961 次，每次同步写文件 + NSLog → 主线程卡死 / 看门狗
 *   3) mmkvWithID: 无去重，登录后按用户 UUID 疯狂创建 → 日志雪崩
 *
 * v0.3 铁律：
 *   ★ Hook 内绝不调用任何宿主方法（只用参数指针 / 指针地址）
 *   ★ Hook 内绝不做文件 IO（只 append 到内存缓冲）
 *   ★ __thread 重入保护 + 同一实例 ID 只记一次
 *   ★ 重活（类 dump / KV dump）全部放后台队列，延迟执行
 *
 * 产出（App 沙盒 Documents/）：
 *   fdm-probe.log    精简事件日志（去重后）
 *   fdm-kv.txt       主动 dump 的 key → value 全表
 *   fdm-blob.bin     app.ab.serverValues 原始内容（服务端下发设置 blob）
 *   fdm-classes.txt  宿主相关类的方法 / ivar
 * ============================================================ */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <stdarg.h>
#import <unistd.h>
#import <mach-o/dyld.h>

/* ==================== 路径 ==================== */

static NSString *gDir = nil;
static NSString *PathOf(NSString *name) { return [gDir stringByAppendingPathComponent:name]; }

/* ==================== 重入保护 ==================== */

static __thread int gDepth = 0;

/* ==================== 日志缓冲（Hook 内只 append） ==================== */

static NSMutableArray<NSString *> *gBuf = nil;
static NSLock *gBufLock = nil;
static NSUInteger gDropped = 0;
#define BUF_MAX 4000

static void FLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSLog(@"[FDM] %@", s);
        if (!gBuf) return;
        [gBufLock lock];
        if (gBuf.count < BUF_MAX) [gBuf addObject:s]; else gDropped++;
        [gBufLock unlock];
    }
}

/* 刷盘（只在后台线程调用） */
static void FlushLog(void) {
    @autoreleasepool {
        NSArray *snap = nil;
        [gBufLock lock];
        if (gBuf.count) { snap = [gBuf copy]; [gBuf removeAllObjects]; }
        [gBufLock unlock];
        if (!snap.count) return;
        NSMutableString *m = [NSMutableString stringWithCapacity:snap.count * 80];
        for (NSString *l in snap) [m appendFormat:@"%@\n", l];
        if (gDropped) { [m appendFormat:@"[FDM] （缓冲溢出丢弃 %lu 行）\n", (unsigned long)gDropped]; gDropped = 0; }
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:PathOf(@"fdm-probe.log")];
            if (!fh) {
                [[NSFileManager defaultManager] createFileAtPath:PathOf(@"fdm-probe.log") contents:nil attributes:nil];
                fh = [NSFileHandle fileHandleForWritingAtPath:PathOf(@"fdm-probe.log")];
            }
            [fh seekToEndOfFile];
            [fh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    }
}

/* 定时常驻刷盘：每 2 秒一次，永不阻塞调用线程 */
static void StartFlusher(void) {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              (uint64_t)(2 * NSEC_PER_SEC), (uint64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{ FlushLog(); });
    dispatch_resume(t);
}

/* ==================== 安全取值（不碰宿主方法） ==================== */

/* 只处理「确定安全」的类；其余一律用指针地址，绝不调 -description */
static NSString *SafeStr(id v) {
    if (v == nil) return @"(nil)";
    @try {
        if ([v isKindOfClass:[NSString class]]) {
            NSString *t = (NSString *)v;
            return t.length > 600 ? [[t substringToIndex:600] stringByAppendingString:@"…"] : t;
        }
        if ([v isKindOfClass:objc_getClass("__NSCFNumber")] ||
            [v isKindOfClass:[NSNumber class]])
            return [(NSNumber *)v stringValue];
        if ([v isKindOfClass:[NSData class]]) {
            NSData *d = (NSData *)v;
            NSUInteger n = MIN(d.length, 64);
            NSMutableString *h = [NSMutableString string];
            const uint8_t *b = d.bytes;
            for (NSUInteger i = 0; i < n; i++) [h appendFormat:@"%02x", b[i]];
            return [NSString stringWithFormat:@"<NSData %luB hex=%@%@>",
                    (unsigned long)d.length, h,
                    d.length > 64 ? @"…" : @""];
        }
        if ([v isKindOfClass:[NSArray class]])
            return [NSString stringWithFormat:@"<NSArray %lu>", (unsigned long)[(NSArray *)v count]];
        if ([v isKindOfClass:[NSDictionary class]])
            return [NSString stringWithFormat:@"<NSDictionary %lu>", (unsigned long)[(NSDictionary *)v count]];
        return [NSString stringWithFormat:@"<%s %p>", class_getName(object_getClass(v)), v];
    } @catch (NSException *e) { return @"(err)"; }
}

/* ==================== ① MMKV （只 hook 读写，不 hook 实例创建） ==================== */

static IMP o_setObject = NULL, o_setString = NULL, o_setData = NULL;
static IMP o_setBool = NULL, o_setInt64 = NULL, o_setDouble = NULL, o_setFloat = NULL;
static IMP o_objForKey = NULL, o_strForKey = NULL, o_dataForKey = NULL;
static IMP o_boolForKey = NULL, o_int64ForKey = NULL, o_dblForKey = NULL;
static IMP o_containsKey = NULL, o_removeKeys = NULL;

/* 用于 dump blob：捕获最近一次写入 serverValues 的 NSData */
static NSData *gServerValues = nil;

/* 收集真实用过的 MMKV 实例 ID（去重 → 11961 次调用只记 1 条日志） */
static NSMutableSet<NSString *> *gSeenIDs = nil;
static NSLock *gSeenLock = nil;
static IMP o_mmkvWithID = NULL;

static id my_mmkvWithID(id self, SEL _cmd, id mid) {
    /* 在进 MMKV 内部锁之前做记录，只处理 NSString，绝不解引用其它类型 */
    if (gSeenIDs && [mid isKindOfClass:[NSString class]]) {
        @try {
            NSString *n = (NSString *)mid;
            BOOL isNew = NO;
            [gSeenLock lock];
            if (![gSeenIDs containsObject:n]) { [gSeenIDs addObject:n]; isNew = YES; }
            [gSeenLock unlock];
            if (isNew) FLog(@"NEW mmkvWithID: %@  （总数 %lu）", n, (unsigned long)gSeenIDs.count);
        } @catch (NSException *e) {}
    }
    return o_mmkvWithID ? ((id(*)(id,SEL,id))o_mmkvWithID)(self, _cmd, mid) : nil;
}

static BOOL HotKey(NSString *k) {
    if (!k) return NO;
    const char *c = k.UTF8String;
    return strstr(c, "app.") || strstr(c, "privacy") || strstr(c, "serverValues") ||
           strstr(c, "kv_") || strstr(c, "prompt") || strstr(c, "voice") ||
           strstr(c, "welcome") || strstr(c, "model") || strstr(c, "think");
}

/* 记录 serverValues blob：抓第一次，并立刻异步落盘（hook 内不做 IO） */
static void CaptureBlob(id val, NSString *key) {
    if (![key isEqualToString:@"app.ab.serverValues"]) return;
    if (![val isKindOfClass:[NSData class]]) return;
    if (gServerValues) return;              /* 只抓第一次 */
    @try {
        gServerValues = [val copy];
        NSData *snap = gServerValues;
        NSUInteger len = snap.length;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                @try {
                    [snap writeToFile:PathOf(@"fdm-blob.bin") atomically:YES];
                    FLog(@"★ blob 落盘 fdm-blob.bin（%lu B）", (unsigned long)len);
                } @catch (NSException *e) {}
            }
        });
    } @catch (NSException *e) {}
}

static void my_setObject(id self, SEL _cmd, id val, id key) {
    if (gDepth == 0) {
        gDepth++;
        NSString *k = SafeStr(key);
        if (HotKey(k)) {
            FLog(@"W %@ = %@", k, SafeStr(val));
            CaptureBlob(val, k);
        }
        gDepth--;
    }
    if (o_setObject) ((void(*)(id,SEL,id,id))o_setObject)(self, _cmd, val, key);
}
static void my_setString(id self, SEL _cmd, id val, id key) {
    if (gDepth == 0) { gDepth++; NSString *k = SafeStr(key);
        if (HotKey(k)) FLog(@"W(str) %@ = %@", k, SafeStr(val)); gDepth--; }
    if (o_setString) ((void(*)(id,SEL,id,id))o_setString)(self, _cmd, val, key);
}
static void my_setData(id self, SEL _cmd, id val, id key) {
    if (gDepth == 0) { gDepth++; NSString *k = SafeStr(key);
        if (HotKey(k)) { FLog(@"W(data) %@ = %@", k, SafeStr(val)); CaptureBlob(val, k); } gDepth--; }
    if (o_setData) ((void(*)(id,SEL,id,id))o_setData)(self, _cmd, val, key);
}
static void my_setBool(id self, SEL _cmd, BOOL v, id key) {
    if (gDepth == 0) { gDepth++; NSString *k = SafeStr(key);
        if (HotKey(k)) FLog(@"W(bool) %@ = %d", k, (int)v); gDepth--; }
    if (o_setBool) ((void(*)(id,SEL,BOOL,id))o_setBool)(self, _cmd, v, key);
}
static void my_setInt64(id self, SEL _cmd, long long v, id key) {
    if (gDepth == 0) { gDepth++; NSString *k = SafeStr(key);
        if (HotKey(k)) FLog(@"W(i64) %@ = %lld", k, v); gDepth--; }
    if (o_setInt64) ((void(*)(id,SEL,long long,id))o_setInt64)(self, _cmd, v, key);
}
static void my_setDouble(id self, SEL _cmd, double v, id key) {
    if (gDepth == 0) { gDepth++; NSString *k = SafeStr(key);
        if (HotKey(k)) FLog(@"W(dbl) %@ = %f", k, v); gDepth--; }
    if (o_setDouble) ((void(*)(id,SEL,double,id))o_setDouble)(self, _cmd, v, key);
}
static void my_setFloat(id self, SEL _cmd, float v, id key) {
    if (gDepth == 0) { gDepth++; NSString *k = SafeStr(key);
        if (HotKey(k)) FLog(@"W(flt) %@ = %f", k, v); gDepth--; }
    if (o_setFloat) ((void(*)(id,SEL,float,id))o_setFloat)(self, _cmd, v, key);
}

static id my_objForKey(id self, SEL _cmd, id key) {
    id r = o_objForKey ? ((id(*)(id,SEL,id))o_objForKey)(self, _cmd, key) : nil;
    if (gDepth == 0) { gDepth++; NSString *k = SafeStr(key);
        if (HotKey(k)) FLog(@"R %@ = %@", k, SafeStr(r)); gDepth--; }
    return r;
}
static id my_strForKey(id self, SEL _cmd, id key) {
    id r = o_strForKey ? ((id(*)(id,SEL,id))o_strForKey)(self, _cmd, key) : nil;
    if (gDepth == 0) { gDepth++; NSString *k = SafeStr(key);
        if (HotKey(k)) FLog(@"R(str) %@ = %@", k, SafeStr(r)); gDepth--; }
    return r;
}
static id my_dataForKey(id self, SEL _cmd, id key) {
    id r = o_dataForKey ? ((id(*)(id,SEL,id))o_dataForKey)(self, _cmd, key) : nil;
    if (gDepth == 0) { gDepth++; NSString *k = SafeStr(key);
        if (HotKey(k)) { FLog(@"R(data) %@ = %@", k, SafeStr(r)); CaptureBlob(r, k); } gDepth--; }
    return r;
}
static BOOL my_boolForKey(id self, SEL _cmd, id key) {
    BOOL r = o_boolForKey ? ((BOOL(*)(id,SEL,id))o_boolForKey)(self, _cmd, key) : NO;
    if (gDepth == 0) { gDepth++; NSString *k = SafeStr(key);
        if (HotKey(k)) FLog(@"R(bool) %@ = %d", k, (int)r); gDepth--; }
    return r;
}
static long long my_i64ForKey(id self, SEL _cmd, id key) {
    long long r = o_int64ForKey ? ((long long(*)(id,SEL,id))o_int64ForKey)(self, _cmd, key) : 0;
    if (gDepth == 0) { gDepth++; NSString *k = SafeStr(key);
        if (HotKey(k)) FLog(@"R(i64) %@ = %lld", k, r); gDepth--; }
    return r;
}
static double my_dblForKey(id self, SEL _cmd, id key) {
    double r = o_dblForKey ? ((double(*)(id,SEL,id))o_dblForKey)(self, _cmd, key) : 0;
    if (gDepth == 0) { gDepth++; NSString *k = SafeStr(key);
        if (HotKey(k)) FLog(@"R(dbl) %@ = %f", k, r); gDepth--; }
    return r;
}
static BOOL my_containsKey(id self, SEL _cmd, id key) {
    BOOL r = o_containsKey ? ((BOOL(*)(id,SEL,id))o_containsKey)(self, _cmd, key) : NO;
    if (gDepth == 0) { gDepth++; NSString *k = SafeStr(key);
        if (HotKey(k)) FLog(@"C %@ = %d", k, (int)r); gDepth--; }
    return r;
}
static void my_removeKeys(id self, SEL _cmd, id keys) {
    if (gDepth == 0) { gDepth++; FLog(@"DEL %@", SafeStr(keys)); gDepth--; }
    if (o_removeKeys) ((void(*)(id,SEL,id))o_removeKeys)(self, _cmd, keys);
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

static IMP SwapCls(Class C, const char *sel, IMP imp) {
    if (!C) return NULL;
    @try {
        Method m = class_getClassMethod(C, sel_registerName(sel));
        if (!m) return NULL;
        IMP old = method_getImplementation(m);
        method_setImplementation(m, imp);
        return old;
    } @catch (NSException *e) { return NULL; }
}

static void HookMMKV(void) {
    Class C = objc_getClass("MMKV");
    if (!C) { FLog(@"!! MMKV 类不存在（可能还没加载）"); return; }

    o_setObject  = SwapInst(C, "setObject:forKey:",  (IMP)my_setObject);
    o_setString  = SwapInst(C, "setString:forKey:",  (IMP)my_setString);
    o_setData    = SwapInst(C, "setData:forKey:",    (IMP)my_setData);
    o_setBool    = SwapInst(C, "setBool:forKey:",    (IMP)my_setBool);
    o_setInt64   = SwapInst(C, "setInt64:forKey:",   (IMP)my_setInt64);
    o_setDouble  = SwapInst(C, "setDouble:forKey:",  (IMP)my_setDouble);
    o_setFloat   = SwapInst(C, "setFloat:forKey:",   (IMP)my_setFloat);
    o_objForKey  = SwapInst(C, "objectForKey:",      (IMP)my_objForKey);
    o_strForKey  = SwapInst(C, "stringForKey:",      (IMP)my_strForKey);
    o_dataForKey = SwapInst(C, "dataForKey:",        (IMP)my_dataForKey);
    o_boolForKey = SwapInst(C, "boolForKey:",        (IMP)my_boolForKey);
    o_int64ForKey= SwapInst(C, "int64ForKey:",       (IMP)my_i64ForKey);
    o_dblForKey  = SwapInst(C, "doubleForKey:",      (IMP)my_dblForKey);
    o_containsKey= SwapInst(C, "containsKey:",       (IMP)my_containsKey);
    o_removeKeys = SwapInst(C, "removeValuesForKeys:", (IMP)my_removeKeys);

    /* 实例创建：只去重收集 ID（不加其它开销），用于后续精准 dump */
    if (!o_mmkvWithID) o_mmkvWithID = SwapCls(C, "mmkvWithID:", (IMP)my_mmkvWithID);

    FLog(@"MMKV 挂钩完成 setObject=%p dataForKey=%p mmkvWithID=%p", o_setObject, o_dataForKey, o_mmkvWithID);
}

/* ==================== ② NSUserDefaults（只 hook 写） ==================== */

static IMP o_ud_setObj = NULL, o_ud_setBool = NULL, o_ud_setInt = NULL;

static BOOL UDHot(NSString *k) {
    if (!k) return NO;
    const char *c = k.UTF8String;
    return strstr(c, "app.") || strstr(c, "setting") || strstr(c, "prompt") ||
           strstr(c, "mmkv") || strstr(c, "deepseek");
}
static void my_ud_setObj(id self, SEL _cmd, id v, id k) {
    if (gDepth == 0) { gDepth++; NSString *ks = SafeStr(k);
        if (UDHot(ks)) FLog(@"UD W %@ = %@", ks, SafeStr(v)); gDepth--; }
    if (o_ud_setObj) ((void(*)(id,SEL,id,id))o_ud_setObj)(self, _cmd, v, k);
}
static void my_ud_setBool(id self, SEL _cmd, BOOL v, id k) {
    if (gDepth == 0) { gDepth++; NSString *ks = SafeStr(k);
        if (UDHot(ks)) FLog(@"UD W(bool) %@ = %d", ks, (int)v); gDepth--; }
    if (o_ud_setBool) ((void(*)(id,SEL,BOOL,id))o_ud_setBool)(self, _cmd, v, k);
}
static void my_ud_setInt(id self, SEL _cmd, NSInteger v, id k) {
    if (gDepth == 0) { gDepth++; NSString *ks = SafeStr(k);
        if (UDHot(ks)) FLog(@"UD W(int) %@ = %ld", ks, (long)v); gDepth--; }
    if (o_ud_setInt) ((void(*)(id,SEL,NSInteger,id))o_ud_setInt)(self, _cmd, v, k);
}
static void HookUD(void) {
    Class C = objc_getClass("NSUserDefaults");
    if (!C) return;
    o_ud_setObj  = SwapInst(C, "setObject:forKey:",  (IMP)my_ud_setObj);
    o_ud_setBool = SwapInst(C, "setBool:forKey:",    (IMP)my_ud_setBool);
    o_ud_setInt  = SwapInst(C, "setInteger:forKey:", (IMP)my_ud_setInt);
    FLog(@"NSUserDefaults 挂钩完成");
}

/* ==================== ③ 主动 dump（全在后台队列） ==================== */

static void WriteFile(NSString *name, NSData *data) {
    @try { [data writeToFile:PathOf(name) atomically:YES]; }
    @catch (NSException *e) { FLog(@"写 %@ 失败: %@", name, e.reason); }
}

/* 枚举一个 MMKV 实例的全部键值 */
static void DumpOneMMKV(id inst, NSString *label, NSMutableString *out) {
    if (!inst) { [out appendFormat:@"\n===== %@ : 实例为空 =====\n", label]; return; }
    @try {
        SEL ak = sel_registerName("allKeys");
        SEL ok = sel_registerName("objectForKey:");

        /* 稳健取 IMP：实例可能不是 MMKV（防御经典方法指针为空） */
        IMP akm = NULL, okm = NULL;
        Method m1 = class_getInstanceMethod([inst class], ak);
        if (m1) akm = method_getImplementation(m1);
        Method m2 = class_getInstanceMethod([inst class], ok);
        if (m2) okm = method_getImplementation(m2);
        if (!akm) { [out appendFormat:@"\n===== %@ : 无 allKeys（非 MMKV？） =====\n", label]; return; }

        NSArray *keys = ((id(*)(id,SEL))akm)(inst, ak);
        [out appendFormat:@"\n===== %@ : %lu 个键 =====\n", label, (unsigned long)keys.count];
        NSUInteger i = 0;
        for (id k in keys) {
            if (i++ > 2000) { [out appendString:@"  ...（截断）\n"]; break; }
            id v = nil;
            if (okm) @try { v = ((id(*)(id,SEL,id))okm)(inst, ok, k); } @catch (NSException *e) {}
            [out appendFormat:@"  %@ = %@\n", SafeStr(k), SafeStr(v)];
        }
    } @catch (NSException *e) {
        [out appendFormat:@"\n===== %@ : dump 异常 %@ =====\n", label, e.reason];
    }
}

/* 兜底：若 hook 没抓到，主动从 mmkv.default 读一次 */
static void DumpBlob(void) {
    @autoreleasepool {
        Class C = objc_getClass("MMKV");
        id inst = nil;
        if (C) {
            Method m = class_getClassMethod(C, sel_registerName("defaultMMKV"));
            if (m) inst = ((id(*)(id,SEL))method_getImplementation(m))((id)C, sel_registerName("defaultMMKV"));
        }
        if (inst) {
            Method m2 = class_getInstanceMethod([inst class], sel_registerName("objectForKey:"));
            if (m2) {
                id v = ((id(*)(id,SEL,id))method_getImplementation(m2))(inst, sel_registerName("objectForKey:"), @"app.ab.serverValues");
                if ([v isKindOfClass:[NSData class]]) gServerValues = [v copy];
            }
        }
        if (!gServerValues) { FLog(@"未捕获到 app.ab.serverValues"); return; }
        WriteFile(@"fdm-blob.bin", gServerValues);
        FLog(@"★ blob 已写出 fdm-blob.bin（%lu B）", (unsigned long)gServerValues.length);

        /* 顺便尝试当 JSON 解析，写成可读文本 */
        @try {
            id j = [NSJSONSerialization JSONObjectWithData:gServerValues options:0 error:nil];
            if (j) {
                NSData *pretty = [NSJSONSerialization dataWithJSONObject:j
                                                                 options:NSJSONWritingPrettyPrinted
                                                                   error:nil];
                WriteFile(@"fdm-blob.json", pretty);
                FLog(@"★ blob 是 JSON，已转 fdm-blob.json");
            } else {
                WriteFile(@"fdm-blob.raw", gServerValues);
                FLog(@"★ blob 非 JSON，原文另存 fdm-blob.raw");
            }
        } @catch (NSException *e) { FLog(@"blob JSON 尝试异常: %@", e.reason); }
    }
}

/* 定时主动 dump（由调用方在后台线程执行） */
static void DumpKV(NSString *tag) {
    @autoreleasepool {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"# FDM KV dump  (%@)  %@\n", tag, [NSDate date]];
        Class C = objc_getClass("MMKV");
        if (!C) { WriteFile(@"fdm-kv.txt", [out dataUsingEncoding:NSUTF8StringEncoding]); return; }

        /* 1) defaultMMKV */
        @try {
            SEL sel = sel_registerName("defaultMMKV");
            Method m = class_getClassMethod(C, sel);
            if (m) {
                id inst = ((id(*)(id,SEL))method_getImplementation(m))((id)C, sel);
                DumpOneMMKV(inst, @"mmkv.default", out);
            }
        } @catch (NSException *e) { [out appendFormat:@"defaultMMKV 异常 %@\n", e.reason]; }

        /* 2) 真实出现过的实例 ID（由 my_mmkvWithID 收集，不主动创建新实例） */
        SEL wid = sel_registerName("mmkvWithID:");
        Method mw = class_getClassMethod(C, wid);
        NSArray *ids = nil;
        [gSeenLock lock]; ids = [gSeenIDs allObjects]; [gSeenLock unlock];
        [out appendFormat:@"\n# 收集到的 mmkvWithID 共 %lu 个\n", (unsigned long)ids.count];
        if (mw) {
            for (NSString *mid in ids) {
                if ([mid isEqualToString:@"default"]) continue;
                @try {
                    id inst = ((id(*)(id,SEL,id))method_getImplementation(mw))((id)C, wid, mid);
                    DumpOneMMKV(inst, [NSString stringWithFormat:@"mmkvWithID:%@", mid], out);
                } @catch (NSException *e) {}
            }
        }
        WriteFile(@"fdm-kv.txt", [out dataUsingEncoding:NSUTF8StringEncoding]);
        FLog(@"★ KV dump 完成 → fdm-kv.txt（%lu 字符）", (unsigned long)out.length);
    }
}

/* 类结构 dump */
static const char *kHot[] = {
    "DeepSeek_Chat", "MMKV", "KVStorage", "SettingsPoller", "SettingReader",
    "RemoteSettings", "AppSettings", "AppMMKV", "Prompt", "Persist", NULL
};
static BOOL NameHot(const char *n) {
    for (int i = 0; kHot[i]; i++) if (strstr(n, kHot[i])) return YES;
    return NO;
}
static void DumpClasses(void) {
    @autoreleasepool {
        int total = objc_getClassList(NULL, 0);
        if (total <= 0) return;
        Class *list = (Class *)malloc(sizeof(Class) * (size_t)total);
        if (!list) return;
        total = objc_getClassList(list, total);

        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"# FDM 类结构 dump  %@\n# 共 %d 个类\n", [NSDate date], total];

        for (int i = 0; i < total; i++) {
            const char *nm = class_getName(list[i]);
            if (!nm || !NameHot(nm)) continue;
            Class SCls = class_getSuperclass(list[i]);
            [out appendFormat:@"\n## %s  (super: %s)\n", nm, SCls ? class_getName(SCls) : "?"];

            unsigned int mc = 0;
            Method *ms = class_copyMethodList(list[i], &mc);
            if (ms) {
                [out appendFormat:@"   - 实例方法 [%u]:\n      ", mc];
                for (unsigned int j = 0; j < mc; j++) {
                    [out appendFormat:@"%s ", sel_getName(method_getName(ms[j]))];
                    if (j % 6 == 5) [out appendString:@"\n      "];
                }
                [out appendString:@"\n"];
                free(ms);
            }
            Method *cms = class_copyMethodList(object_getClass(list[i]), &mc);
            if (cms) {
                [out appendFormat:@"   + 类方法 [%u]:\n      ", mc];
                for (unsigned int j = 0; j < mc; j++) {
                    [out appendFormat:@"%s ", sel_getName(method_getName(cms[j]))];
                    if (j % 6 == 5) [out appendString:@"\n      "];
                }
                [out appendString:@"\n"];
                free(cms);
            }
            unsigned int ic = 0;
            Ivar *ivs = class_copyIvarList(list[i], &ic);
            if (ivs) {
                [out appendFormat:@"   ivar [%u]: ", ic];
                for (unsigned int j = 0; j < ic; j++) {
                    const char *in = ivar_getName(ivs[j]);
                    if (in) [out appendFormat:@"%s ", in];
                }
                [out appendString:@"\n"];
                free(ivs);
            }
        }
        free(list);
        WriteFile(@"fdm-classes.txt", [out dataUsingEncoding:NSUTF8StringEncoding]);
        FLog(@"★ 类结构 dump 完成 → fdm-classes.txt（%lu 字符）", (unsigned long)out.length);
    }
}

static void DumpImages(void) {
    int n = _dyld_image_count();
    FLog(@"已加载镜像 %d 个", n);
    for (int i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        if (strstr(nm, "DeepSeek") || strstr(nm, "MMKV") || strstr(nm, "WCDB") ||
            strstr(nm, "TRTC") || strstr(nm, "Rangers") || strstr(nm, "SmCaptcha"))
            FLog(@"   IMG %s", nm);
    }
}

/* ==================== 入口 ==================== */

__attribute__((constructor))
static void fdm_probe_init(void) {
    @autoreleasepool {
        gBufLock = [NSLock new];
        gBuf = [NSMutableArray array];
        gSeenLock = [NSLock new];
        gSeenIDs = [NSMutableSet set];

        NSArray *ds = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        gDir = [ds firstObject] ?: NSTemporaryDirectory();

        FLog(@"==================================================");
        FLog(@"FDM 探针 v0.3 已注入  pid=%d  build=%s %s", (int)getpid(), __DATE__, __TIME__);
        FLog(@"bundle=%@", [[NSBundle mainBundle] bundleIdentifier]);
        FLog(@"Documents=%@", gDir);

        StartFlusher();                 /* 后台每 2s 刷盘 */
        HookUD();
        HookMMKV();

        /* 3s 后：补挂 + 镜像 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool { HookMMKV(); DumpImages(); FLog(@"3s 阶段完成"); }
        });

        /* 12s 后：首个 KV dump（启动期键已落） */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            DumpKV(@"启动期");
        });

        /* 45s 后：类结构 + blob（等登录/设置拉取完成） */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool { DumpClasses(); DumpBlob(); }
        });

        /* 100s 后：再 dump 一次（登录后会有新键） */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            DumpKV(@"登录后"); FlushLog();
            FLog(@"=== 探针 v0.3 全部任务结束 ===");
        });
    }
}
