// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMPromptUI.m —— 卡片式系统提示词 v2（v72 逐条修）
//
// ══════════════════════════════════════════════════════════════════════════
//  v72 修了主人报的 7 个问题（每条都标了 ★修）
//
//  ① ★修 **UI 偏移**：预览条压在导航栏上
//       → `edgesForExtendedLayout = UIRectEdgeNone` + 预览改成 tableHeaderView
//  ② ★修 **展开内容不显示 / 错位盖到下一行**
//       → expanded 状态从 cell 挪到 VC（NSMutableSet 按 key 存），
//         heightForRow 查那个集合，**不再问 cell**（cell 那时可能还没创建）
//  ③ ★修 **卡片点击三种情况**
//       内置三张 → 展开看约定原文
//       自定义卡 → 展开看正文
//       源卡     → 展开看说明
//       （右侧 ▸ 才是"跳页面/编辑"，两者不抢）
//  ④ ★修 **自定义卡展开看不到内容**
//       → 展开时显示完整正文 + 「标题也进」状态 + 字数
//  ⑤ ★修 **左边拖动条是坏的**（最严重）
//       病根：`UILongPressGestureRecognizer.allowableMovement = 8.0`
//             —— 这个值的含义是「手指移动超过 8pt 就**取消手势**」，
//             所以根本拖不起来，一动就 Cancelled。
//       → 设成 CGFLOAT_MAX；ghost 的 x/y **都**跟随（v71 只跟 y）
//  ⑥ ★修 **新建的卡默认不进提示词**
//       → 新建后**直接移进容器**，并自动展开
//  ⑦ ★修 **「标题也进提示词」太容易误触**
//       → 新建不再自动弹编辑框；那个按钮改成明确文案，且不再循环重开弹窗
// ══════════════════════════════════════════════════════════════════════════
#import <UIKit/UIKit.h>

#import "FDMPromptUI.h"
#import "FDMPromptCard.h"
#import "FDMConfig.h"
#import "FLog.h"

/* ============================================================
 * 〇、小工具
 * ============================================================ */

static NSString *PUPath(void) {
    @try {
        NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES).firstObject;
        return [d stringByAppendingPathComponent:@"fdm-sysprompt-v2.json"];
    } @catch (NSException *e) { return nil; }
}

/** C 字符串 → NSString（三级兜底，坏字节换 '?' + 打日志）。 */
static NSString *PUSafe(NSString *what, const char *utf8) {
    if (!utf8) return @"";
    size_t len = strlen(utf8);
    if (len == 0) return @"";

    NSString *s = [NSString stringWithUTF8String:utf8];
    if (s) return s;

    NSData *d = [NSData dataWithBytes:utf8 length:len];
    s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s) {
        FLOGW(FC_CFG, @"[spv2] %@ 非法 UTF-8，已用 data 兜底（%lu 字节）",
              what, (unsigned long)len);
        return s;
    }

    NSMutableString *m = [NSMutableString stringWithCapacity:len];
    NSUInteger bad = 0;
    for (size_t i = 0; i < len; ) {
        unsigned char b = (unsigned char)utf8[i];
        size_t need = (b < 0x80) ? 1 : ((b >> 5) == 0x6) ? 2
                    : ((b >> 4) == 0xE) ? 3 : ((b >> 3) == 0x1E) ? 4 : 1;
        if (i + need > len) { bad++; break; }
        NSString *ch = [[NSString alloc] initWithBytes:utf8 + i
                                                length:need
                                              encoding:NSUTF8StringEncoding];
        if (ch) [m appendString:ch];
        else { [m appendString:@"?"]; bad++; }
        i += need;
    }
    FLOGE(FC_CFG, @"[spv2] %@ 有 %lu 个非法字节（建议点「重置」）", what, (unsigned long)bad);
    return m;
}

static NSString *PUTypeTitle(const char *type) {
    return PUSafe(@"type_title", fdmpc_type_title(type));
}

static NSString *PUCount(NSString *s) {
    return [NSString stringWithFormat:@"%lu 字", (unsigned long)s.length];
}

/* ============================================================
 * 一、单元格
 * ============================================================ */

@class PUCell;

@protocol PUHandleDelegate <NSObject>
- (void)handlePressOnCell:(PUCell *)cell gesture:(UIGestureRecognizer *)g;
- (void)cellBodyTapped:(PUCell *)cell;
- (void)cellTrailTapped:(PUCell *)cell;
@end

