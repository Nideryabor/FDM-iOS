// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用

/* ============================================================
 * FDM v7.1 —— 修 Content-Length（注入失败的元凶）
 *
 * ══════ v0.6 崩溃复盘 ══════
 * 现象：每 3~5 秒崩一次，全部死在"网络挂钩完成"之后。
 *
 * 错误 ①：hook 了无关的系统类
 *   AMSURLSession（App Store）/ ACSURLSession（系统认证）
 *   WebCoreNSURLSession（WebKit）/ C2NetworkingDelegateURLSession（iCloud）
 *   → DeepSeek 的流量跟这些毫无关系，但它们在启动期被用到 → 崩
 *
 * 错误 ②（致命）：所有类共用同一个"原始 IMP"
 *   if (*olds[s] == NULL) *olds[s] = cur;   ← 只记了第一个类的原函数
 *   → WebCore 的方法被调用时，wrapper 去调 AMSURLSession 的原函数
 *   → self 类型完全不匹配 → 立刻崩
 *
 * ══════ v0.7 修法 ══════
 *  ① 白名单：只碰 Foundation 的会话类（名字精确等于 NSURLSession
 *     或以 __NSCF / __NSURL 开头且含 URLSession）
 *  ② 每个 (类, 方法) 各自记一份原始 IMP —— 精确查表，找不到就安全放弃
 *  ③ 查不到原函数 → 直接返回 nil，绝不乱调
 *  ④ 默认仍然只观察（不改请求体）
 * ============================================================ */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "FLog.h"
#import "FDMConfig.h"
#import "FDMFeatures.h"
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <mach-o/dyld.h>

/* ==================== 路径 & 日志 ==================== */

static NSString *gDir = nil;
static NSString *P(NSString *n) { return [gDir stringByAppendingPathComponent:n]; }

static NSMutableArray<NSString *> *gBuf = nil;
static NSLock *gBufLock = nil;

/* ==================== 日志：统一走 FLog ==================== */
/*  Hook 内用 FLOGD（Debug 级，可关）；正常路径用 FLOGI。
 *  两者都只做内存 append，绝不阻塞。 */
#define Q(fmt, ...)  FLOGD(FC_SYS, fmt, ##__VA_ARGS__)
#define L(fmt, ...)  FLOGI(FC_SYS, fmt, ##__VA_ARGS__)
static void FlushBuf(void) { FLogFlush(); }

static void W(NSString *n, NSData *d) {
    @try { if (d) [d writeToFile:P(n) atomically:YES]; } @catch (NSException *e) {}
}

static __thread int gDepth = 0;
static BOOL gInReplay = NO;          /* 诊断重放中（防止被自己的 hook 再拦） */

/* 供 FDMComposer 使用：标记「这是我们自己发的请求，别再注入」 */
void FDMProbeSetReplay(BOOL on) { gInReplay = on; }

/* ==================== 配置 ==================== */

static NSDictionary *gPatch = nil;
static BOOL      gAllowNewKeys = YES;   /* 允许添加服务端未下发的键 */
static BOOL      gInjectOn = NO;         /* 兼容旧字段 */
static NSString *gInjectText = nil;
static NSString *gMode = @"none";        /* ★ none / plain / tag —— 对照实验 */
static BOOL      gNetHookOn = YES;       /* 网络 Hook 总开关（出问题可一键关） */

/* 读 fdm-debug.json 里的布尔项（带默认值） */
id FDMProbeReadDebugBool(NSString *k, BOOL def) {
    @try {
        NSString *p = [gDir stringByAppendingPathComponent:@"fdm-debug.json"];
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (!d) return @(def);
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if ([j isKindOfClass:[NSDictionary class]] && ((NSDictionary *)j)[k])
            return @([((NSDictionary *)j)[k] boolValue]);
    } @catch (NSException *e) { }
    return @(def);
}

static void LoadConfig(void) {
    @autoreleasepool {
        /* ★ 覆盖表：来自 FDMFeatures（手动覆盖 + 快捷开关） */
        gPatch = FDMPatchTable();
        gAllowNewKeys = [[FDMConfig shared] boolFor:G_QUICK key:@"add_unknown_keys"];
        FLOGI(FC_CFG, @"覆盖表 %lu 项", (unsigned long)gPatch.count);

        /* ★ 注入配置：来自 FDMFeatures */
        {
            NSString *m = nil, *t = nil; BOOL en = NO;
            FDMInjectConfig(&m, &t, &en);
            gMode = m;
            gInjectText = t;
            gInjectOn = en;
        }
        /* 网络 Hook 可单独关：{"net": false} */
        NSData *d3 = [NSData dataWithContentsOfFile:P(@"fdm-net.json")];
        if (d3) {
            id j = [NSJSONSerialization JSONObjectWithData:d3 options:0 error:nil];
            if ([j isKindOfClass:[NSDictionary class]] && j[@"enabled"])
                gNetHookOn = [j[@"enabled"] boolValue];
        }
        FLOGI(FC_CFG, @"配置：覆盖表 %lu 项 | 模式 %@ | 网络Hook %@",
          (unsigned long)gPatch.count, gMode, gNetHookOn?@"开":@"关");

        /* ★ X 光机：渲染层勘察（只读，默认关） */
        {
            extern void FDMXraySetEnabled(BOOL on);
            BOOL x = [[FDMConfig shared] boolFor:G_DEBUG key:@"xray"];
            FDMXraySetEnabled(x);
            if (x) FLOGI(FC_CFG, @"[xray] 已开启 → 启动后会 dump 宿主渲染类表");
        }

        /* ★ 标记抹除开关（显示层 / 数据库层） */
        {
            extern void FDMStripSetEnabled(BOOL display, BOOL db);
            BOOL sd = [[FDMConfig shared] boolFor:G_INJECT key:@"strip_display"];
            BOOL sk = [[FDMConfig shared] boolFor:G_INJECT key:@"strip_db"];
            FDMStripSetEnabled(sd, sk);
        }
    }
}

/* ==================== 零宽编码 ==================== */

static void AppendCP(NSMutableString *s, uint32_t cp) {
    if (cp <= 0xFFFF) {
        unichar u = (unichar)cp;
        [s appendString:[NSString stringWithCharacters:&u length:1]];
    } else {
        uint32_t t = cp - 0x10000;
        unichar b[2] = { (unichar)(0xD800 + (t >> 10)), (unichar)(0xDC00 + (t & 0x3FF)) };
        [s appendString:[NSString stringWithCharacters:b length:2]];
    }
}
static uint32_t *CodePoints(NSString *s, NSUInteger *outCount) {
    NSUInteger n = s.length;
    unichar *b = (unichar *)malloc(sizeof(unichar) * (n ? n : 1));
    if (!b) { *outCount = 0; return NULL; }
    [s getCharacters:b range:NSMakeRange(0, n)];
    uint32_t *o = (uint32_t *)malloc(sizeof(uint32_t) * (n ? n : 1));
    if (!o) { free(b); *outCount = 0; return NULL; }
    NSUInteger k = 0;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = b[i];
        if (c >= 0xD800 && c <= 0xDBFF && i+1 < n && b[i+1] >= 0xDC00 && b[i+1] <= 0xDFFF) {
            o[k++] = 0x10000u + (((uint32_t)(c - 0xD800)) << 10) + (uint32_t)(b[i+1] - 0xDC00);
            i++;
        } else o[k++] = (uint32_t)c;
    }
    free(b); *outCount = k; return o;
}
static NSString *ToTag(NSString *ascii) {
    if (!ascii.length) return @"";
    NSMutableString *out = [NSMutableString string];
    const char *c = ascii.UTF8String;
    if (!c) return @"";
    for (size_t i = 0; i < strlen(c); i++) {
        unsigned char ch = (unsigned char)c[i];
        if (ch < 0x80) AppendCP(out, 0xE0000u + ch);
    }
    return out;
}
static NSString *FromTag(NSString *tag) {
    if (!tag.length) return @"";
    NSMutableString *out = [NSMutableString string];
    NSUInteger n = 0; uint32_t *cps = CodePoints(tag, &n);
    if (!cps) return @"";
    for (NSUInteger i = 0; i < n; i++)
        if (cps[i] >= 0xE0000u && cps[i] <= 0xE007Fu) AppendCP(out, cps[i] - 0xE0000u);
    free(cps); return out;
}
static NSUInteger CountTag(NSString *s) {
    if (!s.length) return 0;
    NSUInteger n = 0, c = 0; uint32_t *cps = CodePoints(s, &n);
    if (!cps) return 0;
    for (NSUInteger i = 0; i < n; i++) if (cps[i] >= 0xE0000u && cps[i] <= 0xE007Fu) c++;
    free(cps); return c;
}

/* ==================== 计数 ==================== */

static NSUInteger gNMMKVWrite = 0, gNMMKVRead = 0;
static NSUInteger gNReqChat = 0, gNReqOther = 0, gNInjected = 0;
static NSData *gLastOrigBlob = nil, *gLastModBlob = nil;
/* ★ modelConfig 的 per-key 缓存（每个 modelConfig_N 单独存） */
static NSMutableDictionary<NSString *, NSData *> *gMCMod = nil;
static NSMutableDictionary<NSString *, NSData *> *gMCOrig = nil;
static NSLock *gMCLock = nil;
static BOOL gBodyDumped = NO;

/* ==================== MMKV（v0.5 验证过，保持） ==================== */

static IMP o_setData=NULL, o_setObject=NULL;
static IMP o_getData=NULL, o_getString=NULL, o_getObj=NULL;

/* ★★★ 键判定（必须精确！）
 *   app.ab.serverValues   → 服务端设置覆盖
 *   modelConfig_<数字>     → 模型配置（回复建议 / 招呼语 / 能力）
 *
 *   ⚠️ 曾经的 bug：用 strncmp(c,"modelConfig",11) 会把
 *      modelConfigVersion(2B) / modelConfigSettingIDs(23B) 也当成目标，
 *      真正的 modelConfig_1(23KB) 反而漏了。
 */
static BOOL IsServerValuesKey(id key) {
    if (!key || ![key isKindOfClass:[NSString class]]) return NO;
    const char *c = ((NSString *)key).UTF8String;
    return c && strcmp(c, "app.ab.serverValues") == 0;
}
static BOOL IsModelConfigKey(id key) {
    if (!key || ![key isKindOfClass:[NSString class]]) return NO;
    const char *c = ((NSString *)key).UTF8String;
    if (!c) return NO;
    if (strncmp(c, "modelConfig_", 12) != 0) return NO;
    const char *p = c + 12;
    if (!*p) return NO;                       /* 必须有编号 */
    while (*p) {
        if (*p < '0' || *p > '9') return NO;  /* 只能是数字 */
        p++;
    }
    return YES;
}
/* ★ P3：账号信息缓存键（MMKV 里就叫 currentUser，实测确认） */
static BOOL IsCurrentUserKey(id key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    return [(NSString *)key isEqualToString:@"currentUser"];
}

static NSData *PatchCurrentUser(NSData *orig);

static BOOL IsBlobKey(id key) {
    return IsServerValuesKey(key) || IsModelConfigKey(key) || IsCurrentUserKey(key);
}

extern NSString *FDMUserProfileRewrite(NSData *body);

/* ============================================================
 * ★★★ P3 · 账号名 / 头像：改 MMKV 里的 currentUser
 *
 *   实测结构（从设备 mmkv.default 里 dump 出来的真数据）：
 *   {
 *     "settingsToken": "eyJ...",
 *     "areaCode": "+86",
 *     "mobile": "158******15",      ← ★ 抽屉底部显示的就是它
 *     "id": "1f4f3f9c-...",
 *     "idProfiles": [],             ← ★ 有昵称就放这里（当前是空）
 *     "chat": {"isMuted": 0},
 *     "needBirthday": false,
 *     "email": "",
 *     "token": "...",
 *     "minorModeStatus": "ADULT",
 *     "isMainland": true
 *   }
 *
 *   ⇒ 用户模型里**既没有 nickname 也没有 avatar**（跟安卓一模一样）。
 *     所以账号名只能落到 `mobile` 上（宿主兜底显示打码手机号）。
 *     若某天 idProfiles 里出现 nickname，会优先改它。
 *
 *   头像：模型里彻底没有 ⇒ 只能走 UI 层（下一步再做）。
 * ============================================================ */
