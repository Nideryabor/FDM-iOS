/* ============================================================
 * FDM v0.6 —— 收口 + 网络层侦察 + 零宽提示词注入（可开关）
 *
 * 三件事：
 *  ① 修正 v0.5 的读 Hook 名字
 *      错：dataForKey / stringForKey / boolForKey / objectForKey
 *      对：getDataForKey: / getStringForKey: / getBoolForKey: / getObjectOfClass:forKey:
 *  ② 网络层 Hook：拦 /api/v0/chat/completion，dump 真实请求体
 *  ③ 零宽字符注入（Unicode Tag 区 U+E0000+ASCII）
 *      —— 配置驱动，默认关闭（先只看）
 *
 * 背景（安卓版结论，iOS 已复核成立）：
 *   DeepSeek 协议里没有 system 通道，唯一能带文本的字段是 prompt。
 *   用 U+E0000~U+E007F（渲染宽度 0，但 tokenizer 会解回 ASCII）投递，
 *   ⇒ 模型读得到、人眼看不见。
 *
 * 配置（App 的 Documents/ 下，都可选）：
 *   fdm-override.json   覆盖服务端设置（同 v0.5）
 *   fdm-inject.json     提示词注入：{"enabled":true,"text":"answer in 99 words"}
 *
 * 安全铁律：Hook 内不调宿主方法、不做 IO、重入保护、失败原样透传
 * ============================================================ */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <mach-o/dyld.h>

/* ==================== 路径 & 日志 ==================== */

static NSString *gDir = nil;
static NSString *P(NSString *n) { return [gDir stringByAppendingPathComponent:n]; }

static NSMutableArray<NSString *> *gBuf = nil;
static NSLock *gBufLock = nil;

