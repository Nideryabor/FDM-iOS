/* ============================================================
 * FDM 探针 v0.4 · 零 Hook 安全模式
 *
 * 为什么要做这个：
 *   v0.2 崩了（Hook 太重，已知）
 *   v0.3 修了所有已知雷，但主人说"还是崩"
 *   ⇒ 说明可能根本不是探针太重，而是「注入本身」被反作弊干掉了
 *
 * 本版本设计（极端保守）：
 *   ★ 零 Hook —— 一行 method_setImplementation 都不做
 *   ★ 只做定时轮询：像普通 App 一样调 MMKV 公开 API 读数据
 *   ★ 每一步都写「阶段标记」，万一崩了能精确定位崩在哪一步
 *   ★ 心跳日志：每 5 秒一条，证明还活着
 *
 * 判读方法：
 *   文件里有 STAGE 1..N 一步步的标记 → 看到哪一步断掉，就知道崩在哪
 *   如果连 STAGE 1 都没有 → 构造函数都没跑完（注入方式有问题）
 *   如果全部 STAGE 都跑完还没崩 → 反作弊没在管，是 v0.2/0.3 太重
 *   如果跑着跑着崩了 → 对面有反作弊（或某个 API 调用本身有问题）
 *
 * 产出（App 沙盒 Documents/）：
 *   fdm2.log        阶段标记 + 心跳
 *   fdm2-kv.txt     mmkv.default 全量键值
 *   fdm2-blob.json  app.ab.serverValues 内容
 *   fdm2-classes.txt 相关类结构
 * ============================================================ */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <stdarg.h>
#import <unistd.h>
#import <mach-o/dyld.h>

static NSString *gDir = nil;
static NSString *P(NSString *n) { return [gDir stringByAppendingPathComponent:n]; }
static NSLock *gLock = nil;
static NSMutableArray<NSString *> *gBuf = nil;

/* ---------- 日志（立即同步写，因为量极小） ---------- */
static void L(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSLog(@"[FDM2] %@", s);
        @try {
            NSString *line = [NSString stringWithFormat:@"%@  %@\n", [NSDate date], s];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:P(@"fdm2.log")];
            if (!fh) {
                [[NSFileManager defaultManager] createFileAtPath:P(@"fdm2.log") contents:nil attributes:nil];
                fh = [NSFileHandle fileHandleForWritingAtPath:P(@"fdm2.log")];
            }
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    }
}

static void W(NSString *name, NSData *d) {
    @try { [d writeToFile:P(name) atomically:YES]; } @catch (NSException *e) {}
}

/* ---------- 安全取值 ---------- */
static NSString *SS(id v) {
    if (!v) return @"(nil)";
    @try {
        if ([v isKindOfClass:[NSString class]]) {
            NSString *t = v;
            return t.length > 800 ? [[t substringToIndex:800] stringByAppendingString:@"…"] : t;
        }
        if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
        if ([v isKindOfClass:[NSData class]]) {
            NSData *d = v;
            NSUInteger n = MIN(d.length, 96);
            NSMutableString *h = [NSMutableString string];
            const uint8_t *b = d.bytes;
            for (NSUInteger i = 0; i < n; i++) [h appendFormat:@"%02x", b[i]];
            /* 顺便尝试当文本显示 */
            NSString *txt = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            return [NSString stringWithFormat:@"<NSData %luB hex=%@%@%@>",
                    (unsigned long)d.length, h, d.length > 96 ? @"…" : @"",
                    (txt && txt.length < 200) ? [NSString stringWithFormat:@" txt=%@", txt] : @""];
        }
        if ([v isKindOfClass:[NSArray class]]) {
            NSArray *a = v;
            return [NSString stringWithFormat:@"<NSArray %lu>", (unsigned long)a.count];
        }
        if ([v isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dd = v;
            NSMutableString *s = [NSMutableString stringWithFormat:@"<NSDictionary %lu>", (unsigned long)dd.count];
            if (dd.count <= 8) [s appendFormat:@" %@", dd];
            return s;
        }
        return [NSString stringWithFormat:@"<%s %p>", class_getName(object_getClass(v)), v];
    } @catch (NSException *e) { return @"(err)"; }
}

/* ---------- 取 MMKV 实例（纯公开 API） ---------- */
static id Mgr(void) {
    Class C = objc_getClass("MMKV");
    if (!C) return nil;
    @try {
        SEL s = sel_registerName("defaultMMKV");
        Method m = class_getClassMethod(C, s);
        if (!m) return nil;
        return ((id(*)(id,SEL))method_getImplementation(m))((id)C, s);
    } @catch (NSException *e) { return nil; }
}

static id KV(id inst, NSString *key) {
    if (!inst) return nil;
    @try {
        SEL s = sel_registerName("objectForKey:");
        Method m = class_getInstanceMethod([inst class], s);
        if (!m) return nil;
        return ((id(*)(id,SEL,id))method_getImplementation(m))(inst, s, key);
    } @catch (NSException *e) { return nil; }
}

/* ---------- 阶段任务 ---------- */

static void TaskKV(NSString *tag) {
    @autoreleasepool {
        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"# FDM v0.4 KV dump (%@)  %@\n", tag, [NSDate date]];

        id inst = Mgr();
        [o appendFormat:@"# defaultMMKV = %p\n", inst];
        if (!inst) { W(@"fdm2-kv.txt", [o dataUsingEncoding:NSUTF8StringEncoding]); return; }

        SEL ak = sel_registerName("allKeys");
        Method m = class_getInstanceMethod([inst class], ak);
        if (!m) { [o appendString:@"# 无 allKeys 方法\n"]; W(@"fdm2-kv.txt", [o dataUsingEncoding:NSUTF8StringEncoding]); return; }

        NSArray *keys = ((id(*)(id,SEL))method_getImplementation(m))(inst, ak);
        [o appendFormat:@"# %lu 个键\n\n", (unsigned long)keys.count];

        NSUInteger i = 0;
        for (id k in keys) {
            if (i++ > 3000) { [o appendString:@"… 截断\n"]; break; }
            id v = KV(inst, k);
            [o appendFormat:@"%@ = %@\n", SS(k), SS(v)];
        }
        W(@"fdm2-kv.txt", [o dataUsingEncoding:NSUTF8StringEncoding]);
        L(@"STAGE: KV dump(%@) 完成，%lu 键", tag, (unsigned long)keys.count);
    }
}