static NSData *PatchCurrentUser(NSData *orig) {
    if (!orig || orig.length < 16) return nil;
    extern BOOL FDMUserNameWanted(NSString **outText);
    NSString *want = nil;
    if (!FDMUserNameWanted(&want)) return nil;

    @try {
        id j = [NSJSONSerialization JSONObjectWithData:orig
                                              options:NSJSONReadingMutableContainers
                                                error:nil];
        if (![j isKindOfClass:[NSMutableDictionary class]]) return nil;
        NSMutableDictionary *d = j;

        int n = 0;
        /* ① idProfiles 里如果有 nickname，优先改那儿（更贴近原意） */
        id profiles = d[@"idProfiles"];
        if ([profiles isKindOfClass:[NSMutableArray class]]) {
            for (id p in profiles) {
                if (![p isKindOfClass:[NSMutableDictionary class]]) continue;
                NSMutableDictionary *pd = p;
                for (NSString *k in @[@"nickname", @"nickName", @"name", @"displayName"]) {
                    if ([pd[k] isKindOfClass:[NSString class]]) {
                        pd[k] = want; n++;
                    }
                }
            }
        }
        /* ② 兜底：改 mobile（宿主在没有昵称时会显示它） */
        if (n == 0 && [d[@"mobile"] isKindOfClass:[NSString class]]) {
            d[@"mobile"] = want;
            n++;
        }
        if (n == 0) return nil;

        NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
        if (!out) return nil;
        FLOGW(FC_MMKV, @"[user] ★ currentUser 改名 → 「%@」（%d 处，%lu→%lu B）",
              want, n, (unsigned long)orig.length, (unsigned long)out.length);
        return out;
    } @catch (NSException *e) {
        FLOGE(FC_MMKV, @"[user] currentUser 改写异常: %@", e.reason);
        return nil;
    }
}

static NSData *PatchBlob(NSData *orig) {
    @autoreleasepool {
        if (!orig || orig.length < 16) return nil;
        @try {
            NSString *outer = [[NSString alloc] initWithData:orig encoding:NSUTF8StringEncoding];
            if (!outer) return nil;
            id s1 = [NSJSONSerialization JSONObjectWithData:[outer dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:NSJSONReadingAllowFragments error:nil];
            NSString *inner = nil;
            if ([s1 isKindOfClass:[NSString class]]) inner = s1;
            else if ([s1 isKindOfClass:[NSDictionary class]]) inner = outer;
            else return nil;
            id obj = [NSJSONSerialization JSONObjectWithData:[inner dataUsingEncoding:NSUTF8StringEncoding]
                                                     options:NSJSONReadingMutableContainers error:nil];
            if (![obj isKindOfClass:[NSDictionary class]]) return nil;
            NSMutableDictionary *root = obj, *st = root[@"settings"];
            if (![st isKindOfClass:[NSDictionary class]]) return nil;
            NSUInteger ok = 0;
            NSMutableArray *skipped = [NSMutableArray array];
            NSMutableArray *added = [NSMutableArray array];
            for (NSString *k in gPatch) {
                id cur = st[k];
                if ([cur isKindOfClass:[NSDictionary class]]) {
                    /* 已下发 → 改 value */
                    NSMutableDictionary *m = [cur mutableCopy]; m[@"value"] = gPatch[k]; st[k] = m; ok++;
                } else if (gAllowNewKeys) {
                    /* ★ 服务端没下发，但宿主二进制认识这个键 → 凭空加进去
                     *   （id 编一个负数，避免和服务端 id 撞） */
                    NSMutableDictionary *m = [NSMutableDictionary dictionary];
                    m[@"id"] = @(-1);
                    m[@"value"] = gPatch[k];
                    st[k] = m;
                    ok++;
                    [added addObject:k];
                } else {
                    [skipped addObject:k];
                }
            }
            if (added.count)
                FLOGI(FC_MMKV, @"★ 新增 %lu 个服务端未下发的键: %@",
                      (unsigned long)added.count, [added componentsJoinedByString:@","]);
            if (skipped.count)
                FLOGW(FC_MMKV, @"%lu 个键被跳过（未开启 add_unknown）: %@",
                      (unsigned long)skipped.count, [skipped componentsJoinedByString:@","]);
            if (!ok) return nil;
            NSData *io = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
            NSString *istr = [[NSString alloc] initWithData:io encoding:NSUTF8StringEncoding];
            return [NSJSONSerialization dataWithJSONObject:istr
                                                   options:NSJSONWritingFragmentsAllowed error:nil];
        } @catch (NSException *e) { return nil; }
    }
}
/* ==================== ★ 模型配置改写（招呼用语 / 回复建议 / 能力） ====================
 *  ⚠️ 这里最容易踩的坑：orig 是调用方的 NSData 指针，
 *     如果直接 &base 传进去、函数内部又做 autorelease，
 *     返回后 base 可能已经是悬垂指针 → objc_retain 崩（EXC_BAD_ACCESS）。
 *  ⇒ 必须自己 strong 持有，并且只返回我们自己创建的 NSData。
 */
static NSData *PatchModelConfig(NSData *orig) {
    if (!orig || orig.length < 4) return nil;

    extern BOOL FDMApplyModelConfig(NSData **out, NSArray **items);

    NSData *base = [orig copy];            /* ★ strong 持有，避免悬垂 */
    if (!base) return nil;

    NSArray *items = nil;
    BOOL changed = NO;
    @try {
        changed = FDMApplyModelConfig(&base, &items);
    } @catch (NSException *e) {
        FLOGE(FC_MMKV, @"modelConfig 改写异常: %@", e.reason);
        return nil;
    }

    if (!changed || !base) return nil;
    if (base.length < 4) return nil;       /* 结果异常，放弃 */

    return base;                            /* base 是 strong 的，安全 */
}

/* ★ 统一改写入口：按 key 类型分派，结果按 key 缓存
 *  返回 nil = 不改（调用方原样透传）
 */
static NSData *EnsurePatched(NSData *orig, id key) {
    if (!orig || orig.length < 16) return nil;   /* 太短的一律跳过 */

    /* ---------- currentUser（账号名，P3） ---------- */
    if (IsCurrentUserKey(key)) {
        return PatchCurrentUser(orig);
    }

    /* ---------- app.ab.serverValues（单例缓存） ---------- */
    if (IsServerValuesKey(key)) {
        if (gLastOrigBlob && gLastModBlob && [gLastOrigBlob isEqualToData:orig])
            return gLastModBlob;
        NSData *m = PatchBlob(orig);
        if (!m) return nil;
        gLastOrigBlob = [orig copy];
        gLastModBlob  = [m copy];
        W(@"fdm-blob-mod.bin", m);
        FLOGI(FC_MMKV, @"serverValues patch %lu → %lu B（%lu 项）",
              (unsigned long)orig.length, (unsigned long)m.length,
              (unsigned long)gPatch.count);
        for (NSString *k in gPatch)
            FLOGD(FC_MMKV, @"   覆盖 %@ = %@", k, gPatch[k]);
        return gLastModBlob;
    }

    /* ---------- modelConfig_<N>（per-key 缓存） ---------- */
    if (IsModelConfigKey(key)) {
        NSString *k = (NSString *)key;
        if (!gMCMod) {
            gMCMod = [NSMutableDictionary dictionary];
            gMCOrig = [NSMutableDictionary dictionary];
            gMCLock = [NSLock new];
        }
        [gMCLock lock];
        NSData *cachedOrig = gMCOrig[k];
        NSData *cachedMod  = gMCMod[k];
        [gMCLock unlock];
        if (cachedOrig && cachedMod && [cachedOrig isEqualToData:orig])
            return cachedMod;

        NSData *m = PatchModelConfig(orig);
        if (!m) return nil;

        [gMCLock lock];
        gMCOrig[k] = [orig copy];
        gMCMod[k]  = [m copy];
        [gMCLock unlock];

        FLOGI(FC_MMKV, @"★ modelConfig patch %@: %lu → %lu B",
              k, (unsigned long)orig.length, (unsigned long)m.length);
        return m;
    }

    return nil;
}

/* ==================== 写：命中目标就改，否则原样透传 ==================== */
static void my_setData(id self, SEL _cmd, id val, id key) {
    if (gDepth == 0 && [val isKindOfClass:[NSData class]] && IsBlobKey(key)) {
        gDepth++;
        gNMMKVWrite++;
        NSData *m = EnsurePatched((NSData *)val, key);
        gDepth--;
        if (m && o_setData && o_setData != (IMP)my_setData) {
            ((void(*)(id,SEL,id,id))o_setData)(self, _cmd, m, key);
            return;
        }
    }
    if (o_setData && o_setData != (IMP)my_setData)
        ((void(*)(id,SEL,id,id))o_setData)(self, _cmd, val, key);
}

static void my_setObject(id self, SEL _cmd, id val, id key) {
    if (gDepth == 0 && [val isKindOfClass:[NSData class]] && IsBlobKey(key)) {
        gDepth++;
        gNMMKVWrite++;
        NSData *m = EnsurePatched((NSData *)val, key);
        gDepth--;
        if (m && o_setObject && o_setObject != (IMP)my_setObject) {
            ((void(*)(id,SEL,id,id))o_setObject)(self, _cmd, m, key);
            return;
        }
    }
    if (o_setObject && o_setObject != (IMP)my_setObject)
        ((void(*)(id,SEL,id,id))o_setObject)(self, _cmd, val, key);
}

/* ==================== 读：命中目标就返回改过的版本 ====================
 *  ★ 关键：宿主很可能在 hook 装之前就写好了 modelConfig_1，
 *    所以**读的时候也必须改写**，不能只靠写入路径。
 */
static id my_getData(id self, SEL _cmd, id key) {
    id orig = nil;
    if (o_getData && o_getData != (IMP)my_getData)
        orig = ((id(*)(id,SEL,id))o_getData)(self, _cmd, key);
    if (gDepth != 0 || ![orig isKindOfClass:[NSData class]]) return orig;

    /* serverValues：优先给缓存 */
    if (IsServerValuesKey(key) && gLastModBlob) {
        gNMMKVRead++;
        return gLastModBlob;
    }
    /* modelConfig：动态改写 */
    if (IsModelConfigKey(key)) {
        gDepth++;
        NSData *m = EnsurePatched((NSData *)orig, key);
        gDepth--;
        if (m) { gNMMKVRead++; return m; }
    }
    /* ★ currentUser（账号名，P3） */
    if (IsCurrentUserKey(key)) {
        gDepth++;
        NSData *m = PatchCurrentUser((NSData *)orig);
        gDepth--;
        if (m) { gNMMKVRead++; return m; }
    }
    return orig;
}

static id my_getString(id self, SEL _cmd, id key) {
    if (IsServerValuesKey(key) && gLastModBlob && gDepth == 0) {
        gNMMKVRead++;
        return [[NSString alloc] initWithData:gLastModBlob encoding:NSUTF8StringEncoding];
    }
    /* ★ currentUser 如果以字符串形式存（实测是 Data，但兜一手） */
    if (IsCurrentUserKey(key) && gDepth == 0) {
        id r0 = nil;
        if (o_getString && o_getString != (IMP)my_getString)
            r0 = ((id(*)(id,SEL,id))o_getString)(self, _cmd, key);
        if ([r0 isKindOfClass:[NSString class]]) {
            NSData *d0 = [(NSString *)r0 dataUsingEncoding:NSUTF8StringEncoding];
            NSData *m0 = PatchCurrentUser(d0);
            if (m0) {
                gNMMKVRead++;
                return [[NSString alloc] initWithData:m0 encoding:NSUTF8StringEncoding];
            }
        }
        return r0;
    }
    id r = nil;
    if (o_getString && o_getString != (IMP)my_getString)
        r = ((id(*)(id,SEL,id))o_getString)(self, _cmd, key);
    return r;
}

static id my_getObj(id self, SEL _cmd, Class cls, id key) {
    id orig = nil;
    if (o_getObj && o_getObj != (IMP)my_getObj)
        orig = ((id(*)(id,SEL,Class,id))o_getObj)(self, _cmd, cls, key);
    if (gDepth != 0 || ![orig isKindOfClass:[NSData class]]) return orig;

    if (IsServerValuesKey(key) && gLastModBlob && [cls isSubclassOfClass:[NSData class]]) {
        gNMMKVRead++;
        return gLastModBlob;
    }
    if (IsModelConfigKey(key) && [cls isSubclassOfClass:[NSData class]]) {
        gDepth++;
        NSData *m = EnsurePatched((NSData *)orig, key);
        gDepth--;
        if (m) { gNMMKVRead++; return m; }
    }
    /* ★ currentUser（账号名，P3） */
    if (IsCurrentUserKey(key) && [cls isSubclassOfClass:[NSData class]]) {
        gDepth++;
        NSData *m = PatchCurrentUser((NSData *)orig);
        gDepth--;
        if (m) { gNMMKVRead++; return m; }
    }
    return orig;
}

/* ★ 幂等：已挂过同一实现就跳过（防重复挂导致"原函数指针指向自己"→ 无限递归）
 *  这个 bug 在 v4.0 崩过一次：HookMMKV 被调两次，
 *  第二次时 old = my_getData，o_getData 就变成了我们自己 → 递归爆栈。 */
static IMP Swap(Class C, const char *sel, IMP imp) {
    if (!C || !sel || !imp) return NULL;
    @try {
        SEL s = sel_registerName(sel);
        Method m = class_getInstanceMethod(C, s);
        if (!m) return NULL;
        IMP old = method_getImplementation(m);
        if (old == imp) return NULL;            /* ★ 已经是我们的了，别动 */
        method_setImplementation(m, imp);
        return old;                             /* ★ 只有真换了才返回原 IMP */
    } @catch (NSException *e) { return NULL; }
}
void HookMMKV(void) {
    static BOOL done = NO;                       /* ★ 只挂一次 */
    if (done) return;
    Class C = objc_getClass("MMKV");
    if (!C) return;
    o_setData   = Swap(C, "setData:forKey:",          (IMP)my_setData);
    o_setObject = Swap(C, "setObject:forKey:",        (IMP)my_setObject);
    o_getData   = Swap(C, "getDataForKey:",           (IMP)my_getData);
    o_getString = Swap(C, "getStringForKey:",         (IMP)my_getString);
    o_getObj    = Swap(C, "getObjectOfClass:forKey:", (IMP)my_getObj);

    /* ★ 保命检查：任何一个"原 IMP"等于我们自己的实现 → 立刻退回原状 */
    if (o_getData == (IMP)my_getData || o_getString == (IMP)my_getString ||
        o_getObj == (IMP)my_getObj || o_setData == (IMP)my_setData ||
        o_setObject == (IMP)my_setObject) {
        FLOGE(FC_MMKV, @"!! 检测到自引用（原 IMP == 我们的实现），放弃 MMKV 挂钩");
        o_getData = o_getString = o_getObj = NULL;
        o_setData = o_setObject = NULL;
        done = YES;
        return;
    }

    done = YES;
    FLOGI(FC_MMKV, @"MMKV 挂钩：setData=%p getData=%p getString=%p getObj=%p",
          o_setData, o_getData, o_getString, o_getObj);
}

/* ==================== ★ 网络 Hook（v0.7 重写） ==================== */

/* 每个 (类, 方法) 一份原始 IMP —— 修掉 v0.6 的致命 bug */
/* ★ v10.1 修复：原来只有 32，而实际要挂
 *   13 个 URLSession 类 × 4 个方法 + task 的 error/response + 43 个 delegate = 90+
 *   表满后 AddHook 静默失败，但 method_setImplementation 照cháng执行
 *   ⇒ 有 hook 没记账 ⇒ FindOrig 返回 NULL ⇒ mw_dt 返回 nil ⇒ 宿主网络全废（App 卡死）
 *   ⇒ 这就是那个「dataTask 找不到原函数」报错刷 46 次、最后把 App 拖死的真因。 */
#define MAX_HOOKS 256
typedef struct { Class cls; SEL sel; IMP orig; } HookEntry;
static HookEntry gHooks[MAX_HOOKS];
static int gHookCount = 0;

static IMP FindOrig(Class cls, SEL sel) {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        for (int i = 0; i < gHookCount; i++)
            if (gHooks[i].cls == c && sel_isEqual(gHooks[i].sel, sel)) return gHooks[i].orig;
    }
    return NULL;
}
/* 四个 wrapper 的前置声明（FindOrigSafe 要拿它们的地址做「排除自己」判断） */
static NSURLSessionDataTask *mw_dt(id, SEL, NSURLRequest *);
static NSURLSessionDataTask *mw_dtcb(id, SEL, NSURLRequest *, id);
static NSURLSessionUploadTask *mw_up(id, SEL, NSURLRequest *, NSData *);
static NSURLSessionUploadTask *mw_upcb(id, SEL, NSURLRequest *, NSData *, id);

