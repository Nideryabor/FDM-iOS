// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用

/* ============================================================
 * FDMUserMeta —— 账号名 / 头像改写（P3）🐲
 *
 * 对标安卓：`专题/账号名与账号头像.md`
 *
 * ------------------------------------------------------------
 * 安卓是 hook UI 层（Compose lambda），因为它的用户模型里
 * **没有头像字段**，只能从渲染层换 URL。
 *
 * iOS 这边网络层干净得多：
 *   /api/v0/users/current   ← 用户信息唯一来源
 *        ↓ 改这一处的响应
 *   抽屉底部 / 设置页 / 头像 —— 全部跟着变
 * 不用挂任何 UI hook，也不怕宿主改渲染实现。
 *
 * ------------------------------------------------------------
 * ⚠️ 字段名**不猜**。宿主每个版本都可能改 JSON key，
 *    所以第一步永远是探针：把真实响应落到
 *    Documents/fdm-users-current.json，看一眼再写映射。
 *
 * 本文件目前的行为：
 *   • 未配置 ⇒ 原样返回 nil（一个字节都不动）
 *   • 配置了 ⇒ 按 JSON 递归找目标 key 并替换
 * ============================================================ */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "FLog.h"
#import "FDMConfig.h"

/* 分组 id（与 FDMFeatures 里 P_NICK / P_AVATAR 对应） */
static NSString *const kNickGroup   = @"nickname";
static NSString *const kAvatarGroup = @"avatar";

/* ============ 配置缓存（hook 内绝不 IO） ============ */

static BOOL      gNameOn   = NO;
static NSString *gNameText  = nil;
static BOOL      gAvatarOn = NO;
static NSString *gAvatarURL = nil;
static BOOL      gLoaded    = NO;

/* 把「Documents 里的文件名」转成 file:// 绝对路径 */
static NSString *ResolveAvatarURL(NSString *raw) {
    if (!raw.length) return @"";
    if ([raw hasPrefix:@"http://"] || [raw hasPrefix:@"https://"] ||
        [raw hasPrefix:@"file://"]) {
        return raw;
    }
    @try {
        NSArray *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
        NSString *dir = [a firstObject];
        if (!dir) return raw;
        NSString *p = [dir stringByAppendingPathComponent:raw];
        return [@"file://" stringByAppendingString:p];
    } @catch (NSException *e) { return raw; }
}

void FDMUserMetaReload(void) {
    @autoreleasepool {
        FDMConfig *C = [FDMConfig shared];
        @try {
            /* ★ 账号名：enabled / name（留空 = 隐藏） */
            gNameOn   = [C boolFor:kNickGroup key:@"enabled"];
            gNameText = [C stringFor:kNickGroup key:@"name"] ?: @"";
            /* ★ 头像：enabled / (url 优先，其次 file 转 file://) */
            gAvatarOn  = [C boolFor:kAvatarGroup key:@"enabled"];
            NSString *rawURL  = [C stringFor:kAvatarGroup key:@"url"] ?: @"";
            NSString *rawFile = [C stringFor:kAvatarGroup key:@"file"] ?: @"";
            gAvatarURL = rawURL.length ? rawURL : ResolveAvatarURL(rawFile);
            /* ★ 诊断：把每个中间值都打出来（不猜） */
            FLOGW(FC_UI, @"[avatar] 读配置 gid=%@ enabled=%d url=「%@」file=「%@」→ 最终=「%@」",
                  kAvatarGroup, (int)gAvatarOn, rawURL, rawFile, gAvatarURL ?: @"(nil)");
            if (gAvatarOn && !gAvatarURL.length) gAvatarOn = NO;
        } @catch (NSException *e) {
            gNameOn = NO; gAvatarOn = NO;
        }
        gLoaded = YES;
        FLOGW(FC_NET, @"[user] 缓存：改名=%d(%lu字) 换头像=%d(%lu字)",
              (int)gNameOn, (unsigned long)gNameText.length,
              (int)gAvatarOn, (unsigned long)gAvatarURL.length);
    }
}

/* 供 FDMProbe.m 的 currentUser 改写用：
 * 返回 YES 表示「要改」，并输出目标文字（可能是 @"" = 隐藏） */
BOOL FDMUserNameWanted(NSString **outText) {
    if (!gLoaded) FDMUserMetaReload();
    if (!gNameOn) return NO;
    if (outText) *outText = gNameText ?: @"";
    return YES;
}

