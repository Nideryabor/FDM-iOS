// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMMusicApi.m —— 见 FDMMusicApi.h
#ifdef __cplusplus
extern "C" {
#endif
#include "FDMMusicCrypto.h"
#ifdef __cplusplus
}
#endif

#include <stdlib.h>

#import "FDMMusicApi.h"
#include "FDMMusicCrypto.h"
#import "FLog.h"

@interface FDMMusicApi ()
+ (void)postEapi:(NSString *)uri
            json:(NSString *)json
      completion:(void (^)(NSDictionary *r, NSError *e))completion;
+ (void)postWeapi:(NSString *)uri
             json:(NSString *)json
       completion:(void (^)(NSDictionary *r, NSError *e))completion;
/// 上一次响应的 Set-Cookie（登录后从中取 MUSIC_U；Java 版同名）
+ (NSString *)lastSetCookie;
@end

#pragma mark - 启动探针（受开关控制，默认关）

/**
 * 读 Debug 开关（与 FDMProbe.m 里同款：Documents/fdm-*.txt 或配置树）。
 * 声明成 extern 而不是 include FDMProbe.h —— 那边是一坨 C 函数，没必要拉进来。
 */
extern id FDMProbeReadDebugBool(NSString *k, BOOL d);

/**
 * 真机网络自检：开关 `music_probe` 打开时，启动后打一次真实搜索。
 * 默认关 —— 正常情况下不该让模块自己往网易云发请求。
 *   echo 1 > Documents/fdm-music-probe.txt
 */
void FDMMusicNetworkProbeIfEnabled(void) {
    BOOL on = NO;
    @try {
        on = [FDMProbeReadDebugBool(@"music_probe", NO) boolValue];
    } @catch (NSException *e) {
        on = NO;
    }
    if (!on) {
        FLOGD(FC_MUSIC, @"[music] 网络自检未开启（music_probe=0）");
        return;
    }
    [FDMMusicApi networkSelfTest:nil];
}

/* ══════════════════════════════════════════════════════════════════════════
 *  常量（与 Java 版 GmMusicApi 逐字一致）
 * ══════════════════════════════════════════════════════════════════════════ */

static NSString *const kApiDomain = @"https://interface.music.163.com";
static NSString *const kDomain    = @"https://music.163.com";

static const NSTimeInterval kTimeout = 12.0;

static FDMMusicOsMode gOsMode = FDMMusicOsModeIPhone;
static NSString *gMusicU = @"";
static NSString *gMusicA = @"";
static NSInteger gLastCode = -1;
static NSString *gDeviceId = nil;      /* 一次进程内固定 */
static NSString *gSetCookie = @"";     /* 上一次响应的 Set-Cookie */

static NSInteger gSeq = 1;

#pragma mark - JSON 手工拼装（要顺序可控，不依赖 NSDictionary 的遍历顺序）

/** 按 GmMusicJson.quote() 的规则转义（含 \" \\ \n \r \t \b \f 与控制字符）。 */
static NSString *FDMMusicJSONQuote(NSString *s) {
    if (!s) s = @"";
    NSMutableString *o = [NSMutableString stringWithCapacity:s.length + 2];
    [o appendString:@"\""];
    NSUInteger n = s.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '"':  [o appendString:@"\\\""]; break;
            case '\\': [o appendString:@"\\\\"]; break;
            case '\n': [o appendString:@"\\n"];  break;
            case '\r': [o appendString:@"\\r"];  break;
            case '\t': [o appendString:@"\\t"];  break;
            case '\b': [o appendString:@"\\b"];  break;
            case '\f': [o appendString:@"\\f"];  break;
            default:
                if (c < 0x20) [o appendFormat:@"\\u%04x", (unsigned)c];
                else [o appendFormat:@"%C", c];
                break;
        }
    }
    [o appendString:@"\""];
    return o;
}

/** encodeURIComponent 等价（Java 版用的就是它）。 */
static NSString *FDMUrlEnc(NSString *s) {
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
                   @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
                   @"0123456789-_.!~*'()"];
    });
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: s;
}

#pragma mark - 客户端伪装

static NSString *FDMOSName(void) {
    switch (gOsMode) {
        case FDMMusicOsModePC:      return @"pc";
        case FDMMusicOsModeAndroid: return @"android";
        default:                    return @"iPhone OS";
    }
}

static NSString *FDMOSVer(void) {
    switch (gOsMode) {
        case FDMMusicOsModePC:      return @"Microsoft-Windows-10-Professional-build-19045-64bit";
        case FDMMusicOsModeAndroid: return @"14";
        default:                    return @"16.2";
    }
}

static NSString *FDMOSAppVer(void) {
    switch (gOsMode) {
        case FDMMusicOsModePC:      return @"3.1.17.204416";
        case FDMMusicOsModeAndroid: return @"8.20.20.231215173437";
        default:                    return @"9.0.90";
    }
}

static NSString *FDMOSChannel(void) {
    switch (gOsMode) {
        case FDMMusicOsModePC:      return @"netease";
        case FDMMusicOsModeAndroid: return @"xiaomi";
        default:                    return @"distribution";
    }
}

static NSString *FDMOSUA(void) {
    switch (gOsMode) {
        case FDMMusicOsModePC:
            return @"Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36"
                   @" (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164"
                   @" NeteaseMusicDesktop/3.0.18.203152";
        case FDMMusicOsModeAndroid:
            return @"NeteaseMusic/9.1.65.240927161425(9001065);Dalvik/2.1.0"
                   @" (Linux; U; Android 14; 23013RK75C Build/UKQ1.230804.001)";
        default:
            return @"NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)";
    }
}

static NSString *FDMWeapiUA(void) {
    return @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
           @" (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0";
}

#pragma mark - 工具