/* ★★ 安全找原 IMP：记账查不到时再兜底一次
 *   宁可调用「看起来正确的实现」，也绝不返回 nil
 *   （返回 nil 会让宿主收到 nil 的 task ⇒ 网络全废 ⇒ App 卡死） */
static IMP FindOrigSafe(Class cls, SEL sel) {
    IMP o = FindOrig(cls, sel);
    if (o) return o;
    /* 兜底：直接问 runtime，但必须排除我们自己的四个 wrapper */
    IMP cand = class_getMethodImplementation(cls, sel);
    if (cand && cand != (IMP)mw_dt && cand != (IMP)mw_dtcb &&
        cand != (IMP)mw_up && cand != (IMP)mw_upcb) {
        return cand;
    }
    return NULL;
}

/* 返回 YES = 记账成功（调用方必须检查，失败就别装 hook） */
static BOOL AddHook(Class cls, SEL sel, IMP orig) {
    if (!cls || !sel || !orig) return NO;
    /* 已记过同样的 (类, 方法) 就直接复用 */
    for (int i = 0; i < gHookCount; i++)
        if (gHooks[i].cls == cls && sel_isEqual(gHooks[i].sel, sel)) return YES;
    if (gHookCount >= MAX_HOOKS) {
        FLOGE(FC_HOOK, @"!! AddHook 表满（%d），拒绝记账 %s", MAX_HOOKS, sel_getName(sel));
        return NO;
    }
    gHooks[gHookCount].cls = cls;
    gHooks[gHookCount].sel = sel;
    gHooks[gHookCount].orig = orig;
    gHookCount++;
    return YES;
}

/* ★ 关键：找出这个方法**真正定义在哪个类**
 *   如果 __NSURLSessionLocal 自己没实现、继承自 NSURLSession，
 *   那 method_setImplementation 改的是父类的 IMP ⇒ FindOrig 必须能从父类那层查到。 */
static Class ClassOwningMethod(Class start, SEL sel) {
    for (Class c = start; c != Nil; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        BOOL found = NO;
        if (ms) {
            for (unsigned int i = 0; i < n; i++)
                if (sel_isEqual(method_getName(ms[i]), sel)) { found = YES; break; }
            free(ms);
        }
        if (found) return c;
    }
    return Nil;
}

/* 白名单：只碰 Foundation 的会话类 */
/* ============================================================
 * ★★ 2026-10-17 收窄：13 个类 → 3 个
 *
 * 旧规则会把 __NSURLSessionStatistics / __NSURLSessionTaskInfo /
 * __NSCFURLSessionConnection / __NSURLBackgroundSession ... 全部挂上。
 * 那些是系统内部类，方法语义我们根本不了解；而且其中多个**共享同一个
 * Method 对象**（继承自 NSURLSession），method_setImplementation 会连带
 * 影响别的类 ⇒ 宿主在某些路径上拿到异常实现 ⇒ 崩。
 *
 * 只需要这三个就够覆盖绝大多数网络请求：
 *   NSURLSession                   ← 基类，宿主通常直接用
 *   __NSURLSessionLocal            ← 真实实现类（+dataTaskWithRequest: 在这里）
 *   __NSCFURLSessionTaskGroup      ← 某些合并请求走这里
 * ============================================================ */
/* ============================================================
 * ★★ 2026-10-17 收窄：13 个类 → 3 个
 *
 * 旧规则（strncmp __NSCF/__NSURL 前缀匹配）会把
 *   __NSURLSessionStatistics / __NSURLSessionTaskInfo /
 *   __NSCFURLSessionConnection / __NSURLBackgroundSession ...
 * 全部挂上。这些是系统内部类，方法语义我们不了解；其中多个
 * **共享同一个 Method 对象**（继承自 NSURLSession），
 * method_setImplementation 会连带影响别的类
 * ⇒ 宿主在某些路径拿到异常实现 ⇒ 崩。
 *
 * 只留这三个就覆盖绝大多数请求：
 *   NSURLSession                ← 基类
 *   __NSURLSessionLocal         ← 真实实现类
 *   __NSCFURLSessionTaskGroup   ← 部分合并请求
 * ============================================================ */
static BOOL ClassAllowed(const char *cn) {
    if (!cn) return NO;
    return (strcmp(cn, "NSURLSession") == 0 ||
            strcmp(cn, "__NSURLSessionLocal") == 0 ||
            strcmp(cn, "__NSCFURLSessionTaskGroup") == 0);
}

/* 判断是不是我们关心的 URL */
static BOOL IsChatURL(NSURLRequest *req) {
    @try {
        NSString *u = req.URL.absoluteString;
        if (!u) return NO;
        return [u containsString:@"/api/v0/chat/completion"] ||
               [u containsString:@"/api/v0/chat/continue"] ||
               [u containsString:@"/api/v0/chat/regenerate"];
    } @catch (NSException *e) { return NO; }
}
static NSString *PromptSummary(NSData *body) {
    @try {
        if (!body || body.length < 2) return @"(空)";
        id j = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) return @"(非 JSON)";
        id p = ((NSDictionary *)j)[@"prompt"];
        if (![p isKindOfClass:[NSString class]]) return @"(无 prompt)";
        NSString *ps = p;
        NSMutableString *r = [NSMutableString string];
        [r appendFormat:@"prompt=%lu字", (unsigned long)ps.length];
        NSUInteger t = CountTag(ps);
        if (t) [r appendFormat:@" 零宽=%lu(解:%@)", (unsigned long)t, FromTag(ps)];
        [r appendFormat:@" | %@", ps.length > 80 ? [ps substringToIndex:80] : ps];
        return r;
    } @catch (NSException *e) { return @"(异常)"; }
}
/* ★★ 字节级替换：只在原始 JSON 字节里改 prompt 的值，
 *     其余字节（键序、数字格式、空白）完全不动 —— 最安全
 */
static NSData *PatchPromptInBytes(NSData *body, NSString *newPrompt) {
    @try {
        NSString *s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!s) return nil;

        NSRange r = [s rangeOfString:@"\"prompt\":\""];
        if (r.location == NSNotFound) return nil;
        NSUInteger start = r.location + r.length;   /* 值的第一个字符（不含引号） */

        /* 找匹配的结束引号（处理 \ 转义） */
        NSUInteger i = start;
        while (i < s.length) {
            unichar c = [s characterAtIndex:i];
            if (c == '\\') { i += 2; continue; }
            if (c == '"') break;
            i++;
        }
        if (i >= s.length) return nil;

        /* 转义新 prompt */
        NSMutableString *esc = [NSMutableString string];
        for (NSUInteger k = 0; k < newPrompt.length; k++) {
            unichar c = [newPrompt characterAtIndex:k];
            if (c == '"' || c == '\\') [esc appendFormat:@"\\%C", c];
            else if (c < 0x20) [esc appendFormat:@"\\u%04x", c];
            else [esc appendFormat:@"%C", c];
        }

        NSMutableString *out = [s mutableCopy];
        [out replaceCharactersInRange:NSMakeRange(start, i - start) withString:esc];
        return [out dataUsingEncoding:NSUTF8StringEncoding];
    } @catch (NSException *e) { return nil; }
}

