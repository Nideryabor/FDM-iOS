// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用

/* ============================================================
 * FDMUI.m —— schema 驱动的设置界面
 *
 * 结构：
 *   「设置」页左上角 🦖  →  FDMSettingsVC（分组列表）
 *        ├─ 系统提示词注入   → FDMGroupVC（字段自动生成）
 *        ├─ 快捷开关         → FDMGroupVC
 *        ├─ 对话增强         → FDMGroupVC
 *        ├─ 服务端设置覆盖   → FDMOverrideVC（59 键全表编辑）
 *        ├─ 界面增强         → FDMGroupVC
 *        ├─ 调试             → FDMGroupVC + 日志入口
 *        └─ 日志             → FDMLogVC
 *
 * 加功能 = 在 FDMFeatures.m 加声明，本文件不用改。
 * ============================================================ */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "FLog.h"
#import "FDMConfig.h"
#import "FDMFeatures.h"
extern NSString *const P_COMPOSER;

#define FDM_VERSION  @"v7.1"
#include <string.h>

#pragma mark - 工具

static NSString *FDMDocs(void) {
    static NSString *d = nil;
    if (!d) {
        NSArray *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
        d = [a firstObject] ?: NSTemporaryDirectory();
    }
    return d;
}


#pragma mark - 多行文本编辑器（String 类型用）

@interface FDMTextEditVC : UIViewController <UITextViewDelegate>
@property (nonatomic, copy)   NSString *fieldTitle;
@property (nonatomic, copy)   NSString *fieldHint;
@property (nonatomic, copy)   NSString *initialText;
@property (nonatomic, assign) BOOL multiline;
@property (nonatomic, copy)   void (^onSave)(NSString *text);
@end

@implementation FDMTextEditVC {
    UITextView *_tv;
    UILabel *_counter;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.fieldTitle ?: @"编辑";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                         style:UIBarButtonItemStyleDone
                                        target:self action:@selector(save)];

    CGFloat top = 8;
    if (self.fieldHint.length) {
        UILabel *hb = [[UILabel alloc] initWithFrame:CGRectMake(12, top, self.view.bounds.size.width - 24, 0)];
        hb.text = self.fieldHint;
        hb.numberOfLines = 0;
        hb.font = [UIFont systemFontOfSize:12];
        hb.textColor = [UIColor secondaryLabelColor];
        [hb sizeToFit];
        hb.frame = CGRectMake(12, top, self.view.bounds.size.width - 24, hb.frame.size.height);
        hb.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self.view addSubview:hb];
        top = CGRectGetMaxY(hb.frame) + 8;
    }

    _tv = [[UITextView alloc] initWithFrame:CGRectMake(8, top,
                                                       self.view.bounds.size.width - 16,
                                                       self.view.bounds.size.height - top - 60)];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    _tv.autocorrectionType = UITextAutocorrectionTypeNo;
    _tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _tv.text = self.initialText ?: @"";
    _tv.delegate = self;
    _tv.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _tv.layer.cornerRadius = 8;
    _tv.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:_tv];

    _counter = [[UILabel alloc] initWithFrame:CGRectMake(12, 0,
                                                         self.view.bounds.size.width - 24, 20)];
    _counter.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _counter.textColor = [UIColor tertiaryLabelColor];
    _counter.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_counter];

    [self updateCounter];
    [_tv becomeFirstResponder];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _counter.frame = CGRectMake(12, self.view.bounds.size.height - 32,
                                self.view.bounds.size.width - 24, 20);
    _tv.frame = CGRectMake(8, _tv.frame.origin.y,
                           self.view.bounds.size.width - 16,
                           self.view.bounds.size.height - _tv.frame.origin.y - 40);
}

- (void)textViewDidChange:(UITextView *)tv { [self updateCounter]; }

- (void)updateCounter {
    NSString *t = _tv.text ?: @"";
    NSUInteger lines = 0;
    if (t.length) lines = [[t componentsSeparatedByString:@"\n"] count];
    _counter.text = [NSString stringWithFormat:@"%lu 字符 · %lu 行",
                     (unsigned long)t.length, (unsigned long)lines];
}

- (void)save {
    if (self.onSave) self.onSave(_tv.text ?: @"");
    [self.navigationController popViewControllerAnimated:YES];
    if (!self.navigationController) [self dismissViewControllerAnimated:YES completion:nil];
}
@end

#pragma mark - 日志查看器

@interface FDMLogVC : UIViewController
@end

@implementation FDMLogVC {
    UITextView *_tv;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"日志";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    _tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.editable = NO;
    _tv.alwaysBounceVertical = YES;
    _tv.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _tv.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:_tv];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(reload)],
        [[UIBarButtonItem alloc] initWithTitle:@"更多" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(more)],
    ];
    [self reload];
}

- (void)reload {
    _tv.text = FLogRecent(800);
    if (_tv.text.length) [_tv scrollRangeToVisible:NSMakeRange(_tv.text.length - 1, 1)];
}

- (void)more {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"更多" message:nil
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    void (^add)(NSString *, void(^)(void)) = ^(NSString *t, void(^b)(void)) {
        [a addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *x){ if (b) b(); }]];
    };
    add(@"更多行（2000）", ^{ self->_tv.text = FLogRecent(2000); });
    add(@"全部（3000）",   ^{ self->_tv.text = FLogRecent(3000); });
    add(@"只 ERROR/WARN",  ^{
        NSMutableString *m = [NSMutableString string];
        for (NSString *l in [FLogRecent(3000) componentsSeparatedByString:@"\n"])
            if ([l containsString:@"[E]"] || [l containsString:@"[W]"])
                [m appendFormat:@"%@\n", l];
        self->_tv.text = m;
    });
    add(@"复制全部", ^{ [UIPasteboard generalPasteboard].string = self->_tv.text ?: @""; });
    add(@"清空", ^{
        [[NSFileManager defaultManager] removeItemAtPath:FLogPath() error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:
            [FLogPath() stringByAppendingString:@".1"] error:nil];
        self->_tv.text = @"（已清空，新日志会继续写入）";
    });
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:a animated:YES completion:nil];
}
@end


/* 从任意子视图往上找所属 UITableViewCell（比 superview.superview 稳） */
static UITableViewCell *FDMCellOf(UIView *v) {
    UIView *p = v;
    while (p && ![p isKindOfClass:[UITableViewCell class]]) p = p.superview;
    return (UITableViewCell *)p;
}

#pragma mark - 分组详情（schema 自动生成）

@interface FDMGroupVC : UITableViewController
@property (nonatomic, strong) FDMGroup *group;
@end

@implementation FDMGroupVC

- (instancetype)initWithGroup:(FDMGroup *)g {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _group = g;
        self.title = g.title;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"恢复默认"
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(resetAll)],
        [[UIBarButtonItem alloc] initWithTitle:@"说明"
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(showNote)],
    ];
}

- (void)resetAll {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"全部恢复默认？"
                         message:@"只会清掉「你改过的项」，没改的不受影响"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *x){
        [[FDMConfig shared] clearAllModified:self.group.gid];
        [self.tableView reloadData];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showNote {
    if (!self.group.note.length) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:self.group.title
                                                              message:self.group.note
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.group.fields.count;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return self.group.note;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    FDMField *f = self.group.fields[ip.row];
    FDMConfig *C = [FDMConfig shared];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                               reuseIdentifier:nil];
    BOOL mod = [C isModified:self.group.gid key:f.key];
    c.textLabel.text = mod ? [NSString stringWithFormat:@"★ %@", f.title] : f.title;
    c.textLabel.textColor = mod ? [UIColor systemBlueColor] : [UIColor labelColor];
    c.detailTextLabel.text = f.hint;
    c.detailTextLabel.numberOfLines = 2;
    c.detailTextLabel.font = [UIFont systemFontOfSize:11];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    switch (f.type) {
        case FDMFieldTypeBool: {
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [C boolFor:self.group.gid key:f.key];
            [sw addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            break;
        }
        case FDMFieldTypeEnum: {
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            c.detailTextLabel.text = [NSString stringWithFormat:@"%@　%@",
                                      [C stringFor:self.group.gid key:f.key] ?: @"",
                                      f.hint ?: @""];
            break;
        }
        /* ---- 子页 / 动作 / 信息 ---- */
        case FDMFieldTypeSub: {
            c.textLabel.text = f.icon.length
                ? [NSString stringWithFormat:@"%@  %@", f.icon, f.title] : f.title;
            c.detailTextLabel.text = f.hint;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case FDMFieldTypeAction: {
            c.textLabel.text = f.icon.length
                ? [NSString stringWithFormat:@"%@  %@", f.icon, f.title] : f.title;
            c.textLabel.textColor = [UIColor systemBlueColor];
            c.detailTextLabel.text = f.hint;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case FDMFieldTypeInfo: {
            c.textLabel.text = f.title;
            c.detailTextLabel.text = f.hint;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            c.accessoryType = UITableViewCellAccessoryNone;
            break;
        }

        /* ★ Int / String：值显示在右侧 label，点击弹输入框（标题不截断） */
        case FDMFieldTypeInt:
        case FDMFieldTypeString: {
            c.textLabel.text = f.title;
            c.detailTextLabel.text = nil;
            NSString *v = [C stringFor:self.group.gid key:f.key];
            c.accessoryType = UITableViewCellAccessoryNone;
            /* 用右侧 label 显示当前值 */
            UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 130, 30)];
            lb.text = v.length ? v : @"(空)";
            lb.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
            lb.textColor = [UIColor systemBlueColor];
            lb.textAlignment = NSTextAlignmentRight;
            lb.lineBreakMode = NSLineBreakByTruncatingMiddle;
            c.accessoryView = lb;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        }
    }
    return c;
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    FDMField *f = self.group.fields[ip.row];
    if (![[FDMConfig shared] isModified:self.group.gid key:f.key]) return nil;
    UIContextualAction *a = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@"恢复默认"
                          handler:^(UIContextualAction *x, UIView *v, void (^done)(BOOL)){
        [[FDMConfig shared] clearModified:self.group.gid key:f.key];
        [tv reloadData];
        done(YES);
    }];
    a.backgroundColor = [UIColor systemOrangeColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[a]];
}

