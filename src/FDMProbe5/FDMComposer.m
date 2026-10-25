// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用

/* ============================================================
 * FDMComposer —— 「模块自己发一条消息」🐲
 *
 * 对标安卓 `GmSender`（382 行），但 iOS 有**更干净的路**。
 *
 * ------------------------------------------------------------
 * 安卓怎么做的（为什么要那么多代码）：
 *   hook Compose 的 ViewModel `gh2`，反射调它的内部静态方法
 *     gh2.h0(gh2, 文本, [], [], "", m1a, ns, false, false, false, false)
 *   最大的坑是「怎么选对会话」——
 *     宿主进程里同时有多个 gh2 实例（每个会话一个），
 *     拿错了就发到别的对话，甚至开新会话。
 *     他们的解法：hook `gh2.W()` 记「被调得最频繁的那个」+ 15 秒 TTL。
 *
 * ------------------------------------------------------------
 * iOS 怎么做（两条路，本文件都实现）：
 *
 *   【路 A · 推荐】往宿主输入框塞文字 + 点发送按钮
 *     = 安卓 `input.c("文字")` + `ao1.I(input)` 的等价物
 *     ✅ 宿主自己做全部工作：UI 立即出现、SSE 流式渲染、落库
 *     ✅ 不需要知道会话 id（本来就是当前会话）
 *     ✅ 不需要反射任何 Swift 私有类型
 *
 *   【路 B · 兜底】抓一条真实 completion 请求当模板，改 prompt 重放
 *     ✅ 一定成功（请求结构已经验证过）
 *     ✗ 宿主 UI 不会自动更新（要等它自己拉历史）
 *     ✗ 需要自己处理 Authorization 等 header
 *
 * ------------------------------------------------------------
 * ⚠️ 铁律
 *   1. 所有 UI 操作必须在主线程
 *   2. 找不到控件就**什么都不做**（只打日志），绝不崩
 *   3. 塞文字/点按钮会触发我们自己的 strip hook ⇒ 必须防重入
 *   4. 绝不 new 一个 NSURLSession 去发（用宿主的会话配置，
 *      否则可能被证书固定 / 自定义 protocol 拦掉）
 * ============================================================ */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreText/CoreText.h>
#import "FLog.h"
#import "FDMConfig.h"

/* ============ 一、配置缓存 ============ */

static BOOL gComposerEnabled = NO;

/* 前置声明（建议按钮点击时要用） */
BOOL FDMComposerSend(NSString *text);

void FDMComposerReload(void) {
    @autoreleasepool {
        @try {
            gComposerEnabled = [[FDMConfig shared] boolFor:@"composer" key:@"enabled"];
        } @catch (NSException *e) { gComposerEnabled = NO; }
        FLOGW(FC_NET, @"[send] 缓存：模块发消息=%d", (int)gComposerEnabled);
    }
}

/* ============ 二、找控件 ============ */

/* 找到当前聊天页的顶层 view
 *
 * ★ 2026-10-17 修正：原来只沿 rootVC → presentedViewController 找，
 *   但聊天页在宿主里挂得**很深**（RootVC → 抽屉容器 → 导航 →
 *   MessageViewController），这条链根本走不到 ⇒ 一直报「不在聊天页」。
 *
 *   改成两条路：
 *     ① 先按 VC 树递归（含 children / nav / tab）找 MessageViewController
 *     ② 找不到就直接把整个 window 当根，靠 BTFindByName 搜 InputAreaView
 *   反正我们最终只要那个 InputAreaView，不一定要先拿到 VC。 */
static UIView *BTFindVCViewByName(UIViewController *vc, const char *needle, int depth) {
    if (!vc || depth > 12) return nil;
    @try {
        const char *cn = class_getName([vc class]);
        if (cn && strstr(cn, needle) != NULL && vc.view && vc.view.window)
            return vc.view;
        for (UIViewController *ch in vc.childViewControllers) {
            UIView *r = BTFindVCViewByName(ch, needle, depth + 1);
            if (r) return r;
        }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIView *r = BTFindVCViewByName(((UINavigationController *)vc).topViewController,
                                           needle, depth + 1);
            if (r) return r;
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIView *r = BTFindVCViewByName(((UITabBarController *)vc).selectedViewController,
                                           needle, depth + 1);
            if (r) return r;
        }
        if (vc.presentedViewController) {
            UIView *r = BTFindVCViewByName(vc.presentedViewController, needle, depth + 1);
            if (r) return r;
        }
    } @catch (NSException *e) { }
    return nil;
}

static UIWindow *BTNormalWindow(void) {
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.windowLevel == UIWindowLevelNormal && w.isKeyWindow) return w;
        }
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.windowLevel == UIWindowLevelNormal) return w;
        }
    }
    return nil;
}

static UIView *FDMChatPageView(void) {
    UIWindow *w = BTNormalWindow();
    if (!w) return nil;
    /* ① 先按 VC 树找聊天页（拿到它的 view 更精准） */
    UIView *v = BTFindVCViewByName(w.rootViewController, "MessageViewController", 0);
    if (v) return v;
    /* ② 兜底：直接把 window 当根，反正后面要找的是 InputAreaView */
    return w;
}

/* 在视图树里找第一个符合类名特征的视图 */
static UIView *BTFindByName(UIView *root, const char *needle, int depth, Class mustBe) {
    if (!root || depth > 20) return nil;
    const char *cn = class_getName([root class]);
    if (cn && strstr(cn, needle) != NULL) {
        if (!mustBe || [root isKindOfClass:mustBe]) return root;
    }
    for (UIView *sv in root.subviews) {
        UIView *r = BTFindByName(sv, needle, depth + 1, mustBe);
        if (r) return r;
    }
    return nil;
}

/* ============================================================
 * ★ 实测结构（2026-10-17 [send-probe] 真机 dump）
 *
 *   DeepSeek_Chat.InputAreaView                        f=(0,0 390x110)
 *     ├ PromptInputView                                 f=(10,4 370x50)
 *     │   └ TextInputView                               f=(0,0 370x46)
 *     │       └ TextInputView.TextView (UITextView)     ★ 输入框
 *     └ ActionAreaView                                  f=(0,58 390x48)
 *         └ SendButton                                  f=(-40,0 36x36)
 *             └ DeepSeek_Chat.DSImageButton (UIButton)  ★ 发送键
 *
 *   ⚠️ 空输入时 SendButton 的父容器宽度是 0（f=(88,6 0x24)），
 *      说明它靠「有没有字」来撑开 ⇒ 必须先塞文字，再找按钮。
 * ============================================================ */

/* 找输入框：InputAreaView 里那个 UITextView */
static UITextView *BTFindInputView(UIView *area) {
    if (!area) return nil;
    /* 优先按 TextInputView 定位（更准） */
    UIView *wrap = BTFindByName(area, "TextInputView", 0, nil);
    UIView *tv = nil;
    if (wrap) tv = BTFindByName(wrap, "TextView", 0, [UITextView class]);
    if (!tv) tv = BTFindByName(area, "TextView", 0, [UITextView class]);
    if (!tv) return nil;
    /* 排除 BANNER 里那个 0x0 的装饰性 UITextView */
    if (tv.bounds.size.width < 100 && tv.bounds.size.height < 20) {
        UIView *alt = nil;
        for (UIView *sv in area.subviews) {
            UIView *r = BTFindByName(sv, "TextInputView", 0, nil);
            if (r) {
                alt = BTFindByName(r, "TextView", 0, [UITextView class]);
                if (alt) break;
            }
        }
        if (alt) tv = alt;
    }
    return (UITextView *)tv;
}

/* 找发送键：SendButton 容器里的那个 UIButton */
static UIButton *BTFindSendButtonExact(UIView *area) {
    if (!area) return nil;
    UIView *cont = BTFindByName(area, "SendButton", 0, nil);
    if (!cont) return nil;
    /* 容器自己可能就是个 view，里面藏着 DSImageButton */
    UIView *b = BTFindByName(cont, "Button", 0, [UIButton class]);
    if (b) return (UIButton *)b;
    /* 退一步：容器本身就是按钮 */
    NSMutableArray<UIView *> *st = [NSMutableArray arrayWithObject:cont];
    int g = 0;
    while (st.count && g++ < 500) {
        UIView *v = st.lastObject;
        [st removeLastObject];
        if ([v isKindOfClass:[UIButton class]]) return (UIButton *)v;
        for (UIView *z in v.subviews) [st addObject:z];
    }
    return nil;
}

/* ============ 三、诊断：把输入区整棵树打出来 ============ */

static void BTLogSubtree(UIView *v, int depth) {
    if (!v || depth > 12) return;
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];
    const char *cn = class_getName([v class]);
    NSString *extra = @"";
    if ([v isKindOfClass:[UITextView class]]) {
        extra = [NSString stringWithFormat:@" TEXTVIEW txt=「%@」",
                 ((UITextView *)v).text ?: @""];
    } else if ([v isKindOfClass:[UIButton class]]) {
        extra = [NSString stringWithFormat:@" BUTTON title=「%@」targets=%lu",
                 [((UIButton *)v) titleForState:UIControlStateNormal] ?: @"",
                 (unsigned long)[((UIButton *)v) allTargets].count];
    } else if ([v isKindOfClass:[UIControl class]]) {
        extra = [NSString stringWithFormat:@" CONTROL targets=%lu",
                 (unsigned long)[((UIControl *)v) allTargets].count];
    }
    FLOGW(FC_UI, @"[send-probe] %@%s f=(%.0f,%.0f %.0fx%.0f)%@",
          pad, cn, v.frame.origin.x, v.frame.origin.y,
          v.frame.size.width, v.frame.size.height, extra);
    for (UIView *sv in v.subviews) BTLogSubtree(sv, depth + 1);
}