static void Q(NSString *fmt, ...) {                 /* 只在 Hook 内用（无 IO） */
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        @try { [gBufLock lock]; if (gBuf.count < 30000) [gBuf addObject:s]; [gBufLock unlock]; }
        @catch (NSException *e) {}
    }
}
static void L(NSString *fmt, ...) {                 /* 非 Hook 上下文可用 */
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSLog(@"[FDM6] %@", s);
        @try {
            NSString *line = [NSString stringWithFormat:@"%@  %@\n", [NSDate date], s];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:P(@"fdm6.log")];
            if (!fh) {
                [[NSFileManager defaultManager] createFileAtPath:P(@"fdm6.log") contents:nil attributes:NULL];
                fh = [NSFileHandle fileHandleForWritingAtPath:P(@"fdm6.log")];
            }
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    }
}
static void FlushBuf(void) {
    @autoreleasepool {
        NSArray *snap = nil;
        [gBufLock lock];
        if (gBuf.count) { snap = [gBuf copy]; [gBuf removeAllObjects]; }
        [gBufLock unlock];
        if (!snap.count) return;
        NSMutableString *m = [NSMutableString string];
        for (NSString *l in snap) [m appendFormat:@"%@  %@\n", [NSDate date], l];
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:P(@"fdm6.log")];
            if (!fh) {
                [[NSFileManager defaultManager] createFileAtPath:P(@"fdm6.log") contents:nil attributes:NULL];
                fh = [NSFileHandle fileHandleForWritingAtPath:P(@"fdm6.log")];
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

static __thread int gDepth = 0;

/* ==================== 配置 ==================== */

static NSDictionary *gPatch = nil;         /* MMKV 覆盖表 */
static BOOL          gInjectOn = NO;       /* 提示词注入开关 */
static NSString     *gInjectText = nil;    /* 要注入的文本（ASCII） */

static void LoadConfig(void) {
    @autoreleasepool {
        /* ① 覆盖表 */
        NSData *d = [NSData dataWithContentsOfFile:P(@"fdm-override.json")];
        if (d) {
            id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([j isKindOfClass:[NSDictionary class]]) {
                gPatch = j;
                L(@"覆盖表：来自 fdm-override.json（%lu 项）", (unsigned long)gPatch.count);
            }
        }
        if (!gPatch) {
            gPatch = @{ @"deep_think_button_suffix"         : @"·FDM",
                        @"show_new_chat_button_above_input" : @YES };
            L(@"覆盖表：使用默认（%lu 项）", (unsigned long)gPatch.count);
        }

        /* ② 注入配置 */
        NSData *d2 = [NSData dataWithContentsOfFile:P(@"fdm-inject.json")];
        if (d2) {
            id j = [NSJSONSerialization JSONObjectWithData:d2 options:0 error:nil];
            if ([j isKindOfClass:[NSDictionary class]]) {
                gInjectOn = [j[@"enabled"] boolValue];
                id t = j[@"text"];
                if ([t isKindOfClass:[NSString class]]) gInjectText = t;
            }
        }
        L(@"提示词注入：%@（文本 %@）", gInjectOn ? @"开" : @"关",
          gInjectText ? gInjectText : @"(无)");
    }
}

/* ==================== 零宽编码 ====================
 * ⚠️ Unicode Tag 区（U+E0000~U+E007F）在 BMP 之外（>0xFFFF），
 *    NSString 内部用 UTF-16 代理对存储，unichar 只有 16 位装不下。
 *    ⇒ 必须按码点（code point）处理。
 */

static void AppendCP(NSMutableString *s, uint32_t cp) {
    if (cp <= 0xFFFF) {
        unichar u = (unichar)cp;
        [s appendString:[NSString stringWithCharacters:&u length:1]];
    } else {
        uint32_t t = cp - 0x10000;
        unichar buf[2] = { (unichar)(0xD800 + (t >> 10)), (unichar)(0xDC00 + (t & 0x3FF)) };
        [s appendString:[NSString stringWithCharacters:buf length:2]];
    }
}

/* 把 NSString 拆成码点数组 */
static uint32_t *CodePoints(NSString *s, NSUInteger *outCount) {
    NSUInteger n = s.length;
    unichar *b = (unichar *)malloc(sizeof(unichar) * (n ? n : 1));
    if (!b) { *outCount = 0; return NULL; }
    [s getCharacters:b range:NSMakeRange(0, n)];
    uint32_t *out = (uint32_t *)malloc(sizeof(uint32_t) * (n ? n : 1));
    if (!out) { free(b); *outCount = 0; return NULL; }
    NSUInteger k = 0;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = b[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n && b[i+1] >= 0xDC00 && b[i+1] <= 0xDFFF) {
            out[k++] = 0x10000u + (((uint32_t)(c - 0xD800)) << 10) + (uint32_t)(b[i+1] - 0xDC00);
            i++;
        } else {
            out[k++] = (uint32_t)c;
        }
    }
    free(b);
    *outCount = k;
    return out;
}

/* ASCII → Unicode Tag 区（U+E0000 + c） */
static NSString *ToTag(NSString *ascii) {
    if (!ascii.length) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:ascii.length * 2];
    const char *c = ascii.UTF8String;
    if (!c) return @"";
    for (size_t i = 0; i < strlen(c); i++) {
        unsigned char ch = (unsigned char)c[i];
        if (ch < 0x80) AppendCP(out, 0xE0000u + ch);
    }
    return out;
}

/* Tag → ASCII（诊断用） */
static NSString *FromTag(NSString *tag) {
    if (!tag.length) return @"";
    NSMutableString *out = [NSMutableString string];
    NSUInteger n = 0;
    uint32_t *cps = CodePoints(tag, &n);
    if (!cps) return @"";
    for (NSUInteger i = 0; i < n; i++) {
        if (cps[i] >= 0xE0000u && cps[i] <= 0xE007Fu) AppendCP(out, cps[i] - 0xE0000u);
    }
    free(cps);
    return out;
}

/* 统计字符串里的零宽字符个数 */
static NSUInteger CountTag(NSString *s) {
    if (!s.length) return 0;
    NSUInteger n = 0, cnt = 0;
    uint32_t *cps = CodePoints(s, &n);
    if (!cps) return 0;
    for (NSUInteger i = 0; i < n; i++)
        if (cps[i] >= 0xE0000u && cps[i] <= 0xE007Fu) cnt++;
    free(cps);
    return cnt;
}

/* ==================== 缓存 ==================== */

static NSUInteger gNMMKVWrite = 0, gNMMKVRead = 0;
static NSUInteger gNReqChat = 0, gNInjected = 0;
static NSData *gLastOrigBlob = nil, *gLastModBlob = nil;
static BOOL gReqDumped = NO;