/* ★ 自检：对比原始 request 和 mutableCopy，看有没有属性丢失 */
static void DiffRequest(NSURLRequest *a, NSURLRequest *b) {
    @try {
        NSMutableArray *d = [NSMutableArray array];
        if (![a.URL isEqual:b.URL]) [d addObject:@"URL"];
        if (!(a.HTTPMethod == b.HTTPMethod || [a.HTTPMethod isEqualToString:b.HTTPMethod])) [d addObject:@"HTTPMethod"];
        if (a.cachePolicy != b.cachePolicy) [d addObject:@"cachePolicy"];
        if (a.timeoutInterval != b.timeoutInterval) [d addObject:@"timeoutInterval"];
        if (a.networkServiceType != b.networkServiceType) [d addObject:@"networkServiceType"];
        if (a.allowsCellularAccess != b.allowsCellularAccess) [d addObject:@"allowsCellularAccess"];
        if (a.HTTPShouldHandleCookies != b.HTTPShouldHandleCookies) [d addObject:@"HTTPShouldHandleCookies"];
        if (a.HTTPShouldUsePipelining != b.HTTPShouldUsePipelining) [d addObject:@"HTTPShouldUsePipelining"];
        if ((a.mainDocumentURL == nil) != (b.mainDocumentURL == nil)) [d addObject:@"mainDocumentURL"];
        if (![a.allHTTPHeaderFields isEqualToDictionary:b.allHTTPHeaderFields]) [d addObject:@"allHTTPHeaderFields"];
        NSUInteger la = a.HTTPBody.length, lb = b.HTTPBody.length;
        if (la != lb) [d addObject:[NSString stringWithFormat:@"HTTPBody长度(%lu→%lu)", (unsigned long)la, (unsigned long)lb]];
        if ((a.HTTPBodyStream == nil) != (b.HTTPBodyStream == nil)) [d addObject:@"HTTPBodyStream"];
        /* 额外：把未知属性用 KVC 枚举一遍（有些内部字段不在公开 API） */
        FLOGI(FC_NET, @"   ★ 自检 mutableCopy 差异: %@", d.count ? d : @"(无差异)");
        FLOGI(FC_NET, @"   ★ 原对象类: %@ / 副本类: %@", [a class], [b class]);
    } @catch (NSException *e) { FLOGI(FC_NET, @"   自检异常 %@", e.reason); }
}

/* ★ 三种模式做对照实验
 *   copy  : 只做 mutableCopy，什么都不改 → 测"复制本身是否破坏请求"
 *   ws    : 只插一个空格（语义不变）      → 测"body 字节是否被保护"
 *   plain : 前缀普通 ASCII                → 测"加前缀这个动作"
 *   tag   : 前缀零宽字符（目标）
 */
static NSData *ProcessBody(NSData *body, NSString *path) {
    if (!body) return nil;
    if ([gMode isEqualToString:@"off"]) return nil;

    @try {
        NSString *orig = nil;
        {
            id j = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
            if (![j isKindOfClass:[NSDictionary class]]) return nil;
            id p = ((NSDictionary *)j)[@"prompt"];
            if (![p isKindOfClass:[NSString class]]) return nil;
            orig = p;
        }

        /* ---- copy 模式：原样返回（外面仍会走 mutableCopy 路径） ---- */
        if ([gMode isEqualToString:@"copy"]) {
            gNInjected++;
            FLOGI(FC_INJECT, @"★★ INJECT mode=copy 只复制不改（%lu B）", (unsigned long)body.length);
            return body;
        }

        /* ---- ws 模式：插一个空格，字节变、语义不变 ---- */
        if ([gMode isEqualToString:@"ws"]) {
            NSString *s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
            NSRange r = [s rangeOfString:@","];
            if (r.location == NSNotFound) return nil;
            NSUInteger byteOff = 0;
            for (NSUInteger k = 0; k < r.location; k++) {
                unichar c = [s characterAtIndex:k];
                byteOff += (c < 0x80) ? 1 : ((c < 0x800) ? 2 : 3);   /* BMP 内最多 3 字节 */
            }
            NSMutableData *md = [body mutableCopy];
            [md replaceBytesInRange:NSMakeRange(byteOff, 0) withBytes:" " length:1];
            gNInjected++;
            W(@"fdm-req-inj-ws.json", md);
            FLOGI(FC_INJECT, @"★★ INJECT mode=ws 插入空格 %lu B → %lu B", (unsigned long)body.length, (unsigned long)md.length);
            return md;
        }

        NSString *pre = @"";
        if ([gMode isEqualToString:@"tag"]) {
            pre = ToTag(gInjectText ?: @"");
        } else if ([gMode isEqualToString:@"fdm"]) {
            /* ★ 安卓同款：⟦FDM⟧ … ⟦/FDM⟧ 明文定界（**支持中文**）
             *   前端显示靠 FDMStrip 抹除，服务端收到的是完整明文。
             *   前后各留一个 \n，避免和用户消息粘成一行。 */
            /* ★ 音乐变量：{music} {lyric} … 在**此刻**替换（发消息这一瞬间的真值）。
             *   总开关 pvar_on 关着时原样返回，连 [[ ]] 都不碰。 */
            extern NSString *FDMPromptVarsApply(NSString *text);
            NSString *t = FDMPromptVarsApply(gInjectText ?: @"");
            if (t.length) {
                pre = [NSString stringWithFormat:
                       @"\u27E6" @"FDM" @"\u27E7\n%@\n\u27E6" @"/FDM" @"\u27E7\n", t];
            }
        } else if ([gMode isEqualToString:@"plain"]) {
            pre = [NSString stringWithFormat:@"[FDM-TEST] %@ —— ", gInjectText ?: @"test"];
        }

        /* ★ 对话增强：发送前追加（明文，会显示在对话里） */
        if (FDMChatAppendEnabled()) {
            NSString *ct = FDMChatAppendText();
            if (ct.length) {
                pre = [pre stringByAppendingFormat:@"%@\n", ct];
                FLOGI(FC_INJECT, @"对话增强：追加 %lu 字明文", (unsigned long)ct.length);
            }
        }

        if (!pre.length) return nil;      /* 什么都没变，别动 body */
        NSString *newPrompt = [pre stringByAppendingString:orig];

        /* ★ 优先走字节级替换（最安全）；失败再退回重新序列化 */
        NSData *out = PatchPromptInBytes(body, newPrompt);
        NSString *how = @"byte-patch";
        if (!out) {
            id j = [NSJSONSerialization JSONObjectWithData:body
                                                   options:NSJSONReadingMutableContainers error:nil];
            if (![j isKindOfClass:[NSDictionary class]]) return nil;
            NSMutableDictionary *mm = j;
            mm[@"prompt"] = newPrompt;
            out = [NSJSONSerialization dataWithJSONObject:mm options:0 error:nil];
            how = @"reencode";
        }
        if (!out) return nil;

        gNInjected++;
        NSString *fn = [NSString stringWithFormat:@"fdm-req-inj-%@.json", gMode];
        W(fn, out);

        FLOGI(FC_INJECT, @"★★ INJECT mode=%@(%@) 前缀%lu字 原%lu→新%lu字 | %@ | %lu B→%lu B",
          gMode, how, (unsigned long)pre.length,
          (unsigned long)orig.length, (unsigned long)newPrompt.length,
          path, (unsigned long)body.length, (unsigned long)out.length);

        /* ★★ 关键：把 header 也跟出来，看 Content-Length 对不对 */
        return out;
    } @catch (NSException *e) {
        FLOGI(FC_INJECT, @"INJECT 异常: %@", e.reason);
        return nil;
    }
}

/* 观察 + 可选注入；返回可能被替换的请求 */
static NSURLRequest *HandleReq(NSURLRequest *req) {
    if (gDepth || gInReplay || !req) return req;
    FLOGW(FC_NET, @"[trace] HandleReq %s", req.URL.path.UTF8String ?: "?");
    gDepth++;
    @try {
        BOOL chat = IsChatURL(req);
        if (chat) gNReqChat++; else gNReqOther++;
        if (chat) {
            /* ★ P4：把这条请求记成「模块发消息」的模板 */
            {
                extern void FDMComposerCapture(NSURLRequest *, NSURLSession *);
                FDMComposerCapture(req, nil);
            }
            NSData *b = req.HTTPBody;
            if (b.length) {
                FLOGI(FC_NET, @"REQ %@ | %@ | headers=%@", req.URL.path, PromptSummary(b), req.allHTTPHeaderFields);
                /* 记原始 body（写不同名字，别覆盖注入后的） */
                if (!gBodyDumped) { gBodyDumped = YES; W(@"fdm-req-raw.json", b); }
                NSData *nb = ProcessBody(b, req.URL.path);
                if (nb) {
                    /* ★★ v1.1 修复：绝不碰 HTTPBodyStream！
                     *   HTTPBody 与 HTTPBodyStream 互斥，后设的赢。
                     *   原请求的 stream 由 body 自动生成；把 stream 设为 nil
                     *   会让 body 变空 → 服务器收到 0 字节 → HTTP 400。
                     *   而且原对象本来就是 NSMutableURLRequest，直接原地改最稳。 */
                    BOOL hadStream = (req.HTTPBodyStream != nil);

                    NSMutableURLRequest *m = [req isKindOfClass:[NSMutableURLRequest class]]
                                             ? (NSMutableURLRequest *)req
                                             : [req mutableCopy];
                    if (m != req) DiffRequest(req, m);

                    m.HTTPBody = nb;
                    /* ←←← 这里原本有一行 m.HTTPBodyStream = nil; 已删除 */

                    FLOGI(FC_SYS, @"   ★ 原地修改(hadStream=%d) body=%lu B | CL=%@",
                      (int)hadStream, (unsigned long)nb.length,
                      m.allHTTPHeaderFields[@"Content-Length"] ?: @"(无)");

                    gDepth--;
                    return m;
                }
            } else {
                FLOGI(FC_NET, @"REQ %@ | body 空或为 stream", req.URL.path);
            }
        }
    } @catch (NSException *e) { FLOGD(FC_NET, @"HandleReq 异常 %@", e.reason); }
    gDepth--;
    return req;
}

/* --- ★ 响应诊断：抓服务端真实返回 --- */

/* 失败时重放一次（原请求已失败，重放安全）拿服务端错误正文 */
__attribute__((unused))
static void DiagReplay(NSURLRequest *req) {
    if (gInReplay || !req) return;
    @try {
        NSMutableURLRequest *r = [req mutableCopy];
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];

        gInReplay = YES;   /* ★ 防止重放被自己的 hook 再拦 */
        NSURLSessionDataTask *t = [sess dataTaskWithRequest:r
                                          completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
            @autoreleasepool {
                NSInteger st = [resp isKindOfClass:[NSHTTPURLResponse class]]
                               ? ((NSHTTPURLResponse *)resp).statusCode : -1;
                NSString *txt = nil;
                if (d.length) txt = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                FLOGI(FC_NET, @"★★★ 重放结果: HTTP=%ld | 正文(%lu B) = %@",
                  (long)st, (unsigned long)d.length, txt ?: @"(非文本)");
                if (d.length) W(@"fdm-diag-error.txt", d);
                gInReplay = NO;
                [sess finishTasksAndInvalidate];
            }
        }];
        [t resume];
    } @catch (NSException *e) {
        gInReplay = NO;
        FLOGI(FC_NET, @"重放异常 %@", e.reason);
    }
}

static BOOL IsChatTask(id task) {
    @try {
        NSURL *u = nil;
        if ([task respondsToSelector:@selector(originalRequest)])
            u = ((NSURLSessionTask *)task).originalRequest.URL;
        if (!u) return NO;
        return [u.absoluteString containsString:@"/api/v0/chat/"];
    } @catch (NSException *e) { return NO; }
}