@interface PUCell : UITableViewCell
@property (nonatomic, weak)   id<PUHandleDelegate> hub;
@property (nonatomic, strong) UIView   *handleBox;
@property (nonatomic, strong) UIView   *bar1, *bar2;
@property (nonatomic, strong) UILabel  *titleLbl;
@property (nonatomic, strong) UILabel  *subLbl;
@property (nonatomic, strong) UIButton *trailBtn;
@property (nonatomic, strong) UIView   *sepLine;
@property (nonatomic, assign) BOOL      expanded;
@end

@implementation PUCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (!self) return nil;

    self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    /* ---- 左侧小横条（拖拽把手）---- */
    _handleBox = [[UIView alloc] initWithFrame:CGRectZero];
    _handleBox.backgroundColor = UIColor.clearColor;
    _handleBox.userInteractionEnabled = YES;
    [self.contentView addSubview:_handleBox];

    _bar1 = [[UIView alloc] initWithFrame:CGRectZero];
    _bar2 = [[UIView alloc] initWithFrame:CGRectZero];
    for (UIView *b in @[ _bar1, _bar2 ]) {
        b.backgroundColor = [UIColor colorWithWhite:0.60 alpha:1.0];
        b.layer.cornerRadius = 1.0;
        b.userInteractionEnabled = NO;
        [_handleBox addSubview:b];
    }

    /* ★★ v72 修「拖动条是坏的」：
     *   v71 写 allowableMovement = 8.0 —— 那是「移动超过 8pt 就取消手势」，
     *   手指一动就 Cancelled，所以根本拖不起来。
     *   现在 = CGFLOAT_MAX（不限制），minimumPressDuration = 0.12。 */
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                     action:@selector(onHandlePress:)];
    lp.minimumPressDuration = 0.12;
    lp.allowableMovement = CGFLOAT_MAX;      /* ★★ 关键 */
    lp.cancelsTouchesInView = NO;
    [_handleBox addGestureRecognizer:lp];

    /* ---- 中间：标题 + 副标题 ---- */
    _titleLbl = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLbl.font = [UIFont systemFontOfSize:16];
    _titleLbl.textColor = [UIColor labelColor];
    _titleLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLbl.userInteractionEnabled = NO;
    [self.contentView addSubview:_titleLbl];

    _subLbl = [[UILabel alloc] initWithFrame:CGRectZero];
    _subLbl.font = [UIFont systemFontOfSize:12];
    _subLbl.textColor = [UIColor secondaryLabelColor];
    _subLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    _subLbl.numberOfLines = 2;
    _subLbl.userInteractionEnabled = NO;
    [self.contentView addSubview:_subLbl];

    /* ---- 右侧动作 ---- */
    _trailBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _trailBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    [_trailBtn addTarget:self action:@selector(onTrail)
        forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_trailBtn];

    _sepLine = [[UIView alloc] initWithFrame:CGRectZero];
    _sepLine.backgroundColor = [UIColor separatorColor];
    [self.contentView addSubview:_sepLine];

    /* ---- 中间点击 = 展开 ---- */
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBodyTap)];
    [self.contentView addGestureRecognizer:tap];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;

    /* 左：44 宽命中区（视觉小横条居中） */
    CGFloat hbW = 44.0;
    _handleBox.frame = CGRectMake(0, 0, hbW, h);
    _bar1.frame = CGRectMake((hbW - 14) * 0.5, h * 0.5 - 3, 14, 2);
    _bar2.frame = CGRectMake((hbW - 14) * 0.5, h * 0.5 + 1, 14, 2);

    /* 右：40 宽动作区 */
    CGFloat trailW = 40.0;
    _trailBtn.frame = CGRectMake(w - trailW - 2, 0, trailW, h);

    CGFloat tx = hbW + 2;
    CGFloat tw = w - tx - trailW - 4;
    if (tw < 40) tw = 40;

    if (_expanded) {
        _titleLbl.frame = CGRectMake(tx, 8, tw, 22);
        CGFloat sh = h - 34;
        if (sh < 20) sh = 20;
        _subLbl.frame = CGRectMake(tx, 32, tw, sh);
    } else {
        _titleLbl.frame = CGRectMake(tx, h * 0.5 - 21, tw, 22);
        _subLbl.frame = CGRectMake(tx, h * 0.5 + 1, tw, 17);
    }

    _sepLine.frame = CGRectMake(tx, h - 0.5, w - tx, 0.5);
}