static NSString *FDMDeviceId(void) {
    if (gDeviceId) return gDeviceId;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gDeviceId = [[[NSUUID UUID] UUIDString]
                     stringByReplacingOccurrencesOfString:@"-" withString:@""];
    });
    return gDeviceId;
}

static NSString *FDMRequestId(void) {
    long long ms = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    NSInteger seq = gSeq++;
    if (gSeq > 10000) gSeq = 1;
    return [NSString stringWithFormat:@"%lld_%04ld", ms, (long)(seq % 10000)];
}

/**
 * ★ ATS 生存指南：宿主 Info.plist 是 `NSAllowsArbitraryLoads = false`，
 *   而网易云返回的播放地址是 **http 协议** ⇒ AVPlayer / UIImage 都会被 ATS 拦掉。
 *   实测（2026-10-23）同一路径换成 https 照样 206 + audio/mpeg ⇒ 直接换协议最省事，
 *   不用改宿主 plist（改 plist 会破坏签名，TrollFools 注入也白搭）。
 */
static NSString *FDMPreferHTTPS(NSString *url) {
    if (![url isKindOfClass:[NSString class]] || !url.length) return url;
    if ([url hasPrefix:@"http://"]) {
        return [@"https://" stringByAppendingString:[url substringFromIndex:7]];
    }
    return url;
}

static NSString *FDMBrief(NSString *s) {
    if (!s) return @"";
    if (s.length <= 400) return s;
    return [[s substringToIndex:400] stringByAppendingString:@"…"];
}

static inline void FDMDeliverMain(dispatch_block_t blk) {
    if (!blk) return;
    if ([NSThread isMainThread]) blk();
    else dispatch_async(dispatch_get_main_queue(), blk);
}

static NSError *FDMErr(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:@"FDMMusicApi"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"unknown"}];
}

/** 从 NSDictionary 里稳妥取数（NSJSONSerialization 把数字都给成 NSNumber） */
static long long FDMNum(id v, long long def) {
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v longLongValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v longLongValue];
    return def;
}

static NSString *FDMStr(id v, NSString *def) {
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return def;
}

#pragma mark - 底层请求

/**
 * POST 文本体。
 * @param extraCookie 已经组装好的 "k=v; k=v"（可为空）
 */
/* ============================================================
 * 手动跟随重定向的 POST
 *
 * ★★ 为什么必须自己跟（2026-10-25 · 照抄安卓 2026-10-06 的血泪）：
 *   网易云登录接口经常先回 **302**，而 `Set-Cookie: MUSIC_U=…`
 *   就在**那一跳**上。NSURLSession 默认自动跟随重定向 ⇒
 *   我们只拿得到**最终响应**的头 ⇒ **凭证抓不到**。
 *   症状特别坑：界面提示"登录成功"，其实什么都没存上，下次照样没登录。
 *
 *   ⇒ HTTPShouldSetCookies=NO + HTTPCookieAcceptPolicyNever（别污染宿主的池）
 *     + delegate 里手动接 willPerformHTTPRedirection，每一跳都攒 Set-Cookie。
 * ============================================================ */

/** 把一份响应头里的 Set-Cookie 全抓出来，塞进罐子（每条一行）。 */
static void FDMHarvestCookies(NSDictionary *headers, NSURL *url, NSMutableString *jar) {
    if (!jar || ![headers isKindOfClass:[NSDictionary class]]) return;
    @try {
        /* ★ 用 NSHTTPCookie 解析，别自己 split —— allHeaderFields 会把多个
         *   Set-Cookie 合并成一行逗号分隔，手拆必错。 */
        NSArray<NSHTTPCookie *> *cks =
            [NSHTTPCookie cookiesWithResponseHeaderFields:headers
                                                   forURL:url ?: [NSURL URLWithString:@"https://music.163.com"]];
        for (NSHTTPCookie *ck in cks) {
            if (!ck.name.length) continue;
            [jar appendFormat:@"%@=%@\n", ck.name, ck.value ?: @""];
            FLOGD(FC_MUSIC, @"[login] 收到 cookie：%@（%lu 字符）",
                  ck.name, (unsigned long)(ck.value ?: @"").length);
        }
    } @catch (NSException *e) { }
}

@interface FDMRedirectPoster : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, strong) NSMutableString *jar;      /* 累积的 Set-Cookie */
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic) NSInteger hops;
@property (nonatomic) BOOL finished;
@end

@implementation FDMRedirectPoster

- (void)dealloc {
    @try { [_session invalidateAndCancel]; } @catch (NSException *e) { }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    /* ① 先把这一跳的 Set-Cookie 收进罐子（★ 这就是 MUSIC_U 的藏身处） */
    FDMHarvestCookies([response allHeaderFields], response.URL, self.jar);

    /* ② 最多跟 5 跳，防死循环 */
    self.hops++;
    if (self.hops > 5) {
        FLOGW(FC_MUSIC, @"[login] 重定向超过 5 跳，停");
        completionHandler(nil);          /* nil = 不跟随 */
        return;
    }

    NSMutableURLRequest *nr = [request mutableCopy];
    /* ③ 重定向后的请求默认会丢 UA，补回来（服务端会按 UA 判客户端） */
    [nr setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
                  " (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0"
       forHTTPHeaderField:@"User-Agent"];
    completionHandler(nr);
}

- (void)stop {
    if (_session) {
        @try { [_session invalidateAndCancel]; } @catch (NSException *e) { }
        _session = nil;
    }
}

@end