static void TaskBlob(void) {
    @autoreleasepool {
        id inst = Mgr();
        id v = KV(inst, @"app.ab.serverValues");
        if (!v) { L(@"STAGE: blob 未取到"); return; }
        if (![v isKindOfClass:[NSData class]]) { L(@"STAGE: blob 类型异常 %@", SS(v)); return; }
        NSData *d = v;
        W(@"fdm2-blob.bin", d);
        L(@"STAGE: blob 落盘 %lu B", (unsigned long)d.length);
        @try {
            id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if (j) {
                NSData *pp = [NSJSONSerialization dataWithJSONObject:j options:NSJSONWritingPrettyPrinted error:nil];
                W(@"fdm2-blob.json", pp);
                L(@"STAGE: blob 是 JSON → fdm2-blob.json (%lu B)", (unsigned long)pp.length);
            } else {
                NSString *t = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                if (t) { W(@"fdm2-blob.txt", [t dataUsingEncoding:NSUTF8StringEncoding]); L(@"STAGE: blob 是文本"); }
                else L(@"STAGE: blob 既非 JSON 也非文本");
            }
        } @catch (NSException *e) { L(@"STAGE: blob 解析异常 %@", e.reason); }
    }
}

static const char *HOT[] = {"DeepSeek_Chat", "MMKV", "KVStorage", "SettingsPoller",
                            "SettingReader", "RemoteSettings", "AppSettings", "AppMMKV",
                            "Prompt", "Persist", NULL};
static void TaskClasses(void) {
    @autoreleasepool {
        int tot = objc_getClassList(NULL, 0);
        if (tot <= 0) return;
        __unsafe_unretained Class *list =
            (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)tot);
        if (!list) return;
        tot = objc_getClassList(list, tot);

        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"# FDM v0.4 类结构 dump  %@\n# 全机类数 %d\n", [NSDate date], tot];
        int hit = 0;
        for (int i = 0; i < tot; i++) {
            const char *nm = class_getName(list[i]);
            if (!nm) continue;
            BOOL ok = NO;
            for (int j = 0; HOT[j]; j++) if (strstr(nm, HOT[j])) { ok = YES; break; }
            if (!ok) continue;
            hit++;
            Class sc = class_getSuperclass(list[i]);
            [o appendFormat:@"\n## %s  (super %s)\n", nm, sc ? class_getName(sc) : "?"];

            unsigned int mc = 0;
            Method *ms = class_copyMethodList(list[i], &mc);
            if (ms) {
                [o appendFormat:@"   -[%u] ", mc];
                for (unsigned int j = 0; j < mc; j++) [o appendFormat:@"%s ", sel_getName(method_getName(ms[j]))];
                [o appendString:@"\n"];
                free(ms);
            }
            Method *cs = class_copyMethodList(object_getClass(list[i]), &mc);
            if (cs) {
                [o appendFormat:@"   +[%u] ", mc];
                for (unsigned int j = 0; j < mc; j++) [o appendFormat:@"%s ", sel_getName(method_getName(cs[j]))];
                [o appendString:@"\n"];
                free(cs);
            }
            unsigned int ic = 0;
            Ivar *iv = class_copyIvarList(list[i], &ic);
            if (iv) {
                [o appendFormat:@"   ivar[%u] ", ic];
                for (unsigned int j = 0; j < ic; j++) {
                    const char *n = ivar_getName(iv[j]);
                    if (n) [o appendFormat:@"%s ", n];
                }
                [o appendString:@"\n"];
                free(iv);
            }
        }
        free(list);
        W(@"fdm2-classes.txt", [o dataUsingEncoding:NSUTF8StringEncoding]);
        L(@"STAGE: 类结构 dump 完成，命中 %d 个类", hit);
    }
}