- (void)onTrail {
    if ([self.hub respondsToSelector:@selector(cellTrailTapped:)])
        [self.hub cellTrailTapped:self];
}

- (void)onBodyTap {
    if ([self.hub respondsToSelector:@selector(cellBodyTapped:)])
        [self.hub cellBodyTapped:self];
}

- (void)onHandlePress:(UILongPressGestureRecognizer *)g {
    if ([self.hub respondsToSelector:@selector(handlePressOnCell:gesture:)])
        [self.hub handlePressOnCell:self gesture:g];
}

@end

/* ============================================================
 * 二、主页面
 * ============================================================ */

@interface PUV2VC : UIViewController <UITableViewDataSource, UITableViewDelegate, PUHandleDelegate>
@end

@implementation PUV2VC {
    fdmpc_state _st;
    BOOL _stReady;
    BOOL _stReadOnly;

    UITableView *_tv;
    UILabel     *_preview;

    /* ★ 展开状态存 VC，不存 cell —— heightForRow 那时 cell 可能还没创建 */
    NSMutableSet<NSString *> *_expandedKeys;

    /* 拖拽 */
    UIView      *_dragGhost;
    NSIndexPath *_dragFrom;
    BOOL         _dragging;
    NSInteger    _dragToSec, _dragToRow;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"系统提示词 v2";

    /* ★ v72 修 UI 偏移：不加这行，self.view 从导航栏下面开始（含导航栏高度），
     *   而子视图按 view 的 0 点排 ⇒ 预览条压在导航栏标题上。 */
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.extendedLayoutIncludesOpaqueBars = NO;

    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    _expandedKeys = [NSMutableSet set];

    [self loadState];
    [self buildUI];
    [self composeAndApply];

    /* ★ v73 按主人要求调整顶栏：
     *     左 = 返回（自己做一个，因为我们设了 leftBarButtonItem，
     *               系统的返回按钮就被顶掉了）
     *     右 = 重置（原来的位置是"新建"）
     *   "新建"移到每个分组的表头右侧 —— 哪儿都能新建，比藏在导航栏更直接。 */
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"返回"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onBack)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"重置"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onReset)];
}