/* 带重定向跟随的 POST。done 里的 jar 是**逐跳累积**的 Set-Cookie。 */
static void FDMPostFollow(NSString *url, NSString *body, NSString *contentType,
                          NSString *cookie, NSString *ua,
                          void (^done)(NSString *raw, long status,
                                       NSString *jar, NSError *err)) {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) {
        done(nil, 0, @"", FDMErr(-1, [NSString stringWithFormat:@"URL 非法: %@", url]));
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u
                                                      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                  timeoutInterval:kTimeout];
    req.HTTPMethod = @"POST";
    [req setValue:contentType forHTTPHeaderField:@"Content-Type"];
    [req setValue:ua forHTTPHeaderField:@"User-Agent"];
    if (cookie.length) [req setValue:cookie forHTTPHeaderField:@"Cookie"];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = kTimeout;
    cfg.timeoutIntervalForResource = kTimeout * 2;
    cfg.HTTPShouldSetCookies = NO;                       /* ★ 手动管理 */
    cfg.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;

    FDMRedirectPoster *poster = [FDMRedirectPoster new];
    poster.jar = [NSMutableString string];
    poster.hops = 0;

    /* ★ 必须用 delegate 版 session，否则 willPerformHTTPRedirection 不会被调 */
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg
                                                        delegate:poster
                                                   delegateQueue:nil];
    poster.session = session;

    NSURLSessionDataTask *task =
        [session dataTaskWithRequest:req
                   completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        long status = 0;
        NSString *jar = poster.jar ?: @"";
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *hr = (NSHTTPURLResponse *)resp;
            status = (long)hr.statusCode;
            /* 最终那一跳的头也收一遍（302 跟完之后通常是 200，这里一般没 cookie，
             * 但有的接口是 200 直接 Set-Cookie，比如直登成功） */
            NSMutableString *tmp = [jar mutableCopy];
            FDMHarvestCookies([hr allHeaderFields], hr.URL, tmp);
            jar = tmp;
        }

        NSString *raw = nil;
        if (data.length) raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!raw && data.length)
            raw = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];

        if (jar.length) gSetCookie = jar;
        if (!poster.finished) poster.finished = YES;
        done(raw, status, jar, err);
        [poster stop];
    }];
    [task resume];
}

/** 从 `name=1\nname2=2` 这种罐子里挑一个值（和安卓 pickCookie 同语义）。 */
static NSString *FDMPickCookie(NSString *jar, NSString *name) {
    if (!jar.length || !name.length) return @"";
    for (NSString *line in [jar componentsSeparatedByString:@"\n"]) {
        /* 兼容 "k=v; Path=/; ..." 这种整条 Set-Cookie 原文 */
        for (NSString *seg in [line componentsSeparatedByString:@";"]) {
            NSString *s = [seg stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSRange eq = [s rangeOfString:@"="];
            if (eq.location == NSNotFound || eq.location == 0) continue;
            NSString *k = [[s substringToIndex:eq.location]
                           stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([k isEqualToString:name]) {
                return [[s substringFromIndex:eq.location + 1]
                        stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
        }
    }
    return @"";
}

static void FDMPost(NSString *url, NSString *body, NSString *contentType,
                    NSString *cookie, NSString *ua,
                    void (^done)(NSString *raw, long status, NSError *err)) {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) {
        done(nil, 0, FDMErr(-1, [NSString stringWithFormat:@"URL 非法: %@", url]));
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u
                                                      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                  timeoutInterval:kTimeout];
    req.HTTPMethod = @"POST";
    [req setValue:contentType forHTTPHeaderField:@"Content-Type"];
    [req setValue:ua forHTTPHeaderField:@"User-Agent"];
    if (cookie.length) [req setValue:cookie forHTTPHeaderField:@"Cookie"];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = kTimeout;
    cfg.timeoutIntervalForResource = kTimeout * 2;
    cfg.HTTPShouldSetCookies = NO;            /* 手动管理，避免被 shared 池污染 */
    cfg.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDataTask *task =
        [session dataTaskWithRequest:req
                   completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            long status = 0;
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
                NSHTTPURLResponse *hr = (NSHTTPURLResponse *)resp;
                status = (long)hr.statusCode;
                NSDictionary *hd = [hr allHeaderFields];
                NSString *sc = hd[@"Set-Cookie"];
                if (sc.length) gSetCookie = sc;
            }
            NSString *raw = nil;
            if (data.length) raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!raw && data.length) {
                raw = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
            }
            done(raw, status, err);
            [session finishTasksAndInvalidate];
        }];
    [task resume];
}