/* ==================== ① MMKV ==================== */

static IMP o_setData=NULL, o_setObject=NULL;
static IMP o_getData=NULL, o_getString=NULL, o_getObj=NULL;

static BOOL IsBlobKey(id key) {
    if (!key || ![key isKindOfClass:[NSString class]]) return NO;
    return strcmp(((NSString *)key).UTF8String, "app.ab.serverValues") == 0;
}

/* --- blob 双层 JSON 打补丁 --- */
static NSData *PatchBlob(NSData *orig) {
    @autoreleasepool {
        if (!orig || orig.length < 16) return nil;
        @try {
            NSString *outer = [[NSString alloc] initWithData:orig encoding:NSUTF8StringEncoding];
            if (!outer) return nil;
            id step1 = [NSJSONSerialization JSONObjectWithData:[outer dataUsingEncoding:NSUTF8StringEncoding]
                                                      options:NSJSONReadingAllowFragments error:nil];
            NSString *inner = nil;
            if ([step1 isKindOfClass:[NSString class]]) inner = step1;
            else if ([step1 isKindOfClass:[NSDictionary class]]) inner = outer;
            else return nil;

            id obj = [NSJSONSerialization JSONObjectWithData:[inner dataUsingEncoding:NSUTF8StringEncoding]
                                                     options:NSJSONReadingMutableContainers error:nil];
            if (![obj isKindOfClass:[NSDictionary class]]) return nil;
            NSMutableDictionary *root = obj;
            NSMutableDictionary *st = root[@"settings"];
            if (![st isKindOfClass:[NSDictionary class]]) return nil;

            NSUInteger ok = 0;
            for (NSString *k in gPatch) {
                id cur = st[k];
                if ([cur isKindOfClass:[NSDictionary class]]) {
                    NSMutableDictionary *mm = [cur mutableCopy];
                    mm[@"value"] = gPatch[k];
                    st[k] = mm; ok++;
                }
            }
            if (!ok) return nil;

            NSData *innerOut = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
            NSString *innerStr = [[NSString alloc] initWithData:innerOut encoding:NSUTF8StringEncoding];
            return [NSJSONSerialization dataWithJSONObject:innerStr
                                                   options:NSJSONWritingFragmentsAllowed error:nil];
        } @catch (NSException *e) { return nil; }
    }
}

static NSData *EnsurePatched(NSData *orig) {
    if (!orig) return nil;
    if (gLastOrigBlob && gLastModBlob && [gLastOrigBlob isEqualToData:orig]) return gLastModBlob;
    NSData *m = PatchBlob(orig);
    if (m) {
        gLastOrigBlob = [orig copy];
        gLastModBlob  = m;
        W(@"fdm6-blob-mod.bin", m);
        Q(@"BLOB patch %lu → %lu B", (unsigned long)orig.length, (unsigned long)m.length);
    }
    return m;
}

/* --- 写 --- */
static void my_setData(id self, SEL _cmd, id val, id key) {
    if (gDepth == 0 && IsBlobKey(key) && [val isKindOfClass:[NSData class]]) {
        gDepth++; gNMMKVWrite++;
        NSData *m = EnsurePatched((NSData *)val);
        gDepth--;
        if (m) { ((void(*)(id,SEL,id,id))o_setData)(self, _cmd, m, key); return; }
    }
    if (o_setData) ((void(*)(id,SEL,id,id))o_setData)(self, _cmd, val, key);
}
static void my_setObject(id self, SEL _cmd, id val, id key) {
    if (gDepth == 0 && IsBlobKey(key)) {
        gDepth++; gNMMKVWrite++;
        NSData *m = [val isKindOfClass:[NSData class]] ? EnsurePatched((NSData *)val) : nil;
        gDepth--;
        if (m) { ((void(*)(id,SEL,id,id))o_setObject)(self, _cmd, m, key); return; }
    }
    if (o_setObject) ((void(*)(id,SEL,id,id))o_setObject)(self, _cmd, val, key);
}