- (void)onSwitch:(UISwitch *)sw {
    UITableViewCell *cell = FDMCellOf(sw);
    NSIndexPath *ip = cell ? [self.tableView indexPathForCell:cell] : nil;
    if (!ip) { FLOGW(FC_UI, @"switch 反查 cell 失败"); return; }
    FDMField *f = self.group.fields[ip.row];
    [[FDMConfig shared] setValue:@(sw.on) for:self.group.gid key:f.key];
    FLOGI(FC_UI, @"%@ = %@", f.key, sw.on ? @"开" : @"关");
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    FDMField *f = self.group.fields[ip.row];
    FDMConfig *C = [FDMConfig shared];

    /* ---- Sub：跳子页 ---- */
    if (f.type == FDMFieldTypeSub) {
        FDMGroup *child = [[FDMConfig shared] groupByID:f.sub];
        if (!child) { FLOGE(FC_UI, @"子页 %@ 不存在", f.sub); return; }
        FDMGroupVC *vc = [[FDMGroupVC alloc] initWithGroup:child];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

    /* ---- Action：执行动作 ---- */
    if (f.type == FDMFieldTypeAction) {
        extern void FDMUIRunAction(NSString *action, UIViewController *host);
        FDMUIRunAction(f.action, self);
        return;
    }

    /* ---- Enum：ActionSheet 选 ---- */
    if (f.type == FDMFieldTypeEnum) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:f.title
                                                                  message:f.hint
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
        NSString *cur = [C stringFor:self.group.gid key:f.key];
        for (NSString *opt in f.options) {
            NSString *title = [opt isEqualToString:cur] ? [NSString stringWithFormat:@"✓ %@", opt] : opt;
            [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *x){
                [C setValue:opt for:self.group.gid key:f.key];
                [tv reloadData];
            }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = tv;
        a.popoverPresentationController.sourceRect = [tv rectForRowAtIndexPath:ip];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    /* ---- String：多行编辑器（保留换行） ---- */
    if (f.type == FDMFieldTypeString) {
        NSString *cur = [C stringFor:self.group.gid key:f.key];
        FDMTextEditVC *vc = [[FDMTextEditVC alloc] init];
        vc.fieldTitle = f.title;
        vc.fieldHint = f.hint;
        vc.initialText = cur;
        vc.multiline = YES;
        __weak typeof(self) weakSelf = self;
        NSIndexPath *curIP = ip;
        vc.onSave = ^(NSString *text) {
            [C setValue:text ?: @"" for:weakSelf.group.gid key:f.key];
            [weakSelf.tableView reloadRowsAtIndexPaths:@[curIP]
                                      withRowAnimation:UITableViewRowAnimationFade];
        };
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

    /* ---- Int：弹输入框 -- */
    if (f.type == FDMFieldTypeInt) {
        NSString *cur = [C stringFor:self.group.gid key:f.key];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:f.title
                                                                  message:f.hint
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = cur;
            tf.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            if (f.type == FDMFieldTypeInt) tf.keyboardType = UIKeyboardTypeNumberPad;
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *x){
            NSString *t = a.textFields.firstObject.text ?: @"";
            if (f.type == FDMFieldTypeInt) {
                NSInteger v = [t integerValue];
                if (f.maxV > 0) v = MIN(MAX(v, f.minV), f.maxV);
                [C setValue:@(v) for:self.group.gid key:f.key];
            } else {
                [C setValue:t for:self.group.gid key:f.key];
            }
            [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}
@end

#pragma mark - 服务端设置覆盖（59 键全表编辑）

@interface FDMOverrideVC : UITableViewController
@property (nonatomic, strong) NSArray *keys;
@property (nonatomic, strong) NSMutableDictionary *cur;
@property (nonatomic) BOOL readOnly;      /* 只读（服务端下发查看用） */
@end

@implementation FDMOverrideVC

/* 从宿主 MMKV 里读出当前设置表 */
static NSDictionary *ReadHostSettings(void) {
    Class C = objc_getClass("MMKV");
    if (!C) return nil;
    id inst = nil;
    Method m = class_getClassMethod(C, sel_registerName("defaultMMKV"));
    if (m) inst = ((id(*)(id,SEL))method_getImplementation(m))((id)C, sel_registerName("defaultMMKV"));
    if (!inst) return nil;
    SEL s = sel_registerName("getDataForKey:");
    Method gm = class_getInstanceMethod([inst class], s);
    if (!gm) return nil;
    id d = ((id(*)(id,SEL,id))method_getImplementation(gm))(inst, s, @"app.ab.serverValues");
    if (![d isKindOfClass:[NSData class]]) return nil;
    @try {
        NSString *outer = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        id s1 = [NSJSONSerialization JSONObjectWithData:[outer dataUsingEncoding:NSUTF8StringEncoding]
                                               options:NSJSONReadingAllowFragments error:nil];
        NSString *inner = nil;
        if ([s1 isKindOfClass:[NSString class]]) inner = s1;
        else if ([s1 isKindOfClass:[NSDictionary class]]) inner = outer;
        if (!inner) return nil;
        id obj = [NSJSONSerialization JSONObjectWithData:[inner dataUsingEncoding:NSUTF8StringEncoding]
                                                 options:0 error:nil];
        NSDictionary *st = [obj isKindOfClass:[NSDictionary class]] ? obj[@"settings"] : nil;
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (NSString *k in st) out[k] = st[k][@"value"];
        return out;
    } @catch (NSException *e) { return nil; }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"服务端设置覆盖";
    self.cur = [NSMutableDictionary dictionary];

    NSDictionary *host = ReadHostSettings();
    if (host) {
        [self.cur addEntriesFromDictionary:host];
        FLOGI(FC_UI, @"读到宿主 %lu 项设置", (unsigned long)host.count);
    } else {
        FLOGW(FC_UI, @"读不到宿主设置（可能没登录 / blob 结构变了）");
    }
    /* 合并已覆盖的值（覆盖优先显示） */
    NSDictionary *ovr = FDMOverrideTable();
    [self.cur addEntriesFromDictionary:ovr];

    self.keys = [[self.cur allKeys] sortedArrayUsingSelector:@selector(compare:)];
    if (!self.readOnly) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"清空覆盖" style:UIBarButtonItemStylePlain
                                            target:self action:@selector(clearAll)];
    }
}

- (void)clearAll {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"清空全部覆盖？"
                                                              message:@"只清 fdm-override.json"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *x){
        [[FDMConfig shared] replace:@"override" with:@{}];
        [self.tableView reloadData];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.keys.count;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (self.readOnly) return @"只读：宿主当前生效的服务端设置";
    return @"点任意一行修改值。已覆盖的项会标 ★。\n重启 App 生效。";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSString *k = self.keys[ip.row];
    id v = self.cur[k];
    BOOL overridden = FDMOverrideTable()[k] != nil;

    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                               reuseIdentifier:nil];
    c.textLabel.text = [NSString stringWithFormat:@"%@%@", overridden ? @"★ " : @"", k];
    c.textLabel.font = [UIFont systemFontOfSize:12];
    c.textLabel.numberOfLines = 1;

    NSString *vs;
    if ([v isKindOfClass:[NSString class]]) vs = [NSString stringWithFormat:@"\"%@\"", v];
    else if (v) vs = [NSString stringWithFormat:@"%@", v];
    else vs = @"null";
    if (vs.length > 60) vs = [[vs substringToIndex:60] stringByAppendingString:@"…"];

    c.detailTextLabel.text = vs;
    c.detailTextLabel.font = [UIFont systemFontOfSize:11];
    c.detailTextLabel.textColor = overridden ? [UIColor systemBlueColor]
                                             : [UIColor secondaryLabelColor];
    c.accessoryType = UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.readOnly) return;          /* 只读模式 */
    NSString *k = self.keys[ip.row];
    id v = self.cur[k];

    NSString *hint;
    if ([v isKindOfClass:[NSNumber class]]) hint = @"数字（true/false 或整数）";
    else if ([v isKindOfClass:[NSString class]]) hint = [NSString stringWithFormat:@"字符串，当前 \"%@\"", v];
    else hint = @"（对象/数组，暂不支持编辑）";

    UIAlertController *a = [UIAlertController alertControllerWithTitle:k
                                                              message:hint
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [v isKindOfClass:[NSString class]] ? v
                 : ([v isKindOfClass:[NSNumber class]] ? [v stringValue] : @"");
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x){
        NSString *t = a.textFields.firstObject.text ?: @"";
        id nv = t;
        if ([v isKindOfClass:[NSNumber class]]) {
            NSString *lo = [t lowercaseString];
            if ([lo isEqualToString:@"true"]) nv = @YES;
            else if ([lo isEqualToString:@"false"]) nv = @NO;
            else if ([t rangeOfString:@"."].location != NSNotFound) nv = @([t doubleValue]);
            else nv = @([t integerValue]);
        }
        FDMConfig *C = [FDMConfig shared];
        NSMutableDictionary *d = [[C dictFor:@"override"] mutableCopy] ?: [NSMutableDictionary dictionary];
        d[k] = nv;
        if (!d[@"enabled"]) d[@"enabled"] = @YES;
        [C replace:@"override" with:d];
        self.cur[k] = nv;
        [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
        FLOGI(FC_UI, @"覆盖 %@ = %@", k, nv);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

#pragma mark - 主页（分组列表）

@interface FDMSettingsVC : UITableViewController
@end

@implementation FDMSettingsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"FDM 设置";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关于" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(about)];
}

- (void)about {
    NSMutableString *m = [NSMutableString string];
    [m appendFormat:@"FuckDSManger iOS %@\n\n", FDM_VERSION];
    [m appendFormat:@"日志: %lu 条\n", (unsigned long)FLogTotal()];
    [m appendFormat:@"页面: %lu 个\n", (unsigned long)[[FDMConfig shared] allGroups].count];
    [m appendFormat:@"\nDocuments:\n%@", FDMDocs()];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"关于" message:m
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x){
        [UIPasteboard generalPasteboard].string = FDMDocs();
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"功能" : @"工具";
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return [[FDMConfig shared] childGroupsOf:nil].count;
    return 2;   /* 日志 / 关于 */
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return s == 0 ? @"改动只在「重启 App」后完全生效" : nil;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];     /* 从子页返回时刷新改动数 */
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                               reuseIdentifier:nil];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (ip.section == 0) {
        NSArray<FDMGroup *> *gs = [[FDMConfig shared] childGroupsOf:nil];
        if (ip.row >= gs.count) return c;
        FDMGroup *g = gs[ip.row];

        /* 统计本页 + 所有子页的改动数 */
        NSUInteger modN = 0, fieldN = 0;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:g];
        while (stack.count) {
            FDMGroup *cur = stack.lastObject;
            [stack removeLastObject];
            fieldN += cur.fields.count;
            modN += [[FDMConfig shared] modifiedKeysFor:cur.gid].count;
            for (FDMGroup *sub in [[FDMConfig shared] childGroupsOf:cur.gid])
                [stack addObject:sub];
        }

        c.textLabel.text = g.icon.length
            ? [NSString stringWithFormat:@"%@  %@", g.icon, g.title] : g.title;
        c.textLabel.font = [UIFont boldSystemFontOfSize:16];

        if (fieldN == 0) {
            c.detailTextLabel.text = @"（子页）";
        } else if (modN > 0) {
            c.detailTextLabel.text = [NSString stringWithFormat:@"已改 %lu 项", (unsigned long)modN];
            c.detailTextLabel.textColor = [UIColor systemBlueColor];
        } else {
            c.detailTextLabel.text = g.note.length ? g.note : @"未改动";
            c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            c.detailTextLabel.numberOfLines = 1;
        }
    } else {
        if (ip.row == 0) {
            c.textLabel.text = @"📜  查看日志";
            c.detailTextLabel.text = [NSString stringWithFormat:@"%lu 条", (unsigned long)FLogTotal()];
        } else {
            c.textLabel.text = @"ℹ️  关于";
            c.detailTextLabel.text = [NSString stringWithFormat:@"FuckDSManger iOS %@", FDM_VERSION];
        }
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 0) {
        NSArray<FDMGroup *> *gs = [[FDMConfig shared] childGroupsOf:nil];
        if (ip.row >= gs.count) return;
        FDMGroup *g = gs[ip.row];

        /* 特殊页：gray = 宿主设置编辑器；dump = 只读查看 */
        if ([g.file isEqualToString:@"__gray__"] || [g.file isEqualToString:@"__dump__"]) {
            FDMOverrideVC *vc = [[FDMOverrideVC alloc] init];
            vc.readOnly = [g.file isEqualToString:@"__dump__"];
            vc.title = g.title;
            [self.navigationController pushViewController:vc animated:YES];
            return;
        }
        FDMGroupVC *vc = [[FDMGroupVC alloc] initWithGroup:g];
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UIViewController *vc = (ip.row == 0) ? [[FDMLogVC alloc] init] : nil;
        if (vc) [self.navigationController pushViewController:vc animated:YES];
        else [self about];
    }
}
@end