static NSDictionary *FDMParseJSON(NSString *raw) {
    if (!raw.length) return nil;
    NSData *d = [raw dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return nil;
    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    return [o isKindOfClass:[NSDictionary class]] ? (NSDictionary *)o : nil;
}

#pragma mark - 归一化

static FDMMusicTrack *FDMNormalize(NSDictionary *s) {
    if (![s isKindOfClass:[NSDictionary class]]) return nil;
    FDMMusicTrack *t = [FDMMusicTrack new];
    t.songId = FDMNum(s[@"id"], 0);

    NSString *name = FDMStr(s[@"name"], @"");
    if (!name.length) name = FDMStr(s[@"title"], @"");
    t.name = name;

    NSMutableArray *artists = [NSMutableArray array];
    id ar = s[@"ar"] ?: s[@"artists"];
    if ([ar isKindOfClass:[NSArray class]]) {
        for (id a in (NSArray *)ar) {
            NSString *n = [a isKindOfClass:[NSDictionary class]] ? FDMStr(((NSDictionary *)a)[@"name"], @"") : @"";
            if (n.length) [artists addObject:n];
        }
    }
    t.artist = [artists componentsJoinedByString:@"/"];

    id al = s[@"al"] ?: s[@"album"];
    if ([al isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)al;
        t.album = FDMStr(d[@"name"], @"");
        NSString *pic = FDMStr(d[@"picUrl"], @"");
        if (!pic.length) pic = FDMStr(d[@"blurPicUrl"], @"");
        t.picUrl = FDMPreferHTTPS(pic);
    } else {
        t.album = @"";
        t.picUrl = @"";
    }

    long long dt = FDMNum(s[@"dt"], 0);
    if (dt <= 0) dt = FDMNum(s[@"duration"], 0);
    t.duration = dt;
    t.fee = (NSInteger)FDMNum(s[@"fee"], 0);
    return t;
}

#pragma mark - FDMMusicTrack

@implementation FDMMusicTrack
- (NSString *)description {
    return [NSString stringWithFormat:@"<Track %lld %@ - %@ (%lldms, fee=%ld)>",
            _songId, _name, _artist, _duration, (long)_fee];
}
@end

#pragma mark - FDMMusicApi

@implementation FDMMusicApi

+ (void)setOsMode:(FDMMusicOsMode)mode {
    gOsMode = (mode < 0 || mode > 2) ? FDMMusicOsModeIPhone : mode;
    FLOGI(FC_MUSIC, @"[music] os 档位 → %ld (%@)", (long)gOsMode, FDMOSName());
}

+ (FDMMusicOsMode)osMode { return gOsMode; }

+ (void)setMusicU:(NSString *)musicU {
    gMusicU = [musicU copy] ?: @"";
    FLOGI(FC_MUSIC, @"[music] MUSIC_U 长度=%lu", (unsigned long)gMusicU.length);
}

+ (void)setMusicA:(NSString *)musicA { gMusicA = [musicA copy] ?: @""; }

+ (BOOL)hasLogin { return gMusicU.length > 0; }

+ (NSInteger)lastCode { return gLastCode; }

+ (NSString *)deviceId { return FDMDeviceId(); }

+ (NSString *)preferHTTPS:(NSString *)url { return FDMPreferHTTPS(url); }

+ (NSString *)lastSetCookie { return gSetCookie; }

#pragma mark eapi

+ (void)postEapi:(NSString *)uri
            json:(NSString *)json
      completion:(void (^)(NSDictionary *r, NSError *e))completion {
    NSString *text = json ?: @"";
    char *params = fdm_music_eapi(uri.UTF8String, text.UTF8String);
    if (!params) {
        completion(nil, FDMErr(-2, @"eapi 加密失败"));
        return;
    }
    NSString *paramsHex = [NSString stringWithUTF8String:params];
    free(params);

    long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    NSString *requestId = FDMRequestId();

    NSMutableString *ck = [NSMutableString string];
    [ck appendFormat:@"osver=%@", FDMUrlEnc(FDMOSVer())];
    [ck appendFormat:@"; deviceId=%@", FDMUrlEnc(FDMDeviceId())];
    [ck appendFormat:@"; os=%@", FDMUrlEnc(FDMOSName())];
    [ck appendFormat:@"; appver=%@", FDMUrlEnc(FDMOSAppVer())];
    [ck appendString:@"; versioncode=140"];
    [ck appendString:@"; mobilename="];
    [ck appendFormat:@"; buildver=%@", FDMUrlEnc([NSString stringWithFormat:@"%lld", now / 1000])];
    [ck appendString:@"; resolution=1920x1080"];
    [ck appendString:@"; __csrf="];
    [ck appendFormat:@"; channel=%@", FDMUrlEnc(FDMOSChannel())];
    [ck appendFormat:@"; requestId=%@", FDMUrlEnc(requestId)];
    if (gMusicU.length) [ck appendFormat:@"; MUSIC_U=%@", FDMUrlEnc(gMusicU)];
    if (gMusicA.length) [ck appendFormat:@"; MUSIC_A=%@", FDMUrlEnc(gMusicA)];

    NSString *tail = [uri hasPrefix:@"/api/"] ? [uri substringFromIndex:5] : uri;
    NSString *url = [NSString stringWithFormat:@"%@/eapi/%@", kApiDomain, tail];
    NSString *body = [NSString stringWithFormat:@"params=%@", paramsHex];

    FDMPost(url, body, @"application/x-www-form-urlencoded", ck, FDMOSUA(),
            ^(NSString *raw, long status, NSError *err) {
        if (err) {
            FLOGE(FC_MUSIC, @"[music] %@ 网络错误: %@", uri, err.localizedDescription);
            completion(nil, err);
            return;
        }
        NSDictionary *m = FDMParseJSON(raw);
        if (!m) {
            FLOGE(FC_MUSIC, @"[music] %@ status=%ld 响应不是 JSON: %@",
                  uri, status, FDMBrief(raw));
            completion(nil, FDMErr(-3, [NSString stringWithFormat:@"响应不是 JSON（HTTP %ld）", status]));
            return;
        }
        NSInteger c = (NSInteger)FDMNum(m[@"code"], -1);
        gLastCode = c;
        if (c != 200) {
            FLOGW(FC_MUSIC, @"[music] %@ 非 200 ⇒ code=%ld · %@", uri, (long)c, FDMBrief(raw));
        }
        completion(m, nil);
    });
}

#pragma mark weapi（登录用，暂时只有底层）

+ (void)postWeapi:(NSString *)uri
             json:(NSString *)json
       completion:(void (^)(NSDictionary *r, NSError *e))completion {
    char *params = NULL;
    char *enc = NULL;
    int rc = fdm_music_weapi((json ?: @"").UTF8String, NULL, &params, &enc);
    if (rc != 0) {
        completion(nil, FDMErr(-4, [NSString stringWithFormat:@"weapi 加密失败 rc=%d", rc]));
        return;
    }
    NSString *p = [NSString stringWithUTF8String:params];
    NSString *e = [NSString stringWithUTF8String:enc];
    free(params);
    free(enc);

    NSString *tail = [uri hasPrefix:@"/api/"] ? [uri substringFromIndex:5] : uri;
    NSString *url = [NSString stringWithFormat:@"%@/weapi/%@", kDomain, tail];
    NSString *body = [NSString stringWithFormat:@"params=%@&encSecKey=%@",
                      FDMUrlEnc(p), FDMUrlEnc(e)];

    NSMutableString *ck = [NSMutableString string];
    if (gMusicU.length) [ck appendFormat:@"MUSIC_U=%@;", gMusicU];
    if (gMusicA.length) [ck appendFormat:@" MUSIC_A=%@;", gMusicA];

    FDMPost(url, body, @"application/x-www-form-urlencoded", ck, FDMWeapiUA(),
            ^(NSString *raw, long status, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSDictionary *m = FDMParseJSON(raw);
        if (!m) {
            completion(nil, FDMErr(-5, [NSString stringWithFormat:@"weapi 响应不是 JSON（HTTP %ld）", status]));
            return;
        }
        completion(m, nil);
    });
}

#pragma mark 业务接口

+ (void)search:(NSString *)keyword
         limit:(NSInteger)limit
        offset:(NSInteger)offset
    completion:(FDMMusicTracksCb)completion {
    NSInteger lim = limit <= 0 ? 30 : limit;
    NSInteger off = offset < 0 ? 0 : offset;
    NSString *json = [NSString stringWithFormat:
                      @"{\"s\":%@,\"type\":1,\"limit\":%ld,\"offset\":%ld}",
                      FDMMusicJSONQuote(keyword ?: @""), (long)lim, (long)off];

    [self postEapi:@"/api/search/get" json:json completion:^(NSDictionary *r, NSError *e) {
        if (e) { FDMDeliverMain(^{ completion(nil, e); }); return; }

        NSMutableArray<FDMMusicTrack *> *out = [NSMutableArray array];
        id result = r[@"result"];
        id songs = [result isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)result)[@"songs"] : nil;
        if ([songs isKindOfClass:[NSArray class]]) {
            for (id o in (NSArray *)songs) {
                FDMMusicTrack *t = FDMNormalize(o);
                if (t) [out addObject:t];
            }
        }

        FLOGI(FC_MUSIC, @"[music] search code=%ld 命中 %lu 首",
              (long)FDMNum(r[@"code"], -1), (unsigned long)out.count);

        /* ★ 搜索接口不给封面（只有 picId），拿 songDetail 补齐 */
        NSMutableArray<NSNumber *> *need = [NSMutableArray array];
        for (FDMMusicTrack *t in out) {
            if (!t.picUrl.length && t.songId > 0) [need addObject:@(t.songId)];
        }
        if (!need.count) {
            FDMDeliverMain(^{ completion(out, nil); });
            return;
        }

        [self songDetail:need completion:^(NSArray<FDMMusicTrack *> *details, NSError *de) {
            NSInteger filled = 0;
            if (!de && details.count) {
                NSMutableDictionary<NSNumber *, NSString *> *map = [NSMutableDictionary dictionary];
                for (FDMMusicTrack *d in details) {
                    if (d.picUrl.length) map[@(d.songId)] = d.picUrl;
                }
                for (FDMMusicTrack *t in out) {
                    if (!t.picUrl.length) {
                        NSString *pic = map[@(t.songId)];
                        if (pic.length) { t.picUrl = pic; filled++; }
                    }
                }
            }
            FLOGI(FC_MUSIC, @"[music] 封面补齐 %ld/%lu 首", (long)filled,
                  (unsigned long)need.count);
            FDMDeliverMain(^{ completion(out, nil); });
        }];
    }];
}