void FDMComposerProbe(void) {
    UIView *page = FDMChatPageView();
    if (!page) {
        FLOGW(FC_UI, @"[send-probe] 不在聊天页");
        return;
    }
    UIView *area = BTFindByName(page, "InputAreaView", 0, nil);
    FLOGW(FC_UI, @"[send-probe] ==== 输入区结构 ====");
    if (area) {
        BTLogSubtree(area, 0);
    } else {
        FLOGW(FC_UI, @"[send-probe] 没找到 InputAreaView，改 dump 整页");
        BTLogSubtree(page, 0);
    }
    FLOGW(FC_UI, @"[send-probe] ==== 结束 ====");
}

/* ============ 四、路 A：塞文字 + 点发送 ============ */

/* 找发送按钮：文字是「发送」或够不着时退而求其次找最后一个 UIButton */
__attribute__((unused))
static UIButton *BTFindSendButton(UIView *area) {
    NSMutableArray<UIButton *> *cands = [NSMutableArray array];
    NSMutableArray<UIView *> *st = [NSMutableArray arrayWithObject:area];
    int guard = 0;
    while (st.count && guard++ < 2000) {
        UIView *v = st.lastObject;
        [st removeLastObject];
        if ([v isKindOfClass:[UIButton class]]) [cands addObject:(UIButton *)v];
        for (UIView *z in v.subviews) [st addObject:z];
    }
    /* 优先按标题匹配 */
    for (UIButton *b in cands) {
        NSString *t = [b titleForState:UIControlStateNormal] ?: @"";
        if ([t isEqualToString:@"发送"] || [t isEqualToString:@"Send"] ||
            [t isEqualToString:@"send"]) {
            if (b.allTargets.count > 0) return b;
        }
    }
    /* 退而求其次：有 target 的最后一个（布局上发送键在右侧） */
    for (UIButton *b in cands.reverseObjectEnumerator) {
        if (b.allTargets.count > 0 && !b.hidden && b.alpha > 0.1) return b;
    }
    return nil;
}

/* 给 UITextView 设置文字并触发 textDidChange（否则宿主的发送按钮不会变可用） */
static void BTSetInputText(UIView *input, NSString *text) {
    if (!input) return;
    @try {
        if ([input isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)input;
            tv.text = text;
            /* ★ 手动发一次 UITextViewTextDidChangeNotification ——
             *   宿主的「发送按钮可用性」多半是监听这个改的。
             *   直接 setText: 不会触发它。 */
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UITextViewTextDidChangeNotification object:tv];
            /* 有些实现同时看 delegate */
            if (tv.delegate &&
                [tv.delegate respondsToSelector:@selector(textViewDidChange:)]) {
                [tv.delegate textViewDidChange:tv];
            }
        } else if ([input isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)input;
            tf.text = text;
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UITextFieldTextDidChangeNotification object:tf];
            if (tf.delegate &&
                [tf.delegate respondsToSelector:@selector(textField:shouldChangeCharactersInRange:replacementString:)]) {
                /* 不调，只靠通知 */
            }
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[send] 设文字异常: %@", e.reason);
    }
}

/* 返回 YES = 已经把「塞文字 + 点发送」的意图发出去了 */
BOOL FDMComposerSendViaUI(NSString *text) {
    if (!gComposerEnabled) return NO;
    if (!text.length) return NO;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FDMComposerSendViaUI(text);
        });
        return YES;
    }

    UIView *page = FDMChatPageView();
    if (!page) {
        FLOGW(FC_UI, @"[send] 找不到窗口，放弃");
        return NO;
    }
    UIView *area = BTFindByName(page, "InputAreaView", 0, nil);
    if (!area) {
        FLOGW(FC_UI, @"[send] 找不到 InputAreaView（可能不在聊天页）");
        return NO;
    }

    UITextView *input = BTFindInputView(area);
    if (!input) {
        FLOGW(FC_UI, @"[send] 找不到输入框");
        return NO;
    }

    /* ① 塞文字 + 触发变更通知（宿主靠这个把 SendButton 撑开） */
    BTSetInputText(input, text);
    FLOGW(FC_UI, @"[send] 已填入输入框（%lu 字），等布局刷新…",
          (unsigned long)text.length);

    /* ② 等一帧（0.25s）再找按钮点 —— 空输入时容器宽度是 0，
     *    立刻找会拿到一个点不动的按钮。 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool {
            UIView *pg = FDMChatPageView();
            UIView *ar = pg ? BTFindByName(pg, "InputAreaView", 0, nil) : nil;
            UIButton *btn = BTFindSendButtonExact(ar);
            if (!btn) {
                FLOGW(FC_UI, @"[send] 找不到发送键（文字已填好，请手动点）");
                return;
            }
            /* ★ 用 sendActionsForControlEvents: 走宿主自己的全部校验
             *   （比如「正在生成时禁止发送」），比直接调 target-action 安全 */
            @try {
                [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                FLOGW(FC_UI, @"[send] ★ 已点击发送键 %@（f=%.0fx%.0f hidden=%d）",
                      NSStringFromClass([btn class]),
                      btn.bounds.size.width, btn.bounds.size.height, (int)btn.hidden);
            } @catch (NSException *e) {
                FLOGE(FC_UI, @"[send] 点按钮异常: %@", e.reason);
            }
        }
    });
    return YES;
}

/* ============ 五、路 B：请求模板重放 ============ */

static NSURLRequest *gTplReq = nil;      /* 最近一条 completion 请求（模板） */
static __weak NSURLSession *gTplSession = nil;
static NSString *gTplSessionId = nil;

/* 由 HandleReq 调用：把这条请求存成模板 */
void FDMComposerCapture(NSURLRequest *req, NSURLSession *sess) {
    if (!req) return;
    @try {
        NSData *b = req.HTTPBody;
        if (!b.length) return;
        id j = [NSJSONSerialization JSONObjectWithData:b options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) return;
        NSString *sid = ((NSDictionary *)j)[@"chat_session_id"];
        if (![sid isKindOfClass:[NSString class]] || !sid.length) return;

        gTplReq = [req copy];
        gTplSession = sess;
        gTplSessionId = sid;
        FLOGW(FC_NET, @"[send] 已记录请求模板（session=%@…）", [sid substringToIndex:8]);
    } @catch (NSException *e) { }
}

BOOL FDMComposerReady(void) { return gTplReq != nil; }
NSString *FDMComposerStatus(void) {
    if (!gTplReq) return @"未记录请求模板（先手动发一条消息）";
    return [NSString stringWithFormat:@"模板就绪 · session=%@…",
            gTplSessionId.length >= 8 ? [gTplSessionId substringToIndex:8] : @"?"];
}

/* 返回 YES = 请求已发出 */
BOOL FDMComposerSendViaReplay(NSString *text) {
    if (!gComposerEnabled) return NO;
    if (!text.length) return NO;
    if (!gTplReq) {
        FLOGW(FC_NET, @"[send] 没有模板，先手动发一条消息");
        return NO;
    }
    @try {
        NSMutableURLRequest *r = [gTplReq mutableCopy];
        NSData *b = gTplReq.HTTPBody;
        id j = [NSJSONSerialization JSONObjectWithData:b
                                              options:NSJSONReadingMutableContainers
                                                error:nil];
        if (![j isKindOfClass:[NSMutableDictionary class]]) return NO;
        NSMutableDictionary *m = j;

        /* ★ 只改这几个字段，其余原样保留（model_type / thinking / search …） */
        m[@"prompt"] = text;
        m[@"parent_message_id"] = [NSNull null];   /* 让服务端自己接最后一轮 */
        NSData *nb = [NSJSONSerialization dataWithJSONObject:m options:0 error:nil];
        if (!nb) return NO;
        r.HTTPBody = nb;
        [r setValue:[NSString stringWithFormat:@"%lu", (unsigned long)nb.length]
            forHTTPHeaderField:@"Content-Length"];

        NSURLSession *sess = gTplSession;
        if (!sess) sess = [NSURLSession sharedSession];

        /* 防止被自己的 hook 再拦（不然 prompt 会被二次注入） */
        extern void FDMProbeSetReplay(BOOL on);
        FDMProbeSetReplay(YES);

        NSURLSessionDataTask *t =
            [sess dataTaskWithRequest:r
                    completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
            @autoreleasepool {
                FDMProbeSetReplay(NO);
                NSInteger st = [resp isKindOfClass:[NSHTTPURLResponse class]]
                               ? ((NSHTTPURLResponse *)resp).statusCode : -1;
                FLOGW(FC_NET, @"[send] ★ 重放完成 HTTP=%ld %lu B %@",
                      (long)st, (unsigned long)d.length, e ? e.localizedDescription : @"");
                if (d.length) {
                    NSString *s = [[NSString alloc] initWithData:d
                                                        encoding:NSUTF8StringEncoding];
                    if (s.length > 200) s = [s substringToIndex:200];
                    FLOGI(FC_NET, @"[send] 响应头 200 字: %@", s);
                }
            }
        }];
        [t resume];
        FLOGW(FC_NET, @"[send] ★ 已重放请求（prompt=「%@」%lu 字）",
              text.length > 20 ? [[text substringToIndex:20] stringByAppendingString:@"…"] : text,
              (unsigned long)text.length);
        return YES;
    } @catch (NSException *e) {
        FLOGE(FC_NET, @"[send] 重放异常: %@", e.reason);
        return NO;
    }
}

/* ============================================================
 * ★ 建议按钮的「点击即发送」（2026-10-17 P4）
 *
 *   问题：AI 正文承载控件是 **UILabel**，UILabel 不响应 .link。
 *   方案：给承载建议按钮的那个 UILabel 挂一个 tap 手势，
 *         用「点击位置 → attributedString 索引 → FDMSugPayload」反查。
 *
 *   为什么可行：NSLayoutManager 能把点坐标映射到字符索引，
 *   我们自己算一遍就能知道点到了哪一段。
 * ============================================================ */

/* 从「文本 + 字符索引」取出 payload
 *
 * ★ 为什么不查 attribute：宿主在 setAttributedText 之后会重建
 *   attributedString，**自定义 attribute 全被清掉**（实测数为 0）。
 *   ⇒ 改用文本内容查表（string 通常不变）。 */
extern NSArray<NSDictionary *> *FDMSugsForText(NSString *text);