#pragma mark - 导航栏入口（零侵入）

static const void *kFDMHostVCKey = &kFDMHostVCKey;

/* ============================================================
 * ★★ 2026-10-17 致命 bug 修复：OBJC_ASSOCIATION_ASSIGN = 野指针
 *
 * 旧写法：
 *      *
 *   ASSIGN 只是存了个指针，**不持有、也不在目标释放时置 nil**。
 *   于是 VC 一被 dealloc，这个关联里就是**野指针**（不是 nil）。
 *
 * 崩溃链条（就是「点进对话必崩」的元凶）：
 *     UIViewController *host = objc_getAssociatedObject(btn, kFDMHostVCKey);
 *     if (!host || !host.view.window) { ... }
 *     //  ↑ 野指针不等于 nil，这句判空拦不住
 *     //  → host.view  ← 向已释放对象发消息 → SIGSEGV
 *
 * 修法：不再存 VC 指针，改为「点击时现找 topVC」。
 *   现有代码里本来就有这个兜底逻辑，直接让它无条件走兜底即可。
 * ============================================================ */

/* 取当前最顶层 VC（线程安全、永不野指针） */
static UIViewController *FDMTopVC(void) {
    @try {
        UIWindow *w = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *ww in ((UIWindowScene *)sc).windows) {
                if (ww.isKeyWindow) { w = ww; break; }
            }
            if (w) break;
        }
        if (!w) return nil;
        UIViewController *top = w.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        if ([top isKindOfClass:[UINavigationController class]] &&
            ((UINavigationController *)top).topViewController)
            top = ((UINavigationController *)top).topViewController;
        if ([top isKindOfClass:[UITabBarController class]] &&
            ((UITabBarController *)top).selectedViewController)
            top = ((UITabBarController *)top).selectedViewController;
        return top;
    } @catch (NSException *e) { return nil; }
}

@interface FDMTapTarget : NSObject
+ (instancetype)shared;
- (void)onTap:(UIBarButtonItem *)sender;
@end

@implementation FDMTapTarget
+ (instancetype)shared {
    static FDMTapTarget *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [FDMTapTarget new]; });
    return s;
}
- (void)onFloatTap:(UIButton *)sender {
    [self onTap:(UIBarButtonItem *)sender];       /* 复用同一逻辑 */
}

- (void)onTap:(UIBarButtonItem *)sender {
    @try {
        /* ============================================================
         * ★★ 2026-10-17 崩溃真因：连续 presentViewController
         *
         * 日志实锤：
         *     13:59:43.283 已弹出 FDM 设置
         *     13:59:44.752 已弹出 FDM 设置      ← 动画还没结束
         *     13:59:46.314 已弹出 FDM 设置
         *     ===== CRASH signal=11 (SIGSEGV) =====
         *
         * UIKit 不允许在模态转场进行中再 present 新的模态 ⇒ 崩。
         * 三道防线：
         *   ① 静态标志：整个进程只允许一次「弹出中」
         *   ② 检查 host.presentedViewController：已有模态就不弹
         *   ③ 0.5s 冷却（防止连续点击）
         * ============================================================ */
        static BOOL sPresenting = NO;
        if (sPresenting)  { FLOGW(FC_UI, @"[ui] 已在弹出中，忽略重复点击"); return; }

        UIViewController *host = FDMTopVC();
        if (!host) return;

        if (host.presentedViewController) {
            FLOGW(FC_UI, @"[ui] 已有模态 %@，忽略",
                  NSStringFromClass([host.presentedViewController class]));
            return;
        }

        sPresenting = YES;
        FDMSettingsVC *root = [[FDMSettingsVC alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [host presentViewController:nav animated:YES completion:^{
            sPresenting = NO;                 /* 转场结束才允许下次 */
        }];
        FLOGI(FC_UI, @"已弹出 FDM 设置");
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"弹窗异常: %@", e.reason);
    }
}
@end

#pragma mark - Hook

#define FDM_MAXHOOK 32
typedef struct { Class cls; SEL sel; IMP orig; } FDMHook;
static FDMHook gHooks[FDM_MAXHOOK];
static int gHookN = 0;
static __thread int gReent = 0;

/* 两个 wrapper 的前向声明（FDMFindOrigSafe / FDMSwap 判定要用地址） */
static void myViewDidLoad(id, SEL);
static void myViewWillAppear(id, SEL, BOOL);

static IMP FDMFindOrig(Class cls, SEL sel) {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c))
        for (int i = 0; i < gHookN; i++)
            if (gHooks[i].cls == c && sel_isEqual(gHooks[i].sel, sel)) return gHooks[i].orig;
    return NULL;
}

/* ============================================================
 * ★★ 兜底：查不到就向 runtime 要，**绝不返回 NULL**
 *
 *   返回 NULL 的后果：wrapper 里 `if (o)` 为假 ⇒ 原实现一次都不跑
 *   ⇒ 宿主页面的 viewDidLoad / viewWillAppear 变成空函数
 *   ⇒ 初始化缺失 ⇒ 点进对话崩（这就是那个「老问题」）
 * ============================================================ */
static IMP FDMFindOrigSafe(id self, SEL _cmd) {
    IMP o = FDMFindOrig(object_getClass(self), _cmd);
    if (o && o != (IMP)myViewDidLoad && o != (IMP)myViewWillAppear) return o;

    /* 沿继承链找第一个「不是我们自己」的实现 */
    for (Class c = object_getClass(self); c != Nil; c = class_getSuperclass(c)) {
        IMP cand = class_getMethodImplementation(c, _cmd);
        if (cand && cand != (IMP)myViewDidLoad && cand != (IMP)myViewWillAppear)
            return cand;
    }
    return NULL;
}
/* ============================================================
 * FDMSwap —— 安全版（2026-10-17 重写）
 *
 * ★★ 历史遗留的致命 bug（从 v7 一直存在，直到今天才定位）：
 *
 *     Method m = class_getInstanceMethod(c, sel);
 *     method_setImplementation(m, imp);
 *
 *   class_getInstanceMethod 会**沿继承链查找**。我们挂的 6 个 Swift VC
 *   （ProfileSharedTableViewController / PersonalizationViewController / ...）
 *   大多**没有自己实现** viewWillAppear:，于是拿到的是
 *   **UIViewController 上的那个方法** ⇒ method_setImplementation
 *   把 **全局 UIViewController.viewWillAppear:** 换成了 myViewWillAppear！
 *
 *   ⇒ 之后 MessageViewController（聊天页）等所有页面走进 myViewWillAppear
 *   ⇒ FDMFindOrig 查不到它们（gHooks 只登记了那 6 个类）→ 返回 NULL
 *   ⇒ `if (o)` 为假 ⇒ **原实现一次都没被调用**
 *   ⇒ 宿主页面的 viewWillAppear 全变成空函数 ⇒ 点进对话立刻崩
 *
 * 修法：
 *   ① 目标类自己没实现 → class_addMethod 只加覆盖，绝不动父类
 *   ② 原 IMP 已经是我们的 wrapper → 拒绝（防无限递归）
 *   ③ FDMFindOrig 兜底向 runtime 要，绝不返回 NULL 让原实现被吞掉
 * ============================================================ */
