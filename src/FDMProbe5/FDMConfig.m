/* ============================================================
 * FDMConfig —— 实现
 * ============================================================ */

#import "FDMConfig.h"
#import "FLog.h"

/* ==================== FDMField ==================== */

@implementation FDMField
+ (instancetype)k:(NSString *)key t:(NSString *)title type:(FDMFieldType)type
              def:(id)def hint:(NSString *)hint {
    return [self k:key t:title type:type def:def hint:hint options:nil];
}
+ (instancetype)k:(NSString *)key t:(NSString *)title type:(FDMFieldType)type
              def:(id)def hint:(NSString *)hint options:(NSArray *)options {
    FDMField *f = [FDMField new];
    f.key = key; f.title = title; f.type = type; f.def = def;
    f.hint = hint; f.options = options; f.minV = 0; f.maxV = 0;
    return f;
}
@end

/* ==================== FDMGroup ==================== */

@implementation FDMGroup
+ (instancetype)gid:(NSString *)gid title:(NSString *)title parent:(NSString *)parent
              order:(NSInteger)order icon:(NSString *)icon
               file:(NSString *)file note:(NSString *)note
             fields:(NSArray<FDMField *> *)fields {
    FDMGroup *g = [FDMGroup new];
    g.gid = gid; g.title = title; g.parent = parent;
    g.order = order; g.icon = icon;
    g.file = file; g.note = note; g.fields = fields;
    g.hasEnable = NO;                 /* 页面默认不是"开关组" */
    return g;
}
@end

/* ==================== FDMConfig ==================== */

@interface FDMConfig ()
@property (nonatomic, strong) NSMutableArray<FDMGroup *> *groups;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *cache;
@property (nonatomic, strong) NSMutableArray *observers;                     /* [owner, blk] */
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *mods; /* gid -> [key] */
@property (nonatomic, strong) NSLock *lock;
@end

@implementation FDMConfig

+ (instancetype)shared {
    static FDMConfig *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [FDMConfig new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _groups = [NSMutableArray array];
        _cache = [NSMutableDictionary dictionary];
        _observers = [NSMutableArray array];
        _mods = [NSMutableDictionary dictionary];
        _lock = [NSLock new];
    }
    return self;
}

static NSString *FDMDocDir(void) {
    static NSString *d = nil;
    if (!d) {
        NSArray *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
        d = [a firstObject] ?: NSTemporaryDirectory();
    }
    return d;
}

- (NSString *)pathFor:(NSString *)gid {
    FDMGroup *g = [self groupByID:gid];
    NSString *f = g.file ?: [gid stringByAppendingString:@".json"];
    return [FDMDocDir() stringByAppendingPathComponent:f];
}

- (void)registerGroup:(FDMGroup *)g {
    if (!g.gid) return;
    [self.lock lock];
    for (FDMGroup *e in self.groups) {
        if ([e.gid isEqualToString:g.gid]) { [self.lock unlock]; return; }
    }
    [self.groups addObject:g];
    [self.lock unlock];

    [self loadGroup:g];
    FLOGI(FC_CFG, @"注册分组 %@（%@，%lu 字段）",
          g.gid, g.title, (unsigned long)g.fields.count);
}

- (FDMGroup *)groupByID:(NSString *)gid {
    for (FDMGroup *g in self.groups)
        if ([g.gid isEqualToString:gid]) return g;
    return nil;
}

- (NSArray<FDMGroup *> *)allGroups {
    [self.lock lock];
    NSArray *a = [self.groups copy];
    [self.lock unlock];
    return a;
}