__attribute__((unused))
static id mw_taskError(id self, SEL _cmd) {
    IMP o = FindOrigSafe(object_getClass(self), _cmd);
    id e = o ? ((id(*)(id,SEL))o)(self, _cmd) : nil;
    if (e && IsChatTask(self)) {
        @try {
            NSURLResponse *rr = ((NSURLSessionTask *)self).response;
            NSInteger code = [rr isKindOfClass:[NSHTTPURLResponse class]]
                             ? ((NSHTTPURLResponse *)rr).statusCode : -1;
            FLOGI(FC_NET, @"★★ 任务失败: HTTP=%ld | error=%@ | url=%@",
              (long)code, e,
              ((NSURLSessionTask *)self).originalRequest.URL.path);
        } @catch (NSException *ex) {}
    }
    return e;
}

__attribute__((unused))
static id mw_taskResponse(id self, SEL _cmd) {
    IMP o = FindOrigSafe(object_getClass(self), _cmd);
    id r = o ? ((id(*)(id,SEL))o)(self, _cmd) : nil;
    if (r && IsChatTask(self)) {
        @try {
            if ([r isKindOfClass:[NSHTTPURLResponse class]]) {
                NSHTTPURLResponse *hr = r;
                if (hr.statusCode != 200) {
                    FLOGI(FC_NET, @"★★ 响应异常: HTTP %ld  headers=%@", (long)hr.statusCode, hr.allHeaderFields);
                    /* 抓服务端错误正文（原请求已失败，重放安全） */
                    DiagReplay(((NSURLSessionTask *)self).originalRequest);
                }
            }
        } @catch (NSException *ex) {}
    }
    return r;
}

/* ============================================================
 * ★★ 服务端同步拦截（v8.1 · 2026-10-17）
 *
 * 真因：消息**不是本地写的**，是服务端存的。我们发给服务端的 prompt 带标记
 *   ⇒ 服务端原样保存 ⇒ 下次拉会话时同步回来 ⇒ 本地库和 UI 都是脏的。
 *   （主人 12:14 的判断：「我猜是登录时数据库自动更新」—— 对）
 *
 * 所以真正该拦的位置是「**从服务端下载回来的字节**」：
 *   ① completion 的 SSE 流（stream_task / buffer）
 *   ② 任意接口的 HTTPBody（会话列表 / 消息详情）
 *   ⇒ 在数据进入宿主的解析器之前，把 ⟦FDM⟧…⟦/FDM⟧ 抹掉。
 *   ⇒ 宿主解析到的就是干净数据 ⇒ 内存干净、库干净、UI 干净，三层一起解决。
 * ============================================================ */

/* ============================================================
 * ★★ 2026-10-17 彻底关闭 didReceiveData 全量挂载
 *
 * 旧实现：return FDMProbeReadDebugBool(@"data_hook", NO);
 *   但 FDMProbeReadDebugBool 返回的是 id (NSNumber*)，
 *   隐式转 BOOL = 「指针非 NULL」= **永远 YES**
 *   ⇒ 即使配置里写 false，43 个 delegate 也一直被挂上！
 *
 * 而 dp_didReceiveData 里 `if (!o) return;` —— 查不到原实现就直接返回，
 * 原实现永远不跑 ⇒ 那些类永远收不到数据 ⇒ 宿主卡死/崩。
 * 其中还包括 UIKeyboardCandidateView* / WKNetworkSessionDelegate /
 * GEODataURLSession / CKStreamingAssetAppendContext 等**系统内部类**。
 *
 * 【收益 0（历史调用计数全 0），风险极高】⇒ 直接永久关闭。
 * ============================================================ */
BOOL FDMNetDataHookOn(void) {
    return NO;
}

/* 一个极快的长度/内容预检，避免对每个数据流做无谓处理 */
static BOOL MaybeHasMarks(NSData *d) {
    if (!d || d.length < 8) return NO;
    const uint8_t *b = (const uint8_t *)d.bytes;
    if (d.length < 512) {
        /* 小数据直接扫 */
        for (NSUInteger i = 0; i + 6 <= d.length; i++)
            if (b[i] == 0xE2 && b[i+1] == 0x9F && b[i+2] == 0xA6 &&
                b[i+3] == 'F' && b[i+4] == 'D' && b[i+5] == 'M') return YES;
        return NO;
    }
    return memmem(b, d.length, "\xE2\x9F\xA6" "FDM", 6) != NULL;
}

extern NSString *FDMStripMarks(NSString *s);

/* 把一段数据（可能是 JSON / SSE / 纯文本）里的标记抹掉；返回 nil = 没变 */
static NSData *StripDataMarks(NSData *d, const char *tag) {
    if (!MaybeHasMarks(d)) return nil;
    @try {
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (!s) return nil;
        NSString *clean = FDMStripMarks(s);
        if (clean == s) return nil;                 /* 有字节特征但没成对标记，别动 */
        NSData *out = [clean dataUsingEncoding:NSUTF8StringEncoding];
        if (!out) return nil;
        FLOGI(FC_INJECT, @"[sync] ★ %s 抹除 %lu → %lu B",
              tag, (unsigned long)d.length, (unsigned long)out.length);
        return out;
    } @catch (NSException *e) { return nil; }
}

/* ---- NSJSONSerialization：服务端数据进宿主解析器之前的最后一道闸 ---- */
static IMP gJSONOrig = NULL;

__attribute__((unused))
static id js_objectWithData(id self, SEL _cmd, NSData *data,
                            NSJSONReadingOptions opt, NSError **err) {
    if (!gJSONOrig) return nil;
    NSData *use = data;
    @try {
        NSData *clean = StripDataMarks(data, "JSONObjectWithData");
        if (clean) use = clean;
    } @catch (NSException *e) { use = data; }
    id (*fn)(id, SEL, NSData *, NSJSONReadingOptions, NSError **) = (void *)gJSONOrig;
    return fn(self, _cmd, use, opt, err);
}

__attribute__((unused))
static void InstallJSONHook(void) {
    @try {
        Class c = [NSJSONSerialization class];
        SEL sel = sel_registerName("JSONObjectWithData:options:error:");
        Method m = class_getClassMethod(c, sel);
        if (!m) { FLOGW(FC_HOOK, @"[sync] NSJSONSerialization 上没有这个方法"); return; }
        IMP old = method_getImplementation(m);
        if (old == (IMP)js_objectWithData) return;      /* 幂等 */
        gJSONOrig = old;
        method_setImplementation(m, (IMP)js_objectWithData);
        FLOGI(FC_HOOK, @"[sync] ★ 已挂 NSJSONSerialization（服务端数据入口，原 IMP=%p）", old);
    } @catch (NSException *e) {
        FLOGE(FC_HOOK, @"[sync] JSON hook 失败: %@", e.reason);
    }
}

/* ============================================================
 * 四个 wrapper
 *
 * ★★ 铁律：**拿不到原实现 = 灾难**
 *   返回 nil 会让宿主收到 nil 的 task ⇒ 立刻崩。
 *   所以：先用 FindOrigSafe 拿到原 IMP，拿不到就「不接管」——
 *   但 Objective-C 没有「不接管」这个概念，唯一安全的做法是
 *   **在安装阶段就确保原 IMP 已经记好**（AddHook 失败就不挂 hook）。
 *   这里再加一道：万一运行时查不到，就直接返回 nil 之前先打错误日志，
 *   并把该 (类,方法) 标记为禁用，下个进程启动时不再挂。
 * ============================================================ */
static NSURLSessionDataTask *mw_dt(id self, SEL _cmd, NSURLRequest *req) {
    IMP o = FindOrigSafe(object_getClass(self), _cmd);
    if (!o) {
        FLOGE(FC_NET, @"!! [致命] dataTask 无原函数 %s - 已记录，请上报",
              class_getName(object_getClass(self)));
        return nil;
    }
    NSURLRequest *r = HandleReq(req);
    return ((NSURLSessionDataTask *(*)(id,SEL,NSURLRequest *))o)(self, _cmd, r);
}
/* ============================================================
 * ★★★ P3 · 账号名 / 头像改写（2026-10-17）
 *
 *   目标：抽屉底部那行「账号名 + 头像」换成自己想要的。
 *
 *   安卓怎么做的：hook Compose 里 UserInfoFooter 的 lambda
 *     （Ls5;->v() 的 a==8 分支取账号名、a==0xf 取头像 URL）
 *     因为安卓的用户模型里**没有头像字段**，只能从 UI 层换。
 *
 *   iOS 怎么做：走**网络层**改响应，比 UI 层干净得多 ——
 *     /api/v0/users/current 返回用户信息，宿主全程只有这一个来源，
 *     改一次 ⇒ 抽屉、设置页、头像全都跟着变，不用挂 UI hook。
 *
 *   ⚠️ 第一步是**探针**：先把真实响应结构打出来，
 *      不猜字段名（宿主版本一换，猜的一定错）。
 * ============================================================ */
static BOOL IsUserInfoURL(NSURLRequest *req) {
    @try {
        NSString *u = req.URL.absoluteString;
        if (!u) return NO;
        return [u containsString:@"/api/v0/users/current"] ||
               [u containsString:@"/api/v0/users/get"];
    } @catch (NSException *e) { return NO; }
}

extern NSString *FDMUserProfileRewrite(NSData *body);   /* FDMUserMeta.m */

static NSURLSessionDataTask *mw_dtcb(id self, SEL _cmd, NSURLRequest *req, id h) {
    IMP o = FindOrigSafe(object_getClass(self), _cmd);
    if (!o) { FLOGE(FC_NET, @"!! [致命] dataTaskCb 无原函数"); return nil; }
    NSURLRequest *r = HandleReq(req);

    /* ---- 用户信息接口：包装 completion，做「探针 + 改写」 ---- */
    if (h && IsUserInfoURL(r)) {
        @try {
            id wrapped = [^(NSData *d, NSURLResponse *resp, NSError *e) {
                @autoreleasepool {
                    NSData *use = d;
                    @try {
                        if (d.length) {
                            /* ① 探针：第一次落盘 + 打日志（不猜字段） */
                            static int dumped = 0;
                            if (dumped < 2) {
                                dumped++;
                                W(@"fdm-users-current.json", d);
                                NSString *s = [[NSString alloc] initWithData:d
                                                                     encoding:NSUTF8StringEncoding];
                                if (s.length > 1500)
                                    s = [s substringToIndex:1500];
                                FLOGI(FC_NET, @"[user] ★ users/current 响应 %lu B:\n%@",
                                      (unsigned long)d.length, s ?: @"(非文本)");
                            }
                            /* ② 改写 */
                            NSString *newStr = FDMUserProfileRewrite(d);
                            if (newStr.length) {
                                NSData *nb = [newStr dataUsingEncoding:NSUTF8StringEncoding];
                                if (nb.length) use = nb;
                            }
                        }
                    } @catch (NSException *ex) {
                        FLOGE(FC_NET, @"[user] 处理异常: %@", ex.reason);
                    }
                    ((void(^)(NSData *, NSURLResponse *, NSError *))h)(use, resp, e);
                }
            } copy];
            return ((NSURLSessionDataTask *(*)(id,SEL,NSURLRequest *,id))o)(self, _cmd, r, wrapped);
        } @catch (NSException *e2) {
            FLOGE(FC_NET, @"[user] 包装异常: %@", e2.reason);
        }
    }

    return ((NSURLSessionDataTask *(*)(id,SEL,NSURLRequest *,id))o)(self, _cmd, r, h);
}
static NSURLSessionUploadTask *mw_up(id self, SEL _cmd, NSURLRequest *req, NSData *body) {
    IMP o = FindOrigSafe(object_getClass(self), _cmd);
    if (!o) { FLOGE(FC_NET, @"!! [致命] upload 无原函数"); return nil; }
    NSURLRequest *r = HandleReq(req);
    return ((NSURLSessionUploadTask *(*)(id,SEL,NSURLRequest *,NSData *))o)(self, _cmd, r, body);
}
static NSURLSessionUploadTask *mw_upcb(id self, SEL _cmd, NSURLRequest *req, NSData *body, id h) {
    IMP o = FindOrigSafe(object_getClass(self), _cmd);
    if (!o) { FLOGE(FC_NET, @"!! [致命] uploadCb 无原函数"); return nil; }
    NSURLRequest *r = HandleReq(req);
    return ((NSURLSessionUploadTask *(*)(id,SEL,NSURLRequest *,NSData *,id))o)(self, _cmd, r, body, h);
}