static IMP FDMSwap(Class c, const char *sel, IMP imp) {
    if (!c || !sel || !imp) return NULL;
    @try {
        SEL s = sel_registerName(sel);
        Method m = class_getInstanceMethod(c, s);
        if (!m) return NULL;
        const char *types = method_getTypeEncoding(m);
        if (!types) return NULL;

        IMP old = method_getImplementation(m);

        /* ② 防递归 */
        if (old == imp || old == (IMP)myViewDidLoad || old == (IMP)myViewWillAppear)
            return NULL;

        /* ① 这个类自己有没有实现？ */
        BOOL hasOwn = NO;
        unsigned int mc = 0;
        Method *own = class_copyMethodList(c, &mc);
        if (own) {
            for (unsigned int i = 0; i < mc; i++)
                if (sel_isEqual(method_getName(own[i]), s)) { hasOwn = YES; break; }
            free(own);
        }

        if (!hasOwn) {
            /* 自己没实现 ⇒ 只在本类加覆盖，绝不污染父类 */
            if (!class_addMethod(c, s, imp, types)) return NULL;
            FLOGD(FC_UI, @"[hook] +覆盖 %s -%s", class_getName(c), sel);
        } else {
            method_setImplementation(m, imp);
        }

        if (gHookN < FDM_MAXHOOK) {
            gHooks[gHookN].cls = c;
            gHooks[gHookN].sel = s;
            gHooks[gHookN].orig = old;
            gHookN++;
        }
        return old;
    } @catch (NSException *e) { return NULL; }
}

/* ★ 兜底：浮动按钮（不依赖 navigationBar，贴右下角）
 *   用于那些自定义标题栏 / 模态页 —— navigationItem 加了不显示的情况 */
/* ============================================================
 * ★★ 2026-10-17 关键修复 2：按钮只注入「白名单页面」
 *
 * 旧行为：myViewWillAppear 会给**每个页面**塞 🦖
 *   ⇒ 聊天页 MessageViewController 的 navigationItem 被我们插了一个
 *     UIBarButtonItem，而宿主的导航栏由它自己管理 ⇒ 状态混乱 ⇒ 崩。
 *
 * 新行为：只在「我的 / 设置」相关页面注入。
 *   这是模块的唯一天然入口（用户从「我的」点 🦖 进模块），
 *   不碰聊天页 ⇒ 彻底断掉这条崩溃路径。
 * ============================================================ */
static BOOL FDMPageAllowsButton(id vc) {
    const char *cn = class_getName(object_getClass(vc));
    if (!cn) return NO;
    /* 只要名字里带 Profile / Settings 的页面 */
    if (strstr(cn, "Profile"))  return YES;
    if (strstr(cn, "Setting"))  return YES;
    /* 明确排除：聊天页 / 会话列表 / 容器 */
    if (strstr(cn, "MessageViewController")) return NO;
    if (strstr(cn, "Session"))               return NO;
    if (strstr(cn, "NavigationController"))  return NO;
    if (strstr(cn, "TabBarController"))      return NO;
    return NO;
}

/* 判重标记：独立 key，只存 @YES（不存 VC，永不会野指针） */
static const void *kFDMTaggedKey = &kFDMTaggedKey;

static const void *kFDMFloatKey = &kFDMFloatKey;

static void FDMAddFloatingButton(UIViewController *vc) {
    if (!vc || !vc.view) return;
    /* ★ 同样只允许白名单页面（绝不往聊天页加子视图） */
    if (!FDMPageAllowsButton(vc)) return;
    if (objc_getAssociatedObject(vc, kFDMFloatKey)) return;     /* 已有 */

    @try {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(0, 0, 46, 46);
        b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
        b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        b.layer.cornerRadius = 23;
        b.titleLabel.font = [UIFont systemFontOfSize:22];
        [b setTitle:@"🦖" forState:UIControlStateNormal];
        [b addTarget:[FDMTapTarget shared] action:@selector(onFloatTap:)
    forControlEvents:UIControlEventTouchUpInside];
        
        [vc.view addSubview:b];
        objc_setAssociatedObject(vc, kFDMFloatKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        FLOGI(FC_UI, @"已加【浮动】🦖 到 %@", NSStringFromClass([vc class]));
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"浮动按钮异常: %@", e.reason);
    }
}

/* 布局：贴在右下角（view 尺寸已知时调） */
static void FDMLayoutFloat(UIViewController *vc) {
    if (!FDMPageAllowsButton(vc)) return;
    UIButton *b = objc_getAssociatedObject(vc, kFDMFloatKey);
    if (!b || !vc.view) return;
    CGSize s = vc.view.bounds.size;
    CGFloat m = 16;
    b.frame = CGRectMake(s.width - 46 - m, s.height - 46 - m - 60, 46, 46);
    [vc.view bringSubviewToFront:b];
}

/* ★ 公共：给某个 VC 加 🦖（可在 viewDidLoad / viewWillAppear 调）
 *  返回 YES = 这次加上了；NO = 已存在或跳过 */


static BOOL FDMEnsureEntryButton(UIViewController *vc) {
    if (!vc || ![vc isKindOfClass:[UIViewController class]]) return NO;

    /* ★ 白名单：只在这些页面注入，绝不碰聊天页 */
    if (!FDMPageAllowsButton(vc)) return NO;

    @try {
        /* 关掉入口？ */
        if (![[FDMConfig shared] boolFor:G_UI key:@"entry_button"]) return NO;

        /* ============================================================
         * ★★ 判重改成「记在 VC 上」
         *
         * 旧做法：查按钮上的标记
         *   for (it in leftBarButtonItems) if (assoc(it, tagKey)) return NO;
         *
         * 为什么失效（三条龙的原因）：
         *   宿主在 viewWillAppear 之后会**重建 navigationItem**，
         *   leftBarButtonItems 被替换成新的数组/新对象，
         *   我们加的按钮对象被丢掉 ⇒ 下次遍历找不到标记
         *   ⇒ 每次都判定「没加过」⇒ 一直往数组里插 ⇒ 0/1/2/3 条龙
         *
         * 新做法：标记记在 **VC 自己** 上（VC 是稳定的，不会每次重建）
         * ============================================================ */
        if (objc_getAssociatedObject(vc, kFDMTaggedKey)) {
            /* 已加过 —— 顺手清理多余的 🦖（修复历史遗留的重复按钮） */
            NSArray *cur = vc.navigationItem.leftBarButtonItems;
            if (cur.count > 1) {
                NSMutableArray *keep = [NSMutableArray array];
                BOOL gotOne = NO;
                for (UIBarButtonItem *it in cur) {
                    BOOL isOurs = [it.title isEqualToString:@"🦖"];
                    if (!isOurs) { [keep addObject:it]; continue; }
                    if (!gotOne) { [keep addObject:it]; gotOne = YES; }   /* 只留第一个 */
                }
                if (keep.count != cur.count) {
                    vc.navigationItem.leftBarButtonItems = keep;
                    FLOGI(FC_UI, @"[ui] 清理重复 🦖：%lu → %lu",
                          (unsigned long)cur.count, (unsigned long)keep.count);
                }
            }
            return NO;
        }

        UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"🦖"
                                                                style:UIBarButtonItemStylePlain
                                                               target:[FDMTapTarget shared]
                                                               action:@selector(onTap:)];
        objc_setAssociatedObject(btn, kFDMTaggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        NSArray *cur = vc.navigationItem.leftBarButtonItems;
        if (!cur.count && vc.navigationItem.leftBarButtonItem)
            cur = @[ vc.navigationItem.leftBarButtonItem ];
        NSMutableArray *arr = [NSMutableArray arrayWithArray:cur ?: @[]];
        [arr insertObject:btn atIndex:0];
        vc.navigationItem.leftBarButtonItems = arr;
        /* ★ 标记记在 VC 上（稳定，不会被宿主重建） */
        objc_setAssociatedObject(vc, kFDMTaggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        FLOGI(FC_UI, @"已加 🦖 到 %@（原有 %lu 个，left=%lu）",
              NSStringFromClass([vc class]), (unsigned long)(arr.count - 1),
              (unsigned long)arr.count);
        return YES;
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"加按钮异常: %@", e.reason);
        return NO;
    }
}


/* ============================================================
 * ★★★ 2026-10-17 深夜：模块入口做进宿主「设置」列表
 *
 *   主人原话：「如果模块入口能插入宿主原生菜单，就不需要这个龙龙按钮了」
 *
 *   以前的做法：navigationItem 左侧插一个 🦖 UIBarButtonItem。
 *   问题是它和旁边的 ✕ 圆钮风格不搭，看着像"浮在上面"，
 *   而且宿主重建 navigationItem 时还可能丢/重复。
 *
 *   现在：宿主设置页的 vc.view **就是那张 UITableView**
 *   （视图树实锤：`[SCROLL] UITableView f=(0,0 414x696)`），
 *   所以可以直接挂 **tableFooterView** —— 一行和宿主
 *   InsetsGroupedCell 长得一样的卡片，落在「关于」那组下面。
 *
 *   为什么选 tableFooterView 而不是 hook 数据源：
 *     · 不碰 numberOfSections / cellForRow ⇒ 不会打乱宿主的分组与 indexPath
 *     · 不参与 cell 复用 ⇒ 不存在复用错位
 *     · 宿主 reloadData 不会清掉它
 *   风险几乎为零。
 * ============================================================ */

static const void *kFDMListEntryKey = &kFDMListEntryKey;
#define FDM_ENTRY_TAG   0x0D1A0600

/* 在子树里找第一张 UITableView（限深）。
 * ★ 为什么需要：重启后实测 ProfileViewController.view 是 **0x0 空壳**，
 *   真正的表格在 ProfileViewControllerRoot → UILayoutContainerView → ... 里。 */
static UITableView *FDMFindTableIn(UIView *root, int depth) {
    if (!root || depth > 6) return nil;
    if ([root isKindOfClass:[UITableView class]]) return (UITableView *)root;
    for (UIView *sv in root.subviews) {
        UITableView *t = FDMFindTableIn(sv, depth + 1);
        if (t) return t;
    }
    return nil;
}