+ (void)songUrl:(long long)songId
          level:(NSString *)level
     completion:(FDMMusicUrlCb)completion {
    if (songId <= 0) { FDMDeliverMain(^{ completion(nil, 0, nil, 0, FDMErr(-6, @"songId 非法")); }); return; }
    NSString *lv = level.length ? level : @"exhigh";
    NSString *json = [NSString stringWithFormat:
                      @"{\"ids\":\"[%lld]\",\"level\":%@,\"encodeType\":\"flac\"}",
                      songId, FDMMusicJSONQuote(lv)];

    [self postEapi:@"/api/song/enhance/player/url/v1" json:json
        completion:^(NSDictionary *r, NSError *e) {
        if (e) { FDMDeliverMain(^{ completion(nil, 0, nil, 0, e); }); return; }
        NSDictionary *d0 = nil;
        id arr = r[@"data"];
        if ([arr isKindOfClass:[NSArray class]] && [(NSArray *)arr count]) {
            id first = [(NSArray *)arr firstObject];
            if ([first isKindOfClass:[NSDictionary class]]) d0 = first;
        }
        NSString *rawUrl = d0 ? FDMStr(d0[@"url"], @"") : @"";
        NSString *url = FDMPreferHTTPS(rawUrl);
        if (rawUrl.length && ![rawUrl isEqualToString:url]) {
            FLOGD(FC_MUSIC, @"[music] 播放地址 http→https（绕 ATS）");
        }
        long long br = d0 ? FDMNum(d0[@"br"], 0) : 0;
        NSString *type = d0 ? FDMStr(d0[@"type"], @"") : @"";
        NSInteger fee = d0 ? (NSInteger)FDMNum(d0[@"fee"], 0) : 0;
        FLOGI(FC_MUSIC, @"[music] songUrl(%lld,%@) br=%lld type=%@ fee=%ld url=%@",
              songId, lv, br, type, (long)fee, url.length ? @"有" : @"空");
        FDMDeliverMain(^{ completion(url.length ? url : nil, br, type, fee, nil); });
    }];
}

