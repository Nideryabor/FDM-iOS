/* ============================================================
 * FDMUITree —— 运行时视图树逆向工具 🐲
 *
 * 目的：不再靠猜，把宿主的真实 UI 结构完整 dump 出来。
 *
 * 输出：Documents/fdm-uitree-<类名>.txt
 *   每个节点一行，含：
 *     层级 / 类名 / frame / bounds / alpha / 背景色 / 是否滚动容器
 *     / 是否有 layer 背景 / 是否是我们的图 / 是否 hidden
 *
 * 触发：fdm-debug.json 里 "uitree": true
 *   启动后 20s 和 40s 各 dump 一次（覆盖首页和进对话后的状态）
 *   也支持从设置页手动触发
 * ============================================================ */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import "FLog.h"

static NSString *UIDocs(void) {
    static NSString *d = nil;
    if (!d) {
        NSArray *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
        d = [a firstObject] ?: NSTemporaryDirectory();
    }
    return d;
}

/* 把颜色转成可读字符串 */
static NSString *UIColorDesc(UIColor *c, CGFloat *outAlpha) {
    if (!c) return @"-";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    @try {
        if ([c getRed:&r green:&g blue:&b alpha:&a]) {
            if (outAlpha) *outAlpha = a;
            return [NSString stringWithFormat:@"#%02X%02X%02X/%.2f",
                    (int)(r*255), (int)(g*255), (int)(b*255), a];
        }
        /* 灰度色 / 系统色 */
        CGFloat w = 0;
        if ([c getWhite:&w alpha:&a]) {
            if (outAlpha) *outAlpha = a;
            return [NSString stringWithFormat:@"W%.2f/%.2f", w, a];
        }
    } @catch (NSException *e) { }
    if (outAlpha) *outAlpha = -1;
    return [c description];
}

/* 递归 dump */
static void DumpView(UIView *v, int depth, NSMutableString *out, CGSize rootSize) {
    if (!v || depth > 14) return;
    @try {
        CGRect f = v.frame;
        CGRect b = v.bounds;

        CGFloat pct = 0;
        if (rootSize.width > 0 && rootSize.height > 0) {
            pct = (b.size.width * b.size.height) /
                  (rootSize.width * rootSize.height) * 100.0;
        }

        CGFloat alpha = -1;
        NSString *bgDesc = UIColorDesc(v.backgroundColor, &alpha);

        /* 类型标签 */
        NSMutableString *tags = [NSMutableString string];
        if ([v isKindOfClass:[UIScrollView class]])     [tags appendString:@"SCROLL "];
        if ([v isKindOfClass:[UITableView class]])      [tags appendString:@"TABLE "];
        if ([v isKindOfClass:[UICollectionView class]]) [tags appendString:@"COLL "];
        if ([v isKindOfClass:[UILabel class]])          [tags appendString:@"LABEL "];
        if ([v isKindOfClass:[UITextView class]])       [tags appendString:@"TEXTVIEW "];
        if ([v isKindOfClass:[UIImageView class]])      [tags appendString:@"IMAGE "];
        if ([v isKindOfClass:[UIVisualEffectView class]])[tags appendString:@"BLUR "];
        if (v.layer.backgroundColor != NULL)            [tags appendString:@"LBG "];
        if (v.layer.mask)                               [tags appendString:@"MASK "];
        if (v.hidden)                                   [tags appendString:@"HIDDEN "];
        if (v.alpha < 0.01)                             [tags appendString:@"INVISIBLE "];
        if (v.tag == 0x0D1A0002)                        [tags appendString:@"★FGIMG "];
        if (v.tag == 0x0D1A0001)                        [tags appendString:@"★DIM "];
        if (v.tag == 0x0D1A0003)                        [tags appendString:@"★CELLDONE "];

        /* layer 子层数量（渐变/模糊常在这里） */
        NSUInteger sublayers = v.layer.sublayers.count;

        /* ★ 临时诊断：把 label 的文字/颜色/透明度也打出来，
         *   用来判断「列表项不见了」是没文字、还是变色、还是被裁掉 */
        NSMutableString *extra = [NSMutableString string];
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *lb = (UILabel *)v;
            NSString *t = lb.text ?: @"";
            if (t.length > 14) t = [[t substringToIndex:14] stringByAppendingString:@"…"];
            t = [t stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            [extra appendFormat:@" txt=「%@」 tc=%@ a=%.2f",
                                  t, lb.textColor, lb.alpha];
        }
        if (v.alpha < 0.99) [extra appendFormat:@" va=%.2f", v.alpha];
        if (v.hidden) [extra appendString:@" HID"];

        [out appendFormat:
         @"%*s%-52s f=(%.0f,%.0f %.0fx%.0f) b=(%.0fx%.0f) %.1f%% bg=%@ sl=%lu %@%@\n",
         depth * 2, "",
         [NSStringFromClass([v class]) UTF8String],
         f.origin.x, f.origin.y, f.size.width, f.size.height,
         b.size.width, b.size.height,
         pct, bgDesc, (unsigned long)sublayers, tags, extra];
    } @catch (NSException *e) { }

    @try {
        for (UIView *sv in [v.subviews copy])
            DumpView(sv, depth + 1, out, rootSize);
    } @catch (NSException *e) { }
}