- (void)onBack {
    if (self.navigationController &&
        self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else if (self.navigationController) {
        [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_tv reloadData];
}

- (void)dealloc {
    if (_stReady) fdmpc_free(&_st);
}

/* ---------------- 存档 ---------------- */

- (void)loadState {
    fdmpc_init(&_st);
    _stReady = YES;

    {
        char err[512] = {0};
        int bad = fdmpc_selftest(err, sizeof(err));
        if (bad) {
            FLOGE(FC_CFG, @"[spv2] ✗ 内核自检失败 #%d：%s ⇒ 只读", bad, err);
            _stReadOnly = YES;
        } else {
            FLOGI(FC_CFG, @"[spv2] 内核自检 47 条全过");
        }
    }

    NSString *p = PUPath();
    NSData *d = p ? [NSData dataWithContentsOfFile:p] : nil;
    if (!d.length) {
        FLOGI(FC_CFG, @"[spv2] 没有存档，用默认卡片池");
        return;
    }

    NSString *js = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!js.length) { FLOGW(FC_CFG, @"[spv2] 存档不是合法 UTF-8，丢弃"); return; }

    /* ★★ 2026-10-25 v73 修：**别再靠字符串猜存档好不好**
     *
     * v72 的检测是 `[js containsString:@"\"\""]` —— 想抓 v70 那个 sprintf bug
     * 留下的 `""music`。但**正常的存档里也有 `""`**：
     *     内置三张卡的正文本来就是空的 → `"tx":""`
     * ⇒ 每次读到「有内置卡且正文为空」的存档，就被判"可疑"⇒ 丢弃 ⇒ **UI 重置**。
     *   这就是主人说的「重进页面卡片 UI 界面重置」。
     *
     * 正确做法：**不猜字符串，直接看解析结果**。
     *   fdmpc_from_json 内部已经有归一化（孤儿 key 补卡、未知类型丢掉、
     *   同 key 去重、内置三张必须存在）。解析成功就信它；
     *   只有"解析失败"或"归一化之后 box/drawer 里还有非法 key"才判坏。 */
    BOOL suspicious = NO;
    int rc = fdmpc_from_json(&_st, js.UTF8String);
    if (rc != 0) {
        suspicious = YES;
    } else {
        /* 归一化之后仍然有「key 少于 2 字符」的，只能是真的脏了 */
        for (size_t i = 0; i < _st.box_n; i++)
            if (!_st.box[i] || strlen(_st.box[i]) < 2) suspicious = YES;
        for (size_t i = 0; i < _st.drawer_n; i++)
            if (!_st.drawer[i] || strlen(_st.drawer[i]) < 2) suspicious = YES;
        if (_st.count < 4) suspicious = YES;    /* 内置三张+源卡都没了 ⇒ 真坏 */
    }

    FLOGI(FC_CFG, @"[spv2] 读存档 rc=%d（%zu 卡 / 容器 %zu / 抽屉 %zu）%s",
          rc, _st.count, _st.box_n, _st.drawer_n,
          suspicious ? " ⇒ 判定为坏档" : "");

    if (suspicious) {
        FLOGW(FC_CFG, @"[spv2] ⚠️ 存档确实坏了 ⇒ 回默认池（原文件备份成 .bad）");
        @try { [d writeToFile:[p stringByAppendingString:@".bad"] atomically:YES]; }
        @catch (NSException *e) { }
        fdmpc_free(&_st);
        fdmpc_init(&_st);
        [self saveState];
    }
}

- (void)saveState {
    @try {
        char *js = fdmpc_to_json(&_st);
        if (!js) return;
        NSString *s = [NSString stringWithUTF8String:js];
        free(js);
        if (s.length)
            [s writeToFile:PUPath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {
        FLOGE(FC_CFG, @"[spv2] 存档写失败：%@", e.reason);
    }
}

- (void)composeAndApply {
    char *js = fdmpc_compose(&_st);
    NSString *out = js ? [NSString stringWithUTF8String:js] : @"";
    free(js);
    if (!out) out = @"";

    [[FDMConfig shared] setValue:out for:@"sysprompt" key:@"text"];
    FLOGI(FC_CFG, @"[spv2] 重算提示词：%lu 字（容器 %zu 张）",
          (unsigned long)out.length, _st.box_n);

    NSString *one = [out stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (one.length > 110) one = [[one substringToIndex:110] stringByAppendingString:@"…"];
    _preview.text = out.length
        ? [NSString stringWithFormat:@"现在拼出 %@：\n%@", PUCount(out),
           one.length ? one : @"（全是空段）"]
        : @"（容器是空的 ⇒ 提示词会被清空）";
}

/* ---------------- 界面 ---------------- */

- (void)buildUI {
    _tv = [[UITableView alloc] initWithFrame:self.view.bounds
                                      style:UITableViewStyleGrouped];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.dataSource = self;
    _tv.delegate = self;
    _tv.backgroundColor = [UIColor systemGroupedBackgroundColor];
    _tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tv.contentInset = UIEdgeInsetsMake(0, 0, 60, 0);
    [_tv registerClass:[PUCell class] forCellReuseIdentifier:@"c"];
    [self.view addSubview:_tv];

    /* ★ 预览条做 tableHeaderView —— 跟着列表滚，永远不会压到导航栏上 */
    UIView *hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
                                                           self.view.bounds.size.width, 74)];
    _preview = [[UILabel alloc] initWithFrame:CGRectMake(16, 8,
                                                         hdr.bounds.size.width - 32, 58)];
    _preview.numberOfLines = 3;
    _preview.font = [UIFont systemFontOfSize:11];
    _preview.textColor = [UIColor secondaryLabelColor];
    _preview.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    _preview.layer.cornerRadius = 10;
    _preview.layer.cornerCurve = kCACornerCurveContinuous;
    _preview.clipsToBounds = YES;
    _preview.text = @"（还没算）";
    [hdr addSubview:_preview];
    _tv.tableHeaderView = hdr;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    return (sec == 0) ? (NSInteger)_st.box_n : (NSInteger)_st.drawer_n;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)sec {
    if (sec == 0)
        return [NSString stringWithFormat:@"容器（进提示词）· %zu 张　—　按住左边 ≡ 拖动",
                _st.box_n];
    return [NSString stringWithFormat:@"抽屉（不生效）· %zu 张", _st.drawer_n];
}

/** ★ v73：新建按钮放到表头右边（导航栏右位给了"重置"）。 */
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)sec {
    CGFloat w = tv.bounds.size.width;
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 40)];

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, 10, w - 100, 20)];
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = [UIColor secondaryLabelColor];
    l.text = [self tableView:tv titleForHeaderInSection:sec];
    [h addSubview:l];

    /* 只在「容器」那个分组上放「＋ 新建」 */
    if (sec == 0) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(w - 74, 4, 62, 32);
        [b setTitle:@"＋ 新建" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13];
        [b setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        [b addTarget:self action:@selector(onAdd) forControlEvents:UIControlEventTouchUpInside];
        [h addSubview:b];
    }
    return h;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)sec {
    return 40;
}