+ (void)songDetail:(NSArray<NSNumber *> *)songIds
        completion:(FDMMusicTracksCb)completion {
    if (!songIds.count) { FDMDeliverMain(^{ completion(@[], nil); }); return; }
    NSMutableString *c = [NSMutableString stringWithString:@"["];
    [songIds enumerateObjectsUsingBlock:^(NSNumber *n, NSUInteger i, BOOL *stop) {
        if (i) [c appendString:@","];
        [c appendFormat:@"{\"id\":%lld}", n.longLongValue];
    }];
    [c appendString:@"]"];

    NSString *json = [NSString stringWithFormat:@"{\"c\":%@}", FDMMusicJSONQuote(c)];
    [self postEapi:@"/api/v3/song/detail" json:json completion:^(NSDictionary *r, NSError *e) {
        if (e) { FDMDeliverMain(^{ completion(nil, e); }); return; }
        NSMutableArray *out = [NSMutableArray array];
        id songs = r[@"songs"];
        if ([songs isKindOfClass:[NSArray class]]) {
            for (id o in (NSArray *)songs) {
                FDMMusicTrack *t = FDMNormalize(o);
                if (t) [out addObject:t];
            }
        }
        FDMDeliverMain(^{ completion(out, nil); });
    }];
}

+ (void)lyric:(long long)songId completion:(FDMMusicLyricCb)completion {
    if (songId <= 0) { FDMDeliverMain(^{ completion(nil, nil, FDMErr(-6, @"songId 非法")); }); return; }
    NSString *json = [NSString stringWithFormat:
                      @"{\"id\":%lld,\"lv\":-1,\"kv\":-1,\"tv\":-1}", songId];
    [self postEapi:@"/api/song/lyric" json:json completion:^(NSDictionary *r, NSError *e) {
        if (e) { FDMDeliverMain(^{ completion(nil, nil, e); }); return; }
        NSString *lrc = @"";
        NSString *tlrc = @"";
        id l = r[@"lrc"];
        if ([l isKindOfClass:[NSDictionary class]]) lrc = FDMStr(((NSDictionary *)l)[@"lyric"], @"");
        id t = r[@"tlyric"];
        if ([t isKindOfClass:[NSDictionary class]]) tlrc = FDMStr(((NSDictionary *)t)[@"lyric"], @"");
        FLOGI(FC_MUSIC, @"[music] lyric(%lld) lrc=%lu字 tlrc=%lu字",
              songId, (unsigned long)lrc.length, (unsigned long)tlrc.length);
        FDMDeliverMain(^{ completion(lrc, tlrc, nil); });
    }];
}

#pragma mark 自检

+ (void)networkSelfTest:(NSString *)keyword {
    NSString *kw = keyword.length ? keyword : @"晴天";
    FLOGI(FC_MUSIC, @"[music] 网络自检开始：搜索「%@」", kw);
    [self search:kw limit:3 offset:0 completion:^(NSArray<FDMMusicTrack *> *tracks, NSError *e) {
        if (e) {
            FLOGE(FC_MUSIC, @"[music] 搜索 ✗ %@", e.localizedDescription);
            return;
        }
        if (!tracks.count) {
            FLOGW(FC_MUSIC, @"[music] 搜索 ✓ 但 0 条（关键词太偏？）");
            return;
        }
        FLOGI(FC_MUSIC, @"[music] 搜索 ✓ %lu 首", (unsigned long)tracks.count);
        for (FDMMusicTrack *t in tracks) {
            FLOGI(FC_MUSIC, @"[music]   %lld | %@ | %@ | 封面%@",
                  t.songId, t.name, t.artist, t.picUrl.length ? @"有" : @"无");
        }
        FDMMusicTrack *first = tracks.firstObject;
        [self songUrl:first.songId level:@"exhigh" completion:^(NSString *url, long long br,
                                                               NSString *type, NSInteger fee, NSError *ue) {
            if (ue) {
                FLOGE(FC_MUSIC, @"[music] 播放地址 ✗ %@", ue.localizedDescription);
                return;
            }
            FLOGI(FC_MUSIC, @"[music] 播放地址 ✓ br=%lld type=%@ fee=%ld",
                  br, type, (long)fee);
        }];
    }];
}

#pragma mark 登录（weapi）

+ (NSString *)pickCookie:(NSString *)jar name:(NSString *)name {
    return FDMPickCookie(jar, name);
}

+ (NSString *)md5Hex:(NSString *)s {
    if (!s) return @"";
    char out[33] = {0};
    fdm_md5_hex(s.UTF8String, out);
    return [NSString stringWithUTF8String:out] ?: @"";
}

/** 统一的「登录响应 → 收尾」：抠 MUSIC_U → 注入 Api → 回调。 */
+ (void)finishLogin:(NSDictionary *)r
                jar:(NSString *)jar
              label:(NSString *)label
         completion:(FDMMusicLoginCb)completion {
    NSInteger code = -1;
    id c = r[@"code"];
    if ([c respondsToSelector:@selector(integerValue)]) code = [c integerValue];

    /* 凭证可能藏在两处：响应体里的 cookie 字段 / 逐跳累积的 Set-Cookie */
    NSString *mu = FDMPickCookie(jar, @"MUSIC_U");
    if (!mu.length) {
        id bodyCk = r[@"cookie"];
        if ([bodyCk isKindOfClass:[NSString class]])
            mu = FDMPickCookie(bodyCk, @"MUSIC_U");
    }
    NSString *ma = FDMPickCookie(jar, @"MUSIC_A");

    if (code == 200 && mu.length) {
        [self setMusicU:mu];
        if (ma.length) [self setMusicA:ma];
        FLOGI(FC_MUSIC, @"[login] ✓ %@ 成功（MUSIC_U %lu 字符）",
              label, (unsigned long)mu.length);
        if (completion) completion(YES, @"登录成功", jar);
        return;
    }

    /* ★ 别把「没拿到 cookie」说成「登录失败」—— 这两种情况给用户的提示完全不同。
     *   code=200 但没 MUSIC_U ⇒ 十有八九是跳转没跟上（见文件头那段血泪）。 */
    NSString *msg = nil;
    id m = r[@"msg"] ?: r[@"message"];
    if ([m isKindOfClass:[NSString class]] && [m length]) msg = m;

    if (code == 200 && !mu.length) {
        FLOGE(FC_MUSIC, @"[login] ✗ %@ 返回 200 但**没拿到 MUSIC_U**（重定向没跟上？）",
              label);
        if (completion) completion(NO, @"服务端说成功，但没拿到凭证（把日志发给尼尼）", jar);
        return;
    }
    FLOGW(FC_MUSIC, @"[login] ✗ %@ code=%ld msg=%@", label, (long)code, msg ?: @"(无)");
    if (completion)
        completion(NO,
                   msg.length ? msg
                              : [NSString stringWithFormat:@"失败（code=%ld）", (long)code],
                   jar);
}