/* ============ 递归改写 ============ */

/* 已知的「账号名」候选 key（多写几个，命中哪个算哪个 —— 不猜错也不漏） */
static BOOL IsNameKey(NSString *k) {
    if (![k isKindOfClass:[NSString class]]) return NO;
    return ([k isEqualToString:@"nickname"] ||
            [k isEqualToString:@"nick_name"] ||
            [k isEqualToString:@"display_name"] ||
            [k isEqualToString:@"displayName"] ||
            [k isEqualToString:@"name"] ||
            [k isEqualToString:@"user_name"] ||
            [k isEqualToString:@"userName"]);
}

/* 已知的「头像」候选 key */
static BOOL IsAvatarKey(NSString *k) {
    if (![k isKindOfClass:[NSString class]]) return NO;
    return ([k isEqualToString:@"avatar"] ||
            [k isEqualToString:@"avatar_url"] ||
            [k isEqualToString:@"avatarUrl"] ||
            [k isEqualToString:@"avatar_uri"] ||
            [k isEqualToString:@"head_url"] ||
            [k isEqualToString:@"headUrl"] ||
            [k isEqualToString:@"headimgurl"]);
}

/* 递归遍历，返回改了多少处 */
static int RewriteNode(id node, int depth) {
    if (!node || depth > 12) return 0;
    int n = 0;
    @try {
        if ([node isKindOfClass:[NSMutableDictionary class]]) {
            NSMutableDictionary *d = node;
            for (NSString *k in [d allKeys]) {
                id v = d[k];
                if ([v isKindOfClass:[NSString class]]) {
                    if (gNameOn && IsNameKey(k)) {
                        d[k] = gNameText;      /* 可能是 @"" ⇒ 隐藏 */
                        n++;
                        FLOGW(FC_NET, @"[user] 改名 %@ = 「%@」", k, gNameText);
                        continue;
                    }
                    if (gAvatarOn && IsAvatarKey(k) && gAvatarURL.length) {
                        d[k] = gAvatarURL;
                        n++;
                        FLOGW(FC_NET, @"[user] 换头像 %@ = %@", k, gAvatarURL);
                        continue;
                    }
                }
                n += RewriteNode(v, depth + 1);
            }
        } else if ([node isKindOfClass:[NSMutableArray class]]) {
            for (id v in node) n += RewriteNode(v, depth + 1);
        }
    } @catch (NSException *e) { }
    return n;
}

/* ============ 对外入口 ============ */

/* 返回非 nil = 用新串替换响应体；nil = 原样不动 */
NSString *FDMUserProfileRewrite(NSData *body) {
    if (!body.length) return nil;
    if (!gLoaded) FDMUserMetaReload();
    if (!gNameOn && !gAvatarOn) return nil;      /* 没配置 ⇒ 零开销透传 */

    @try {
        id j = [NSJSONSerialization JSONObjectWithData:body
                                              options:NSJSONReadingMutableContainers
                                                error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) return nil;

        int n = RewriteNode(j, 0);
        if (n <= 0) return nil;                  /* 没命中 ⇒ 别重新序列化 */
        NSData *out = [NSJSONSerialization dataWithJSONObject:j options:0 error:nil];
        if (!out) return nil;
        NSString *s = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
        FLOGW(FC_NET, @"[user] ★ 改写完成 %d 处（%lu → %lu B）",
              n, (unsigned long)body.length, (unsigned long)out.length);
        return s;
    } @catch (NSException *e) {
        FLOGE(FC_NET, @"[user] 改写异常: %@", e.reason);
        return nil;
    }
}

/* ============================================================
 * ★★★ 2026-10-17 深夜 · 账号头像（只换头像，名字不动）
 *
 *   主人要求：「账号头像单独做（名字不动，只换头像）」
 *
 *   宿主结构（类表实锤）：
 *     _TtCC13DeepSeek_Chat25SessionListViewController10FooterView
 *       ivar: avatar(UIImageView)  avatarUrl  nameLabel  dots
 *   ⇒ 侧栏底部那块「头像 + 名字」就是它。
 *
 *   为什么走 UI 层而不是网络层：
 *     MMKV 里的 currentUser **只有 settingsToken，没有头像字段**
 *     （android 侧也是这个情况），`/api/v0/users/current` 这台设备
 *     一次都没请求过 ⇒ 网络层改响应根本无从下手。
 *
 *   做法：hook FooterView 的 `layoutSubviews`，布局完把 avatar.image
 *         换成我们的图。好处：
 *           · 宿主自己刷新（换 avatarUrl、重新下载）之后，下一次布局
 *             又会被我们盖上去 ⇒ 不会闪回原头像
 *           · 完全不碰 nameLabel ⇒ 名字保持宿主原样
 *           · 找不到 avatar ivar 就安静退出（版本一换也不会崩）
 * ============================================================ */