static void FDMInstallSettingsEntry(UIViewController *vc) {
    if (!vc || !vc.view) return;
    /* ★ 自家页面绝不插（FDM 设置页的类名里也含 "Settings"，
     *   不排除的话会给自己套一个入口，点进去又一层） */
    {
        const char *own = class_getName([vc class]);
        if (own && strncmp(own, "FDM", 3) == 0) return;
    }
    if (!FDMPageAllowsButton(vc)) return;
    @try {
        if (![[FDMConfig shared] boolFor:G_UI key:@"entry_list"]) return;
        if (objc_getAssociatedObject(vc, kFDMListEntryKey)) return;

        UITableView *tv = [vc.view isKindOfClass:[UITableView class]]
                        ? (UITableView *)vc.view
                        : FDMFindTableIn(vc.view, 0);
        /* ★ 实测：刚 present 时 ProfileViewController.view 是 0x0 空壳，
         *   真正的表格在 **parentViewController 的视图树**里
         *   （ProfileViewControllerRoot → UILayoutContainerView → … → UITableView） */
        if (!tv && vc.parentViewController.view)
            tv = FDMFindTableIn(vc.parentViewController.view, 0);
        if (!tv && vc.presentingViewController.view)
            tv = FDMFindTableIn(vc.presentingViewController.view, 0);
        if (!tv) {
            /* 还没布局好（view 是 0x0）：0.35 秒后再试一次 */
            static const void *kRetryKey = &kRetryKey;
            if (objc_getAssociatedObject(vc, kRetryKey)) return;
            objc_setAssociatedObject(vc, kRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak UIViewController *wv = vc;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (wv) {
                    objc_setAssociatedObject(wv, kRetryKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    FDMInstallSettingsEntry(wv);
                }
            });
            return;
        }

        /* ★ 宽度：viewWillAppear 早期 tv.bounds 还是 0（实测日志 footer 0x106），
         *   依次退到 window / screen，最后才用常量。 */
        /* ★ 判重看表格本身：ProfileViewController 和 ProfileViewControllerRoot
         *   可能共用同一张表，两个 vc 都会进来一次 ⇒ 只看 associated object 会插两遍。
         *   （第二次会把第一次的 footer 顶掉，视觉上没事但会多打日志/闪一下） */
        if (tv.tableFooterView && tv.tableFooterView.tag == FDM_ENTRY_TAG) {
            objc_setAssociatedObject(vc, kFDMListEntryKey, tv.tableFooterView,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }

        CGFloat w = tv.bounds.size.width;
        if (w < 200 && tv.window) w = tv.window.bounds.size.width;
        if (w < 200) w = [UIScreen mainScreen].bounds.size.width;
        if (w < 200) w = 414;
        /* ★ 表格自己没宽度就别插（会插进一张 0 宽的框） */
        if (tv.bounds.size.width < 100) {
            static const void *kRetry2 = &kRetry2;
            if (!objc_getAssociatedObject(vc, kRetry2)) {
                objc_setAssociatedObject(vc, kRetry2, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                __weak UIViewController *wv2 = vc;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (wv2) {
                        objc_setAssociatedObject(wv2, kRetry2, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        FDMInstallSettingsEntry(wv2);
                    }
                });
            }
            return;
        }

        UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 106)];
        wrap.tag = FDM_ENTRY_TAG;
        wrap.backgroundColor = [UIColor clearColor];
        wrap.autoresizingMask = UIViewAutoresizingFlexibleWidth;

        /* 分组小标题（和宿主的「关于」「应用」同款：13pt 灰） */
        UILabel *cap = [[UILabel alloc] initWithFrame:CGRectMake(32, 6, 220, 18)];
        cap.text = @"模块";
        cap.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        cap.textColor = [UIColor colorWithWhite:0.53 alpha:1.0];
        cap.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [wrap addSubview:cap];

        /* 卡片：和宿主 InsetsGroupedCell 一致的底色/圆角/高度(49) */
        UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
        card.frame = CGRectMake(16, 30, w - 32, 50);
        card.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        card.backgroundColor = [UIColor colorWithWhite:0.157 alpha:1.0];   /* #282828 */
        card.layer.cornerRadius = 10;
        card.layer.masksToBounds = YES;
        [card addTarget:[FDMTapTarget shared] action:@selector(onTap:)
       forControlEvents:UIControlEventTouchUpInside];

        UILabel *icon = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, 26, 26)];
        icon.text = @"\U0001F996";                 /* 🦖 */
        icon.font = [UIFont systemFontOfSize:19];
        icon.textAlignment = NSTextAlignmentCenter;
        [card addSubview:icon];

        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(52, 0, w - 140, 50)];
        name.text = @"FDM 模块设置";
        name.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        name.textColor = [UIColor whiteColor];
        name.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [card addSubview:name];

        UILabel *chev = [[UILabel alloc] initWithFrame:CGRectMake(w - 32 - 40, 0, 30, 50)];
        chev.text = @"\u203A";
        chev.font = [UIFont systemFontOfSize:19 weight:UIFontWeightLight];
        chev.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
        chev.textAlignment = NSTextAlignmentRight;
        chev.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [card addSubview:chev];

        [wrap addSubview:card];

        /* ★ 保留宿主自己的 footer（有些版本会拿它放备案号），原样摞在下面 */
        UIView *orig = tv.tableFooterView;
        if (orig && orig.tag != FDM_ENTRY_TAG && orig.bounds.size.height > 0) {
            CGRect of = orig.frame;
            of.origin.y = 106;
            of.size.width = w;
            orig.frame = of;
            orig.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            wrap.frame = CGRectMake(0, 0, w, 106 + orig.bounds.size.height);
            [wrap addSubview:orig];
        }
        tv.tableFooterView = wrap;

        objc_setAssociatedObject(vc, kFDMListEntryKey, wrap,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        FLOGW(FC_UI, @"[entry] ★ 已把 FDM 入口插进设置列表（%@，footer %.0fx%.0f）",
              NSStringFromClass([vc class]), wrap.bounds.size.width, wrap.bounds.size.height);
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[entry] 插列表入口异常: %@", e.reason);
    }
}

/* ★ 排除自家页面（FDM 自己的 VC 不要加 🦖） */
static BOOL FDMIsOwnVC(id obj) {
    const char *cn = class_getName(object_getClass(obj));
    if (!cn) return NO;
    return strncmp(cn, "FDM", 3) == 0 ||
           strstr(cn, "FDMGroupVC") ||
           strstr(cn, "FDMSettingsVC") ||
           strstr(cn, "FDMConfigViewController") ||
           strstr(cn, "FDMLogVC") ||
           strstr(cn, "FDMOverrideVC");
}

static void myViewDidLoad(id self, SEL _cmd) {
    FLOGW(FC_UI, @"[trace] viewDidLoad ENTER %s", class_getName(object_getClass(self)));
    IMP o = FDMFindOrigSafe(self, _cmd);
    FLOGW(FC_UI, @"[trace] viewDidLoad ORIG %p", o);
    if (o) ((void(*)(id,SEL))o)(self, _cmd);
    FLOGW(FC_UI, @"[trace] viewDidLoad ORIG-DONE %s", class_getName(object_getClass(self)));
    if (gReent) return;
    if (FDMIsOwnVC(self)) return;              /* ★ 自家页面跳过 */
    gReent++;
    FDMInstallSettingsEntry((UIViewController *)self);   /* ★ 列表入口（首选） */
    FDMEnsureEntryButton((UIViewController *)self);
    if ([[FDMConfig shared] boolFor:G_UI key:@"float_button"])
        FDMAddFloatingButton((UIViewController *)self);
    gReent--;
}

/* ★ 每次进页面都检查（viewDidLoad 一个 VC 只调一次，不够） */
static void myViewWillAppear(id self, SEL _cmd, BOOL animated) {
    FLOGW(FC_UI, @"[trace] willAppear ENTER %s", class_getName(object_getClass(self)));
    IMP o = FDMFindOrigSafe(self, _cmd);
    FLOGW(FC_UI, @"[trace] willAppear ORIG %p", o);
    if (o) ((void(*)(id,SEL,BOOL))o)(self, _cmd, animated);
    FLOGW(FC_UI, @"[trace] willAppear ORIG-DONE %s", class_getName(object_getClass(self)));
    if (gReent) return;
    if (FDMIsOwnVC(self)) return;                        /* ★ 自家页面跳过 */
    if (![self isKindOfClass:[UIViewController class]]) return;
    if ([self isKindOfClass:[UINavigationController class]] ||
        [self isKindOfClass:[UITabBarController class]]) return;
    gReent++;
    @try {
        /* ★ 节流：同一个 VC 0.3s 内只处理一次（宿主可能连续触发多次） */
        {
            static __thread NSTimeInterval lastT = 0;
            static __thread __unsafe_unretained id lastVC = nil;
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            if (lastVC == self && (now - lastT) < 0.3) { gReent--; return; }
            lastVC = self; lastT = now;
        }
        /* ⓪ 列表入口：宿主「设置」页底部插一行（最原生）
         *   ★ 延迟 1 秒再补一次：viewWillAppear 这一刻宿主表格常常还是 0x0 */
        FDMInstallSettingsEntry((UIViewController *)self);
        if (FDMPageAllowsButton(self)) {
            __weak UIViewController *wv = (UIViewController *)self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (wv) FDMInstallSettingsEntry(wv);
            });
        }
        /* ① navigationItem（有标准导航栏时可见） */
        FDMEnsureEntryButton((UIViewController *)self);
        /* ② 浮动按钮（不依赖导航栏，独立加） */
        if ([[FDMConfig shared] boolFor:G_UI key:@"float_button"])
            FDMAddFloatingButton((UIViewController *)self);
        FDMLayoutFloat((UIViewController *)self);
        FLOGD(FC_UI, @"viewWillAppear: %@", NSStringFromClass([self class]));
    } @catch (NSException *e) {}
    gReent--;
}

#pragma mark - 安装