/* ============================================================
 * ★★ v9.1：URLSession 数据层抹除
 *
 * 为什么之前全线 0 命中：
 *   • Swift 用 **JSONDecoder**，不是 NSJSONSerialization ⇒ JSON hook 空转
 *   • 消息可能是服务端同步下来的（主人 12:14 的判断），本地 sqlite 未必写
 *   ⇒ 唯一 100% 必经的地方是「**URLSession 收到的那块 Data**」。
 *
 * 拦两个口：
 *   ① delegate 模式：-[<Delegate> URLSession:dataTask:didReceiveData:]
 *      （按 selector 精确匹配，不会误伤；宿主 delegate 类名无所谓）
 *   ② completionHandler 模式：包装 dataTaskWithRequest:completionHandler: 的 block
 *
 * ⚠️ 跨块问题：Data 是分块到达的，⟦FDM⟧ 和 ⟦/FDM⟧ 可能被切到两个块里。
 *   处理原则：只有「块内出现完整开始+闭合」才抹；不完整就原样透传。
 *   宁可漏（下次刷新会补），也不做缓冲重组 —— 那会破坏 SSE 流式渲染。
 * ============================================================ */

static int gNDataHits = 0;

__attribute__((unused))
static void dp_didReceiveData(id self, SEL _cmd, NSURLSession *session,
                              NSURLSessionDataTask *task, NSData *data) {
    IMP o = FindOrigSafe(object_getClass(self), _cmd);
    if (!o) return;
    NSData *use = data;
    @try {
        NSData *clean = StripDataMarks(data, "didReceiveData");
        if (clean) {
            use = clean;
            gNDataHits++;
        }
    } @catch (NSException *e) { use = data; }
    ((void(*)(id,SEL,id,id,id))o)(self, _cmd, session, task, use);
}

/* 把所有实现了 didReceiveData 的类都挂上（select 精确，不会误伤） */
__attribute__((unused))
static int InstallDataDelegateHook(void) {
    int done = 0;
    @try {
        SEL sel = sel_registerName("URLSession:dataTask:didReceiveData:");
        int n = objc_getClassList(NULL, 0);
        if (n <= 0) return 0;
        __unsafe_unretained Class *list =
            (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)n);
        if (!list) return 0;
        n = objc_getClassList(list, n);
        for (int i = 0; i < n; i++) {
            Class c = list[i];
            if (!c) continue;
            Method m = class_getInstanceMethod(c, sel);
            if (!m) continue;
            IMP cur = method_getImplementation(m);
            if (cur == (IMP)dp_didReceiveData) continue;
            /* 只挂「自己实现」的类，跳过纯继承（避免重复挂父类）*/
            unsigned int mc = 0;
            Method *own = class_copyMethodList(c, &mc);
            BOOL isOwn = NO;
            if (own) {
                for (unsigned int k = 0; k < mc; k++)
                    if (sel_isEqual(method_getName(own[k]), sel)) { isOwn = YES; break; }
                free(own);
            }
            if (!isOwn) continue;
            AddHook(c, sel, cur);
            method_setImplementation(m, (IMP)dp_didReceiveData);
            done++;
            FLOGI(FC_NET, @"[data] 挂 %s didReceiveData", class_getName(c));
        }
        free(list);
    } @catch (NSException *e) {
        FLOGE(FC_NET, @"[data] 安装异常: %@", e.reason);
    }
    if (done) FLOGI(FC_NET, @"[data] ★ 已挂 %d 个 delegate 的 didReceiveData", done);
    else      FLOGW(FC_NET, @"[data] 没找到任何 delegate 的 didReceiveData（可能走 completionHandler）");
    return done;
}

static void HookNet(void) {
    if (!gNetHookOn) { FLOGI(FC_CFG, @"网络 Hook 已按配置关闭"); return; }
    /* ============================================================
     * ★★ 2026-10-17 移除 NSJSONSerialization hook
     *
     * 理由：
     *   ① 宿主是 Swift，走 **JSONDecoder**，根本不经过 NSJSONSerialization
     *      ⇒ 挂了也是空转，零收益
     *   ② 但它是**全局**类方法：一旦某处真的用到（第三方 SDK、WebKit 内部），
     *      我们的 wrapper 在 gJSONOrig 未就绪时会 `return nil`
     *      ⇒ 对方拿到 nil 而不是解析结果 ⇒ 空指针崩
     *   ③ 每次调用还要走一轮 MaybeHasMarks + 可能的 NSString 转换
     *
     * 【收益 0，风险高】⇒ 删掉。
     * ============================================================ */
    FLOGI(FC_NET, @"[net] 已跳过 NSJSONSerialization hook（Swift 用 JSONDecoder，无收益）");
    /* ⚠️ v9.1 的 didReceiveData 全量挂载（43 个类）疑似导致静默死亡，
     *    先关掉；要开请在 fdm-debug.json 里把 "data_hook": true 打开。 */
    {
        /* 2026-10-17：永久关闭，见 FDMNetDataHookOn 上方注释 */
        FLOGI(FC_NET, @"[data] didReceiveData 全量挂载已永久禁用（43 个系统类风险太高）");
    }

    static const char *sels[] = {
        "dataTaskWithRequest:",
        "dataTaskWithRequest:completionHandler:",
        "uploadTaskWithRequest:fromData:",
        "uploadTaskWithRequest:fromData:completionHandler:",
        NULL
    };
    IMP news[] = { (IMP)mw_dt, (IMP)mw_dtcb, (IMP)mw_up, (IMP)mw_upcb };

    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    __unsafe_unretained Class *list = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)n);
    if (!list) return;
    n = objc_getClassList(list, n);

    /* ============================================================
     * ★★ 2026-10-17 彻底移除 NSURLSessionTask 的 error / response hook
     *
     * 为什么删（它们导致了「点进对话必崩」）：
     *   ① 这两个是 **@property getter**，必须返回有效值。
     *      我们的 wrapper 在 FindOrig 失败时 `return nil`，
     *      宿主拿到 nil 的 response ⇒ 解析响应时崩。
     *
     *   ② wrapper 里调用了 DiagReplay() —— **在 getter 里发网络请求**。
     *      getter 会被调用几十上百次（多线程、多上下文），
     *      每次非 200 就新建一个 NSURLSession 重放 ⇒ 线程风暴。
     *
     *   ③ gInReplay 是**全局变量**，多线程完全不可靠：
     *      线程 A 重放时置 YES，线程 B 的正常请求就被跳过 hook；
     *      A 结束后置 NO，而 B 还在重放 ⇒ 防护失效 ⇒ 递归。
     *
     *   收益 vs 风险：它们只用来「抓非 200 响应的正文」这种诊断功能，
     *   而我们已经有 didReceiveData（数据层）可以拿响应体。
     *   ⇒ 直接删掉，网络 hook 只保留「改请求」这一个职责。
     * ============================================================ */
    FLOGI(FC_NET, @"[net] 已跳过 error/response getter hook（历史崩溃源）");

    int done = 0;
    /* 只列我们真正会挂的（白名单命中），避免刷屏 */
    int cand = 0;
    for (int i = 0; i < n; i++) {
        const char *cn = class_getName(list[i]);
        if (cn && strstr(cn, "URLSession")) cand++;
    }
    FLOGI(FC_HOOK, @"URLSession 家族类 %d 个，白名单命中（会被挂）：", cand);
    for (int i = 0; i < n; i++) {
        const char *cn = class_getName(list[i]);
        if (cn && ClassAllowed(cn))
            FLOGI(FC_HOOK, @"   → %s", cn);
    }

    for (int i = 0; i < n; i++) {
        const char *cn = class_getName(list[i]);
        if (!ClassAllowed(cn)) continue;
        for (int s = 0; sels[s]; s++) {
            SEL sel = sel_registerName(sels[s]);
            Method m = class_getInstanceMethod(list[i], sel);
            if (!m) continue;
            IMP cur = method_getImplementation(m);
            if (cur == news[s]) continue;

            /* ★★ 关键修复：记账失败就**不装** hook。
             *   旧代码不检查返回值 ⇒ 表满后照样改 IMP，但 FindOrig 查不到
             *   ⇒ 返回 nil ⇒ 网络全废。 */
            Class owner = ClassOwningMethod(list[i], sel);   /* 方法真正定义在哪个类 */
            if (!AddHook(owner ?: list[i], sel, cur)) {
                FLOGW(FC_SYS, @"   跳过 %s -%s（记账失败）", cn, sels[s]);
                continue;
            }
            method_setImplementation(m, news[s]);
            done++;
            FLOGI(FC_SYS, @"   挂 %s -%s（定义于 %s）", cn, sels[s],
                  owner ? class_getName(owner) : "?");
        }
    }
    free(list);
    FLOGI(FC_NET, @"网络挂钩完成：%d 处（★ 每类独立原函数）", done);
}

/* ==================== 状态 ==================== */

__attribute__((unused)) static void DumpImages(void) {
    @autoreleasepool {
        NSMutableString *o = [NSMutableString string];
        int n = _dyld_image_count(), ti = 0, ek = 0;
        for (int i = 0; i < n; i++) {
            const char *nm = _dyld_get_image_name(i);
            if (!nm) continue;
            if (strstr(nm, "TweakInject")) { ti++; [o appendFormat:@"TweakInject %s\n", nm]; }
            else if (strstr(nm, "libellekit")) { ek++; [o appendFormat:@"ellekit    %s\n", nm]; }
            else if (strstr(nm, "FDMProbe")) [o appendFormat:@"★我们      %s\n", nm];
        }
        [o appendFormat:@"\nTweakInject=%d ellekit=%d\n", ti, ek];
        W(@"fdm-images.txt", [o dataUsingEncoding:NSUTF8StringEncoding]);
    }
}
static void DumpHits(void) {
    @autoreleasepool {
        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"# FDM v7.1 统计  %@\n\n", [NSDate date]];
        [o appendFormat:@"MMKV 写 serverValues : %lu\n", (unsigned long)gNMMKVWrite];
        [o appendFormat:@"MMKV 读 serverValues : %lu\n", (unsigned long)gNMMKVRead];
        [o appendFormat:@"blob 已改造          : %@\n", gLastModBlob ? @"是" : @"否"];
        [o appendFormat:@"chat 请求            : %lu\n", (unsigned long)gNReqChat];
        [o appendFormat:@"其它请求             : %lu\n", (unsigned long)gNReqOther];
        [o appendFormat:@"请求体已抓           : %@\n", gBodyDumped ? @"是 (fdm-req-raw.json)" : @"否"];
        [o appendFormat:@"提示词注入模式       : %@ (已注入 %lu 次)\n",
            gMode, (unsigned long)gNInjected];
        [o appendFormat:@"网络Hook             : %@\n", gNetHookOn?@"开":@"关"];
        [o appendFormat:@"\n覆盖表：\n"];
        for (NSString *k in gPatch) [o appendFormat:@"  %@ = %@\n", k, gPatch[k]];
        W(@"fdm-hits.txt", [o dataUsingEncoding:NSUTF8StringEncoding]);
    }
}

/* ==================== 入口 ==================== */