/* 头像图片缓存（hook 内绝不 IO / 绝不下载） */
static UIImage *gAvatarImage = nil;
static NSString *gAvatarLoadingURL = nil;

static UIImage *FDMResolveAvatarImage(void) {
    if (!gAvatarOn || !gAvatarURL.length) return nil;
    if (gAvatarImage) return gAvatarImage;

    /* 本地文件：直接读（只在第一次，之后走缓存） */
    if ([gAvatarURL hasPrefix:@"file://"]) {
        @try {
            NSString *p = [gAvatarURL substringFromIndex:7];
            gAvatarImage = [UIImage imageWithContentsOfFile:p];
            if (gAvatarImage) {
                FLOGW(FC_UI, @"[avatar] 已加载本地图 %@（%.0fx%.0f）",
                      p.lastPathComponent, gAvatarImage.size.width, gAvatarImage.size.height);
            } else {
                FLOGW(FC_UI, @"[avatar] 本地图读不出来：%@", p);
            }
        } @catch (NSException *e) { }
        return gAvatarImage;
    }

    /* 远程：异步下（下载中返回 nil，下一次布局就会用上） */
    if (!gAvatarLoadingURL) {
        gAvatarLoadingURL = [gAvatarURL copy];
        NSURL *u = [NSURL URLWithString:gAvatarURL];
        if (u) {
            FLOGW(FC_UI, @"[avatar] 开始下载 %@", gAvatarURL);
            NSURLSessionDataTask *t =
                [[NSURLSession sharedSession] dataTaskWithURL:u
                    completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                @autoreleasepool {
                    if (d.length) {
                        UIImage *img = [UIImage imageWithData:d];
                        if (img) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                gAvatarImage = img;
                                FLOGW(FC_UI, @"[avatar] ★ 下载完成 %.0fx%.0f",
                                      img.size.width, img.size.height);
                            });
                            return;
                        }
                    }
                    FLOGW(FC_UI, @"[avatar] 下载失败 %@ %@",
                          @(d.length), e.localizedDescription ?: @"");
                    gAvatarLoadingURL = nil;      /* 允许下次重试 */
                }
            }];
            [t resume];
        }
    }
    return nil;
}

