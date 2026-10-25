/* ============================================================
 * FDMPhotoPicker —— 从系统相册选图（不需要 Filza）🐲
 *
 * 为什么用它：
 *   之前「聊天背景」要求用户把图片放进 App 的 Documents 目录，
 *   但那要 Filza / 越狱文件管理器 —— 普通用户玩不了。
 *   iOS 14+ 的 PHPickerViewController **不需要相册权限**
 *   （系统在独立进程里选图，只把选中那张交给我们）。
 *
 * 流程：
 *   设置页点「从相册选图」→ present PHPicker
 *     → 用户选一张 → 缩到 ≤1440px、压 JPEG
 *     → 存 Documents/fdm-bg.jpg → 回写 fdm-bg.json
 *     → 立刻刷新背景
 * ============================================================ */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import "FLog.h"

extern void FDMBeautyRefreshBackground(void);

static NSString *PPDocs(void) {
    static NSString *d = nil;
    if (!d) {
        NSArray *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
        d = [a firstObject] ?: NSTemporaryDirectory();
    }
    return d;
}

/* 拿当前最顶层 VC（用来 present） */
static UIViewController *PPTopVC(void) {
    @try {
        UIWindow *keyWin = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) { keyWin = w; break; }
            }
            if (keyWin) break;
        }
        if (!keyWin) return nil;
        UIViewController *vc = keyWin.rootViewController;
        while (vc) {
            if (vc.presentedViewController) vc = vc.presentedViewController;
            else if ([vc isKindOfClass:[UINavigationController class]] &&
                     ((UINavigationController *)vc).topViewController)
                vc = ((UINavigationController *)vc).topViewController;
            else if ([vc isKindOfClass:[UITabBarController class]] &&
                     ((UITabBarController *)vc).selectedViewController)
                vc = ((UITabBarController *)vc).selectedViewController;
            else break;
        }
        return vc;
    } @catch (NSException *e) { return nil; }
}

static BOOL PPSaveImageTo(UIImage *img, NSString *name, NSString *gid, NSString *key);

/* 缩到最长边 ≤ maxSide（省内存；原图可能几十 MB） */
static UIImage *PPDownscale(UIImage *img, CGFloat maxSide) {
    if (!img) return nil;
    CGSize sz = img.size;
    CGFloat m = MAX(sz.width, sz.height);
    if (m <= maxSide || m <= 0) return img;
    CGFloat k = maxSide / m;
    CGSize nsz = CGSizeMake(floor(sz.width * k), floor(sz.height * k));
    UIGraphicsBeginImageContextWithOptions(nsz, NO, 1.0);
    [img drawInRect:CGRectMake(0, 0, nsz.width, nsz.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: img;
}

/* 存图 + 回写配置文件
 *
 * ★ 2026-10-23 扩展：原来只会写 fdm-bg.json（背景专用），
 *   现在支持任意「组 + 键」，这样助手图片 / 气泡图片底也能复用同一套选图流程。
 *   gid == nil ⇒ 老行为（写 fdm-bg.json 的 mode/file）。
 */
static BOOL PPSaveImageTo(UIImage *img, NSString *name, NSString *gid, NSString *key) {
    @try {
        UIImage *small = PPDownscale(img, 1440);
        NSData *jpg = UIImageJPEGRepresentation(small, 0.85);
        if (!jpg) { FLOGE(FC_UI, @"[photo] JPEG 编码失败"); return NO; }

        NSString *path = [PPDocs() stringByAppendingPathComponent:name];
        if (![jpg writeToFile:path atomically:YES]) {
            FLOGE(FC_UI, @"[photo] 写文件失败: %@", path);
            return NO;
        }
        FLOGI(FC_UI, @"[photo] ★ 已保存 %@（%.0f×%.0f，%lu B）",
              name, small.size.width, small.size.height, (unsigned long)jpg.length);

        NSString *cfgFile = gid.length
            ? [NSString stringWithFormat:@"fdm-%@.json", gid]
            : @"fdm-bg.json";
        NSString *cfgPath = [PPDocs() stringByAppendingPathComponent:cfgFile];
        NSMutableDictionary *cfg = nil;
        NSData *raw = [NSData dataWithContentsOfFile:cfgPath];
        if (raw) {
            id j = [NSJSONSerialization JSONObjectWithData:raw
                                                  options:NSJSONReadingMutableContainers
                                                    error:nil];
            if ([j isKindOfClass:[NSDictionary class]]) cfg = j;
        }
        if (!cfg) cfg = [NSMutableDictionary dictionary];

        NSMutableArray *modKeys = [NSMutableArray array];
        if (gid.length && key.length) {
            cfg[key] = name;
            [modKeys addObject:key];
        } else {
            cfg[@"mode"] = @"image";
            cfg[@"file"] = name;
            [modKeys addObject:@"mode"];
            [modKeys addObject:@"file"];
        }
        NSMutableArray *mods = [cfg[@"__mod"] mutableCopy] ?: [NSMutableArray array];
        for (NSString *k in modKeys) if (![mods containsObject:k]) [mods addObject:k];
        cfg[@"__mod"] = mods;

        NSData *out = [NSJSONSerialization dataWithJSONObject:cfg
                                                      options:NSJSONWritingPrettyPrinted
                                                        error:nil];
        [out writeToFile:cfgPath atomically:YES];
        FLOGI(FC_UI, @"[photo] 配置已更新 → %@.%@=%@",
              gid.length ? gid : @"bg", key.length ? key : @"file", name);

        /* 老行为：背景立刻刷新。新行为：让调用方的 reload 去做。 */
        if (!gid.length) FDMBeautyRefreshBackground();
        return YES;
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[photo] 保存异常: %@", e.reason);
        return NO;
    }
}

/* ★ 安全弹窗：presenting 中/正在 dismiss 时不弹，避免 "presentation in progress" 崩溃，
 *   而且延后 0.35s 等动画走完。 */
static void PPSimpleAlert(NSString *title, NSString *msg) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            UIViewController *top = PPTopVC();
            if (!top) return;
            if (top.presentedViewController) {          /* 已经有东西在弹，别抢 */
                FLOGW(FC_UI, @"[photo] 已有模态 %@，跳过弹窗", 
                      NSStringFromClass([top.presentedViewController class]));
                return;
            }
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:title message:msg
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                 style:UIAlertActionStyleCancel
                                               handler:nil]];
            [top presentViewController:a animated:YES completion:nil];
        } @catch (NSException *e) {
            FLOGE(FC_UI, @"[photo] 弹窗异常: %@", e.reason);
        }
    });
}

