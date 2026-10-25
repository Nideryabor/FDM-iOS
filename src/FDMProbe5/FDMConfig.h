/* ============================================================
 * FDMConfig —— 统一配置 + 功能注册表（树形结构）
 *
 * 排版参考安卓 LSP 模块的 Tree.kt：
 *   FDMGroup = 一个「页面」（有 parent 就挂在别的页面下）
 *   FDMField = 页面里的一行（开关/数字/文本/枚举/子页/动作/信息）
 *
 * 加功能 = 在 FDMFeatures.m 加一段声明，UI/存储/热生效全自动。
 * ============================================================ */
#ifndef FDMCONFIG_H
#define FDMCONFIG_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, FDMFieldType) {
    FDMFieldTypeBool = 0,
    FDMFieldTypeInt,
    FDMFieldTypeString,
    FDMFieldTypeEnum,
    FDMFieldTypeSub,       /* 子页（跳到另一个 FDMGroup） */
    FDMFieldTypeAction,    /* 动作（打开日志 / 清空 / 等） */
    FDMFieldTypeInfo,      /* 只读信息 */
};

/* ---------------- 单个配置项 ---------------- */
@interface FDMField : NSObject
@property (nonatomic, copy)   NSString *key;
@property (nonatomic, copy)   NSString *title;
@property (nonatomic)         FDMFieldType type;
@property (nonatomic, strong) id def;
@property (nonatomic, copy)   NSString *hint;
@property (nonatomic, strong) NSArray *options;
@property (nonatomic, copy)   NSString *unit;
@property (nonatomic)         NSInteger minV, maxV;
@property (nonatomic, copy)   NSString *sub;       /* Sub: 目标 page id */
@property (nonatomic, copy)   NSString *action;    /* Action: 动作 id */
@property (nonatomic, copy)   NSString *icon;      /* emoji */

+ (instancetype)k:(NSString *)key t:(NSString *)title
             type:(FDMFieldType)type def:(id)def hint:(NSString *)hint;
+ (instancetype)k:(NSString *)key t:(NSString *)title
             type:(FDMFieldType)type def:(id)def hint:(NSString *)hint
        options:(NSArray *)options;
@end

/* ---------------- 一个页面 ---------------- */
@interface FDMGroup : NSObject
@property (nonatomic, copy)   NSString *gid;
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, copy)   NSString *parent;    /* nil = 首页 */
@property (nonatomic)         NSInteger order;
@property (nonatomic, copy)   NSString *icon;      /* emoji */
@property (nonatomic, copy)   NSString *file;      /* Documents/<file> */
@property (nonatomic, copy)   NSString *note;
@property (nonatomic, strong) NSArray<FDMField *> *fields;
@property (nonatomic)         BOOL hasEnable;

+ (instancetype)gid:(NSString *)gid title:(NSString *)title parent:(NSString *)parent
              order:(NSInteger)order icon:(NSString *)icon
               file:(NSString *)file note:(NSString *)note
             fields:(NSArray<FDMField *> *)fields;
@end

/* ---------------- 配置管理器 ---------------- */
@interface FDMConfig : NSObject

+ (instancetype)shared;

- (void)registerGroup:(FDMGroup *)g;

/* 读 */
- (id)valueFor:(NSString *)gid key:(NSString *)key;
- (BOOL)boolFor:(NSString *)gid key:(NSString *)key;
- (NSInteger)intFor:(NSString *)gid key:(NSString *)key;
- (NSString *)stringFor:(NSString *)gid key:(NSString *)key;
- (BOOL)enabledFor:(NSString *)gid;

/* 写（自动标记「已修改」） */
- (void)setValue:(id)v for:(NSString *)gid key:(NSString *)key;
/* ★ 写值但不记「用户已修改」（内部自动回写用，如 ui_auto_shot 自动关回） */
- (void)setValueQuietly:(id)v for:(NSString *)gid key:(NSString *)key;
- (void)setEnabled:(BOOL)on for:(NSString *)gid;

/* 整组 */
- (NSMutableDictionary *)dictFor:(NSString *)gid;
- (void)replace:(NSString *)gid with:(NSDictionary *)d;

/* 树 */
- (NSArray<FDMGroup *> *)childGroupsOf:(NSString *)parentGid;   /* parentGid=nil → 首页 */
- (NSArray<FDMGroup *> *)allGroups;
- (FDMGroup *)groupByID:(NSString *)gid;
- (NSString *)pathFor:(NSString *)gid;

/* 已修改追踪 */
- (BOOL)isModified:(NSString *)gid key:(NSString *)key;
- (NSArray<NSString *> *)modifiedKeysFor:(NSString *)gid;
- (void)clearModified:(NSString *)gid key:(NSString *)key;
- (void)clearAllModified:(NSString *)gid;

/* 变更通知 */
typedef void (^FDMConfigObserver)(NSString *gid);
- (void)addObserver:(id)owner block:(FDMConfigObserver)blk;
- (void)removeObserver:(id)owner;
- (void)reloadAll;
@end

#endif /* FDMCONFIG_H */