__attribute__((unused))
static NSString *BTGetSugPayloadAtText(NSString *text, NSUInteger idx) {
    if (!text.length) return nil;
    @try {
        NSArray<NSDictionary *> *list = FDMSugsForText(text);
        if (!list.count) return nil;
        for (NSDictionary *d in list) {
            NSValue *rv = d[@"range"];
            NSString *pl = d[@"payload"];
            if (![rv isKindOfClass:[NSValue class]] || ![pl isKindOfClass:[NSString class]])
                continue;
            NSRange r = [rv rangeValue];
            if (idx >= r.location && idx < NSMaxRange(r)) return pl;
        }
    } @catch (NSException *e) { }
    return nil;
}

/* 兼容旧签名（attribute 版），保留但不用 */
__attribute__((unused))
static NSString *BTGetSugPayloadAt(NSAttributedString *as, NSUInteger idx) {
    if (![as isKindOfClass:[NSAttributedString class]] || idx >= as.length) return nil;
    @try {
        NSRange eff = NSMakeRange(0, 0);
        NSDictionary *a = [as attributesAtIndex:idx effectiveRange:&eff];
        id v = a[@"FDMSugPayload"];
        return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
    } @catch (NSException *e) { return nil; }
}

static NSUInteger BTCharIndexAtPointWith(UILabel *lb, CGPoint p,
                                         NSAttributedString *as);

/* 把「点在 UILabel 上的坐标」换算成字符索引 */
static NSUInteger BTCharIndexAtPoint(UILabel *lb, CGPoint p) {
    if (!lb) return NSNotFound;
    /* 宿主可能只设了 text 而 attributedText 为空 ⇒ 临时造一个用于测量 */
    if (!lb.attributedText.length) {
        if (!lb.text.length) return NSNotFound;
        NSMutableAttributedString *tmp =
            [[NSMutableAttributedString alloc] initWithString:lb.text
                                                   attributes:@{NSFontAttributeName:
                                                       lb.font ?: [UIFont systemFontOfSize:16]}];
        return BTCharIndexAtPointWith(lb, p, tmp);
    }
    @try {
        /* 用 CoreText 算：先算 inset（UILabel 默认可能有） */
        return BTCharIndexAtPointWith(lb, p, lb.attributedText);
    } @catch (NSException *e) {
        return NSNotFound;
    }
}

/* 真正干活的那个（可传入任意 attributedString 用于测量） */
static NSUInteger BTCharIndexAtPointWith(UILabel *lb, CGPoint p, NSAttributedString *as) {
    if (!lb || !as.length) return NSNotFound;
    @try {
        CGSize sz = lb.bounds.size;

        /* UILabel 的垂直对齐可能居中，这里按「上对齐」近似，
         * 差几个像素不影响命中判定（我们要的是"点到哪一段"）。 */
        UIEdgeInsets ins = UIEdgeInsetsZero;
        if (lb.numberOfLines != 1 && [lb respondsToSelector:@selector(textInsets)]) {
            /* iOS 15 没有 textInsets，跳过 */
        }
        CGRect box = CGRectMake(ins.left, ins.top,
                                sz.width - ins.left - ins.right,
                                sz.height - ins.top - ins.bottom);

        UIBezierPath *path = [UIBezierPath bezierPathWithRect:box];
        NSMutableParagraphStyle *ps = nil;
        id exist = [as attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL];
        if ([exist isKindOfClass:[NSParagraphStyle class]])
            ps = [(NSParagraphStyle *)exist mutableCopy];
        if (!ps) ps = [NSMutableParagraphStyle new];
        ps.alignment = lb.textAlignment;   /* ★ 必须和 label 一致，否则算错 */

        CTFrameRef frame = NULL;
        CTFramesetterRef fs = CTFramesetterCreateWithAttributedString(
            (__bridge CFAttributedStringRef)as);
        if (!fs) return NSNotFound;
        CTFrameRef f = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0),
            (__bridge CGPathRef)path, NULL);
        frame = f;
        if (!frame) { CFRelease(fs); return NSNotFound; }

        CFArrayRef lines = CTFrameGetLines(frame);
        CFIndex nLines = CFArrayGetCount(lines);
        CGPoint *origins = malloc(sizeof(CGPoint) * (size_t)nLines);
        CTFrameGetLineOrigins(frame, CFRangeMake(0, nLines), origins);

        NSUInteger result = NSNotFound;
        for (CFIndex i = 0; i < nLines; i++) {
            CGPoint o = origins[i];
            /* CoreText 原点在左下，UIKit 在左上 ⇒ 翻转 y */
            CGPoint t = CGPointMake(p.x, lb.bounds.size.height - p.y);
            CTLineRef line = (CTLineRef)CFArrayGetValueAtIndex(lines, i);
            CGPoint next = (i + 1 < nLines) ? origins[i + 1] : CGPointMake(0, 0);
            CGFloat top = i + 1 < nLines ? next.y : 0;
            CGFloat bottom = o.y;
            if (t.y <= bottom && t.y >= top) {
                CFIndex idx = CTLineGetStringIndexForPosition(line,
                                                              CGPointMake(t.x - o.x, t.y - o.y));
                if (idx != kCFNotFound) result = (NSUInteger)idx;
                break;
            }
        }
        free(origins);
        CFRelease(frame);
        CFRelease(fs);
        return result;
    } @catch (NSException *e) {
        return NSNotFound;
    }
}

/* 手势 handler */
@interface FDMSugTapTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation FDMSugTapTarget
- (void)onTap:(UITapGestureRecognizer *)g {
    @try {
        UILabel *lb = (UILabel *)g.view;
        if (![lb isKindOfClass:[UILabel class]]) return;
        CGPoint p = [g locationInView:lb];
        NSUInteger idx = BTCharIndexAtPoint(lb, p);
        if (idx == NSNotFound) return;
        NSString *payload = BTGetSugPayloadAt(lb.attributedText, idx);
        if (!payload.length) return;
        FLOGW(FC_UI, @"[sug] ★ 点击建议「%@」，发送…", payload);
        FDMComposerSend(payload);
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[sug] 点击处理异常: %@", e.reason);
    }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return YES;   /* 允许同时识别，不抢宿主的手势链 */
}

/* ★ 覆盖按钮的点击（真正生效的那条路） */
- (void)onButton:(UIButton *)b {
    @try {
        NSString *pl = objc_getAssociatedObject(b, "fdm_sug_payload");
        if (![pl isKindOfClass:[NSString class]] || !pl.length) return;
        FLOGW(FC_UI, @"[sug] ★ 覆盖按钮命中，发送「%@」", pl);
        b.enabled = NO;         /* 防连点 */
        FDMComposerSend(pl);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ b.enabled = YES; });
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[sug] 按钮处理异常: %@", e.reason);
    }
}

/* ★ 让我们的 tap 优先于宿主的"文字选择"手势 —— 
 *   返回 YES = 我们先处理。 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)o {
    return NO;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
        shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)o {
    return NO;
}
@end

static FDMSugTapTarget *gSugTap = nil;

/* ============================================================
 * ★★★ 覆盖层方案（2026-10-17 主人的主意）
 *
 *   试过三种都抢不到点击：
 *     ① UILabel + tap 手势
 *     ② delegate 优先级各种组合
 *     ③ hook -[UIWindow sendEvent:] 做 hit-test
 *   原因：宿主在消息正文上盖了 TextSelectionMenuHostView，
 *        它自己的手势链优先；且 sendEvent 里我们拿到的已经是"事后"。
 *
 *   ⇒ 在建议文字**上方浮一个真正的透明 UIButton**。
 *     按钮是 UIKit 控件，事件直接进它，不经过选择层。
 * ============================================================ */

static NSMapTable<UIView *, UIButton *> *gSugBtns = nil;

/* 用 CoreText 算「某个字符区间在 UILabel 里的矩形」（label 本地坐标） */
static CGRect BTRectForRange(UILabel *lb, NSRange range) {
    if (!lb || !lb.text.length || range.length == 0) return CGRectZero;
    @try {
        NSString *txt = lb.text;
        if (NSMaxRange(range) > txt.length) return CGRectZero;

        NSMutableAttributedString *as =
            [[NSMutableAttributedString alloc] initWithString:txt
                                                   attributes:@{NSFontAttributeName:
                                                       lb.font ?: [UIFont systemFontOfSize:16]}];
        if (lb.attributedText.length == txt.length) as = [lb.attributedText mutableCopy];

        /* ⚠️ 绝对不能覆盖 paragraphStyle！
         *   一旦改了对齐/换行模式，CoreText 算出的换行位置就变了，
         *   于是算出来的矩形和屏幕上的实际位置对不上（实测按钮偏上）。
         *   ⇒ 保留原文属性，只补一个「缺省」的对齐（如果原来没有）。 */
        if (![as attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL]) {
            NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
            ps.alignment = lb.textAlignment;
            ps.lineBreakMode = lb.lineBreakMode;
            [as addAttribute:NSParagraphStyleAttributeName value:ps
                      range:NSMakeRange(0, as.length)];
        }

        CGRect box = lb.bounds;
        UIBezierPath *path = [UIBezierPath bezierPathWithRect:box];
        CTFramesetterRef fs = CTFramesetterCreateWithAttributedString(
            (__bridge CFAttributedStringRef)as);
        if (!fs) return CGRectZero;
        CTFrameRef frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0),
                                                    (__bridge CGPathRef)path, NULL);
        if (!frame) { CFRelease(fs); return CGRectZero; }

        CGFloat minX = CGFLOAT_MAX, minY = CGFLOAT_MAX;
        CGFloat maxX = -1, maxY = -1;
        CFArrayRef lines = CTFrameGetLines(frame);
        CFIndex nL = CFArrayGetCount(lines);
        CGPoint *org = malloc(sizeof(CGPoint) * (size_t)(nL > 0 ? nL : 1));
        CTFrameGetLineOrigins(frame, CFRangeMake(0, nL), org);

        for (CFIndex i = 0; i < nL; i++) {
            CTLineRef line = (CTLineRef)CFArrayGetValueAtIndex(lines, i);
            CFRange lr = CTLineGetStringRange(line);
            NSUInteger ls = (NSUInteger)lr.location;
            NSUInteger le = ls + (NSUInteger)lr.length;
            if (le <= range.location || ls >= NSMaxRange(range)) continue;

            CGFloat asc = 0, desc = 0;
            CTLineGetTypographicBounds(line, &asc, &desc, NULL);
            CGFloat a = 0, d = 0;
            if (range.location > ls)
                a = CTLineGetOffsetForStringIndex(line, (CFIndex)range.location, NULL);
            NSUInteger hr = MIN(NSMaxRange(range), le);
            d = (hr > ls) ? CTLineGetOffsetForStringIndex(line, (CFIndex)hr, NULL)
                          : (a + CTLineGetTypographicBounds(line, NULL, NULL, NULL));

            CGFloat x0 = org[i].x + a;
            CGFloat x1 = org[i].x + d;
            CGFloat yBase = org[i].y;
            CGFloat y0 = box.size.height - (yBase + asc);
            CGFloat y1 = box.size.height - (yBase - desc);

            minX = MIN(minX, x0); maxX = MAX(maxX, x1);
            minY = MIN(minY, y0); maxY = MAX(maxY, y1);
        }
        free(org);
        CFRelease(frame);
        CFRelease(fs);

        if (maxX <= minX || maxY <= minY) return CGRectZero;
        return CGRectMake(minX, minY, maxX - minX, maxY - minY);
    } @catch (NSException *e) {
        return CGRectZero;
    }
}