/* dump 所有窗口 + 所有 VC */
void FDMUITreeDump(NSString *reason) {
    @autoreleasepool {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"# FDM 视图树 dump\n# 时间: %@\n# 原因: %@\n\n",
            [NSDate date], reason ?: @"?"];

        @try {
            int wi = 0;
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    [out appendFormat:
                     @"\n========== Window #%d ==========\n"
                     @"class   = %@\n"
                     @"level   = %.1f\n"
                     @"key     = %d\n"
                     @"frame   = %@\n"
                     @"rootVC  = %@\n"
                     @"alpha   = %.2f  hidden=%d\n",
                     wi,
                     NSStringFromClass([w class]),
                     (double)w.windowLevel,
                     (int)w.isKeyWindow,
                     NSStringFromCGRect(w.frame),
                     NSStringFromClass([w.rootViewController class]),
                     w.alpha, (int)w.hidden];

                    [out appendString:@"\n--- UIView 层级 ---\n"];
                    DumpView(w, 0, out, w.bounds.size);

                    /* VC 层级（有些 VC 的 view 不在 window 的 subviews 里） */
                    [out appendString:@"\n--- VC 链 ---\n"];
                    UIViewController *vc = w.rootViewController;
                    int d = 0;
                    while (vc && d < 12) {
                        [out appendFormat:@"%*s%@\n", d * 2, "",
                         NSStringFromClass([vc class])];
                        /* 子 VC */
                        for (UIViewController *ch in vc.childViewControllers)
                            [out appendFormat:@"%*s  child: %@\n", d * 2, "",
                             NSStringFromClass([ch class])];
                        vc = vc.presentedViewController;
                        d++;
                    }
                    wi++;
                }
            }
        } @catch (NSException *e) {
            [out appendFormat:@"\n!! dump 异常: %@\n", e.reason];
        }

        NSString *path = [UIDocs() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"fdm-uitree-%@.txt",
                           [reason stringByReplacingOccurrencesOfString:@" " withString:@"_"]]];
        NSError *err = nil;
        [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
        if (err) {
            FLOGE(FC_UI, @"[uitree] 写文件失败: %@", err.localizedDescription);
        } else {
            FLOGW(FC_UI, @"[uitree] ★ 已 dump → %@（%lu 字节）",
                  path.lastPathComponent, (unsigned long)out.length);
        }
    }
}


/* ★ iOS15：统一取正常窗口（避免 deprecated 警告） */
static UIWindow *BTKeyWindowSafe(void) {
    UIWindow *fallback = nil;
    @try {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.windowLevel != UIWindowLevelNormal) continue;
                if (w.isKeyWindow) return w;
                if (!fallback) fallback = w;
            }
        }
    } @catch (NSException *e) { }
    return fallback;
}

/* ============================================================
 * ★★★ 截图（2026-10-17）
 *
 *   为什么必须在这里做：
 *     命令行进程（SSH 进来的 shell）看不到宿主的 UI，
 *     只有 App 自己进程内才能 drawViewHierarchy。
 *
 *   用法：🦖 → 调试 → 📸 截图 → 存到 Documents/fdm-shot-<时间>.png
 *         然后尼尼 scp/base64 拉走。
 * ============================================================ */