- (const char *)keyAt:(NSInteger)sec row:(NSInteger)row {
    if (sec == 0) {
        if (row < 0 || (size_t)row >= _st.box_n) return NULL;
        return _st.box[row];
    }
    if (row < 0 || (size_t)row >= _st.drawer_n) return NULL;
    return _st.drawer[row];
}

/** ★ v72：行高查 VC 的 _expandedKeys（不看 cell）。 */
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    const char *key = [self keyAt:ip.section row:ip.item];
    if (!key) return 62.0;
    NSString *ks = [NSString stringWithUTF8String:key];
    return [_expandedKeys containsObject:ks] ? 168.0 : 62.0;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    PUCell *c = [tv dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    c.hub = self;

    const char *key = [self keyAt:ip.section row:ip.item];
    const fdmpc_card *card = key ? fdmpc_get_c(&_st, key) : NULL;
    if (!card) { c.titleLbl.text = @"?"; c.subLbl.text = @""; return c; }

    NSString *ks = [NSString stringWithUTF8String:key];
    c.expanded = [_expandedKeys containsObject:ks];

    c.contentView.backgroundColor = [ks isEqualToString:@FDMPC_K_SRC]
        ? [UIColor tertiarySystemGroupedBackgroundColor]
        : [UIColor secondarySystemGroupedBackgroundColor];

    /* ---- 标题：内置/源卡由类型决定，自定义读存档 ---- */
    if (fdmpc_is_builtin_type(card->type) ||
        strcmp(card->type ?: "", FDMPC_T_TEXTSRC) == 0) {
        c.titleLbl.text = PUTypeTitle(card->type);
    } else {
        c.titleLbl.text = PUSafe(@"title", card->title);
        if (!c.titleLbl.text.length) c.titleLbl.text = @"(无标题)";
    }

    /* ---- 副标题 ---- */
    const char *sp = fdmpc_builtin_spec(card->type);
    if (sp) {
        NSString *spt = PUSafe(@"spec", sp);
        if (c.expanded) {
            c.subLbl.text = [NSString stringWithFormat:@"自带约定 · %@\n\n%@",
                             PUCount(spt), spt];
            c.subLbl.numberOfLines = 0;
        } else {
            NSString *one = [spt stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            if (one.length > 30) one = [[one substringToIndex:30] stringByAppendingString:@"…"];
            c.subLbl.text = [NSString stringWithFormat:@"自带约定 · %@　%@", PUCount(spt), one];
            c.subLbl.numberOfLines = 1;
        }
    } else if (strcmp(card->type ?: "", FDMPC_T_TEXTSRC) == 0) {
        c.subLbl.text = c.expanded
            ? @"这是一张模板卡。\n拖进容器（或点右边 ＋）= 复制出一张新的自定义卡，\n"
              @"源卡本身留在抽屉里，可以无限复制。"
            : @"拖进容器 = 复制一张新的";
        c.subLbl.numberOfLines = c.expanded ? 0 : 1;
    } else {
        NSString *body = PUSafe(@"text", card->text);
        if (c.expanded) {
            /* ★ v72：完整正文 + 状态（修"看不到内容"） */
            c.subLbl.text = [NSString stringWithFormat:@"%@　·　本条 %@\n\n%@",
                             card->withTitle ? @"✓ 标题也会进提示词"
                                             : @"✗ 只有正文进提示词",
                             PUCount(body),
                             body.length ? body : @"(正文是空的，点右边 ▸ 去编辑)"];
            c.subLbl.numberOfLines = 0;
        } else {
            NSString *one = [body stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            if (one.length > 26) one = [[one substringToIndex:26] stringByAppendingString:@"…"];
            c.subLbl.text = card->withTitle
                ? [NSString stringWithFormat:@"⚠️ 标题也进 · %@", one.length ? one : @"(空)"]
                : (one.length ? one : @"(正文是空的)");
            c.subLbl.numberOfLines = 1;
        }
    }

    /* ---- 右侧 ---- */
    c.trailBtn.hidden = NO;
    if (ip.section == 0) {
        [c.trailBtn setTitle:@"▸" forState:UIControlStateNormal];
        [c.trailBtn setTitleColor:[UIColor tertiaryLabelColor] forState:UIControlStateNormal];
    } else {
        [c.trailBtn setTitle:@"＋" forState:UIControlStateNormal];
        [c.trailBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    }

    NSInteger n = [self tableView:tv numberOfRowsInSection:ip.section];
    c.sepLine.hidden = (ip.item == n - 1);

    [c setNeedsLayout];
    return c;
}

/* ---------------- 中间点击：统一展开/收起 ---------------- */

- (void)cellBodyTapped:(PUCell *)cell {
    NSIndexPath *ip = [_tv indexPathForCell:cell];
    if (!ip) return;
    const char *key = [self keyAt:ip.section row:ip.item];
    if (!key) return;

    NSString *ks = [NSString stringWithUTF8String:key];
    BOOL wasOpen = [_expandedKeys containsObject:ks];
    if (wasOpen) [_expandedKeys removeObject:ks];
    else         [_expandedKeys addObject:ks];

    FLOGD(FC_CFG, @"[spv2] 展开 %@ → %d", ks, !wasOpen);

    [_tv beginUpdates];
    [_tv endUpdates];
    [_tv reloadRowsAtIndexPaths:@[ ip ] withRowAnimation:UITableViewRowAnimationFade];
}

/* ---------------- 右侧按钮 ---------------- */

- (void)cellTrailTapped:(PUCell *)cell {
    NSIndexPath *ip = [_tv indexPathForCell:cell];
    if (!ip) return;
    const char *key = [self keyAt:ip.section row:ip.item];
    if (!key) return;

    if (ip.section == 0) {
        [self openPageForKey:[NSString stringWithUTF8String:key]];
    } else {
        if (![self guardWrite]) return;
        NSString *ks = [NSString stringWithUTF8String:key];
        int rc = fdmpc_move_in(&_st, key);
        FLOGI(FC_CFG, @"[spv2] ＋ 移入容器 %@ rc=%d（容器 %zu）", ks, rc, _st.box_n);
        [self afterChange];
    }
}

- (void)openPageForKey:(NSString *)key {
    const fdmpc_card *c = fdmpc_get_c(&_st, key.UTF8String);
    if (!c) return;
    NSString *type = PUSafe(@"type", c->type);

    if ([type isEqualToString:@FDMPC_T_TEXT]) {
        [self editCard:key];
        return;
    }

    NSString *sub = nil;
    if ([type isEqualToString:@FDMPC_T_SUGGEST])       sub = @"suggest";
    else if ([type isEqualToString:@FDMPC_T_MUSIC])    sub = @"music";
    else if ([type isEqualToString:@FDMPC_T_RICHTEXT]) sub = @"richtext";
    else if ([type isEqualToString:@FDMPC_T_TEXTSRC])  {
        [self alert:@"这是一张模板卡"
                msg:@"点右边 ＋ 或把它拖进容器 ⇒ 会长出一张新的自定义卡，\n"
                     @"源卡本身留在抽屉里，可以无限复制。"];
        return;
    }

    if (sub) {
        FDMGroup *g = [[FDMConfig shared] groupByID:sub];
        Class vcCls = NSClassFromString(@"FDMGroupVC");
        if (g && vcCls) {
            UIViewController *vc = [[vcCls alloc] init];
            @try {
                [vc setValue:g forKey:@"group"];
                [self.navigationController pushViewController:vc animated:YES];
                return;
            } @catch (NSException *e) {
                FLOGE(FC_CFG, @"[spv2] 跳页失败：%@", e.reason);
            }
        }
        [self alert:@"这个页面还没接上" msg:@"去 设置 → 聊天 / 美化 里找同名项"];
        return;
    }
    [self alert:@"未知卡片类型" msg:type];
}

/* ---------------- 编辑自定义卡 ---------------- */

- (void)editCard:(NSString *)key {
    const fdmpc_card *c = fdmpc_get_c(&_st, key.UTF8String);
    if (!c) return;
    NSString *title = PUSafe(@"title", c->title);
    NSString *text  = PUSafe(@"text", c->text);
    BOOL wt = c->withTitle != 0;

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"编辑卡片"
                         message:@"第一个框是标题（只给你自己看）\n"
                                  @"第二个框是正文（整段进系统提示词）"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = title;
        tf.placeholder = @"卡片标题（只给你自己看）";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = text;
        tf.placeholder = @"正文（会进系统提示词）";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    /* ★ v72 修误触：原来点一下**立刻保存+重开弹窗**，新建时随手一点就跑偏。
     *   现在只切「标题也进」并保存当前两个框的内容，弹窗关掉。 */
    [a addAction:[UIAlertAction actionWithTitle:(wt ? @"✗ 关掉「标题也进」"
                                                    : @"✓ 打开「标题也进」")
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        [self applyCard:key title:a.textFields[0].text text:a.textFields[1].text
              withTitle:!wt];
        FLOGI(FC_CFG, @"[spv2] 「标题也进」切成 %d 并已保存", !wt);
    }]];

    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        [self applyCard:key title:a.textFields[0].text text:a.textFields[1].text withTitle:wt];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)applyCard:(NSString *)key title:(NSString *)t text:(NSString *)tx withTitle:(BOOL)wt {
    if (![self guardWrite]) return;
    fdmpc_set_title(&_st, key.UTF8String, t.UTF8String);
    fdmpc_set_text(&_st, key.UTF8String, tx.UTF8String);
    fdmpc_set_with_title(&_st, key.UTF8String, wt);
    FLOGI(FC_CFG, @"[spv2] 卡片已更新 %@（withTitle=%d，正文 %lu 字）",
          key, wt, (unsigned long)tx.length);
    [self afterChange];
}

/* ---------------- 新建 ---------------- */

- (void)onAdd {
    if (![self guardWrite]) return;
    char *nk = fdmpc_new_text_card(&_st);
    if (!nk) { [self alert:@"建不了" msg:@"卡片太多啦（上限 200 张）"]; return; }
    NSString *key = [NSString stringWithUTF8String:nk];
    free(nk);

    /* ★★ v72 修「新建默认不进提示词」：直接搬进容器 */
    int rc = fdmpc_move_in(&_st, key.UTF8String);
    FLOGI(FC_CFG, @"[spv2] 新建 %@（自动进容器 rc=%d，容器 %zu 张）",
          key, rc, _st.box_n);

    /* ★ v77：进容器后**自动展开**，让用户一眼看到内容
     *   （主人报过"看不到里面内容"，展开是默认更好的选择） */
    [_expandedKeys addObject:key];

    /* 新建后刷新，并把最后一张可展开的卡（这张）排到容器末尾 */
    [self afterChange];

    /* 滚到它 */
    for (NSInteger r = 0; r < (NSInteger)_st.box_n; r++) {
        const char *k = [self keyAt:0 row:r];
        if (k && [key isEqualToString:[NSString stringWithUTF8String:k]]) {
            [_tv scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:r inSection:0]
                       atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
            break;
        }
    }
}

- (void)onReset {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"重置卡片？"
                         message:@"所有卡片回到出厂状态（内置三张 + 模板卡，全在抽屉里）。\n"
                                  @"你自己建的和写的会没掉。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) {
        fdmpc_free(&self->_st);
        fdmpc_init(&self->_st);
        self->_stReadOnly = NO;
        [self->_expandedKeys removeAllObjects];
        [self afterChange];
        FLOGI(FC_CFG, @"[spv2] 已重置卡片池");
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

/* ---------------- ★ 拖拽 ---------------- */

- (void)handlePressOnCell:(PUCell *)cell gesture:(UIGestureRecognizer *)g {
    if (_stReadOnly) return;
    NSIndexPath *ip = [_tv indexPathForCell:cell];

    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            if (!ip) return;
            _dragFrom = ip;
            _dragging = YES;
            _dragToSec = ip.section;
            _dragToRow = ip.item;
            _tv.scrollEnabled = NO;

            UIView *snap = [cell snapshotViewAfterScreenUpdates:NO];
            if (snap) {
                CGRect f = [cell convertRect:cell.bounds toView:self.view];
                snap.frame = f;
                snap.alpha = 0.94;
                snap.layer.shadowColor = UIColor.blackColor.CGColor;
                snap.layer.shadowOpacity = 0.30f;
                snap.layer.shadowRadius = 10;
                snap.layer.shadowOffset = CGSizeMake(0, 5);
                snap.userInteractionEnabled = NO;
                [self.view addSubview:snap];
                _dragGhost = snap;
            }
            cell.contentView.alpha = 0.2;
            FLOGI(FC_CFG, @"[spv2] 拖起 sec=%ld row=%ld",
                  (long)ip.section, (long)ip.item);
            break;
        }

        case UIGestureRecognizerStateChanged: {
            if (!_dragging || !_dragGhost) return;
            CGPoint p = [g locationInView:self.view];
            CGPoint q = [g locationInView:_tv];

            /* ★ v72：只跟 y（横向不需要动），但 y 必须真正跟手 */
            CGRect f = _dragGhost.frame;
            f.origin.y = p.y - f.size.height * 0.5;
            _dragGhost.frame = f;

            /* 边缘自动滚 */
            CGFloat m = 80.0;
            if (q.y < m) {
                CGFloat ny = MAX(-_tv.contentInset.top, _tv.contentOffset.y - 7);
                [_tv setContentOffset:CGPointMake(0, ny) animated:NO];
            } else if (q.y > _tv.bounds.size.height - m) {
                CGFloat maxY = MAX(-_tv.contentInset.top,
                                   _tv.contentSize.height - _tv.bounds.size.height
                                   + _tv.contentInset.bottom);
                CGFloat ny = MIN(maxY, _tv.contentOffset.y + 7);
                [_tv setContentOffset:CGPointMake(0, ny) animated:NO];
            }

            NSIndexPath *under = [_tv indexPathForRowAtPoint:q];
            if (under) {
                _dragToSec = under.section;
                _dragToRow = under.item;
            } else if (q.y < 0) {
                _dragToSec = 0; _dragToRow = 0;
            } else {
                _dragToSec = 1;
                _dragToRow = MAX(0, (NSInteger)_st.drawer_n - 1);
            }
            break;
        }

        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (!_dragging) return;
            _dragging = NO;
            _tv.scrollEnabled = YES;
            [_dragGhost removeFromSuperview];
            _dragGhost = nil;
            cell.contentView.alpha = 1.0;

            NSIndexPath *from = _dragFrom;
            _dragFrom = nil;
            if (from) [self performDropFrom:from toSec:_dragToSec toRow:_dragToRow];
            else      [self afterChange];
            break;
        }
        default: break;
    }
}