/* 给某个 label 铺建议按钮（幂等：先清旧的） */
void FDMEnsureSugTap(UILabel *lb) {
    if (!lb || ![lb isKindOfClass:[UILabel class]]) return;
    if (![NSThread isMainThread]) {
        __weak UILabel *weakLb = lb;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakLb) FDMEnsureSugTap(weakLb);
        });
        return;
    }
    if (!gSugTap) gSugTap = [FDMSugTapTarget new];
    if (!gSugBtns) gSugBtns = [NSMapTable weakToStrongObjectsMapTable];
    @try {
        UIButton *old = [gSugBtns objectForKey:lb];
        if (old) { [old removeFromSuperview]; [gSugBtns removeObjectForKey:lb]; }

        NSArray<NSDictionary *> *sugs = FDMSugsForText(lb.text);
        if (!sugs.count) return;

        UIView *host = lb.superview;
        if (!host) return;

        UIButton *lastBtn = nil;
        for (NSDictionary *d in sugs) {
            NSValue *rv = d[@"range"];
            NSString *pl = d[@"payload"];
            if (![rv isKindOfClass:[NSValue class]] || ![pl isKindOfClass:[NSString class]])
                continue;
            CGRect local = BTRectForRange(lb, [rv rangeValue]);
            if (CGRectIsEmpty(local)) continue;
            local = CGRectInset(local, -4, -3);
            CGRect inHost = [host convertRect:local fromView:lb];

            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = inHost;
            btn.backgroundColor = [UIColor clearColor];
            btn.tag = 0x0D1A0521;
            objc_setAssociatedObject(btn, "fdm_sug_payload", pl,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [btn addTarget:gSugTap action:@selector(onButton:)
                   forControlEvents:UIControlEventTouchUpInside];
            [host addSubview:btn];
            lastBtn = btn;
            FLOGW(FC_UI, @"[sug] ★ 覆盖按钮 %.0fx%.0f @(%.0f,%.0f) →「%@」",
                  inHost.size.width, inHost.size.height,
                  inHost.origin.x, inHost.origin.y, pl);
        }
        if (lastBtn) [gSugBtns setObject:lastBtn forKey:lb];
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[sug] 铺按钮异常: %@", e.reason);
    }
}


/* 兼容：sendEvent 钩子已废弃（改用覆盖层方案），保留空实现避免链接错误 */
void FDMInstallSugEventHook(void) { }

/* ============================================================
 * ★★★ 真气泡方案（2026-10-17 · 主人的主意，最可靠）
 *
 *   前面几种全失败的原因：
 *     宿主的正文文字上盖了 TextSelectionMenuHostView，
 *     我们加在 label 上的任何手势 / 覆盖按钮都被它吃掉。
 *
 *   ⇒ 干脆**不用宿主的文字**：
 *     在 AgentMessageCell 里插一个**我们自己的容器**，
 *     里面放真正的 UIButton。它是独立视图，不跟宿主的
 *     手势链、attributedString、cell 复用纠缠。
 *
 *   位置：贴 cell 底部往上排（autoresizing 贴底），
 *        不改变宿主任何布局 ⇒ 零风险。
 *
 *   捕获不到 <Suggestion> 就整块不显示（干净）。
 * ============================================================ */

#define BT_SUGBOX_TAG   0x0D1A0530
#define BT_SUGBTN_TAG   0x0D1A0531

/* ★ 记住「cell 指针 → 原始文本」，供定时重铺用 */
static NSMapTable<UIView *, NSString *> *gSugCellMap = nil;

/* ★★★ 2026-10-17 修（anchors）：记住「哪个视图承载了建议文本」
 *
 *   为什么必须有这张表：
 *     AI 正文的承载控件是 Swift 泛型类
 *       _TtGC13DeepSeek_Chat17PlainTextNodeViewOS_23ResponseMarkdownAdapter_
 *     —— **不是 UILabel**。
 *     而巡检旧版只扫 UILabel ⇒ 永远扫不到它 ⇒
 *     FDMEnsureSugBox 一生只被调一次 ⇒ BTTextStable 第一次必然返回 NO
 *     ⇒ 按钮永远不出现（日志停在「准备铺」就是这个原因）。
 *
 *   这张表在 EnsureSugBox 的**最开头**登记（在稳定性检查之前），
 *   巡检只遍历它（几个条目），不再全树扫描 —— 又快又准。
 */
static NSMapTable<UIView *, NSString *> *gSugAnchors = nil;

/* ★ 安全版锚点容器（2026-10-17）：
 *   NSPointerArray 用 weak 语义，视图释放后槽位自动变 NULL，
 *   枚举时绝不会拿到野指针（NSMapTable 的 keyEnumerator 做不到这点）。
 *   文本用 NSMapTable（key weak / value strong）单独存。 */
static NSPointerArray *gSugAnchorList = nil;

static void BTRegAnchor(UIView *v, NSString *raw) {
    if (!v || !raw.length) return;
    if (!gSugAnchorList) {
        gSugAnchorList = [NSPointerArray weakObjectsPointerArray];
        gSugAnchorList.count = 0;
    }
    if (!gSugAnchors) gSugAnchors = [NSMapTable weakToStrongObjectsMapTable];
    NSUInteger idx = NSNotFound;
    for (NSUInteger i = 0; i < gSugAnchorList.count; i++) {
        if ([gSugAnchorList pointerAtIndex:i] == (__bridge void *)v) { idx = i; break; }
    }
    if (idx == NSNotFound) {
        if (gSugAnchorList.count > 60) {   /* 上限，防泄漏 */
            NSPointerArray *nl = [NSPointerArray weakObjectsPointerArray];
            nl.count = 0;
            for (NSUInteger i = 30; i < gSugAnchorList.count; i++)
                [nl addPointer:[gSugAnchorList pointerAtIndex:i]];
            gSugAnchorList = nl;
        }
        [gSugAnchorList addPointer:(__bridge void *)v];
    }
    [gSugAnchors setObject:[raw copy] forKey:v];
}



extern NSUInteger gSugRegistryCount(void);

/* ============================================================
 * ★★★ 流式稳定检测（2026-10-17 主人定的方案）
 *
 *   问题：AI 回复是流式的，文字一直在长，
 *     · 这期间铺的按钮位置必然偏（后面文字还在变）
 *     · 而且铺完就不再更新 ⇒ 必须重启 App 才刷新
 *
 *   ⇒ 记录每个 label 上次的文本 + 变化时刻。
 *     只有「文本在最近 STABLE_MS 内没变过」才认为回复结束，
 *     这时才铺按钮 —— 位置是最终位置，一次到位。
 * ============================================================ */
#define BT_STABLE_MS 800

static NSMapTable<UIView *, NSString *>    *gLastText = nil;   /* label → 上次文本 */
static NSMapTable<UIView *, NSNumber *>    *gLastAt   = nil;   /* label → 时间戳 */

/* 返回 YES = 这段文本已经稳定（可以铺了） */
__attribute__((unused))
static BOOL BTTextStable(UIView *v, NSString *txt) {
    if (!v || !txt.length) return NO;
    if (!gLastText) gLastText = [NSMapTable weakToStrongObjectsMapTable];
    if (!gLastAt)   gLastAt   = [NSMapTable weakToStrongObjectsMapTable];

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *prev = [gLastText objectForKey:v];
    if (![prev isEqualToString:txt]) {
        /* 变了 ⇒ 重新计时 */
        [gLastText setObject:[txt copy] forKey:v];
        [gLastAt setObject:@(now) forKey:v];
        return NO;
    }
    NSNumber *at = [gLastAt objectForKey:v];
    if (!at) { [gLastAt setObject:@(now) forKey:v]; return NO; }
    return ((now - at.doubleValue) * 1000.0) >= BT_STABLE_MS;
}

/* ★ 判断是不是「思考块」里的文字 —— 那里面的 <Suggestion> 不该渲染成按钮
 *   实测类名：_TtGC13DeepSeek_Chat17PlainTextNodeViewOS_23ThinkingMarkdownA...
 *   ⇒ 沿 superview 链看有没有 Thinking */
static BOOL BTIsThinkingNode(UIView *v) {
    int d = 0;
    for (UIView *p = v; p && d++ < 16; p = p.superview) {
        const char *cn = class_getName([p class]);
        if (!cn) continue;
        if (strstr(cn, "Thinking") != NULL) return YES;
        if (strstr(cn, "AgentMessageCell") != NULL) return NO;   /* 到 cell 就停 */
    }
    return NO;
}