/* ==================== 热生效：配置变更后重算 ==================== */
void FDMReloadFromConfig(void) {
    @autoreleasepool {
        gPatch = FDMPatchTable();
        gAllowNewKeys = [[FDMConfig shared] boolFor:G_QUICK key:@"add_unknown_keys"];
        /* 覆盖表变了 → 清掉已改造缓存，下次写入时重新打补丁 */
        gLastOrigBlob = nil;
        gLastModBlob = nil;

        NSString *m = nil, *t = nil; BOOL en = NO;
        FDMInjectConfig(&m, &t, &en);
        gMode = m; gInjectText = t; gInjectOn = en;

        /* ★ 富文本引擎的缓存也要跟着刷新（模板池/色板可能被改了） */
        {
            extern void FDMRichTextReload(void);
            FDMRichTextReload();
        }
        FLOGI(FC_CFG, @"★ 已热重载：覆盖表 %lu 项 | 模式 %@ | 文本 %lu 字",
              (unsigned long)gPatch.count, gMode, (unsigned long)gInjectText.length);
        FLOGI(FC_CFG, @"   下次写入 blob 时自动应用新覆盖表");
    }
}

/* ============================================================
 * ★★ v9.0：改成「安全构造 + 延迟初始化」
 *
 * 原因：v8.x 的构造函数里直接玩 Foundation（NSSearchPath / NSLock / NSMutableArray）。
 *   这在 TrollFools 模式下没事（它是启动后 2s 才 dlopen，ObjC 早就绪了），
 *   但改用 ElleKit / TweakInject 注入后，构造函数会在 **dyld 初始化阶段** 跑，
 *   那时 ObjC runtime 还没完全起来 ⇒ 崩（本项目 v0.2 就是这么死的）。
 *
 * 所以：构造函数里只做一件事 —— 调度一个延迟块。
 *   真正的初始化在 fdm_real_init() 里，等主队列跑起来再执行。
 * ============================================================ */

static void fdm_real_init(void);

/* ★★★ MMKV hook 必须**最早**装（2026-10-17 P3 教训）
 *
 *   之前 HookMMKV 排在 fdm_real_init 之后 0.3s，而 fdm_real_init 本身
 *   又延迟了 3.5s ⇒ 实际 3.8s 才装。
 *   但宿主 **启动 1 秒内**就把 currentUser 读进内存了 ⇒ 我们的改写
 *   永远追不上 ⇒ 账号名改不动。
 *
 *   ⇒ 单独开辟一条「快速通道」：构造函数里立刻调度一个 0s 块，
 *     只做一件事 —— 挂 MMKV hook。
 *     MMKV 类在宿主进程里很早就存在（它是被 App 动态加载的），
 *     所以这里能挂上；挂不上就等下一次重试，绝不崩。
 *
 *   ⚠️ 为什么敢这么早：HookMMKV 只调用 objc 运行时接口
 *     （objc_getClass / method_setImplementation），
 *     不碰 NSFileManager / NSLog 之类 —— dyld 阶段之后是安全的。
 */
static void fdm_early_mmkv(void) {
    @autoreleasepool {
        extern void HookMMKV(void);
        @try {
            HookMMKV();
        } @catch (NSException *e) { }
    }
}

/* ============================================================
 * ★★★ 2026-10-17 深夜 · 极早期防重（比 FDMInitGuard 更早）
 *
 *   场景：用户可能**同时**存在两份模块
 *     · TrollFools 注入到 App bundle/Frameworks/FDM.dylib
 *     · ElleKit 注入 /var/jb/usr/lib/TweakInject/FDM.dylib
 *   两份都会被 dyld 加载，构造函数各跑一次。
 *
 *   FDMInitGuard 那个类锁要等 3.5 秒的 fdm_real_init 才生效，
 *   在那之前 **fdm_early_mmkv（0 秒）会跑两遍** —— MMKV 的 hook
 *   重复挂虽然被 Swap 的幂等检查挡住，但不必要的重入还是有风险。
 *
 *   ⇒ 在构造函数里就设一个**纯 C 的原子标志**（不碰任何 Foundation），
 *     第二个进来的直接 return。
 * ============================================================ */
static volatile int g_fdm_ctor_claimed = 0;