/** weapi 的通用 POST（带重定向跟随）。 */
+ (void)weapiPostFollow:(NSString *)uri
                   json:(NSString *)json
             completion:(void (^)(NSDictionary *r, NSString *jar, NSError *e))completion {
    char *params = NULL;
    char *enc = NULL;
    int rc = fdm_music_weapi((json ?: @"").UTF8String, NULL, &params, &enc);
    if (rc != 0) {
        completion(nil, @"", FDMErr(-4, [NSString stringWithFormat:@"weapi 加密失败 rc=%d", rc]));
        return;
    }
    NSString *p = [NSString stringWithUTF8String:params];
    NSString *e = [NSString stringWithUTF8String:enc];
    free(params);
    free(enc);

    NSString *tail = [uri hasPrefix:@"/api/"] ? [uri substringFromIndex:5] : uri;
    NSString *url = [NSString stringWithFormat:@"%@/weapi/%@", kDomain, tail];
    NSString *body = [NSString stringWithFormat:@"params=%@&encSecKey=%@",
                      FDMUrlEnc(p), FDMUrlEnc(e)];

    NSMutableString *ck = [NSMutableString string];
    if (gMusicU.length) [ck appendFormat:@"MUSIC_U=%@; ", gMusicU];
    if (gMusicA.length) [ck appendFormat:@"MUSIC_A=%@;", gMusicA];

    FDMPostFollow(url, body, @"application/x-www-form-urlencoded", ck, FDMWeapiUA(),
                  ^(NSString *raw, long status, NSString *jar, NSError *err) {
        if (err) { completion(nil, jar, err); return; }
        NSDictionary *m = FDMParseJSON(raw);
        if (!m) {
            completion(nil, jar,
                       FDMErr(-5, [NSString stringWithFormat:@"weapi 响应不是 JSON（HTTP %ld）",
                                   status]));
            return;
        }
        completion(m, jar, nil);
    });
}

+ (void)captchaSent:(NSString *)phone
             ctcode:(NSString *)ctcode
         completion:(FDMMusicLoginCb)completion {
    if (!phone.length) { if (completion) completion(NO, @"填手机号", @""); return; }
    NSString *cc = ctcode.length ? ctcode : @"86";
    /* 照抄安卓：secrete 是写死的 "music_middleuser_pclogin" */
    NSString *json = [NSString stringWithFormat:
        @"{\"ctcode\":%@,\"secrete\":\"music_middleuser_pclogin\",\"cellphone\":%@}",
        FDMMusicJSONQuote(cc), FDMMusicJSONQuote(phone)];

    FLOGI(FC_MUSIC, @"[login] ① 发验证码 → %@（+%@）", phone, cc);
    [self weapiPostFollow:@"/api/sms/captcha/sent" json:json
               completion:^(NSDictionary *r, NSString *jar, NSError *e) {
        if (e) { if (completion) completion(NO, e.localizedDescription, jar); return; }
        NSInteger code = [r[@"code"] respondsToSelector:@selector(integerValue)]
                       ? [r[@"code"] integerValue] : -1;
        if (code == 200) {
            FLOGI(FC_MUSIC, @"[login] ✓ 验证码已发出");
            if (completion) completion(YES, @"验证码已发出，看手机短信", jar);
        } else {
            id mm = r[@"msg"] ?: r[@"message"];
            NSString *m = [mm isKindOfClass:[NSString class]] ? mm : nil;
            FLOGW(FC_MUSIC, @"[login] ✗ 发码失败 code=%ld msg=%@", (long)code, m ?: @"");
            if (completion)
                completion(NO, m.length ? m
                                        : [NSString stringWithFormat:@"发码失败（%ld）", (long)code],
                           jar);
        }
    }];
}

+ (void)loginByCaptcha:(NSString *)phone
               captcha:(NSString *)captcha
                ctcode:(NSString *)ctcode
            completion:(FDMMusicLoginCb)completion {
    if (!phone.length || !captcha.length) {
        if (completion) completion(NO, @"手机号和验证码都要填", @"");
        return;
    }
    NSString *cc = ctcode.length ? ctcode : @"86";
    NSString *json = [NSString stringWithFormat:
        @"{\"type\":\"1\",\"https\":\"true\",\"phone\":%@,\"countrycode\":%@,"
         "\"captcha\":%@,\"remember\":\"true\"}",
        FDMMusicJSONQuote(phone), FDMMusicJSONQuote(cc), FDMMusicJSONQuote(captcha)];

    FLOGI(FC_MUSIC, @"[login] ② 验证码登录 → %@", phone);
    [self weapiPostFollow:@"/api/w/login/cellphone" json:json
               completion:^(NSDictionary *r, NSString *jar, NSError *e) {
        if (e) { if (completion) completion(NO, e.localizedDescription, jar); return; }
        [self finishLogin:r jar:jar label:@"验证码登录" completion:completion];
    }];
}