/* 沿 superview 往上找消息 cell */
static UIView *BTFindMsgCell(UIView *v) {
    int d = 0;
    for (UIView *p = v; p && d++ < 20; p = p.superview) {
        const char *cn = class_getName([p class]);
        if (!cn) continue;
        if (strstr(cn, "AgentMessageCell") != NULL ||
            strstr(cn, "UserMessageCell") != NULL ||
            strstr(cn, "BaseMessageCell") != NULL) {
            return p;
        }
    }
    return nil;
}

/* 从原始文本解析 <Suggestion>显示|发送</Suggestion>
 * 返回 @[@{@"show":…, @"payload":…}, …] */
static NSArray<NSDictionary *> *ParseSuggestions(NSString *raw) {
    if (!raw.length) return nil;
    NSMutableArray *out = [NSMutableArray array];
    @try {
        NSString *s = raw;
        NSUInteger i = 0;
        int guard = 0;
        while (i < s.length && guard++ < 30) {
            NSRange ro = [s rangeOfString:@"<Suggestion>"
                                  options:NSCaseInsensitiveSearch
                                    range:NSMakeRange(i, s.length - i)];
            if (ro.location == NSNotFound) break;
            NSUInteger bs = NSMaxRange(ro);
            NSRange rc = [s rangeOfString:@"</Suggestion>"
                                  options:NSCaseInsensitiveSearch
                                    range:NSMakeRange(bs, s.length - bs)];
            if (rc.location == NSNotFound) break;
            NSString *inner = [s substringWithRange:
                               NSMakeRange(bs, rc.location - bs)];
            inner = [inner stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *show = inner, *payload = inner;
            NSRange bar = [inner rangeOfString:@"|"];
            if (bar.location != NSNotFound) {
                show = [[inner substringToIndex:bar.location]
                        stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
                payload = [[inner substringFromIndex:bar.location + 1]
                           stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
            }
            /* 去掉 ▸ › > 之类装饰（★ show 和 payload 都要去） */
            while (show.length) {
                unichar c0 = [show characterAtIndex:0];
                if (c0 == 0x25B8 || c0 == 0x203A || c0 == '>' ||
                    c0 == 0x2022 || c0 == 0x00B7 || c0 == ' ') {
                    show = [show substringFromIndex:1];
                } else break;
            }
            {
                BOOL cut2 = YES;
                while (cut2 && payload.length) {
                    cut2 = NO;
                    unichar c0 = [payload characterAtIndex:0];
                    if (c0 == 0x25B8 || c0 == 0x203A || c0 == '>' ||
                        c0 == 0x2022 || c0 == 0x00B7 || c0 == ' ') {
                        payload = [payload substringFromIndex:1];
                        cut2 = YES;
                    }
                }
            }
            if (show.length && payload.length) {
                [out addObject:@{ @"show": show, @"payload": payload }];
            }
            i = NSMaxRange(rc);
        }
    } @catch (NSException *e) { }
    return out.count ? out : nil;
}

/* ★ 自定义按钮：重写 touchesEnded 拿到**准确的触摸点**
 *   （UIButton 本身不给手势位置，只能自己接） */
@interface FDMSugHitButton : UIButton
@end

@implementation FDMSugHitButton
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    @try {
        UITouch *t = touches.anyObject;
        CGPoint p = [t locationInView:self];
        SEL sel = NSSelectorFromString(@"handleHitAt:");
        if (self.superview && [self.superview respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.superview performSelector:sel withObject:[NSValue valueWithCGPoint:p]];
#pragma clang diagnostic pop
        }
    } @catch (NSException *e) { }
    /* 不调 super —— 避免 UIButton 自己的高亮逻辑干扰 */
}
@end

/* ============================================================
 * ★★★ 建议按钮 v3（2026-10-17 深夜 · 尼尼重写）
 *
 * 旧版一次说清的问题：
 *   ① 透明点击层**盖住整个正文视图** ⇒ 长按选中/复制全被吞掉，
 *      点正文空白处也会走一遍字符索引换算。
 *   ② 只靠字符索引反查、视觉完全交给宿主画 ⇒ AI 在回复中间写
 *      <Suggestion> 时，建议就长在回复中间，看着"位置偏上"。
 *   ③ 宿主重建 cell 后旧框不摘 ⇒ 老消息残留。
 *   ④ objc_setAssociatedObject 用 ASSIGN 存视图 ⇒ 野指针。
 *   ⑤ 巡检每 0.35s 对同一批 anchor 重算 + 打日志 ⇒ 白烧 CPU（7P 只有 2G）。
 *
 * v3 的做法：
 *   · 在 -[setAttributedText:] 里截获**宿主真正渲染的那份
 *     NSAttributedString**，用 CoreText 只算「建议那段字符」的矩形
 *     ⇒ 覆盖层只盖住那几行，其它地方一点都不挡。
 *   · 覆盖层是**无文字的圆角胶囊**：外观由宿主画的蓝字撑着，
 *     我们只加一层淡底 + 圆角 + 点击。视觉与点击区域完全同源，
 *     不存在"差几个像素"。
 *   · 算不出矩形就**什么都不加**（优雅降级：蓝字还在，只是不能点）。
 *   · anchor 用弱引用包裹；文本里没建议了就摘框。
 * ============================================================ */

/* 弱引用包裹（替代 OBJC_ASSOCIATION_ASSIGN —— 它不会置空，会读到野指针） */
@interface FDMSugWeakRef : NSObject
@property (nonatomic, weak) UIView *v;
@end
@implementation FDMSugWeakRef
@end

/* anchor → 宿主渲染用的 NSAttributedString（算矩形必须用它，不能用我们自己拼的） */
static NSMapTable<UIView *, NSAttributedString *> *gSugAS = nil;

/* anchor → 它的胶囊容器（★ 一个 cell 里可能有多个正文视图，各管各的，
 *   以前按 cell tag 找框，两个 anchor 会互相抢、每 0.35s 打架一次） */
static NSMapTable<UIView *, UIView *> *gSugBoxes = nil;

/* ★ 所有还活着的胶囊容器（强引用，最多 80 个）。
 *   宿主重建正文视图后，旧 anchor 会释放、weak key 自动消失，
 *   但框还挂在 cell 里没人管 ⇒ 这就是"老消息残留"的最后一条来源。
 *   每轮巡检拿这张表清孤儿。 */
static NSMutableArray<UIView *> *gAllSugBoxes = nil;

@interface FDMSugBox : UIView
@end
@implementation FDMSugBox
/* 点中了某一颗胶囊 */
- (void)onTap:(UIButton *)b {
    @try {
        NSString *pl = objc_getAssociatedObject(b, "fdm_sug_pl");
        if (![pl isKindOfClass:[NSString class]] || !pl.length) return;
        FLOGW(FC_UI, @"[sug] ★ 命中「%@」→ 发送",
              pl.length > 24 ? [[pl substringToIndex:24] stringByAppendingString:@"…"] : pl);
        b.enabled = NO;                        /* 防连点 */
        FDMComposerSend(pl);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ b.enabled = YES; });
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[sug] onTap 异常: %@", e.reason);
    }
}
@end

/* 用「宿主真正用的 attributedString」算某段字符的矩形（UIKit 坐标，左上原点）
 * 与 BTRectForRange 同一套算法，只是改成传 AS + 尺寸，不再依赖 UILabel。 */
static CGRect BTRectForRangeAS(NSAttributedString *as, NSRange range, CGSize size) {
    if (!as.length || range.length == 0) return CGRectZero;
    if (NSMaxRange(range) > as.length) return CGRectZero;
    if (size.width < 8 || size.height < 8) return CGRectZero;
    @try {
        UIBezierPath *path = [UIBezierPath bezierPathWithRect:
                              CGRectMake(0, 0, size.width, size.height)];
        CTFramesetterRef fs = CTFramesetterCreateWithAttributedString(
            (__bridge CFAttributedStringRef)as);
        if (!fs) return CGRectZero;
        CTFrameRef frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0),
                                                    (__bridge CGPathRef)path, NULL);
        if (!frame) { CFRelease(fs); return CGRectZero; }

        CGFloat minX = CGFLOAT_MAX, minY = CGFLOAT_MAX;
        CGFloat maxX = -1, maxY = -1;
        CFArrayRef lines = CTFrameGetLines(frame);
        CFIndex nL = CFArrayGetCount(lines);
        CGPoint *org = malloc(sizeof(CGPoint) * (size_t)(nL > 0 ? nL : 1));
        CTFrameGetLineOrigins(frame, CFRangeMake(0, nL), org);

        for (CFIndex i = 0; i < nL; i++) {
            CTLineRef line = (CTLineRef)CFArrayGetValueAtIndex(lines, i);
            CFRange lr = CTLineGetStringRange(line);
            NSUInteger ls = (NSUInteger)lr.location;
            NSUInteger le = ls + (NSUInteger)lr.length;
            if (le <= range.location || ls >= NSMaxRange(range)) continue;

            CGFloat asc = 0, desc = 0;
            CTLineGetTypographicBounds(line, &asc, &desc, NULL);
            NSUInteger aIdx = MAX(ls, range.location);
            NSUInteger dIdx = MIN(NSMaxRange(range), le);
            CGFloat x0 = org[i].x + CTLineGetOffsetForStringIndex(line, (CFIndex)aIdx, NULL);
            CGFloat x1 = org[i].x + CTLineGetOffsetForStringIndex(line, (CFIndex)dIdx, NULL);
            if (x1 <= x0) {   /* 行尾：给个最小宽度，别算出 0 宽 */
                x1 = x0 + 6;
            }
            CGFloat y0 = size.height - (org[i].y + asc);
            CGFloat y1 = size.height - (org[i].y - desc);

            minX = MIN(minX, x0); maxX = MAX(maxX, x1);
            minY = MIN(minY, y0); maxY = MAX(maxY, y1);
        }
        free(org);
        CFRelease(frame);
        CFRelease(fs);
        if (maxX <= minX || maxY <= minY) return CGRectZero;
        return CGRectMake(minX, minY, maxX - minX, maxY - minY);
    } @catch (NSException *e) {
        return CGRectZero;
    }
}