void FDMUIInstall(void) {
    @autoreleasepool {
        FLOGI(FC_UI, @"=== FDMUIInstall 开始 ===");
        /* ★★★ 2026-10-17 深夜 · 这里曾是一颗地雷：
         *   旧代码判断 `entry_button` 为关就 **整个 return**，
         *   于是 viewWillAppear / viewDidLoad 的 hook 全都不装。
         *   把 entry_button 默认改成 NO（改用列表入口）之后，
         *   连列表入口自己都跑不起来 —— 因为调用它的 hook 没装。
         *   ⇒ 改成：**三个入口全关**才跳过。 */
        {
            FDMConfig *Cu = [FDMConfig shared];
            BOOL any = [Cu boolFor:G_UI key:@"entry_list"] ||
                       [Cu boolFor:G_UI key:@"entry_button"] ||
                       [Cu boolFor:G_UI key:@"float_button"];
            if (!any) {
                FLOGI(FC_UI, @"三个入口都关了，跳过 FDMUI 安装");
                return;
            }
        }
        /* ★ 运行时遍历所有类，按【后缀】匹配（不依赖硬编码长度前缀）
         *   目标：所有 *ProfileViewController* / *ProfileSharedTableViewController*
         *   —— 后者是所有设置页的基类 */
        int total = objc_getClassList(NULL, 0);
        __unsafe_unretained Class *list =
            (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)(total > 0 ? total : 1));
        if (!list) { FLOGE(FC_UI, @"类枚举失败"); return; }
        total = objc_getClassList(list, total);

        int n = 0;
        for (int i = 0; i < total; i++) {
            const char *cn = class_getName(list[i]);
            if (!cn || !strstr(cn, "DeepSeek_Chat")) continue;
            BOOL hit = NO;
            /* ★ 严格匹配：必须是 UITableViewController 系的设置页
             *   （名字里带 ProfileViewController 的还有 Layer/View/Cell/Button/
             *    NavigationController，全都不是设置页） */
            if (strstr(cn, "ProfileSharedTableViewController"))     hit = YES;  /* 基类 */
            else if (strstr(cn, "21ProfileViewController"))         hit = YES;  /* 设置页本体 */
            else if (strstr(cn, "AccountManagementViewController")) hit = YES;
            else if (strstr(cn, "DataConfigViewController"))        hit = YES;
            else if (strstr(cn, "AboutViewController"))             hit = YES;
            else if (strstr(cn, "PersonalizationViewController"))   hit = YES;
            else if (strstr(cn, "ShareListViewController"))         hit = YES;
            if (!hit) continue;

            /* ★★★ 三重校验（任一不过就跳过）：
             *   ① 必须是 UIViewController 子类
             *   ② 不能是 UINavigationController / UINavigationController 子类
             *   ③ 自己或祖先必须真正实现 viewWillAppear:（不能靠"没有"硬挂） */
            Class VCCls = objc_getClass("UIViewController");
            if (!VCCls || !class_getSuperclass(list[i]) ||
                ![list[i] isSubclassOfClass:VCCls]) {
                FLOGD(FC_UI, @"  ✗ 跳过 %s（非 UIViewController）", cn);
                continue;
            }
            Class NavCls = [UINavigationController class];
            if (NavCls && [list[i] isSubclassOfClass:NavCls]) {
                FLOGD(FC_UI, @"  ✗ 跳过 %s（是导航控制器）", cn);
                continue;
            }

            if (FDMSwap(list[i], "viewDidLoad", (IMP)myViewDidLoad)) n++;
            if (FDMSwap(list[i], "viewWillAppear:", (IMP)myViewWillAppear)) n++;
            FLOGI(FC_UI, @"  ✓ 处理 %s", cn);
        }
        free(list);
        FLOGI(FC_UI, @"=== FDMUIInstall 结束（%d 处 hook）===", n);
        if (n == 0) FLOGW(FC_UI, @"⚠️ 一个都没挂上 —— 目标类可能还没加载");
    }
}

/* ============================================================
 * ★★★ 2026-10-17 深夜：巡检版入口安装（绕开 FDMUIInstall 那条死链）
 *
 *   实测：FDMUIInstall / FDMUIInstallRetry 整条链**没有跑起来**
 *   （日志里连"第 N 次尝试"都没有），而我们的 viewWillAppear hook
 *   正是装在 FDMUIInstall 里的 ⇒ 所有入口都失效。
 *
 *   ⇒ 改由**一直活着的**建议按钮巡检（FDMComposer 每 0.35s）来调用本函数，
 *     每 ~4 秒找一次顶层 VC，是「设置/我的」页就插入口。
 *     完全不依赖 FDMUIInstall 是否成功。
 * ============================================================ */
void FDMUICheckSettingsEntry(void) {
    @try {
        UIWindow *w = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *x in ((UIWindowScene *)sc).windows)
                if (x.windowLevel == UIWindowLevelNormal) { w = x; break; }
            if (w) break;
        }
        if (!w) return;
        UIViewController *vc = w.rootViewController;
        if (!vc) return;
        /* 一路追到最顶层（presented / child） */
        int guard = 0;
        while (guard++ < 8) {
            if (vc.presentedViewController) { vc = vc.presentedViewController; continue; }
            if ([vc isKindOfClass:[UINavigationController class]]) {
                UIViewController *top = ((UINavigationController *)vc).topViewController;
                if (top && top != vc) { vc = top; continue; }
            }
            break;
        }
        if (!vc) return;
        const char *cn = class_getName([vc class]);
        if (!cn) return;
        BOOL isSetting = (strstr(cn, "Profile") != NULL || strstr(cn, "Setting") != NULL);
        if (!isSetting) return;
        FDMInstallSettingsEntry(vc);
        /* 也试一次它的 parent（0x0 空壳的情况） */
        if (vc.parentViewController) FDMInstallSettingsEntry(vc.parentViewController);
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[entry] 巡检异常: %@", e.reason);
    }
}

int FDMUIInstallRetry(int attempt) {
    if (!objc_getClass("_TtC13DeepSeek_Chat21ProfileViewController")) return 0;
    /* ★ 2026-10-17 深夜 · 第二颗地雷：这里也曾只看 entry_button。
     *   改成「三个入口任一开启」都要装 hook（列表入口同样依赖这些 hook）。 */
    {
        FDMConfig *C = [FDMConfig shared];
        BOOL any = [C boolFor:G_UI key:@"entry_list"] ||
                   [C boolFor:G_UI key:@"entry_button"] ||
                   [C boolFor:G_UI key:@"float_button"];
        if (!any) {
            FLOGI(FC_UI, @"[entry] 三个入口都关，不装 UI hook");
            return 1;
        }
    }
    FDMUIInstall();
    return 1;
}

#pragma mark - 动作执行

static NSString *FDMDocs2(void) { return FDMDocs(); }