+ (void)loginByPassword:(NSString *)phone
               password:(NSString *)password
                 ctcode:(NSString *)ctcode
             completion:(FDMMusicLoginCb)completion {
    if (!phone.length || !password.length) {
        if (completion) completion(NO, @"手机号和密码都要填", @"");
        return;
    }
    NSString *cc = ctcode.length ? ctcode : @"86";
    /* ★ 服务端要的是 md5(明文)，不是明文 */
    NSString *md5 = [self md5Hex:password];
    NSString *json = [NSString stringWithFormat:
        @"{\"type\":\"1\",\"https\":\"true\",\"phone\":%@,\"countrycode\":%@,"
         "\"password\":%@,\"remember\":\"true\"}",
        FDMMusicJSONQuote(phone), FDMMusicJSONQuote(cc), FDMMusicJSONQuote(md5)];

    FLOGI(FC_MUSIC, @"[login] ③ 密码登录 → %@", phone);
    [self weapiPostFollow:@"/api/w/login/cellphone" json:json
               completion:^(NSDictionary *r, NSString *jar, NSError *e) {
        if (e) { if (completion) completion(NO, e.localizedDescription, jar); return; }
        [self finishLogin:r jar:jar label:@"密码登录" completion:completion];
    }];
}

+ (void)loginByEmail:(NSString *)email
            password:(NSString *)password
          completion:(FDMMusicLoginCb)completion {
    if (!email.length || !password.length) {
        if (completion) completion(NO, @"邮箱和密码都要填", @"");
        return;
    }
    NSString *md5 = [self md5Hex:password];
    NSString *json = [NSString stringWithFormat:
        @"{\"type\":\"0\",\"https\":\"true\",\"username\":%@,"
         "\"password\":%@,\"rememberLogin\":\"true\"}",
        FDMMusicJSONQuote(email), FDMMusicJSONQuote(md5)];

    FLOGI(FC_MUSIC, @"[login] ④ 邮箱登录 → %@", email);
    [self weapiPostFollow:@"/api/w/login" json:json
               completion:^(NSDictionary *r, NSString *jar, NSError *e) {
        if (e) { if (completion) completion(NO, e.localizedDescription, jar); return; }
        [self finishLogin:r jar:jar label:@"邮箱登录" completion:completion];
    }];
}

+ (void)loginByCookie:(NSString *)rawCookie completion:(FDMMusicLoginCb)completion {
    /* 这条路不发请求：用户从浏览器 / 别的客户端把 cookie 抠出来直接贴 */
    NSString *raw = [rawCookie stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!raw.length) { if (completion) completion(NO, @"把 cookie 粘进来", @""); return; }

    /* 用户可能贴整条 "MUSIC_U=xxx; Path=/; ..."，也可能只贴 xxx。
     * 先试"带名字"的解析，解析不到就整条当 MUSIC_U。 */
    NSString *mu = FDMPickCookie(raw, @"MUSIC_U");
    if (!mu.length) {
        /* 纯值形态：长度够、又没有 = 和 ; ⇒ 认成值 */
        if (raw.length >= 20 &&
            [raw rangeOfString:@";"].location == NSNotFound &&
            [raw rangeOfString:@"="].location == NSNotFound) {
            mu = raw;
        }
    }
    if (!mu.length) {
        if (completion) completion(NO, @"没找到 MUSIC_U（要贴 MUSIC_U=… 那一段）", @"");
        return;
    }
    NSString *ma = FDMPickCookie(raw, @"MUSIC_A");
    [self setMusicU:mu];
    if (ma.length) [self setMusicA:ma];
    FLOGI(FC_MUSIC, @"[login] ✓ cookie 登录（MUSIC_U %lu 字符）", (unsigned long)mu.length);
    if (completion) completion(YES, @"登录成功（cookie）", raw);
}

+ (void)loginStatus:(FDMMusicLoginCb)completion {
    if (!gMusicU.length) {
        if (completion) completion(NO, @"还没登录", @"");
        return;
    }
    [self weapiPostFollow:@"/api/w/nuser/account/get" json:@"{}"
               completion:^(NSDictionary *r, NSString *jar, NSError *e) {
        if (e) { if (completion) completion(NO, e.localizedDescription, jar); return; }
        NSInteger code = [r[@"code"] respondsToSelector:@selector(integerValue)]
                       ? [r[@"code"] integerValue] : -1;
        /* 200 且有 account/profile ⇒ 真登录了；200 但 account 为 null ⇒ 凭证过期 */
        id acct = r[@"account"];
        BOOL ok = (code == 200 && acct && ![acct isKindOfClass:[NSNull class]]);
        NSString *nick = nil;
        id prof = r[@"profile"];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            id n = ((NSDictionary *)prof)[@"nickname"];
            if ([n isKindOfClass:[NSString class]]) nick = n;
        }
        if (ok) {
            FLOGI(FC_MUSIC, @"[login] ✓ 已登录（%@）", nick ?: @"昵称未知");
            if (completion)
                completion(YES, nick.length ? [NSString stringWithFormat:@"已登录：%@", nick]
                                            : @"已登录", jar);
        } else {
            FLOGW(FC_MUSIC, @"[login] ✗ 凭证无效/过期 code=%ld", (long)code);
            if (completion) completion(NO, @"凭证已失效，请重新登录", jar);
        }
    }];
}

+ (void)logout {
    gMusicU = @"";
    gMusicA = @"";
    gSetCookie = @"";
    FLOGI(FC_MUSIC, @"[login] 已退出登录（内存态已清）");
}

@end