/* ==================== picker 代理 ==================== */

@interface FDMPhotoPickerVC : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *saveName;
@property (nonatomic, copy) NSString *gid;      /* 非空 ⇒ 写 fdm-<gid>.json 的 key */
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) void (^onSaved)(BOOL ok);
@end

@implementation FDMPhotoPickerVC

- (void)picker:(PHPickerViewController *)picker
    didFinishPicking:(NSArray<PHPickerResult *> *)results {
    FLOGW(FC_UI, @"[photo] didFinishPicking %lu 项", (unsigned long)results.count);

    if (results.count == 0) {
        [picker dismissViewControllerAnimated:YES completion:nil];
        FLOGW(FC_UI, @"[photo] 用户取消");
        return;
    }

    /* ★★ 关键：必须在 dismiss 的 completion 里才做后续。
     *   原来 dismiss 后立刻 present alert / 改 UI ⇒
     *   "Attempt to present while a presentation is in progress"
     *   ⇒ 直接崩（而且崩得早，连崩溃日志都可能来不及写）。 */
    PHPickerResult *r = results.firstObject;
    NSItemProvider *prov = r.itemProvider;
    NSString *nm = self.saveName ?: @"fdm-bg.jpg";

    [picker dismissViewControllerAnimated:YES completion:^{
        FLOGW(FC_UI, @"[photo] picker 已关闭，开始解码");
        if (![prov canLoadObjectOfClass:[UIImage class]]) {
            FLOGE(FC_UI, @"[photo] 这个 item 不是图片");
            return;
        }
        [prov loadObjectOfClass:[UIImage class]
              completionHandler:^(UIImage *img, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (err || !img) {
                    FLOGE(FC_UI, @"[photo] 解码失败: %@", err.localizedDescription);
                    PPSimpleAlert(@"读取失败", err.localizedDescription ?: @"无法解码这张图片");
                    return;
                }
                FLOGW(FC_UI, @"[photo] 解码成功 %.0f×%.0f，开始保存",
                      img.size.width, img.size.height);
                BOOL ok = PPSaveImageTo(img, nm, self.gid, self.key);
                FLOGW(FC_UI, @"[photo] 保存结果 = %@", ok ? @"成功" : @"失败");
                if (ok) {
                    if (self.onSaved) {
                        self.onSaved(YES);
                    } else {
                        PPSimpleAlert(@"背景已设置", @"已保存并应用，回到聊天页看看～");
                    }
                }
                else    PPSimpleAlert(@"保存失败", @"请看日志里的 [photo] 记录");
            });
        }];
    }];
}