void FDMUIRunAction(NSString *action, UIViewController *host) {
    if (!action.length || !host) return;
    FLOGI(FC_UI, @"执行动作: %@", action);

    if ([action isEqualToString:@"open_log"]) {
        FDMLogVC *vc = [[FDMLogVC alloc] init];
        [host.navigationController pushViewController:vc animated:YES];
        return;
    }
    if ([action isEqualToString:@"composer_probe"]) {
        extern void FDMComposerProbe(void);
        FDMComposerProbe();
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"已探查输入区"
                             message:@"结果在 fdm.log 里，搜 [send-probe]"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                           handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }
    if ([action isEqualToString:@"composer_test"]) {
        extern BOOL FDMComposerSend(NSString *text);
        extern NSString *FDMComposerStatus(void);
        NSString *txt = [[FDMConfig shared] stringFor:P_COMPOSER key:@"test_text"];
        if (!txt.length) txt = @"这是一条来自模块的测试消息";
        BOOL ok = FDMComposerSend(txt);
        NSString *st = FDMComposerStatus();
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:ok ? @"已尝试发送" : @"发送失败"
                             message:[NSString stringWithFormat:
                                      @"结果：%@\n%@\n\n细节看日志 [send]",
                                      ok ? @"已发出" : @"没发出去", st]
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                           handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }
    if ([action isEqualToString:@"capture_shot"]) {
        extern int FDMUICapture(NSString *name);
        extern int FDMUICapture2x(NSString *name);
        NSString *nm = [NSString stringWithFormat:@"fdm-shot-%@.png",
                        [[NSDate date] description]];
        nm = [nm stringByReplacingOccurrencesOfString:@" " withString:@"_"];
        nm = [nm stringByReplacingOccurrencesOfString:@":" withString:@"-"];
        int r = FDMUICapture2x(nm);
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:(r == 0 ? @"截图完成" : @"截图失败")
                             message:[NSString stringWithFormat:
                                      @"%@\n文件：%@\n（用 Filza 或让尼尼拉走）",
                                      r == 0 ? @"已存到 Documents" : [NSString stringWithFormat:@"错误码 %d", r],
                                      nm]
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                           handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }
    if ([action isEqualToString:@"dump_msg"]) {
        extern void FDMUIDumpMessages(void);
        FDMUIDumpMessages();
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"消息区已 dump"
                             message:@"结果在 fdm.log 里，搜 [msgdump]"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                           handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }
    if ([action isEqualToString:@"dump_uitree"]) {
        extern void FDMUITreeDump(NSString *reason);
        FDMUITreeDump(@"手动");
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"视图树已导出"
                             message:@"文件在 Documents/fdm-uitree-手动.txt\n可以用 Filza 打开，或让尼尼拉取"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }
    if ([action isEqualToString:@"pick_photo"]) {
        extern void FDMPhotoPickerPresent(NSString *);
        FDMPhotoPickerPresent(@"fdm-bg.jpg");
        return;
    }
    /* ── 助手图片 ── */
    if ([action isEqualToString:@"pick_assistant_photo"]) {
        extern void FDMPhotoPickerPresentFor(NSString *, NSString *, NSString *,
                                             void (^)(BOOL));
        extern void FDMAssistantReload(void);
        FDMPhotoPickerPresentFor(@"fdm-assistant.jpg", @"assistant", @"file",
                                 ^(BOOL ok) {
            if (!ok) return;
            FDMConfig *c = [FDMConfig shared];
            [c setValue:@YES for:@"assistant" key:@"on"];
            FDMAssistantReload();
            FLOGW(FC_UI, @"[assistant] 选图完成并已启用");
        });
        return;
    }

    /* ── 我·气泡图片底 ── */
    if ([action isEqualToString:@"pick_bubble_mine_photo"]) {
        extern void FDMPhotoPickerPresentFor(NSString *, NSString *, NSString *,
                                             void (^)(BOOL));
        extern void FDMBubbleReload(void);
        FDMPhotoPickerPresentFor(@"fdm-bubble-mine.jpg", @"bubble", @"mine_img_file",
                                 ^(BOOL ok) {
            if (!ok) return;
            FDMConfig *c = [FDMConfig shared];
            [c setValue:@YES for:@"bubble" key:@"on"];
            [c setValue:@YES for:@"bubble" key:@"mine_img_on"];
            FDMBubbleReload();
            FLOGW(FC_UI, @"[bubble] 我·图片底已设置");
        });
        return;
    }

    /* ── AI·气泡图片底 ── */
    if ([action isEqualToString:@"pick_bubble_theirs_photo"]) {
        extern void FDMPhotoPickerPresentFor(NSString *, NSString *, NSString *,
                                             void (^)(BOOL));
        extern void FDMBubbleReload(void);
        FDMPhotoPickerPresentFor(@"fdm-bubble-theirs.jpg", @"bubble", @"theirs_img_file",
                                 ^(BOOL ok) {
            if (!ok) return;
            FDMConfig *c = [FDMConfig shared];
            [c setValue:@YES for:@"bubble" key:@"on"];
            [c setValue:@YES for:@"bubble" key:@"theirs_img_on"];
            FDMBubbleReload();
            FLOGW(FC_UI, @"[bubble] AI·图片底已设置");
        });
        return;
    }

    /* ── 文件快捷：一键填示例 ── */
    if ([action isEqualToString:@"filecard_example"]) {
        FDMConfig *c = [FDMConfig shared];
        NSString *demo = @"总结|帮我用要点总结这个文件\n"
                         @"翻译|把这个文件翻译成中文\n"
                         @"表格|把这个文件里的数据整理成表格";
        [c setValue:demo for:@"filecard" key:@"items"];
        [c setValue:@YES for:@"filecard" key:@"on"];
        extern void FDMFileCardReload(void);
        FDMFileCardReload();
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"示例已填入"
                             message:@"三条默认示例已写进文本框，并自动打开开关。\n"
                                     @"想改就改文本框，改完退出去就生效。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                           handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }

    /* ── 便签：重新显示（✕ 之后用）── */
    if ([action isEqualToString:@"note_show"]) {
        extern void FDMNoteSetVisible(BOOL);
        FDMNoteSetVisible(YES);
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"便签已恢复"
                             message:@"如果还看不见，检查「启用」开关是否打开。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                           handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }

    /* ══════════════════════════════════════════════════════════
     * 卡片式系统提示词 v2（2026-10-25）
     * 用一个自绘 VC，不是 FDMGroup 表格 —— 它要拖拽。
     * ══════════════════════════════════════════════════════════ */
    if ([action isEqualToString:@"open_spv2"]) {
        extern UIViewController *FDMPromptV2ViewController(void);
        UIViewController *vc = FDMPromptV2ViewController();
        if (vc) [host.navigationController pushViewController:vc animated:YES];
        else FLOGE(FC_UI, @"[spv2] 页面创建失败");
        return;
    }

    /* ══════════════════════════════════════════════════════════
     * 网易云登录（2026-10-25）
     *
     * ★ 密码 / cookie 输入框在**登录成功后立刻清空** ——
     *   因为 FDMConfig 会把所有字段明文写进 fdm-music-login.json，
     *   不清的话用户的密码会长期躺在磁盘上。
     *   验证码和手机号也一起清（验证码有时效，留着没用）。
     * ══════════════════════════════════════════════════════════ */
    if ([action hasPrefix:@"music_"] || [action isEqualToString:@"music_logout"]) {
        FDMConfig *lc = [FDMConfig shared];
        NSString *gid = @"musiclogin";

        /* 统一的「弹一句话给用户」 */
        void (^toast)(NSString *, NSString *) = ^(NSString *t, NSString *m) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *a = [UIAlertController
                    alertControllerWithTitle:t message:m
                             preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
                [host presentViewController:a animated:YES completion:nil];
            });
        };

        /* 登录成功后清空敏感输入框 */
        void (^wipe)(void) = ^{
            [lc setValue:@"" for:gid key:@"password"];
            [lc setValue:@"" for:gid key:@"cookie"];
            [lc setValue:@"" for:gid key:@"captcha"];
            FLOGI(FC_MUSIC, @"[login] 已清空密码/cookie/验证码输入框");
        };

        extern void FDMMusicLoginSendCaptcha(NSString *, NSString *, void (^)(BOOL, NSString *));
        extern void FDMMusicLoginByCaptcha(NSString *, NSString *, NSString *, void (^)(BOOL, NSString *));
        extern void FDMMusicLoginByPassword(NSString *, NSString *, NSString *, void (^)(BOOL, NSString *));
        extern void FDMMusicLoginByEmail(NSString *, NSString *, void (^)(BOOL, NSString *));
        extern void FDMMusicLoginByCookie(NSString *, void (^)(BOOL, NSString *));
        extern void FDMMusicLoginCheck(void (^)(BOOL, NSString *));
        extern NSString *FDMMusicLoginDiag(void);
        extern NSString *FDMMusicLoginSummary(void);
        extern BOOL FDMMusicLoginClear(void);

        if ([action isEqualToString:@"music_send_captcha"]) {
            NSString *phone = [lc stringFor:gid key:@"phone"];
            NSString *cc    = [lc stringFor:gid key:@"ctcode"];
            if (!phone.length) { toast(@"先填手机号", @"「手机号」那一栏是空的"); return; }
            toast(@"发码中…", @"等一两秒");
            FDMMusicLoginSendCaptcha(phone, cc, ^(BOOL ok, NSString *msg) {
                toast(ok ? @"验证码已发出" : @"发码失败", msg ?: @"");
            });
            return;
        }

        if ([action isEqualToString:@"music_login_captcha"]) {
            NSString *phone = [lc stringFor:gid key:@"phone"];
            NSString *cap   = [lc stringFor:gid key:@"captcha"];
            NSString *cc    = [lc stringFor:gid key:@"ctcode"];
            if (!phone.length || !cap.length) { toast(@"信息不全", @"手机号和验证码都要填"); return; }
            toast(@"登录中…", @"");
            FDMMusicLoginByCaptcha(phone, cap, cc, ^(BOOL ok, NSString *msg) {
                if (ok) wipe();
                toast(ok ? @"✅ 登录成功" : @"登录失败", msg ?: @"");
            });
            return;
        }

        if ([action isEqualToString:@"music_login_password"]) {
            NSString *phone = [lc stringFor:gid key:@"phone"];
            NSString *pwd   = [lc stringFor:gid key:@"password"];
            NSString *cc    = [lc stringFor:gid key:@"ctcode"];
            if (!phone.length || !pwd.length) { toast(@"信息不全", @"手机号和密码都要填"); return; }
            toast(@"登录中…", @"密码只做 md5，不会明文上传");
            FDMMusicLoginByPassword(phone, pwd, cc, ^(BOOL ok, NSString *msg) {
                if (ok) wipe();
                toast(ok ? @"✅ 登录成功" : @"登录失败", msg ?: @"");
            });
            return;
        }

        if ([action isEqualToString:@"music_login_email"]) {
            NSString *mail = [lc stringFor:gid key:@"email"];
            NSString *pwd  = [lc stringFor:gid key:@"password"];
            if (!mail.length || !pwd.length) { toast(@"信息不全", @"邮箱和密码都要填"); return; }
            toast(@"登录中…", @"");
            FDMMusicLoginByEmail(mail, pwd, ^(BOOL ok, NSString *msg) {
                if (ok) wipe();
                toast(ok ? @"✅ 登录成功" : @"登录失败", msg ?: @"");
            });
            return;
        }

        if ([action isEqualToString:@"music_login_cookie"]) {
            NSString *ck = [lc stringFor:gid key:@"cookie"];
            if (!ck.length) { toast(@"先粘 cookie", @"「cookie」那一栏是空的"); return; }
            FDMMusicLoginByCookie(ck, ^(BOOL ok, NSString *msg) {
                if (ok) wipe();
                toast(ok ? @"✅ 登录成功" : @"登录失败", msg ?: @"");
            });
            return;
        }

        if ([action isEqualToString:@"music_login_status"]) {
            FDMMusicLoginCheck(^(BOOL ok, NSString *msg) { toast(@"登录状态", msg ?: @""); });
            return;
        }

        if ([action isEqualToString:@"music_login_diag"]) {
            NSString *d = FDMMusicLoginDiag();
            /* 诊断串直接复制到剪贴板，省得用户手打 */
            [UIPasteboard generalPasteboard].string = d;
            toast(@"诊断已复制到剪贴板", d);
            return;
        }

        if ([action isEqualToString:@"music_logout"]) {
            BOOL ok = FDMMusicLoginClear();
            toast(ok ? @"已退出登录" : @"退出失败", @"本地凭证已删除");
            return;
        }
        (void)FDMMusicLoginSummary;
    }

    if ([action isEqualToString:@"clear_photo"]) {
        NSString *p = [FDMDocs2() stringByAppendingPathComponent:@"fdm-bg.jpg"];
        [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
        /* 配置切回纯色 */
        NSString *cfgPath = [FDMDocs2() stringByAppendingPathComponent:@"fdm-bg.json"];
        NSMutableDictionary *cfg = nil;
        NSData *raw = [NSData dataWithContentsOfFile:cfgPath];
        if (raw) {
            id j = [NSJSONSerialization JSONObjectWithData:raw
                                                  options:NSJSONReadingMutableContainers
                                                    error:nil];
            if ([j isKindOfClass:[NSDictionary class]]) cfg = j;
        }
        if (!cfg) cfg = [NSMutableDictionary dictionary];
        cfg[@"mode"] = @"solid";
        cfg[@"file"] = @"";
        NSData *out = [NSJSONSerialization dataWithJSONObject:cfg
                                                      options:NSJSONWritingPrettyPrinted error:nil];
        [out writeToFile:cfgPath atomically:YES];
        extern void FDMBeautyRefreshBackground(void);
        FDMBeautyRefreshBackground();
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已清除"
                                                                  message:@"背景图已删除"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }
    if ([action isEqualToString:@"open_db"]) {
        NSString *p = FDMDocs2();
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Documents"
                                                                  message:p
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *x){
            [UIPasteboard generalPasteboard].string = p;
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }
    if ([action isEqualToString:@"clear_log"]) {
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"清空日志？"
                             message:@"会删除 fdm.log 与 .1 备份"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *x){
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:FLogPath() error:nil];
            [fm removeItemAtPath:[FLogPath() stringByAppendingString:@".1"] error:nil];
            FLOGI(FC_UI, @"日志已清空");
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }
    if ([action isEqualToString:@"clear_shots"]) {
        /* ★ 2026-10-25 自动截图产生的图里可能含聊天内容，给个一键清空 */
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *err = nil;
        NSArray *all = [fm contentsOfDirectoryAtPath:FDMDocs() error:&err];
        NSUInteger n = 0;
        unsigned long long bytes = 0;
        for (NSString *f in all) {
            if (![f hasPrefix:@"fdm-ui-"] || ![f hasSuffix:@".png"]) continue;
            NSString *p = [FDMDocs() stringByAppendingPathComponent:f];
            NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
            bytes += [at[NSFileSize] unsignedLongLongValue];
            if ([fm removeItemAtPath:p error:nil]) n++;
        }
        FLOGI(FC_UI, @"[shots] 已删除 %lu 张截图（%.1f KB）",
              (unsigned long)n, bytes / 1024.0);

        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:(n ? @"截图已清空" : @"没有截图")
                             message:[NSString stringWithFormat:
                                      @"删除 %lu 张，释放 %.1f KB",
                                      (unsigned long)n, bytes / 1024.0]
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                           handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }
    if ([action isEqualToString:@"open_gray"]) {
        FDMOverrideVC *vc = [[FDMOverrideVC alloc] init];
        vc.readOnly = YES;
        vc.title = @"服务端下发";
        [host.navigationController pushViewController:vc animated:YES];
        return;
    }
    if ([action isEqualToString:@"show_sample"]) {
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"富文本示例"
                             message:@"<b>粗体</b> <i>斜体</i> <code>代码</code>\n\n（iOS 端渲染层待接入）"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }
    FLOGW(FC_UI, @"未知动作: %@", action);
}