/* ★ 树：取某个页面的子页（parentGid=nil → 首页）。按 order 排序 */
- (NSArray<FDMGroup *> *)childGroupsOf:(NSString *)parentGid {
    NSMutableArray *out = [NSMutableArray array];
    for (FDMGroup *g in [self allGroups]) {
        BOOL isRoot = (g.parent == nil || g.parent.length == 0);
        if (parentGid == nil || parentGid.length == 0) {
            if (isRoot) [out addObject:g];
        } else if ([g.parent isEqualToString:parentGid]) {
            [out addObject:g];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(FDMGroup *a, FDMGroup *b) {
        return a.order < b.order ? NSOrderedAscending
             : (a.order > b.order ? NSOrderedDescending : NSOrderedSame);
    }];
    return out;
}

/* ---- 从磁盘加载（填默认值 + 读已修改列表） ---- */
- (void)loadGroup:(FDMGroup *)g {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSMutableArray *mods = [NSMutableArray array];

    NSData *raw = [NSData dataWithContentsOfFile:[self pathFor:g.gid]];
    if (raw) {
        id j = [NSJSONSerialization JSONObjectWithData:raw
                                              options:NSJSONReadingMutableContainers error:nil];
        if ([j isKindOfClass:[NSDictionary class]]) {
            NSDictionary *src = j;
            for (NSString *k in src) {
                if ([k isEqualToString:@"__mod"]) {          /* 已修改键列表 */
                    id arr = src[k];
                    if ([arr isKindOfClass:[NSArray class]]) mods = [arr mutableCopy];
                    continue;
                }
                d[k] = src[k];
            }
        } else {
            FLOGW(FC_CFG, @"%@ 解析失败，用默认值", g.file);
        }
    }

    /* 填默认值 */
    for (FDMField *f in g.fields)
        if (!d[f.key] && f.def) d[f.key] = f.def;
    if (g.hasEnable && !d[@"enabled"]) d[@"enabled"] = @YES;

    [self.lock lock];
    self.cache[g.gid] = d;
    self.mods[g.gid] = mods;
    [self.lock unlock];

    FLOGD(FC_CFG, @"  %@ 加载完成：%lu 项，其中 %lu 项用户改过",
          g.gid, (unsigned long)d.count, (unsigned long)mods.count);
}

- (void)reloadAll {
    for (FDMGroup *g in [self allGroups]) [self loadGroup:g];
    FLOGI(FC_CFG, @"已从磁盘重载全部配置");
}

/* ---- 读 ---- */
- (NSMutableDictionary *)dictFor:(NSString *)gid {
    [self.lock lock];
    NSMutableDictionary *d = self.cache[gid];
    [self.lock unlock];
    return d;
}

- (id)valueFor:(NSString *)gid key:(NSString *)key {
    id v = [self dictFor:gid][key];
    if (v) return v;
    FDMGroup *g = [self groupByID:gid];
    for (FDMField *f in g.fields) if ([f.key isEqualToString:key]) return f.def;
    return nil;
}
- (BOOL)boolFor:(NSString *)gid key:(NSString *)key {
    id v = [self valueFor:gid key:key];
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
}
- (NSInteger)intFor:(NSString *)gid key:(NSString *)key {
    id v = [self valueFor:gid key:key];
    return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0;
}
- (NSString *)stringFor:(NSString *)gid key:(NSString *)key {
    id v = [self valueFor:gid key:key];
    return [v isKindOfClass:[NSString class]] ? v : (v ? [v description] : @"");
}
- (BOOL)enabledFor:(NSString *)gid {
    id v = [self dictFor:gid][@"enabled"];
    return v ? [v boolValue] : YES;
}

/* ---- 写 ---- */
- (void)setValue:(id)v for:(NSString *)gid key:(NSString *)key {
    if (!v) return;
    [self.lock lock];
    NSMutableDictionary *d = self.cache[gid];
    if (!d) { d = [NSMutableDictionary dictionary]; self.cache[gid] = d; }
    d[key] = v;

    /* ★ 记录"用户改过" —— 只有改过的才会进覆盖表 */
    NSMutableArray *mk = self.mods[gid];
    if (!mk) { mk = [NSMutableArray array]; self.mods[gid] = mk; }
    if (![mk containsObject:key]) [mk addObject:key];
    [self.lock unlock];

    [self save:gid];
    FLOGI(FC_CFG, @"✎ %@.%@ = %@（标记已修改）", gid, key, v);
}

/* ★ 2026-10-25 内部回写：写值但**不**记「用户已修改」
 *   场景：ui_auto_shot 只跑一轮，跑完要把它关回去。
 *   用 setValue: 关回去会让它在 UI 上挂个 ⭐、首页显示「已改 1 项」——
 *   但用户其实什么都没改。这个版本连 __mod 里的记录一起摘掉。 */
- (void)setValueQuietly:(id)v for:(NSString *)gid key:(NSString *)key {
    if (!v) return;
    [self.lock lock];
    NSMutableDictionary *d = self.cache[gid];
    if (!d) { d = [NSMutableDictionary dictionary]; self.cache[gid] = d; }
    d[key] = v;
    NSMutableArray *mk = self.mods[gid];
    if (mk) [mk removeObject:key];          /* 从「已修改」里摘掉 */
    [self.lock unlock];

    [self save:gid];
    FLOGI(FC_CFG, @"%@.%@ → %@（内部回写，不记已修改）", gid, key, v);
}

- (void)setEnabled:(BOOL)on for:(NSString *)gid {
    [self.lock lock];
    NSMutableDictionary *d = self.cache[gid];
    if (!d) { d = [NSMutableDictionary dictionary]; self.cache[gid] = d; }
    d[@"enabled"] = @(on);
    [self.lock unlock];
    [self save:gid];
    FLOGI(FC_CFG, @"%@ 总开关 → %@", gid, on ? @"开" : @"关");
}

- (void)replace:(NSString *)gid with:(NSDictionary *)src {
    [self.lock lock];
    NSMutableDictionary *d = [src mutableCopy] ?: [NSMutableDictionary dictionary];
    self.cache[gid] = d;
    [self.lock unlock];
    [self save:gid];
}

- (void)save:(NSString *)gid {
    NSMutableDictionary *d = [self dictFor:gid];
    if (!d) return;

    /* 把已修改列表一并写入 __mod */
    NSMutableDictionary *out = [d mutableCopy];
    NSArray *mk = [self modifiedKeysFor:gid];
    if (mk.count) out[@"__mod"] = mk;

    @try {
        NSData *data = [NSJSONSerialization dataWithJSONObject:out
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:nil];
        if (data) [data writeToFile:[self pathFor:gid] atomically:YES];
    } @catch (NSException *e) {
        FLOGE(FC_CFG, @"%@ 保存失败: %@", gid, e.reason);
    }
    [self notify:gid];
}

/* ---- 已修改追踪 ---- */

- (BOOL)isModified:(NSString *)gid key:(NSString *)key {
    [self.lock lock];
    NSMutableArray *mk = self.mods[gid];
    BOOL r = mk && [mk containsObject:key];
    [self.lock unlock];
    return r;
}

- (NSArray<NSString *> *)modifiedKeysFor:(NSString *)gid {
    [self.lock lock];
    NSArray *r = [self.mods[gid] copy] ?: @[];
    [self.lock unlock];
    return r;
}

- (void)clearModified:(NSString *)gid key:(NSString *)key {
    FDMGroup *g = [self groupByID:gid];
    [self.lock lock];
    NSMutableArray *mk = self.mods[gid];
    if (mk) {
        [mk removeObject:key];
        NSMutableDictionary *d = self.cache[gid];
        for (FDMField *f in g.fields) {
            if (![f.key isEqualToString:key]) continue;
            if (f.def) d[key] = f.def; else [d removeObjectForKey:key];
            break;
        }
    }
    [self.lock unlock];
    [self save:gid];
    FLOGI(FC_CFG, @"%@.%@ 已恢复默认", gid, key);
}

- (void)clearAllModified:(NSString *)gid {
    FDMGroup *g = [self groupByID:gid];
    [self.lock lock];
    [self.mods removeObjectForKey:gid];
    NSMutableDictionary *d = self.cache[gid];
    for (FDMField *f in g.fields) {
        if (f.def) d[f.key] = f.def; else [d removeObjectForKey:f.key];
    }
    [self.lock unlock];
    [self save:gid];
    FLOGI(FC_CFG, @"%@ 全部恢复默认", gid);
}

/* ---- 变更通知（热生效） ---- */
- (void)addObserver:(id)owner block:(FDMConfigObserver)blk {
    if (!owner || !blk) return;
    [self.lock lock];
    [self.observers addObject:@[ owner, [blk copy] ]];
    [self.lock unlock];
}
- (void)removeObserver:(id)owner {
    [self.lock lock];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSArray *p in self.observers) if (p[0] != owner) [keep addObject:p];
    self.observers = keep;
    [self.lock unlock];
}
- (void)notify:(NSString *)gid {
    NSArray *snap;
    [self.lock lock];
    snap = [self.observers copy];
    [self.lock unlock];
    for (NSArray *p in snap) {
        FDMConfigObserver b = p[1];
        @try { b(gid); } @catch (NSException *e) {
            FLOGE(FC_CFG, @"observer 异常: %@", e.reason);
        }
    }
}
@end