/* 头像容器 → 我们的图 */
static void FDMApplyAvatarTo(id footer) {
    if (!footer) return;
    if (!gAvatarOn) return;
    UIImage *img = FDMResolveAvatarImage();
    if (!img) return;
    @try {
        Ivar iv = class_getInstanceVariable(object_getClass(footer), "avatar");
        if (!iv) iv = class_getInstanceVariable([footer class], "avatar");
        if (!iv) {
            /* ★ 兜底：ivar 找不到就扫子视图，找第一个圆形 UIImageView */
            UIImageView *found = nil;
            NSMutableArray *st = [NSMutableArray arrayWithObject:footer];
            int g = 0;
            while (st.count && g++ < 200) {
                UIView *v = st.lastObject; [st removeLastObject];
                if ([v isKindOfClass:[UIImageView class]]) { found = (UIImageView *)v; break; }
                for (UIView *sv in v.subviews) [st addObject:sv];
            }
            if (found) {
                found.image = img;
                found.contentMode = UIViewContentModeScaleAspectFill;
                found.clipsToBounds = YES;
                FLOGW(FC_UI, @"[avatar] ★ 兜底扫描换图成功 %@", NSStringFromClass([found class]));
            }
            return;
        }
        id a = object_getIvar(footer, iv);
        if (![a isKindOfClass:[UIImageView class]]) return;
        UIImageView *iv2 = (UIImageView *)a;
        if (iv2.image == img) return;             /* 已经是我们的 */
        iv2.image = img;
        iv2.contentMode = UIViewContentModeScaleAspectFill;
        iv2.clipsToBounds = YES;
        /* 圆形（宿主默认就是圆的，但换图后可能被重置） */
        iv2.layer.cornerRadius = MIN(iv2.bounds.size.width, iv2.bounds.size.height) / 2.0;
        static int logN = 0;
        if (logN++ < 6) {
            FLOGW(FC_UI, @"[avatar] ★ 已换上自定义头像（%@@%.0fx%.0f）",
                  NSStringFromClass([footer class]),
                  iv2.bounds.size.width, iv2.bounds.size.height);
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[avatar] 换图异常: %@", e.reason);
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 *  ★ 账号名：直接改 nameLabel（2026-10-23 补）
 *
 *  之前只做了「网络层改响应」，但宿主有**内存缓存**：
 *    · /api/v0/users/current 只在登录/启动时请一次
 *    · 之后抽屉里的名字来自内存里的 user model
 *  ⇒ 改响应根本不生效（文档 30 记的「半成品」就是这个）。
 *
 *  现在走和头像同一条路：hook FooterView 的 layoutSubviews，
 *  布局完把 nameLabel.text 再写一遍。好处一样：
 *    · 宿主自己刷新之后，下次布局又被我们盖上去 ⇒ 不会闪回原名
 *    · 找不到 nameLabel 就安静退出
 * ══════════════════════════════════════════════════════════════════════════ */

static void FDMApplyNameTo(id footer) {
    if (!footer || !gNameOn) return;
    @try {
        Ivar iv = class_getInstanceVariable(object_getClass(footer), "nameLabel");
        if (!iv) iv = class_getInstanceVariable([footer class], "nameLabel");
        if (!iv) {
            /* 兜底：找第一个 UILabeL，但排除我们自己加的头像（头像不是 label）*/
            UILabel *found = nil;
            NSMutableArray *st = [NSMutableArray arrayWithObject:(UIView *)footer];
            int g = 0;
            while (st.count && g++ < 200) {
                UIView *v = st.lastObject; [st removeLastObject];
                if ([v isKindOfClass:[UILabel class]] &&
                    ![v.accessibilityIdentifier isEqualToString:@"fdm.assistant.avatar"]) {
                    /* 名字一般是最宽的那个 label */
                    if (!found || v.bounds.size.width > found.bounds.size.width) {
                        found = (UILabel *)v;
                    }
                }
                for (UIView *sv in v.subviews) [st addObject:sv];
            }
            if (!found) return;
            if (![found.text isEqualToString:gNameText]) {
                found.text = gNameText;
                FLOGW(FC_UI, @"[name] ★ 兜底扫描改名成功（%@）",
                      NSStringFromClass([found class]));
            }
            return;
        }
        id a = object_getIvar(footer, iv);
        if (![a isKindOfClass:[UILabel class]]) return;
        UILabel *l = (UILabel *)a;
        if ([[l text] isEqualToString:gNameText]) return;
        l.text = gNameText;
        static int logN = 0;
        if (logN++ < 6) {
            FLOGW(FC_UI, @"[name] ★ 已换上自定义账号名（%@）「%@」",
                  NSStringFromClass([footer class]), gNameText);
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[name] 改名异常: %@", e.reason);
    }
}

/* ============================================================
 * hook：FooterView -layoutSubviews:
 *
 * ⚠️ 类表实锤 FooterView 只实现了 init / initWithCoder: / initWithFrame:，
 *    **没有自己的 layoutSubviews**（用的是 UIView 的）。
 *    所以不能直接 method_setImplementation（那会改到 UIView 上，
 *    全局污染所有视图！）—— 必须 class_addMethod 到子类。
 * ============================================================ */
static const char *kFooterCls = "_TtCC13DeepSeek_Chat25SessionListViewController10FooterView";

/* 原实现：子类自己有就用自己的，没有就用 UIView 的 */
static IMP gFooterOrigLayout = NULL;

static void bt_footerLayout(id self, SEL _cmd) {
    if (gFooterOrigLayout) ((void(*)(id,SEL))gFooterOrigLayout)(self, _cmd);
    @autoreleasepool { FDMApplyAvatarTo(self); FDMApplyNameTo(self); }
}

/* ============================================================
 * ★ 主动扫描：hook 装得晚的时候，footer 早就 layout 完了，
 *   之后它可能再也不 layout ⇒ 单靠 layoutSubviews 永远不触发（实测）。
 *   ⇒ 装完 hook 立刻扫一遍，之后每 2 秒再扫，直到换上或超时。
 * ============================================================ */
static int FDMScanFootersOnce(void) {
    int hit = 0;
    @try {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                NSMutableArray *st = [NSMutableArray arrayWithObject:w];
                int g = 0;
                while (st.count && g++ < 6000) {
                    UIView *v = st.lastObject; [st removeLastObject];
                    const char *cn = class_getName([v class]);
                    if (cn && strstr(cn, "SessionListViewController10FooterView") != NULL) {
                        FDMApplyAvatarTo(v);
                        FDMApplyNameTo(v);
                        hit++;
                        continue;               /* 不用再往下钻 */
                    }
                    for (UIView *sv in v.subviews) [st addObject:sv];
                }
            }
        }
    } @catch (NSException *e) { }
    return hit;
}

static BOOL FDMHookFooterLayout(void) {
    Class c = objc_getClass(kFooterCls);
    if (!c) return NO;                      /* 还没加载，下次再试 */
    SEL s = sel_registerName("layoutSubviews");

    if (method_getImplementation(class_getInstanceMethod(c, s)) == (IMP)bt_footerLayout)
        return YES;                         /* 已经挂过了 */

    Method m = class_getInstanceMethod(c, s);      /* 至少有 UIView 的 */
    if (!m) return NO;
    const char *types = method_getTypeEncoding(m);

    /* 这个类自己有没有实现？ */
    BOOL hasOwn = NO;
    unsigned int mc = 0;
    Method *own = class_copyMethodList(c, &mc);
    if (own) {
        for (unsigned int i = 0; i < mc; i++)
            if (sel_isEqual(method_getName(own[i]), s)) { hasOwn = YES; break; }
        free(own);
    }

    if (hasOwn) {
        gFooterOrigLayout = method_getImplementation(m);
        method_setImplementation(m, (IMP)bt_footerLayout);
    } else {
        /* 只在本类加覆盖，父类（UIView）一动不动 */
        gFooterOrigLayout = method_getImplementation(class_getInstanceMethod([UIView class], s));
        if (!class_addMethod(c, s, (IMP)bt_footerLayout, types)) return NO;
    }
    FLOGW(FC_UI, @"[avatar] ★ 已 hook %s layoutSubviews（自有实现=%d）", kFooterCls, (int)hasOwn);

    /* ★ 立刻主动扫一遍（layoutSubviews 可能永远不会再触发，见上方注释） */
    {
        static dispatch_source_t st = nil;
        if (st) return YES;
        __block int n = 0;
        st = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                    dispatch_get_main_queue());
        dispatch_source_set_timer(st,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
            (uint64_t)(2.0 * NSEC_PER_SEC), (uint64_t)(0.3 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(st, ^{
            @autoreleasepool {
                int hit = FDMScanFootersOnce();
                static int lastHit = -1, logN = 0;
                if (hit != lastHit && logN++ < 4) {
                    lastHit = hit;
                    FLOGW(FC_UI, @"[avatar] 巡扫：%d 个 FooterView", hit);
                }
                if (++n >= 15) {                 /* 30 秒后停 */
                    dispatch_source_cancel(st);
                    FLOGW(FC_UI, @"[avatar] 巡扫结束（%d 轮）", n);
                }
            }
        });
        dispatch_resume(st);
    }
    return YES;
}

void FDMUserMetaInstall(void) {
    FDMUserMetaReload();
    FLOGI(FC_NET, @"[user] 账号名/头像改写就绪");

    /* ★ 头像：hook FooterView 的 layoutSubviews。
     *   这个 Swift 类是懒加载的，启动时可能还不存在 ⇒ 每 1 秒重试，
     *   最多 20 次（20 秒）。 */
    if (!gAvatarOn) {
        FLOGI(FC_UI, @"[avatar] 未启用，跳过 hook");
        return;
    }
    {
        static dispatch_source_t tp = nil;
        if (tp) return;
        __block int n = 0;
        tp = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                    dispatch_get_main_queue());
        dispatch_source_set_timer(tp,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
            (uint64_t)(1.0 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(tp, ^{
            @autoreleasepool {
                if (FDMHookFooterLayout() || ++n > 20) {
                    if (n > 20) FLOGW(FC_UI, @"[avatar] 20 次都没等到 FooterView 类");
                    dispatch_source_cancel(tp);
                }
            }
        });
        dispatch_resume(tp);
    }
}