/* --- 读（★ 修正后的真名）--- */
static id my_getData(id self, SEL _cmd, id key) {
    if (gDepth == 0 && IsBlobKey(key) && gLastModBlob) {
        gDepth++; gNMMKVRead++; gDepth--; return gLastModBlob;
    }
    return o_getData ? ((id(*)(id,SEL,id))o_getData)(self, _cmd, key) : nil;
}
static id my_getString(id self, SEL _cmd, id key) {
    if (gDepth == 0 && IsBlobKey(key) && gLastModBlob) {
        gDepth++; gNMMKVRead++; gDepth--;
        return [[NSString alloc] initWithData:gLastModBlob encoding:NSUTF8StringEncoding];
    }
    return o_getString ? ((id(*)(id,SEL,id))o_getString)(self, _cmd, key) : nil;
}
static id my_getObj(id self, SEL _cmd, Class cls, id key) {
    if (gDepth == 0 && IsBlobKey(key) && gLastModBlob && [cls isSubclassOfClass:[NSData class]]) {
        gDepth++; gNMMKVRead++; gDepth--; return gLastModBlob;
    }
    return o_getObj ? ((id(*)(id,SEL,Class,id))o_getObj)(self, _cmd, cls, key) : nil;
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
    if (!C) return NO;
    o_setData    = SwapInst(C, "setData:forKey:",            (IMP)my_setData);
    o_setObject  = SwapInst(C, "setObject:forKey:",          (IMP)my_setObject);
    o_getData    = SwapInst(C, "getDataForKey:",             (IMP)my_getData);
    o_getString  = SwapInst(C, "getStringForKey:",           (IMP)my_getString);
    o_getObj     = SwapInst(C, "getObjectOfClass:forKey:",   (IMP)my_getObj);
    L(@"MMKV 挂钩：setData=%p getData=%p getString=%p getObj=%p",
      o_setData, o_getData, o_getString, o_getObj);
    return YES;
}

/* ==================== ② 网络层 ==================== */

static BOOL IsChatURL(NSURLRequest *req) {
    @try {
        NSString *u = req.URL.absoluteString;
        if (!u) return NO;
        return [u containsString:@"/api/v0/chat/completion"] ||
               [u containsString:@"/api/v0/chat/continue"] ||
               [u containsString:@"/api/v0/chat/regenerate"];
    } @catch (NSException *e) { return NO; }
}

/* 从请求体（JSON）里取 prompt，返回可读摘要 */
static NSString *PromptSummary(NSData *body) {
    @try {
        if (!body || body.length < 2) return @"(空)";
        id j = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) return @"(非 JSON)";
        id p = ((NSDictionary *)j)[@"prompt"];
        if (![p isKindOfClass:[NSString class]]) return @"(无 prompt 字段)";
        NSString *ps = p;
        NSMutableString *r = [NSMutableString string];
        [r appendFormat:@"长度=%lu", (unsigned long)ps.length];
        NSUInteger tag = CountTag(ps);
        if (tag) [r appendFormat:@" 零宽字符=%lu（解出：%@）", (unsigned long)tag, FromTag(ps)];
        [r appendFormat:@" 前100字=%@", ps.length > 100 ? [ps substringToIndex:100] : ps];
        return r;
    } @catch (NSException *e) { return @"(解析异常)"; }
}

/* 对请求体做注入（需要时） */
static NSData *ProcessBody(NSData *body) {
    if (!gInjectOn || !gInjectText.length || !body) return nil;
    @try {
        id j = [NSJSONSerialization JSONObjectWithData:body options:NSJSONReadingMutableContainers error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) return nil;
        NSMutableDictionary *mm = j;
        id p = mm[@"prompt"];
        if (![p isKindOfClass:[NSString class]]) return nil;

        NSString *tag = ToTag(gInjectText);
        /* 前置：模型先读到指令；同时保持原文本在后 */
        mm[@"prompt"] = [tag stringByAppendingString:p];
        NSData *out = [NSJSONSerialization dataWithJSONObject:mm options:0 error:nil];
        gNInjected++;
        Q(@"INJECT 已注入 %lu 个零宽字符（文本：%@）", (unsigned long)tag.length, gInjectText);
        return out;
    } @catch (NSException *e) { return nil; }
}

static NSData *BodyOf(NSURLRequest *req) {
    @try {
        NSData *b = req.HTTPBody;
        if (b.length) return b;
        /* Alamofire 常用 HTTPBodyStream —— 不动它，只报告 */
        if (req.HTTPBodyStream) return nil;
        return nil;
    } @catch (NSException *e) { return nil; }
}