static void TaskImages(void) {
    @autoreleasepool {
        NSMutableString *o = [NSMutableString string];
        int n = _dyld_image_count();
        [o appendFormat:@"# 已加载镜像 %d 个\n", n];
        int marked = 0;
        for (int i = 0; i < n; i++) {
            const char *nm = _dyld_get_image_name(i);
            if (!nm) continue;
            if (strstr(nm, "FDM") || strstr(nm, "ellekit") || strstr(nm, "substrate") ||
                strstr(nm, "Substitute") || strstr(nm, "libhooker") || strstr(nm, "TweakInject") ||
                strstr(nm, "MMKV") || strstr(nm, "DeepSeek") || strstr(nm, "SmCaptcha") ||
                strstr(nm, "frida") || strstr(nm, "Cycript")) {
                [o appendFormat:@"  ★ %s\n", nm];
                marked++;
            }
        }
        [o appendFormat:@"\n# 标记 %d 个\n", marked];
        W(@"fdm2-images.txt", [o dataUsingEncoding:NSUTF8StringEncoding]);
        L(@"STAGE: 镜像列表完成（%d 个，标记 %d）", n, marked);
    }
}

/* ---------- 入口 ---------- */

__attribute__((constructor))
static void fdm2_init(void) {
    @autoreleasepool {
        NSArray *ds = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        gDir = [ds firstObject] ?: NSTemporaryDirectory();
        gLock = [NSLock new];
        gBuf = [NSMutableArray array];

        L(@"============================================");
        L(@"FDM 探针 v0.4（零 Hook 安全模式）已加载");
        L(@"STAGE 0: 构造函数已进入  pid=%d", (int)getpid());
        L(@"bundle=%@", [[NSBundle mainBundle] bundleIdentifier]);
        L(@"Documents=%@", gDir);

        /* 心跳：每 5 秒 → 用于判断"活到哪一刻" */
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            __block int tick = 0;
            dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
            dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 5ull*NSEC_PER_SEC),
                                      5ull*NSEC_PER_SEC, 1ull*NSEC_PER_SEC);
            dispatch_source_set_event_handler(t, ^{
                tick++;
                [gLock lock];
                BOOL many = (gBuf.count > 0);
                [gLock unlock];
                (void)many;
                L(@"心跳 #%d（存活 %.0f 秒）", tick, tick * 5.0);
            });
            dispatch_resume(t);
        });

        /* 分阶段任务：每步都发标记，崩了就知道断在哪 */
        struct { int64_t delay; const char *name; void (^blk)(void); } steps[] = {
            {  8, "S1 镜像列表",   ^{ TaskImages(); } },
            { 15, "S2 KV dump#1",  ^{ TaskKV(@"启动期"); } },
            { 25, "S3 blob",       ^{ TaskBlob(); } },
            { 40, "S4 类结构",     ^{ TaskClasses(); } },
            { 70, "S5 KV dump#2",  ^{ TaskKV(@"登录后"); } },
            { 75, "S6 blob#2",     ^{ TaskBlob(); } },
            {100, "S7 收尾",       ^{ L(@"=== v0.4 全部任务完成 ==="); } },
        };
        int nsteps = (int)(sizeof(steps)/sizeof(steps[0]));
        for (int i = 0; i < nsteps; i++) {
            int64_t d = steps[i].delay;
            NSString *nm = [NSString stringWithUTF8String:steps[i].name];
            void (^b)(void) = steps[i].blk;
            L(@"已排程 %@（+%lld 秒）", nm, d);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, d * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @autoreleasepool { L(@"→→ 开始 %@", nm); b(); }
            });
        }
        L(@"STAGE 0 完成：全部任务已排程");
    }
}