/* ============================================================
 * ★★ 2026-10-25 自动拍照：让模块自己打开设置页、自己截图、自己退场
 *
 *   为什么会有这么个东西：
 *     真机上 MCP（8090）挂了、没有 frida、/var/jb/usr/bin 里也没有任何
 *     命令行截屏工具 ⇒ 尼尼在电脑这头**完全看不见**设置页长啥样，
 *     只能靠日志猜。改了 UI 树以后，这个盲区必须补上。
 *
 *   做法：全程走 App 自己进程内的 UI，不需要点屏幕、不需要外部工具。
 *     fdm-debug.json:  { "ui_auto_shot": true,
 *                        "ui_auto_shot_pages": "misc,chat" }
 *     启动后自动：弹设置页 → 拍首页 → 依次深进每个子页拍一张 → 关掉。
 *     产物：Documents/fdm-ui-<页名>.png（2x 分辨率，可 scp 拉走）
 *
 *   ⚠️ 只在开关打开时才跑，默认关；拍完会自己 dismiss，不挡人。
 * ============================================================ */

/* ★ 必须**强持有**：`__weak` 在 ARC 下，present 完成前没人强引用它，
 *   这行一执行完 nav 就被释放成 nil ⇒ 后面「没有 nav，跳过 misc」。
 *   强持有到 End()，那时 dismiss 完再置 nil。 */
static UINavigationController *gFDMAutoShotNav = nil;

/* 弹出设置页；gid 为空 ⇒ 只停在首页 */
void FDMUIAutoShotBegin(NSString *gid) {
    @try {
        UIViewController *host = FDMTopVC();
        if (!host) { FLOGW(FC_UI, @"[autoshot] 没有可用 VC"); return; }

        /* ★ 2026-10-25 修：**先判空，再赋值**
         *   旧写法是先 `gFDMAutoShotNav = nav` 再判断 presentedViewController，
         *   一旦当时有别的模态 ⇒ nav 已经存进全局却永远不会 present，
         *   后面 Push 会往一个不在屏幕上的 nav 里塞 VC，截图 rc=0（拍的是宿主界面），
         *   看起来"成功"其实是错的。 */
        if (host.presentedViewController) {
            FLOGW(FC_UI, @"[autoshot] 已有模态 %@ ⇒ 本轮跳过",
                  NSStringFromClass([host.presentedViewController class]));
            return;
        }

        FDMSettingsVC *root = [[FDMSettingsVC alloc] init];
        root.title = @"FDM 设置";
        UINavigationController *nav =
            [[UINavigationController alloc] initWithRootViewController:root];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;

        if (gid.length) {
            FDMGroup *g = [[FDMConfig shared] groupByID:gid];
            if (g) [nav pushViewController:[[FDMGroupVC alloc] initWithGroup:g] animated:NO];
            else   FLOGE(FC_UI, @"[autoshot] 子页 %@ 不存在（按首页拍）", gid);
        }

        gFDMAutoShotNav = nav;      /* ★ 确认要 present 了才持有 */
        [host presentViewController:nav animated:NO completion:^{
            FLOGI(FC_UI, @"[autoshot] 已弹出设置页（%@）", gid.length ? gid : @"首页");
        }];
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[autoshot] 弹出异常: %@", e.reason);
    }
}

void FDMUIAutoShotPush(NSString *gid) {
    @try {
        UINavigationController *nav = gFDMAutoShotNav;
        if (!nav) { FLOGW(FC_UI, @"[autoshot] 没有 nav，跳过 %@", gid); return; }
        FDMGroup *g = [[FDMConfig shared] groupByID:gid];
        if (!g) { FLOGE(FC_UI, @"[autoshot] 子页 %@ 不存在", gid); return; }
        /* 回到根再逐级 push，保证拍到的层级是「首页 → 子页」真实路径 */
        [nav popToRootViewControllerAnimated:NO];
        FDMGroup *parent = g.parent.length ? [[FDMConfig shared] groupByID:g.parent] : nil;
        if (parent) [nav pushViewController:[[FDMGroupVC alloc] initWithGroup:parent] animated:NO];
        [nav pushViewController:[[FDMGroupVC alloc] initWithGroup:g] animated:NO];
        FLOGI(FC_UI, @"[autoshot] 已进入 %@", g.title);
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[autoshot] push 异常: %@", e.reason);
    }
}

void FDMUIAutoShotCapture(NSString *name) {
    extern int FDMUICapture2x(NSString *nm);
    NSString *fn = [NSString stringWithFormat:@"fdm-ui-%@.png", name ?: @"x"];
    int r = FDMUICapture2x(fn);
    FLOGI(FC_UI, @"[autoshot] 拍照 %@ → rc=%d", fn, r);
}

/* ★ 2026-10-25 页尾补充拍照
 *   为什么：设置页经常比一屏长，只拍一张「首屏」会漏掉页面下半部分
 *   （这次加的三个点歌字段就全在「说明」区后面，第一张根本看不到）。
 *   这里把当前页的 tableView 滚到底，再拍一张 -tail。
 */
void FDMUIAutoShotCaptureTail(NSString *name) {
    @try {
        UINavigationController *nav = gFDMAutoShotNav;
        UIViewController *top = nav.topViewController;
        if (!top) return;

        UITableView *tv = nil;
        if ([top.view isKindOfClass:[UITableView class]]) {
            tv = (UITableView *)top.view;
        } else {
            /* 找 view 里第一个 UITableView */
            NSMutableArray *st = [NSMutableArray arrayWithObject:top.view];
            while (st.count && !tv) {
                UIView *v = st.lastObject;
                [st removeLastObject];
                if ([v isKindOfClass:[UITableView class]]) { tv = (UITableView *)v; break; }
                for (UIView *s in v.subviews) [st addObject:s];
            }
        }
        if (!tv) { FLOGW(FC_UI, @"[autoshot] 没找到 tableView，跳过尾拍"); return; }

        NSInteger secs = [tv numberOfSections];
        NSInteger last = secs > 0 ? [tv numberOfRowsInSection:secs - 1] : 0;
        if (secs <= 0 || last <= 0) { FLOGW(FC_UI, @"[autoshot] 表为空，跳过尾拍"); return; }

        NSIndexPath *ip = [NSIndexPath indexPathForRow:last - 1 inSection:secs - 1];
        [tv scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionBottom animated:NO];
        FLOGI(FC_UI, @"[autoshot] 已滚到底（%ld 段 / 末段 %ld 行）",
              (long)secs, (long)last);

        /* 滚完让渲染落定一帧再拍 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSString *fn = [NSString stringWithFormat:@"fdm-ui-%@-tail.png", name ?: @"x"];
            extern int FDMUICapture2x(NSString *nm);
            int r = FDMUICapture2x(fn);
            FLOGI(FC_UI, @"[autoshot] 尾拍 %@ → rc=%d", fn, r);
        });
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[autoshot] 尾拍异常: %@", e.reason);
    }
}

void FDMUIAutoShotEnd(void) {
    @try {
        UINavigationController *nav = gFDMAutoShotNav;
        gFDMAutoShotNav = nil;
        if (!nav) return;
        [nav dismissViewControllerAnimated:NO completion:^{
            FLOGI(FC_UI, @"[autoshot] 已收起设置页");
        }];
    } @catch (NSException *e) {
        FLOGE(FC_UI, @"[autoshot] 收起异常: %@", e.reason);
    }
}