/* ============================================================
 * ★★★ v4（2026-10-17 深夜）：**直接问 UITextView 要矩形**
 *
 *   诊断日志实锤：宿主正文控件其实是 UITextView 的子类
 *     _TtGC13DeepSeek_Chat17PlainTextNodeViewOS_23ResponseMarkdownAdapter_
 *       ·· _UITextLayoutView
 *       ·· _UITextContainerView 366x264
 *       ·· ·· _UITextViewCanvasView 366x264
 *
 *   ⇒ 我们的 CoreText 自算是白费力气，还会因为
 *     textContainerInset / lineFragmentPadding / TextKit2 差几个像素。
 *   直接用 UITextInput 的 -selectionRectsForRange:（多行也给）拿**精确**矩形，
 *   拿不到再退 firstRectForRange，最后才退自算 CoreText。
 * ============================================================ */
static CGRect BTRectForAnchor(UIView *anchor, NSAttributedString *as, NSRange range) {
    if (!anchor || range.length == 0) return CGRectZero;
    if ([anchor isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)anchor;
        @try {
            UITextPosition *p0 = [tv positionFromPosition:tv.beginningOfDocument
                                                  offset:(NSInteger)range.location];
            UITextPosition *p1 = p0 ? [tv positionFromPosition:p0
                                                        offset:(NSInteger)range.length] : nil;
            UITextRange *tr = (p0 && p1) ? [tv textRangeFromPosition:p0 toPosition:p1] : nil;
            if (tr) {
                CGRect uni = CGRectNull;
                if ([tv respondsToSelector:@selector(selectionRectsForRange:)]) {
                    for (UITextSelectionRect *sr in [tv selectionRectsForRange:tr]) {
                        CGRect r = sr.rect;
                        if (r.size.height < 1 || r.size.width < 1) continue;
                        uni = CGRectIsNull(uni) ? r : CGRectUnion(uni, r);
                    }
                }
                if (CGRectIsNull(uni) || CGRectIsEmpty(uni)) {
                    uni = [tv firstRectForRange:tr];
                }
                if (!CGRectIsNull(uni) && !CGRectIsEmpty(uni)) return uni;
            }
        } @catch (NSException *e) { }
    }
    if (as.length) return BTRectForRangeAS(as, range, anchor.bounds.size);
    return CGRectZero;
}

/* ============================================================
 * ★ 把「显示文字 → 要发的内容」解析成「文本里的 range → payload」
 *
 *   两条来源都要用上：
 *     A. rawText 里还带 <Suggestion> 标签（宿主第一次渲染前）
 *     B. 渲染后的文本里标签已经变成可见文字（最常用）
 *        ⇒ 用 FDMSugsForText()（渲染那一刻登记的注册表）反查
 * ============================================================ */
static NSArray<NSDictionary *> *BTResolveSugs(NSString *text, NSString *rawText) {
    NSString *t = text.length ? text : (rawText ?: @"");
    if (!t.length) return nil;
    NSMutableArray *out = [NSMutableArray array];

    /* A. 标签路径 */
    NSArray<NSDictionary *> *tagged = ParseSuggestions(rawText.length ? rawText : t);
    if (tagged.count) {
        for (NSDictionary *d in tagged) {
            NSString *show = d[@"show"], *pl = d[@"payload"];
            if (!show.length || !pl.length) continue;
            NSRange r = [t rangeOfString:show];
            if (r.location == NSNotFound) continue;
            [out addObject:@{ @"range": [NSValue valueWithRange:r], @"payload": pl }];
        }
        if (out.count) return out;
    }

    /* B. 注册表路径（返回的 range 已经是相对当前文本的） */
    extern NSArray<NSDictionary *> *FDMSugsForText(NSString *text);
    NSArray *reg = FDMSugsForText(t);
    if (reg.count) return reg;
    return nil;
}

/* 摘掉某个 anchor 名下的框（文本里没建议了 / 视图要走了） */
static void BTRemoveSugBox(UIView *anchor) {
    if (!anchor) return;
    FDMSugBox *box = gSugBoxes ? (FDMSugBox *)[gSugBoxes objectForKey:anchor] : nil;
    UIView *cell = nil;
    if (box) {
        cell = box.superview;
        [box removeFromSuperview];
        [gSugBoxes removeObjectForKey:anchor];
    }
    if (cell && gSugCellMap) [gSugCellMap removeObjectForKey:cell];
}

/* ★ 一次性诊断：把 anchor 的子树打出来（前 2 次），用来确认宿主到底
 *   用什么控件画文字、有没有内边距。看完就自动闭嘴。 */
static void BTDumpAnchorTree(UIView *v, int depth, int maxDepth) {
    if (!v || depth > maxDepth) return;
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"·· "];
    NSString *extra = @"";
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        NSString *s = l.text.length ? l.text : l.attributedText.string;
        extra = [NSString stringWithFormat:@" label「%@」attr=%lu",
                 s.length > 16 ? [s substringToIndex:16] : (s ?: @""),
                 (unsigned long)l.attributedText.length];
    } else if ([v isKindOfClass:[UITextView class]]) {
        extra = @" textview";
    }
    FLOGW(FC_UI, @"[sug-tree] %@%@ f=(%.1f,%.1f %.1fx%.1f)%@",
          pad, NSStringFromClass([v class]),
          v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height,
          extra);
    for (UIView *sv in v.subviews) BTDumpAnchorTree(sv, depth + 1, maxDepth);
}