- (void)performDropFrom:(NSIndexPath *)from toSec:(NSInteger)toSec toRow:(NSInteger)toRow {
    if (from.section == toSec) {
        if (from.section == 0) {
            NSUInteger f = (NSUInteger)from.item;
            NSUInteger t = (NSUInteger)MIN(MAX(toRow, 0), (NSInteger)_st.box_n - 1);
            if (f != t) {
                fdmpc_box_move(&_st, f, t);
                FLOGI(FC_CFG, @"[spv2] 容器内重排 %lu → %lu",
                      (unsigned long)f, (unsigned long)t);
            }
        }
        [self afterChange];
        return;
    }

    const char *key = [self keyAt:from.section row:from.item];
    if (!key) { [self afterChange]; return; }
    NSString *ks = [NSString stringWithUTF8String:key];

    if (from.section == 1 && toSec == 0) {
        int rc = fdmpc_move_in(&_st, key);
        FLOGI(FC_CFG, @"[spv2] 拖进容器 %@ rc=%d（容器 %zu）", ks, rc, _st.box_n);
    } else if (from.section == 0 && toSec == 1) {
        int rc = fdmpc_move_out(&_st, key);
        FLOGI(FC_CFG, @"[spv2] 拖回抽屉 %@ rc=%d（抽屉 %zu）", ks, rc, _st.drawer_n);
    }
    [self afterChange];
}

/* ---------------- 公共 ---------------- */

- (void)afterChange {
    [self saveState];
    [self composeAndApply];
    [_tv reloadData];
}

- (BOOL)guardWrite {
    if (_stReadOnly) {
        [self alert:@"页面是只读的"
                msg:@"内核自检没过（详见日志 spv2），\n"
                     @"为了不让你的提示词被写坏，这里禁止修改。\n把日志发给尼尼。"];
        return NO;
    }
    return YES;
}

- (void)alert:(NSString *)t msg:(NSString *)m {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:m
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

/* ============================================================
 * 三、对外
 * ============================================================ */

UIViewController *FDMPromptV2ViewController(void) {
    return [[PUV2VC alloc] init];
}