@end

/* ==================== 对外入口 ==================== */

void FDMPhotoPickerPresent(NSString *saveName) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (@available(iOS 14.0, *)) {
                PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
                cfg.filter = PHPickerFilter.imagesFilter;
                cfg.selectionLimit = 1;
                /* 0 = 只要「当前」那张，不重新编码，快 */
                cfg.preferredAssetRepresentationMode =
                    PHPickerConfigurationAssetRepresentationModeCurrent;

                PHPickerViewController *pv =
                    [[PHPickerViewController alloc] initWithConfiguration:cfg];

                FDMPhotoPickerVC *dele = [FDMPhotoPickerVC new];
                dele.saveName = saveName.length ? saveName : @"fdm-bg.jpg";
                pv.delegate = dele;

                /* ★ delegate 是 weak，必须强引用住，否则选完就释放 → 点了没反应 */
                static FDMPhotoPickerVC *gKeepAlive = nil;
                gKeepAlive = dele;
                (void)gKeepAlive;      /* 只为保活，别让编译器当成无用变量 */

                UIViewController *top = PPTopVC();
                if (!top) { FLOGE(FC_UI, @"[photo] 找不到可 present 的 VC"); return; }
                [top presentViewController:pv animated:YES completion:nil];
                FLOGI(FC_UI, @"[photo] 相册已打开（从 %@）", NSStringFromClass([top class]));
            } else {
                FLOGW(FC_UI, @"[photo] iOS < 14 不支持 PHPicker");
            }
        } @catch (NSException *e) {
            FLOGE(FC_UI, @"[photo] 打开相册异常: %@", e.reason);
        }
    });
}

/* ══════════════════════════════════════════════════════════════════════════
 *  ★ 通用入口：选一张图 → 存成 Documents/<saveName> → 把文件名写进
 *    fdm-<gid>.json 的 <key> 字段 → 调 onSaved。
 *
 *  四个地方复用它：
 *    assistant.file      助手图片
 *    bubble.mine_img_file   我·气泡图片底
 *    bubble.theirs_img_file AI·气泡图片底
 *    (bg 走老入口，保持兼容)
 * ══════════════════════════════════════════════════════════════════════════ */
void FDMPhotoPickerPresentFor(NSString *saveName, NSString *gid, NSString *key,
                              void (^onSaved)(BOOL ok)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (@available(iOS 14.0, *)) {
                PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
                cfg.filter = PHPickerFilter.imagesFilter;
                cfg.selectionLimit = 1;
                cfg.preferredAssetRepresentationMode =
                    PHPickerConfigurationAssetRepresentationModeCurrent;

                PHPickerViewController *pv =
                    [[PHPickerViewController alloc] initWithConfiguration:cfg];

                FDMPhotoPickerVC *dele = [FDMPhotoPickerVC new];
                dele.saveName = saveName.length ? saveName : @"fdm-img.jpg";
                dele.gid = gid;
                dele.key = key;
                dele.onSaved = onSaved;
                pv.delegate = dele;

                /* delegate 是 weak，必须强引用住 */
                static FDMPhotoPickerVC *gKeep2 = nil;
                gKeep2 = dele;
                (void)gKeep2;

                UIViewController *top = PPTopVC();
                if (!top) {
                    FLOGE(FC_UI, @"[photo] 找不到可 present 的 VC");
                    return;
                }
                [top presentViewController:pv animated:YES completion:nil];
                FLOGI(FC_UI, @"[photo] 相册已打开（目标 %@.%@ → %@）",
                      gid ?: @"bg", key ?: @"file", dele.saveName);
            } else {
                FLOGW(FC_UI, @"[photo] iOS < 14 不支持 PHPicker");
            }
        } @catch (NSException *e) {
            FLOGE(FC_UI, @"[photo] 打开相册异常: %@", e.reason);
        }
    });
}