/* ★ 建议按钮的诊断日志开关（默认关；1 次读盘后缓存，避免每轮 stat） */
BOOL FDMSugDiagOn(void) {
    static int cached = -1;
    if (cached >= 0) return cached ? YES : NO;
    cached = 0;
    @try {
        NSArray *ds = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES);
        NSString *dir = [ds firstObject];
        if (!dir) return NO;
        NSString *p = [dir stringByAppendingPathComponent:@"fdm-sugdiag.txt"];
        NSString *v = [NSString stringWithContentsOfFile:p
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
        v = [v stringByTrimmingCharactersInSet:
             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (v.length && ![v isEqualToString:@"0"]) cached = 1;
    } @catch (NSException *e) { }
    return cached ? YES : NO;
}

/* ============================================================
 * 主入口：给某个「承载正文的视图」铺建议胶囊
 *   anchor  —— 正文视图（可能是 UILabel，也可能是 Swift 泛型视图）
 *   rawText —— 截获那一刻的文本（可能还带标签）
 *   as      —— 宿主即将渲染的那份 attributedString（算矩形用）
 * ============================================================ */
void FDMEnsureSugBox(UIView *anchor, NSString *rawText, NSAttributedString *as) {
    if (!anchor) return;
    if (![NSThread isMainThread]) {
        __weak UIView *w = anchor;
        NSString *t = [rawText copy];
        NSAttributedString *a = [as copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (w) FDMEnsureSugBox(w, t, a);
        });
        return;
    }
    @try {
        if (!gSugAnchors) gSugAnchors = [NSMapTable weakToStrongObjectsMapTable];
        BTRegAnchor(anchor, rawText ?: @"");

        /* ★ 把宿主真正用的 AS 记下来（后续重算矩形全靠它） */
        if (as.length) {
            if (!gSugAS) gSugAS = [NSMapTable weakToStrongObjectsMapTable];
            [gSugAS setObject:as forKey:anchor];
        } else if (gSugAS) {
            as = [gSugAS objectForKey:anchor];
        }

        /* 思考块里不铺（那里的标记不该变按钮） */
        if (BTIsThinkingNode(anchor)) return;

        /* 用户气泡里绝不铺（系统提示词里的 <Suggestion> 示例会漏出来） */
        {
            int d0 = 0;
            for (UIView *p0 = anchor; p0 && d0++ < 16; p0 = p0.superview) {
                const char *cn0 = class_getName([p0 class]);
                if (!cn0) continue;
                if (strstr(cn0, "UserRequestBubble") || strstr(cn0, "UserBubble") ||
                    strstr(cn0, "UserMessageCell") || strstr(cn0, "UserTextCell")) return;
                if (strstr(cn0, "AgentMessageCell")) break;
            }
        }

        UIView *cell = BTFindMsgCell(anchor);
        if (!cell) return;

        NSString *display = as.length ? as.string : (rawText ?: @"");
        NSArray<NSDictionary *> *items = BTResolveSugs(display, rawText);
        if (!items.count) {
            BTRemoveSugBox(anchor);       /* ★ 残留根因：没建议了必须摘框 */
            return;
        }

        /* ★★★ 便宜的先做：文本长度 / 视图尺寸 / 建议条数 = 签名。
         *   三者都没变、框也还在 ⇒ 直接返回，不重算 CoreText。
         *   （以前每 0.35s 对每条 anchor 全量重算，7P 上纯属白烧 CPU） */
        {
            static NSMapTable<UIView *, NSString *> *gSugSig = nil;
            if (!gSugSig) gSugSig = [NSMapTable weakToStrongObjectsMapTable];
            NSString *sig = [NSString stringWithFormat:@"%lu|%.0f|%.0f|%lu",
                             (unsigned long)display.length,
                             anchor.bounds.size.width,
                             anchor.bounds.size.height,
                             (unsigned long)items.count];
            UIView *mine = [gSugBoxes objectForKey:anchor];
            BOOL haveBox = (mine != nil && mine.superview != nil);
            NSString *prev = [gSugSig objectForKey:anchor];
            if (haveBox && prev && [prev isEqualToString:sig]) return;
            [gSugSig setObject:sig forKey:anchor];
        }

        /* ★ 诊断：看一眼宿主的真实层级（只打 2 次） */
        {
            static int dumpN = 0;
            if (dumpN < 2) {
                dumpN++;
                FLOGW(FC_UI, @"[sug-tree] ===== anchor %@ bounds=%.1fx%.1f 整段 %lu 字 =====",
                      NSStringFromClass([anchor class]),
                      anchor.bounds.size.width, anchor.bounds.size.height,
                      (unsigned long)display.length);
                BTDumpAnchorTree(anchor, 0, 5);
            }
        }

        /* 逐条算矩形（anchor 本地坐标）→ 转成 cell 坐标 */
        NSMutableArray<NSDictionary *> *placed = [NSMutableArray array];
        for (NSDictionary *d in items) {
            NSValue *rv = d[@"range"];
            NSString *pl = d[@"payload"];
            if (![rv isKindOfClass:[NSValue class]] || ![pl isKindOfClass:[NSString class]]) continue;
            if (!pl.length) continue;
            CGRect r = BTRectForAnchor(anchor, as, [rv rangeValue]);
            /* ★ 行高常常比"字高"大 ⇒ 直接用行矩形会上下行互相压住。
             *   这里把高度收到「字体行高 + 4」，横向再各让 2px。 */
            if (!CGRectIsEmpty(r) && as.length) {
                UIFont *f = nil;
                @try {
                    NSUInteger fi = MIN([rv rangeValue].location, as.length - 1);
                    id fv = [as attribute:NSFontAttributeName atIndex:fi effectiveRange:NULL];
                    if ([fv isKindOfClass:[UIFont class]]) f = fv;
                } @catch (NSException *e) { }
                if (f) {
                    CGFloat want = ceil(f.lineHeight) + 4;
                    if (want < r.size.height) {
                        r = CGRectInset(r, 0, (r.size.height - want) / 2.0);
                    }
                    if (r.size.height < 22) {
                        CGFloat dy = (22 - r.size.height) / 2.0;
                        r = CGRectInset(r, 0, -dy);
                    }
                }
            }
            {
                static int dbgR = 0;
                if (dbgR < 8) {
                    dbgR++;
                    FLOGW(FC_UI, @"[sug-rect] range=%lu,%lu AS=%lu → (%.1f,%.1f %.1fx%.1f) 「%@」",
                          (unsigned long)[rv rangeValue].location,
                          (unsigned long)[rv rangeValue].length,
                          (unsigned long)as.length,
                          r.origin.x, r.origin.y, r.size.width, r.size.height,
                          pl.length > 12 ? [pl substringToIndex:12] : pl);
                }
            }
            if (CGRectIsEmpty(r)) continue;          /* 算不出来 ⇒ 这条跳过（降级） */
            r = CGRectInset(r, -4, -3);
            if (r.size.height < 20) {                 /* 单行太薄，上下补一点 */
                CGFloat dy = (20 - r.size.height) / 2.0;
                r = CGRectInset(r, 0, -dy);
            }
            CGRect inCell = [cell convertRect:r fromView:anchor];
            [placed addObject:@{ @"rect": [NSValue valueWithCGRect:inCell],
                                 @"payload": pl }];
        }
        if (!placed.count) { BTRemoveSugBox(anchor); return; }

        /* 并集（容器 frame） */
        CGRect uni = [placed[0][@"rect"] CGRectValue];
        for (NSUInteger i = 1; i < placed.count; i++)
            uni = CGRectUnion(uni, [placed[i][@"rect"] CGRectValue]);
        uni = CGRectInset(uni, -2, -2);

        if (!gSugBoxes) gSugBoxes = [NSMapTable weakToStrongObjectsMapTable];
        FDMSugBox *box = (FDMSugBox *)[gSugBoxes objectForKey:anchor];
        BOOL reused = NO;
        if (box && box.superview != cell) {
            /* cell 被复用/重建过 ⇒ 框跟过去（不是丢掉重建，避免闪） */
            [cell addSubview:box];
        } else if (box) {
            reused = YES;
        }
        if (!box) {
            box = [[FDMSugBox alloc] initWithFrame:uni];
            box.tag = BT_SUGBOX_TAG;
            box.backgroundColor = [UIColor clearColor];
            box.opaque = NO;
            box.userInteractionEnabled = YES;
            FDMSugWeakRef *nw = [FDMSugWeakRef new];
            nw.v = anchor;
            objc_setAssociatedObject(box, "fdm_sug_ref", nw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(box, "fdm_sug_label", anchor, OBJC_ASSOCIATION_ASSIGN);
            [gSugBoxes setObject:box forKey:anchor];
            if (!gAllSugBoxes) gAllSugBoxes = [NSMutableArray array];
            if (gAllSugBoxes.count > 80) [gAllSugBoxes removeObjectAtIndex:0];
            [gAllSugBoxes addObject:box];
            [cell addSubview:box];
        }
        if (!CGRectEqualToRect(box.frame, uni)) box.frame = uni;
        [cell bringSubviewToFront:box];

        /* 复用已有按钮，缺的补上，多的删掉 */
        NSMutableArray *keepTags = [NSMutableArray array];
        BOOL changed = (box.subviews.count != placed.count);
        for (NSUInteger i = 0; i < placed.count; i++) {
            NSInteger tag = BT_SUGBTN_TAG + (NSInteger)i;
            [keepTags addObject:@(tag)];
            CGRect inCell = [placed[i][@"rect"] CGRectValue];
            CGRect local = CGRectOffset(inCell, -uni.origin.x, -uni.origin.y);
            local = CGRectInset(local, -1, -1);
            NSString *pl = placed[i][@"payload"];

            UIButton *btn = (UIButton *)[box viewWithTag:tag];
            if (!btn) {
                btn = [UIButton buttonWithType:UIButtonTypeCustom];
                btn.tag = tag;
                btn.backgroundColor = [UIColor clearColor];
                [btn addTarget:box action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
                [box addSubview:btn];
            }
            if (!CGRectEqualToRect(btn.frame, local)) { btn.frame = local; changed = YES; }
            objc_setAssociatedObject(btn, "fdm_sug_pl", pl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            /* 视觉：淡底 + 圆角（文字仍由宿主画，位置天然正确） */
            UIColor *tint = [UIColor colorWithRed:0.26 green:0.55 blue:1.0 alpha:1.0];
            btn.layer.cornerRadius = 9;
            btn.layer.borderWidth = 1.0;
            btn.layer.borderColor = [tint colorWithAlphaComponent:0.8].CGColor;
            btn.backgroundColor = [tint colorWithAlphaComponent:0.22];
        }
        for (UIView *sv in [box.subviews copy]) {
            if (![keepTags containsObject:@(sv.tag)]) { [sv removeFromSuperview]; changed = YES; }
        }

        if (!gSugCellMap) gSugCellMap = [NSMapTable weakToStrongObjectsMapTable];
        [gSugCellMap setObject:(rawText ?: display) forKey:cell];

        /* ★ 只在「真的变了」时打日志：以前每 0.35s 四条日志，白烧 CPU */
        if (!reused || changed) {
            NSMutableString *brief = [NSMutableString string];
            for (NSUInteger i = 0; i < placed.count && i < 3; i++) {
                NSString *pl = placed[i][@"payload"];
                [brief appendFormat:@"「%@」", pl.length > 14 ? [pl substringToIndex:14] : pl];
            }
            FLOGW(FC_UI, @"[sug] %@ %lu 条 %@ in %@ box=(%.0f,%.0f %.0fx%.0f)",
                  reused ? @"↻ 更新" : @"★ 铺上",
                  (unsigned long)placed.count, brief,
                  NSStringFromClass([cell class]),
                  box.frame.origin.x, box.frame.origin.y,
                  box.frame.size.width, box.frame.size.height);
        }
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[sug] 铺建议异常: %@", e.reason);
    }
}

/* ============================================================
 * ★★★ 巡检 v2（2026-10-17 主人反馈"必须重启 App 才刷新"）
 *
 *   旧版只处理 gSugCellMap 里登记过的 cell ——
 *   但宿主复用时可能根本不调 setAttributedText（用缓存的
 *   attributedString）⇒ 永远不会登记 ⇒ 按钮不出现。
 *
 *   新版：**主动遍历整个视图树**，凡是 AgentMessageCell 里的
 *        文本能在建议表里查到，就补按钮。不依赖任何事件。
 * ============================================================ */
/* ============================================================
 * ★★★ 扫描 v3（2026-10-17 最终）
 *
 *   前两版失败原因：按类名找"消息容器"，再在容器里找 label。
 *   但宿主层级太深（615 个视图），且类名组合很多
 *   （MessageView / AgentMessageView / ResponseFragment…），
 *   漏一个就整条链断。
 *
 *   ⇒ 干脆**不找容器**：全局遍历所有 UILabel，
 *     文本能查到建议就直接铺（cell 由 BTFindMsgCell 反查）。
 * ============================================================ */
static void BTScanCellsForSug(UIView *root, int depth) {
    if (!root || depth > 30) return;
    if ([root isKindOfClass:[UILabel class]]) {
        NSString *txt = ((UILabel *)root).text;
        if (txt.length > 10 && FDMSugsForText(txt).count) {
            FDMEnsureSugBox(root, txt, ((UILabel *)root).attributedText);
            return;
        }
    }
    for (UIView *sv in root.subviews) BTScanCellsForSug(sv, depth + 1);
}
/* 定时巡检：宿主重建 cell 后把按钮补回去 */
void FDMRepairSugBoxes(void) {
    if (![NSThread isMainThread]) return;
    @try {
        /* ============================================================
         * ★★★ 2026-10-17 新增：按锚点表巡检（不再全树扫描）
         *
         *   为什么不再全树扫：
         *     · 全树 615+ 视图 / 每 0.35s 一次，7P 上纯浪费
         *     · 而且扫的是 UILabel，根本扫不到真正的正文控件
         *         _TtGC13DeepSeek_Chat17PlainTextNodeViewOS_23ResponseMarkdownAdapter_
         *   锚点表由 FDMEnsureSugBox 自己登记，
         *   条目数 == 屏上带建议的消息数（通常 1~5 条）。
         *
         *   ⚠️ 必须先把 key 拷成数组再遍历：
         *      迭代中 EnsureSugBox 会 setObject:（同一 key 更新 value），
         *      直接在 NSMapTable 上做 fast enumeration 会抛异常。
         * ============================================================ */
        /* ★ 孤儿框清理（每轮都做，成本 = 屏幕上消息数）：
         *   anchor 已经释放 / 框已经离开 window ⇒ 摘掉，绝不留残影。 */
        if (gAllSugBoxes.count) {
            NSMutableArray *kill = [NSMutableArray array];
            for (UIView *b in gAllSugBoxes) {
                FDMSugWeakRef *wr = objc_getAssociatedObject(b, "fdm_sug_ref");
                if (!wr || !wr.v || !b.window) {
                    [b removeFromSuperview];
                    [kill addObject:b];
                }
            }
            if (kill.count) {
                [gAllSugBoxes removeObjectsInArray:kill];
                static int kc = 0;
                if (kc++ < 6)
                    FLOGW(FC_UI, @"[sug] 清掉 %lu 个孤儿框（anchor 已释放）",
                          (unsigned long)kill.count);
            }
        }
        {
            @autoreleasepool {
                NSUInteger ac = gSugAnchorList.count;
                for (NSUInteger i = 0; i < ac; i++) {
                    UIView *a = (UIView *)[gSugAnchorList pointerAtIndex:i];   /* weak → NULL 安全 */
                    if (!a || ![a isKindOfClass:[UIView class]]) continue;
                    if (!a.window) continue;
                    NSString *raw = [gSugAnchors objectForKey:a];
                    if (!raw.length) continue;
                    FDMEnsureSugBox(a, raw, nil);
                }
            }
            /* ★ 诊断（每 5 秒一次，限 12 轮）：锚点到底在哪、能不能在屏幕上看见
             *
             * ★★★ 2026-10-17 深夜：**默认关掉**。
             *   18 条 anchor 每条一行，7P 上每 5 秒白写一次日志。
             *   要开：fdm-debug.json 里 "sug_diag": true（或设备上
             *         echo 1 > Documents/fdm-sugdiag.txt）
             */
            extern BOOL FDMSugDiagOn(void);
            {
                static NSTimeInterval lastDiag = 0;
                static int diagN = 0;
                NSTimeInterval nowT = [NSDate date].timeIntervalSince1970;
                if (FDMSugDiagOn() && diagN < 12 && nowT - lastDiag > 5.0) {
                    lastDiag = nowT;
                    diagN++;
                    UIWindow *dw = nil;
                    for (UIScene *s2 in [UIApplication sharedApplication].connectedScenes) {
                        if (![s2 isKindOfClass:[UIWindowScene class]]) continue;
                        for (UIWindow *x2 in ((UIWindowScene *)s2).windows)
                            if (x2.windowLevel == UIWindowLevelNormal) { dw = x2; break; }
                        if (dw) break;
                    }
                    FLOGW(FC_UI, @"[sug-diag] 锚点表 %lu 条，窗口 %@",
                          (unsigned long)gSugAnchorList.count,
                          dw ? NSStringFromClass([dw class]) : @"(nil)");
                    NSUInteger ac2 = gSugAnchorList.count;
                    for (NSUInteger i = 0; i < ac2; i++) {
                        UIView *a = (UIView *)[gSugAnchorList pointerAtIndex:i];
                        if (!a) { FLOGW(FC_UI, @"[sug-diag]  #%lu = NULL", (unsigned long)i); continue; }
                        CGRect wr = dw ? [a convertRect:a.bounds toView:dw] : a.bounds;
                        NSString *txt = [gSugAnchors objectForKey:a];
                        NSMutableString *subs = [NSMutableString string];
                        int k = 0;
                        for (UIView *sv in a.subviews) {
                            if (k++ >= 3) break;
                            [subs appendFormat:@"%@ ", NSStringFromClass([sv class])];
                        }
                        FLOGW(FC_UI, @"[sug-diag]  #%lu %@ win=(%.0f,%.0f %.0fx%.0f) 屏内=%d 建议=%lu 子=%@ 文=「%@」",
                              (unsigned long)i, NSStringFromClass([a class]),
                              wr.origin.x, wr.origin.y, wr.size.width, wr.size.height,
                              (int)CGRectIntersectsRect(wr, dw ? dw.bounds : a.bounds),
                              (unsigned long)FDMSugsForText(txt ?: @"").count,
                              subs, txt.length > 18 ? [txt substringToIndex:18] : (txt ?: @""));
                    }
                }
            }
        }
        UIWindow *w = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *x in ((UIWindowScene *)sc).windows) {
                if (x.windowLevel == UIWindowLevelNormal) { w = x; break; }
            }
            if (w) break;
        }
        if (w) {
            /* ★ 2026-10-17 修：全树扫描降频到每 12 轮（约 4 秒）一次。
             *   锚点表已经覆盖了真正承载正文的 Swift 视图，
             *   全树扫只为兜底 UILabel 型正文，不必每 0.35s 都跑。 */
            static int scanTick = 0;
            BOOL doFull = ((scanTick++ % 12) == 0);
            if (doFull) BTScanCellsForSug(w, 0);

            /* ★ 诊断：确认真的扫到了窗口，以及扫到几个 Message 容器 */
            static int sdbg = 0;
            if (FDMSugDiagOn() && sdbg < 6) {
                sdbg++;
                int cnt = 0;
                NSMutableArray *st = [NSMutableArray arrayWithObject:w];
                int g = 0;
                while (st.count && g++ < 6000) {
                    UIView *v = st.lastObject; [st removeLastObject];
                    const char *cn = class_getName([v class]);
                    if (cn && strstr(cn, "Message") != NULL) cnt++;
                    for (UIView *z in v.subviews) [st addObject:z];
                }
                FLOGW(FC_UI, @"[sug-scan] window=%@ 层数=%d 含Message的视图=%d 表=%lu条",
                      NSStringFromClass([w class]), g, cnt,
                      (unsigned long)gSugRegistryCount());
            }
        }

        if (!gSugCellMap || gSugCellMap.count == 0) return;
        /* ============================================================
         * ★★★ 2026-10-17 深夜（v3）：**不再"贴 cell 底部补一排真按钮"**。
         *
         *   那段旧代码是"位置偏上"和"压在 复制/赞踩 那排按钮上"的元凶：
         *     frame.y = cell.height - boxH - 14  ⇒ 正好盖在操作栏上，
         *     跟建议文字的真实位置毫无关系。
         *
         *   v3 的补框完全交给「anchor 巡检」：anchor 还活着 ⇒
         *   FDMEnsureSugBox(anchor,…) 会用同一份 AS 重算出正确矩形。
         *   这里只负责**清掉已经死掉的条目**（cell 释放 / 文本没建议了）。
         * ============================================================ */
        NSMutableArray<UIView *> *dead = [NSMutableArray array];
        for (UIView *cell in gSugCellMap) {
            NSString *raw = [gSugCellMap objectForKey:cell];
            if (!cell || !raw.length) { [dead addObject:cell]; continue; }
            if (!cell.window) { [dead addObject:cell]; continue; }
            /* 框还在就交给 anchor 巡检管；不在了也不在这里重建 */
            UIView *box = [cell viewWithTag:BT_SUGBOX_TAG];
            if (box && box.superview != cell) { [box removeFromSuperview]; [dead addObject:cell]; }
        }
        for (UIView *d in dead) [gSugCellMap removeObjectForKey:d];
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[sug] 重铺异常: %@", e.reason);
    }
}

/* ============ 六、统一入口 ============ */

/* 优先路 A（UI），失败再路 B（重放） */
BOOL FDMComposerSend(NSString *text) {
    if (FDMComposerSendViaUI(text)) return YES;
    return FDMComposerSendViaReplay(text);
}

void FDMComposerInstall(void) {
    FDMComposerReload();
    FDMInstallSugEventHook();
    /* ★ 每 1.2 秒巡检一次：宿主重建 cell 后把建议按钮补回去 */
    {
        static dispatch_source_t tp = nil;
        if (tp) dispatch_source_cancel(tp);
        tp = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                    dispatch_get_main_queue());
        dispatch_source_set_timer(tp,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
            (uint64_t)(0.35 * NSEC_PER_SEC),
            (uint64_t)(0.3 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(tp, ^{
            @autoreleasepool {
                FDMRepairSugBoxes();
                /* ★ 搭车：每 ~4 秒检查一次是否该往宿主「设置」页插模块入口
                 *   （FDMUIInstall 那条链实测没跑起来，只能从这条活着的巡检借道） */
                static int entryTick = 0;
                if ((entryTick++ % 12) == 0) {
                    extern void FDMUICheckSettingsEntry(void);
                    FDMUICheckSettingsEntry();
                }
            }
        });
        dispatch_resume(tp);
        FLOGW(FC_UI, @"[sug] ↻ 自动重铺巡检已启动（v4.1 · 0.35s）");
    }
    FLOGI(FC_NET, @"[send] 模块发消息就绪（开关=%d）", (int)gComposerEnabled);
}

/* ══════════════════════════════════════════════════════════════════════════
 *  ★ 公开能力：只填输入框，不发送
 *
 *  为什么单独给一个（而不是复用 SendViaUI）：
 *    文件快捷选项点了之后，用户可能还想改两笔再发 ——
 *    直接发出去风险太大（他可能只是想看看提示词长什么样）。
 *  所以这里只做「塞进去 + 触发变更通知」，发不发由用户决定。
 *
 *  @return YES = 已经塞进去了
 * ══════════════════════════════════════════════════════════════════════════ */
BOOL FDMComposerFillText(NSString *text) {
    if (!text.length) return NO;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FDMComposerFillText(text);
        });
        return YES;
    }

    @try {
        UIView *page = FDMChatPageView();
        if (!page) {
            FLOGW(FC_UI, @"[fill] 找不到聊天页");
            return NO;
        }
        UIView *area = BTFindByName(page, "InputAreaView", 0, nil);
        if (!area) {
            FLOGW(FC_UI, @"[fill] 找不到 InputAreaView");
            return NO;
        }
        UITextView *input = BTFindInputView(area);
        if (!input) {
            FLOGW(FC_UI, @"[fill] 找不到输入框");
            return NO;
        }
        BTSetInputText(input, text);
        [input becomeFirstResponder];
        FLOGI(FC_UI, @"[fill] 已填入 %lu 字", (unsigned long)text.length);
        return YES;
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[fill] 异常: %@", e.reason);
        return NO;
    }
}