int FDMUICapture(NSString *name) {
    @try {
        UIWindow *target = BTKeyWindowSafe();
        if (!target) return -1;

        CGSize sz = target.bounds.size;
        if (sz.width < 1 || sz.height < 1) return -2;

        UIGraphicsBeginImageContextWithOptions(sz, NO, 0);
        /* ★ afterScreenUpdates:YES 才能拿到最新渲染（NO 会拿到旧帧） */
        [target drawViewHierarchyInRect:target.bounds afterScreenUpdates:YES];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (!img) return -3;

        NSData *png = UIImagePNGRepresentation(img);
        if (!png.length) return -4;

        NSString *dir = UIDocs();
        NSString *fn = name.length ? name : @"fdm-shot.png";
        NSString *path = [dir stringByAppendingPathComponent:fn];
        if (![png writeToFile:path atomically:YES]) return -5;

        FLOGW(FC_UI, @"[shot] ★ 已保存 %@（%lu 字节, %.0fx%.0f）",
              fn, (unsigned long)png.length, sz.width, sz.height);
        return 0;
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[shot] 异常: %@", e.reason);
        return -99;
    }
}

int FDMUICapture2x(NSString *name) {
    @try {
        UIWindow *target = BTKeyWindowSafe();
        if (!target) return -1;

        CGSize sz = target.bounds.size;
        CGFloat scale = target.screen.scale > 0 ? target.screen.scale : 2.0;
        UIGraphicsBeginImageContextWithOptions(sz, NO, scale);
        [target drawViewHierarchyInRect:target.bounds afterScreenUpdates:YES];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (!img) return -3;
        NSData *png = UIImagePNGRepresentation(img);
        NSString *fn = name.length ? name : @"fdm-shot2x.png";
        NSString *path = [UIDocs() stringByAppendingPathComponent:fn];
        if (![png writeToFile:path atomically:YES]) return -5;
        FLOGW(FC_UI, @"[shot] ★ 已保存 %@（%lu 字节, %dx%d）",
              fn, (unsigned long)png.length,
              (int)img.size.width, (int)img.size.height);
        return 0;
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[shot] 异常: %@", e.reason);
        return -99;
    }
}


/* ============================================================
 * ★ 消息区专项 dump（2026-10-17）
 *
 *   为什么单独做一个：
 *     全窗口 dump 有 615 层、几万行，翻一次要命。
 *     这里只管「AI 消息 cell 里的所有 UILabel」，
 *     把 类名 / frame / 文本 / 是否含建议 全打出来。
 * ============================================================ */
void FDMUIDumpMessages(void) {
    @try {
        UIWindow *w = BTKeyWindowSafe();
        if (!w) { FLOGW(FC_UI, @"[msgdump] 没有可用窗口"); return; }

        FLOGW(FC_UI, @"[msgdump] ==== 开始（窗口 %@）====",
              NSStringFromClass([w class]));

        NSMutableArray<UIView *> *st = [NSMutableArray arrayWithObject:w];
        int guard = 0, nLabel = 0, nCell = 0;
        while (st.count && guard++ < 8000) {
            UIView *v = st.lastObject;
            [st removeLastObject];
            const char *cn = class_getName([v class]);
            if (cn) {
                if (strstr(cn, "MessageCell") || strstr(cn, "AgentMessage")) nCell++;
                if (strstr(cn, "ResponseFragment") || strstr(cn, "MessageView")) nCell++;
            }
            if ([v isKindOfClass:[UILabel class]]) {
                UILabel *lb = (UILabel *)v;
                NSString *t = lb.text ?: @"";
                if (t.length >= 2 && lb.window) {
                    nLabel++;
                    if (nLabel <= 60) {
                        NSString *show = t.length > 50
                            ? [[t substringToIndex:50] stringByAppendingString:@"…"] : t;
                        show = [show stringByReplacingOccurrencesOfString:@"\n"
                                                                withString:@"⏎"];
                        /* 找它在窗口里的绝对位置 */
                        CGRect inWin = [lb convertRect:lb.bounds toView:w];
                        FLOGW(FC_UI, @"[msgdump] %@ f=(%.0f,%.0f %.0fx%.0f) %lu字「%@」",
                              NSStringFromClass([lb class]),
                              inWin.origin.x, inWin.origin.y,
                              inWin.size.width, inWin.size.height,
                              (unsigned long)t.length, show);
                    }
                }
            }
            for (UIView *z in v.subviews) [st addObject:z];
        }
        FLOGW(FC_UI, @"[msgdump] ==== 结束：遍历 %d 个视图，label %d 个，消息容器 %d 个 ====",
              guard, nLabel, nCell);
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[msgdump] 异常: %@", e.reason);
    }
}
