// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMLyricIOS —— FDMLyric.c 的 ObjC 包装（管内存 + 给 {lyric} 三个变量供数）
#import <Foundation/Foundation.h>

#include "FDMLyric.h"
#import "FLog.h"

@interface FDMLyricDoc : NSObject {
    fdmlrc _doc;
}
@property (nonatomic, readonly) NSUInteger lineCount;

- (instancetype)initWithLRC:(NSString *)lrc;

/** 取 pos 毫秒时的三句（永远非 nil，取不到就是空串）。 */
- (void)aroundMs:(long long)pos
             cur:(NSString **)cur
            prev:(NSString **)prev
            next:(NSString **)next;
@end

@implementation FDMLyricDoc

- (instancetype)initWithLRC:(NSString *)lrc {
    self = [super init];
    if (self) {
        _doc.lines = NULL;
        _doc.count = 0;
        if (lrc.length) {
            fdmlrc_parse(lrc.UTF8String, &_doc);
        }
    }
    return self;
}

- (void)dealloc {
    fdmlrc_free(&_doc);
}

- (NSUInteger)lineCount { return _doc.count; }

- (void)aroundMs:(long long)pos
             cur:(NSString **)cur
            prev:(NSString **)prev
            next:(NSString **)next {
    const char *c = "", *p = "", *x = "";
    fdmlrc_around(&_doc, pos, &c, &p, &x);
    if (cur)  *cur  = [NSString stringWithUTF8String:c ?: ""] ?: @"";
    if (prev) *prev = [NSString stringWithUTF8String:p ?: ""] ?: @"";
    if (next) *next = [NSString stringWithUTF8String:x ?: ""] ?: @"";
}

@end

/** 在 FDMProbe 的 6s 定时器里调用。 */
void FDMLyricInstall(void) {
    char err[512] = {0};
    int bad = fdmlrc_selftest(err, sizeof(err));
    if (bad) {
        FLOGE(FC_MUSIC, @"[lyric] LRC 解析自检失败 #%d\n%s", bad, err);
        return;
    }
    FLOGI(FC_MUSIC, @"[lyric] LRC 引擎 ✓（15 组断言：多标签/小数位/前奏/元数据忽略）");
}