static NSURLRequest *HandleReq(NSURLRequest *req) {
    if (gDepth || !req || !IsChatURL(req)) return req;
    gDepth++;
    gNReqChat++;
    NSData *b = BodyOf(req);
    if (b) {
        Q(@"REQ %@  body=%lu B | %@", req.URL.path, (unsigned long)b.length, PromptSummary(b));
        if (!gReqDumped) { gReqDumped = YES; W(@"fdm6-req-body.json", b); }
        NSData *nb = ProcessBody(b);
        if (nb) {
            NSMutableURLRequest *m = [req mutableCopy];
            m.HTTPBody = nb;
            m.HTTPBodyStream = nil;
            gDepth--;
            return m;
        }
    } else {
        Q(@"REQ %@  (body 是 stream 或空，无法读取)", req.URL.path);
    }
    gDepth--;
    return req;
}

static IMP o_dataTask=NULL, o_dataTaskCb=NULL, o_uploadData=NULL, o_uploadDataCb=NULL;

static NSURLSessionDataTask *my_dataTask(id self, SEL _cmd, NSURLRequest *req) {
    NSURLRequest *r = HandleReq(req);
    return o_dataTask ? ((NSURLSessionDataTask *(*)(id,SEL,NSURLRequest *))o_dataTask)(self, _cmd, r) : nil;
}
static NSURLSessionDataTask *my_dataTaskCb(id self, SEL _cmd, NSURLRequest *req, id h) {
    NSURLRequest *r = HandleReq(req);
    return o_dataTaskCb ? ((NSURLSessionDataTask *(*)(id,SEL,NSURLRequest *,id))o_dataTaskCb)(self, _cmd, r, h) : nil;
}
static NSURLSessionUploadTask *my_uploadData(id self, SEL _cmd, NSURLRequest *req, NSData *body) {
    NSURLRequest *r = HandleReq(req);
    return o_uploadData ? ((NSURLSessionUploadTask *(*)(id,SEL,NSURLRequest *,NSData *))o_uploadData)(self, _cmd, r, body) : nil;
}
static NSURLSessionUploadTask *my_uploadDataCb(id self, SEL _cmd, NSURLRequest *req, NSData *body, id h) {
    NSURLRequest *r = HandleReq(req);
    return o_uploadDataCb ? ((NSURLSessionUploadTask *(*)(id,SEL,NSURLRequest *,NSData *,id))o_uploadDataCb)(self, _cmd, r, body, h) : nil;
}

static void HookNet(void) {
    /* 直接 hook NSURLSession 可能不够：Alamofire 用的可能是
     * __NSCFURLSession / __NSCFBackgroundSession 等私有子类。
     * ⇒ 枚举全部类，凡是实现了目标方法的都挂一遍。 */
    static const char *sels[] = {
        "dataTaskWithRequest:",
        "dataTaskWithRequest:completionHandler:",
        "uploadTaskWithRequest:fromData:",
        "uploadTaskWithRequest:fromData:completionHandler:",
        NULL
    };
    IMP news[] = { (IMP)my_dataTask, (IMP)my_dataTaskCb, (IMP)my_uploadData, (IMP)my_uploadDataCb };
    IMP *olds[] = { &o_dataTask, &o_dataTaskCb, &o_uploadData, &o_uploadDataCb };

    int n = objc_getClassList(NULL, 0);
    if (n <= 0) { L(@"!! 类枚举失败"); return; }
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!list) return;
    n = objc_getClassList(list, n);

    NSUInteger hooked = 0;
    for (int i = 0; i < n; i++) {
        const char *cn = class_getName(list[i]);
        if (!cn) continue;
        /* 只关心名字里带 URLSession 的类，避免误伤 */
        if (!strstr(cn, "URLSession") && !strstr(cn, "URLConnection")) continue;
        for (int s = 0; sels[s]; s++) {
            Method m = class_getInstanceMethod(list[i], sel_registerName(sels[s]));
            if (!m) continue;
            IMP cur = method_getImplementation(m);
            /* 已经是我们的实现就跳过（子类可能共享同一个 IMP） */
            if (cur == news[s]) continue;
            /* 记录第一个原始 IMP 作为 fallback */
            if (*olds[s] == NULL) *olds[s] = cur;
            method_setImplementation(m, news[s]);
            hooked++;
            L(@"   挂 %s -%s", cn, sels[s]);
        }
    }
    free(list);
    L(@"网络挂钩完成：改了 %lu 处（dataTask=%p cb=%p upload=%p uploadCb=%p）",
      (unsigned long)hooked, o_dataTask, o_dataTaskCb, o_uploadData, o_uploadDataCb);
}