__attribute__((constructor))
static void fdm_init(void) {
    /* 纯 C 的原子抢占：谁先到谁干活，后来的立刻退出 */
    if (__sync_lock_test_and_set(&g_fdm_ctor_claimed, 1)) {
        return;                      /* 另一份已经在跑了 */
    }
    /* ★★ 2026-10-23 架构调整（主人指出）：
     *   宿主创建 UI **之前**就要把 hook 装好，否则「注入前就存在」的
     *   按钮永远拿不到玻璃（实际上根本没有"注入前"—— 我们只是拖到 6s 才装）。
     *
     *   ⚠️ 这里只能做**纯 runtime 的 swizzle**，绝不能碰 Foundation：
     *      FDMGlassEarlyInstall 内部只用 objc_getClass / method_setImplementation
     *      / C 数组，dyld 阶段就可用。业务逻辑全部延后到 6s 之后。
     *
     *   也不能用 dispatch_after(0)：那要等主队列跑起来，比宿主建 UI 晚。 */
    {
        extern void FDMGlassEarlyInstall(void);
        FDMGlassEarlyInstall();
    }

    /* ⚠️ 这里绝对不碰 Foundation / ObjC / NSLog —— 只注册延迟块 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0), dispatch_get_main_queue(), ^{
        fdm_early_mmkv();
    });
    /* ★ 3.5s：宿主自己启动大概要 2~3s，我们要**排在它后面**，
     *   不然两边抢 CPU/内存，watchdog 会认为启动超时直接杀进程（不留崩溃日志）。 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        fdm_real_init();
    });
}

static void fdm_real_init(void) {
    @autoreleasepool {
        /* ★ 防重复加载：同一份代码可能被两条路注入
         *   （TrollFools 的 fdm-hot.dylib + ElleKit 的 TweakInject/FDM.dylib）
         *   用一个全局 ObjC 类名做「进程内唯一」的锁：
         *   谁先注册上，后来的那个就安静退出。 */
        {
            extern Class objc_allocateClassPair(Class, const char *, size_t);
            extern void objc_registerClassPair(Class);
            if (NSClassFromString(@"FDMInitGuard")) {
                return;                      /* 别的副本已经初始化过了 */
            }
            Class g = objc_allocateClassPair([NSObject class], "FDMInitGuard", 0);
            if (g) objc_registerClassPair(g);
            /* 注册失败也继续（说明极端情况，宁可多跑一次也别不跑） */
        }

        NSArray *ds = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        gDir = [ds firstObject] ?: NSTemporaryDirectory();
        gBufLock = [NSLock new];
        gBuf = [NSMutableArray array];

        /* ★ 日志框架（自带刷盘 + 崩溃处理） */
        FLogInit();
        /* ★ 日志级别从配置读，默认 W（只记警告/错误）
         *   D 级会上万行，启动期写日志本身就吃 CPU，是「启动超时」的帮凶之一 */
        {
            FLogLevel lv = FLogLevelWarn;
            NSString *lvS = nil;
            @try {
                NSString *dp = [gDir stringByAppendingPathComponent:@"fdm-debug.json"];
                NSData *dd = [NSData dataWithContentsOfFile:dp];
                if (dd) {
                    id j = [NSJSONSerialization JSONObjectWithData:dd options:0 error:nil];
                    if ([j isKindOfClass:[NSDictionary class]]) {
                        id v = ((NSDictionary *)j)[@"log_level"];
                        if ([v isKindOfClass:[NSString class]]) lvS = v;
                    }
                }
            } @catch (NSException *e) { }
            if ([lvS isEqualToString:@"E"])      lv = FLogLevelError;
            else if ([lvS isEqualToString:@"W"]) lv = FLogLevelWarn;
            else if ([lvS isEqualToString:@"I"]) lv = FLogLevelInfo;
            else if ([lvS isEqualToString:@"D"]) lv = FLogLevelDebug;
            else if ([lvS isEqualToString:@"T"]) lv = FLogLevelTrace;
            FLogSetLevel(lv);
        }

        /* ★ 注册全部功能（必须在 LoadConfig 之前） */
        FDMFeaturesRegister();

        /* ★ 热生效：配置一改，重新算覆盖表 */
        [[FDMConfig shared] addObserver:(id)@1 block:^(NSString *gid) {
            extern void FDMReloadFromConfig(void);
            FDMReloadFromConfig();

            /* ★ 背景相关配置一改，立即重贴（不用重启） */
            if ([gid isEqualToString:P_BG]) {
                extern void FDMBeautyForceRefresh(void);
                dispatch_async(dispatch_get_main_queue(), ^{
                    FDMBeautyForceRefresh();
                });
            }
            /* 字号档位改了也要提示重启（MMKV 那条路必须重启） */
            if ([gid isEqualToString:P_RICH]) {
                extern BOOL FDMApplyFontLevel(void);
                FDMApplyFontLevel();
            }

            /* ★ 2026-10-23 新增四组 + 玻璃：改完立刻生效 */
            if ([gid isEqualToString:P_ASSIST]) {
                extern void FDMAssistantReload(void);
                dispatch_async(dispatch_get_main_queue(), ^{ FDMAssistantReload(); });
            }
            if ([gid isEqualToString:P_BUBBLE]) {
                extern void FDMBubbleReload(void);
                dispatch_async(dispatch_get_main_queue(), ^{ FDMBubbleReload(); });
            }
            if ([gid isEqualToString:P_FILECARD]) {
                extern void FDMFileCardReload(void);
                dispatch_async(dispatch_get_main_queue(), ^{ FDMFileCardReload(); });
            }
            if ([gid isEqualToString:P_NOTE]) {
                extern void FDMNoteReload(void);
                dispatch_async(dispatch_get_main_queue(), ^{ FDMNoteReload(); });
            }
            if ([gid isEqualToString:P_GLASS]) {
                extern void FDMGlassReloadConfig(void);
                dispatch_async(dispatch_get_main_queue(), ^{ FDMGlassReloadConfig(); });
            }
        }];
        #if DEBUG
        FLogSetMirrorNSLog(YES);
        #endif

        FLOGI(FC_SYS, @" ");
        FLOGI(FC_SYS, @"==================== 启动 ====================");
        FLOGI(FC_SYS, @"FDM v7.1 已加载  pid=%d", (int)getpid());
        FLOGI(FC_SYS, @"构建时间: %s %s", __DATE__, __TIME__);
        FLOGI(FC_SYS, @"日志文件: %@", FLogPath());
        FLOGI(FC_SYS, @"bundle: %@", [[NSBundle mainBundle] bundleIdentifier]);
        FLOGI(FC_SYS, @"系统: %@", [[UIDevice currentDevice] systemVersion]);
        FLOGI(FC_SYS, @"设备: %@", [[UIDevice currentDevice] model]);

        LoadConfig();

        /* ★★ 错峰：这两个 hook 都要遍历所有类（5 万+），很吃 CPU。
         *   第一版直接在 fdm_real_init 里同步跑 ⇒ 主线程被占住 ⇒
         *   宿主启动没完成 ⇒ watchdog 杀进程（不留崩溃日志，特别难查）。 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                HookMMKV();
                FLOGI(FC_MMKV, @"MMKV hook 完成");
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                HookNet();
                FLOGI(FC_NET, @"Net hook 完成");
            }
        });

        /* ★ 安装美化功能（聊天背景 / 富文本样式），同样轮询 */
        {
            extern int FDMBeautyInstallRetry(int attempt);
            __block int bt = 0;
            /* ★ 用主队列：FDMBeautyInstall 要做 swizzling + UI，后台跑会死 */
            dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                dispatch_get_main_queue());
            dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 6ull*NSEC_PER_SEC),
                                      3ull*NSEC_PER_SEC, 0);
            dispatch_source_set_event_handler(t, ^{
                @autoreleasepool {
                    bt++;
                    int ok = FDMBeautyInstallRetry(bt);
                    if (ok || bt >= 10) {
                        L(@"FDMBeauty: 第 %d 次尝试 → %@", bt, ok ? @"完成" : @"放弃");
                        dispatch_source_cancel(t);
                    }
                }
            });
            dispatch_resume(t);
        }

        /* ★ 安装「我的」页入口：轮询重试，等 Swift 类 realize */
        {
            extern int FDMUIInstallRetry(int attempt);
            __block int try_n = 0;
            dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                dispatch_get_main_queue());
            dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 4ull*NSEC_PER_SEC),
                                      2ull*NSEC_PER_SEC, 0);
            dispatch_source_set_event_handler(t, ^{
                @autoreleasepool {
                    try_n++;
                    int ok = FDMUIInstallRetry(try_n);
                    if (ok || try_n >= 15) {
                        FLOGI(FC_SYS, @"FDMUI: 第 %d 次尝试 → %@", try_n, ok ? @"成功" : @"放弃");
                        dispatch_source_cancel(t);
                    }
                }
            });
            dispatch_resume(t);
        }
        /* ★ X 光机 / 抹除：延到 12s，且错峰成两步
         *   xray 默认关闭（配置里 xray=false 时不 dump） */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                extern void FDMStripSetEnabled(BOOL, BOOL);
                extern int  FDMStripInstall(void);
                extern void FDMRichTextInstall(void);
                extern void FDMUserMetaInstall(void);
                extern void FDMComposerInstall(void);
                /* ★ 音乐加密层：不联网也能自检（MD5/AES/Base64/RSA 与 Java 版逐字节对拍）
                 *   放在 6s 而不是构造函数里 —— 构造函数里碰 Foundation 会死在 dyld 阶段。 */
                {
                    extern void FDMMusicCryptoInstall(void);
                    extern void FDMPromptVarsInstall(void);
                    extern void FDMLyricInstall(void);
                    extern void FDMMusicNetworkProbeIfEnabled(void);
                    FDMMusicCryptoInstall();
                    FDMPromptVarsInstall();
                    FDMLyricInstall();
                    FDMMusicNetworkProbeIfEnabled();

                    /* ★ 音乐播放器（2026-10-24 · 全在宿主进程内跑 AVPlayer）
                     *
                     *   · 内核 FDMMusicModel.c 自检 47 条，不过就整个不启用
                     *   · 存档 Documents/FDMmusic/state.json（只有事实性元数据）
                     *   · 迷你卡挂在宿主 window 上；开关在 Documents/fdm-music.json 的 mini_on
                     *   · 装完把「此刻在听什么」注册给 {music}/{lyric} 变量引擎
                     *     （变量引擎早就移植好了，一直没人给它供数 —— 这里补上）
                     *
                     *   ⚠️ 版权：音频流式播放不落盘 / 封面只内存 / 歌词只内存。 */
                    extern void FDMMusicInstall(void);
                    FDMMusicInstall();

                    /* ★ 网易云登录（2026-10-25）
                     *   · 纯函数自检 12 条（cookie 三种形态 / md5）
                     *   · 从 Documents/FDMmusic/login.json 恢复凭证并注入 Api
                     *   · 必须在 FDMMusicInstall 之后（那边已经 init 完队列）
                     *   ⚠️ 明文存储，界面上必须告知用户；文件已排除 iCloud 备份 */
                    extern void FDMMusicLoginInstall(void);
                    FDMMusicLoginInstall();

                    /* ★ 卡片式系统提示词 v2（2026-10-25）
                     *   内核 FDMPromptCard.c 纯 C，启动就跑 42 条断言 ——
                     *   和音乐/便签同一套做法：**先自证，再让用户碰**。
                     *   真机上只要看到「[spv2] 内核自检 42 条全过」就说明
                     *   「拖卡片重建提示词」这套逻辑一定是对的。 */
                    {
                        extern int fdmpc_selftest(char *errbuf, int errlen);
                        char perr[512] = {0};
                        int pbad = fdmpc_selftest(perr, sizeof(perr));
                        if (pbad) {
                            FLOGE(FC_CFG, @"[spv2] ✗ 内核自检失败 #%d：%s ⇒ 卡片页面禁用",
                                  pbad, perr);
                        } else {
                            FLOGI(FC_CFG, @"[spv2] 内核自检 47 条全过"
                                          @"（搬/复制/重排/归一化/坏存档）");
                        }
                    }

                    /* ★ 液态玻璃（iOS 26 以下自合成 + 性能分级）
                     *   Install 自己读 Documents/fdm-debug.json 的
                     *     glass_on   （默认 YES —— 主人要的是"强开"）
                     *     glass_tier （-1 自动 / 0 关 / 1 高光 / 2 模糊+ / 3 折射 / 4 原生）
                     *   关掉就一条 hook 都不下。 */
                    extern void FDMGlassInstall(void);
                    FDMGlassInstall();

                    /* ★ 美化页剩余四项（2026-10-23）
                     *   assistant  修改助手图片
                     *   bubble     对话气泡设置
                     *   filecard   文件快捷选项
                     *   note       悬浮便签
                     * 全部自己判断开关，关着就只打一行日志。 */
                    {
                        extern void FDMAssistantInstall(void);
                        extern void FDMBubbleInstall(void);
                        extern void FDMFileCardInstall(void);
                        extern void FDMNoteInstall(void);
                        FDMAssistantInstall();
                        FDMBubbleInstall();
                        FDMFileCardInstall();
                        FDMNoteInstall();

                        /* ★★ 2026-10-23 气泡纯诊断（只读不写）
                         *   上一轮 12 个版本全跪，根因是「没先 dump 就动手」。
                         *   这个开关独立于气泡功能，diag=true 才装，
                         *   只 hook layoutSubviews 把几何写进 fdm-bubble-geom.txt。 */
                        extern void FDMBubbleDiagInstall(void);
                        FDMBubbleDiagInstall();

                        /* ★ 2026-10-24 宿主升到 2.7.1，Swift 类名全被剥离
                         *   （_TtC13DeepSeek_Chat: 534 → 0）
                         *   ⇒ 气泡/助手图片的锚点需要重新测绘。*/
                        extern void FDMMap271Install(void);
                        FDMMap271Install();
                    }
                }
                FLOGW(FC_HOOK, @"[init] 6s: 开始装 strip");
                FDMRichTextInstall();      /* ★ 富文本引擎：先备好缓存再装 hook */
                FDMUserMetaInstall();      /* ★ 账号名/头像改写 */
                FDMComposerInstall();      /* ★ 模块发消息 */
                FDMStripInstall();
                FLOGW(FC_HOOK, @"[init] 6s: strip 装完");
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                extern void FDMXrayDumpClasses(void);
                extern void FDMXrayInstall(void);
                FDMXrayDumpClasses();      /* 内部会检查开关，关着就直接返回 */
                FDMXrayInstall();
                FLOGW(FC_HOOK, @"[init] 12s: xray 处理完");
            }
        });

        /* ★ 视图树逆向：20s / 40s 各 dump 一次（覆盖首页 + 进对话后） */
        {
            extern id FDMProbeReadDebugBool(NSString *k, BOOL d);
            extern void FDMUITreeDump(NSString *reason);
            BOOL want = [FDMProbeReadDebugBool(@"uitree", NO) boolValue];
            if (want) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @autoreleasepool { FDMUITreeDump(@"t20-首页"); }
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @autoreleasepool { FDMUITreeDump(@"t40-进对话后"); }
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(70 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @autoreleasepool { FDMUITreeDump(@"t70"); }
                });
                FLOGW(FC_UI, @"[uitree] 已安排在 20s / 40s / 70s dump 视图树");
            }
        }

        /* ★★ 2026-10-25 自动截图（改 UI 树专用）
         *   入口在「调试 → 📸 自动截图」，开关存在 fdm-debug.json。
         *   ⚠️ 隐私三件套：
         *     ① 默认关（字段默认 NO）
         *     ② 拍完**立刻把开关写回 NO** —— 只跑一轮，不会次次弹
         *     ③ 开跑前先删掉上一轮的 fdm-ui-*.png（不攒聊天截图）
         */
        {
            extern void FDMUIAutoShotBegin(NSString *gid);
            extern void FDMUIAutoShotPush(NSString *gid);
            extern void FDMUIAutoShotCapture(NSString *name);
            extern void FDMUIAutoShotEnd(void);

            FDMConfig *cfg = [FDMConfig shared];
            BOOL shot = [cfg boolFor:P_DEBUG key:@"ui_auto_shot"];
            if (shot) {
                /* ---- ② 先关开关：即使后面崩了，也不会下次再弹 ---- */
                [cfg setValueQuietly:@NO for:P_DEBUG key:@"ui_auto_shot"];

                /* ---- ③ 清上一轮旧图 ---- */
                {
                    NSFileManager *fm = [NSFileManager defaultManager];
                    NSUInteger n = 0;
                    for (NSString *f in [fm contentsOfDirectoryAtPath:gDir error:nil]) {
                        if ([f hasPrefix:@"fdm-ui-"] && [f hasSuffix:@".png"]) {
                            if ([fm removeItemAtPath:
                                 [gDir stringByAppendingPathComponent:f] error:nil]) n++;
                        }
                    }
                    if (n) FLOGI(FC_UI, @"[autoshot] 已清掉上一轮 %lu 张旧图",
                                 (unsigned long)n);
                }

                NSString *list = [cfg stringFor:P_DEBUG key:@"ui_auto_shot_pages"];
                NSMutableArray<NSString *> *pages = [NSMutableArray array];
                if ([list isKindOfClass:[NSString class]] && list.length) {
                    for (NSString *s in [list componentsSeparatedByString:@","]) {
                        NSString *t = [s stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceCharacterSet]];
                        if (t.length) [pages addObject:t];
                    }
                }

                FLOGW(FC_UI, @"[autoshot] ★ 开关已自动关回；本轮拍 首页 + %lu 个子页",
                      (unsigned long)pages.count);

                /* 首页：18s（等宿主自己的首屏动画收尾） */
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(18 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @autoreleasepool {
                        FDMUIAutoShotBegin(nil);
                        /* present 是异步的，给它 1.2s 落定再拍 */
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            FDMUIAutoShotCapture(@"01-首页");
                        });
                    }
                });

                /* 子页：从 21s 起，每页 3s 一个（进入 → 等 0.8s → 拍） */
                for (NSUInteger i = 0; i < pages.count; i++) {
                    NSString *gid = pages[i];
                    int64_t at = (int64_t)((21 + i * 3) * NSEC_PER_SEC);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, at),
                                   dispatch_get_main_queue(), ^{
                        @autoreleasepool {
                            FDMUIAutoShotPush(gid);
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                         (int64_t)(0.8 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                FDMUIAutoShotCapture([NSString stringWithFormat:
                                    @"%02lu-%@", (unsigned long)(i + 2), gid]);
                            });
                            /* ★ 再给 0.6s，滚到底补拍一张（页长超一屏时必需） */
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                         (int64_t)(1.4 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                extern void FDMUIAutoShotCaptureTail(NSString *name);
                                FDMUIAutoShotCaptureTail([NSString stringWithFormat:
                                    @"%02lu-%@", (unsigned long)(i + 2), gid]);
                            });
                        }
                    });
                }

                /* 收场 */
                int64_t endAt = (int64_t)((24 + pages.count * 3) * NSEC_PER_SEC);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, endAt),
                               dispatch_get_main_queue(), ^{
                    @autoreleasepool { FDMUIAutoShotEnd(); }
                });
            }
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45*NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            DumpHits(); FLOGI(FC_MMKV, @"45s：MMKV写%lu 读%lu | chat%lu 其它%lu | 注入%lu",
                          (unsigned long)gNMMKVWrite, (unsigned long)gNMMKVRead,
                          (unsigned long)gNReqChat, (unsigned long)gNReqOther,
                          (unsigned long)gNInjected);
            {
                extern int FDMStripDisplayCount(void);
                extern int gNDataHits;
                FLOGI(FC_MMKV, @"[strip] 显示层抹除命中 %d 次 | Data %d 次",
                      FDMStripDisplayCount(), gNDataHits);
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120*NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            DumpHits(); FlushBuf(); FLOGI(FC_SYS, @"=== v0.7 结束 ===");
        });
    }
}