/* ==================== 状态输出 ==================== */

static void DumpImages(void) {
    @autoreleasepool {
        NSMutableString *o = [NSMutableString string];
        int n = _dyld_image_count();
        int ti = 0, ek = 0;
        [o appendFormat:@"# 镜像 %d 个  %@\n", n, [NSDate date]];
        for (int i = 0; i < n; i++) {
            const char *nm = _dyld_get_image_name(i);
            if (!nm) continue;
            if (strstr(nm, "TweakInject")) { ti++; [o appendFormat:@"  TweakInject %s\n", nm]; }
            else if (strstr(nm, "libellekit")) { ek++; [o appendFormat:@"  ellekit     %s\n", nm]; }
            else if (strstr(nm, "FDMProbe")) [o appendFormat:@"  ★我们       %s\n", nm];
        }
        [o appendFormat:@"\n## TweakInject=%d ellekit=%d\n", ti, ek];
        [o appendString:(ti==0&&ek==0) ? @"✅ 无 ElleKit 注入\n" : @"⚠️ 仍有 ElleKit 注入\n"];
        W(@"fdm6-images.txt", [o dataUsingEncoding:NSUTF8StringEncoding]);
    }
}

static void DumpHits(void) {
    @autoreleasepool {
        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"# FDM v0.6 命中统计  %@\n\n", [NSDate date]];
        [o appendFormat:@"MMKV  写 serverValues : %lu\n", (unsigned long)gNMMKVWrite];
        [o appendFormat:@"MMKV  读 serverValues : %lu\n", (unsigned long)gNMMKVRead];
        [o appendFormat:@"blob  已改造         : %@\n", gLastModBlob ? @"是" : @"否"];
        [o appendFormat:@"网络  chat 请求       : %lu\n", (unsigned long)gNReqChat];
        [o appendFormat:@"提示词注入           : %@（已注入 %lu 次）\n",
            gInjectOn ? @"开" : @"关", (unsigned long)gNInjected];
        [o appendFormat:@"注入文本             : %@\n", gInjectText ?: @"(无)"];
        [o appendFormat:@"\n覆盖表：\n"];
        for (NSString *k in gPatch) [o appendFormat:@"  %@ = %@\n", k, gPatch[k]];
        W(@"fdm6-hits.txt", [o dataUsingEncoding:NSUTF8StringEncoding]);
    }
}

/* ==================== 入口 ==================== */

__attribute__((constructor))
static void fdm6_init(void) {
    @autoreleasepool {
        NSArray *ds = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        gDir = [ds firstObject] ?: NSTemporaryDirectory();
        gBufLock = [NSLock new];
        gBuf = [NSMutableArray array];

        L(@"==================================================");
        L(@"FDM v0.6 已加载  pid=%d  build=%s %s", (int)getpid(), __DATE__, __TIME__);
        L(@"Documents=%@", gDir);

        LoadConfig();

        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 2ull*NSEC_PER_SEC),
                                  2ull*NSEC_PER_SEC, 1ull*NSEC_PER_SEC);
        dispatch_source_set_event_handler(t, ^{ FlushBuf(); });
        dispatch_resume(t);

        HookMMKV();
        HookNet();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool { HookMMKV(); HookNet(); DumpImages(); }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45*NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            DumpHits(); L(@"45s：MMKV写%lu 读%lu | chat请求%lu | 注入%lu",
                          (unsigned long)gNMMKVWrite, (unsigned long)gNMMKVRead,
                          (unsigned long)gNReqChat, (unsigned long)gNInjected);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120*NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            DumpHits(); FlushBuf(); L(@"=== v0.6 结束 ===");
        });
    }
}
