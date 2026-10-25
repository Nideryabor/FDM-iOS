// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMPromptVarsIOS —— FDMPromptVars.c 的 NSString 薄封装 + 启动自检
//
// 这里刻意只做「转换」，不做任何业务判断 —— 规则全在纯 C 里，
// 因为那份能在小窝 Linux 上跑 20 条断言。
#import <Foundation/Foundation.h>

#include "FDMPromptVars.h"
#import "FLog.h"

/* ── 开关：hook 内**绝不读文件**。
 *    这里用 5 秒 TTL 的内存缓存兜底（发消息是低频动作，最多 5 秒一次 stat/read），
 *    另外提供 FDMPromptVarsReload() 给设置页在改完开关后立刻刷新。 */
extern id FDMProbeReadDebugBool(NSString *k, BOOL def);

static BOOL gPvOn = NO;
static BOOL gPvLyricOn = NO;
static CFAbsoluteTime gPvAt = 0;

static void pv_reload_if_stale(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gPvAt > 0 && now - gPvAt < 5.0) return;
    gPvAt = now;
    @try {
        gPvOn = [FDMProbeReadDebugBool(@"pvar_on", NO) boolValue];
        gPvLyricOn = [FDMProbeReadDebugBool(@"pvar_lyric", NO) boolValue];
    } @catch (NSException *e) {
        gPvOn = NO;
        gPvLyricOn = NO;
    }
}

void FDMPromptVarsReload(void) {
    gPvAt = 0;
    pv_reload_if_stale();
}

BOOL FDMPromptVarsOn(void) {
    pv_reload_if_stale();
    return gPvOn;
}

BOOL FDMPromptVarsLyricOn(void) {
    pv_reload_if_stale();
    return gPvLyricOn;
}

/* ── 播放状态来源：现在还没有播放器 ⇒ 默认返回 nil。
 *    播放器做好之后只要调 FDMPromptVarsSetProvider 注册一个 block，
 *    变量引擎立刻就能拿到真实数据（歌曲 / 进度 / 歌词三句）。 */
static NSDictionary *(^gPvProvider)(void) = nil;

void FDMPromptVarsSetProvider(NSDictionary *(^provider)(void)) {
    gPvProvider = [provider copy];
}

NSString *FDMPromptVarsResolve(NSString *text, const fdmpv_snap *snap) {
    if (!text) return nil;
    if (!text.length) return text;
    char *r = fdmpv_resolve(text.UTF8String, snap);
    if (!r) return text;                 /* 引擎失败 ⇒ 原样放行（宁可没替换） */
    NSString *out = [NSString stringWithUTF8String:r];
    free(r);
    return out ?: text;
}

BOOL FDMPromptVarsHasAny(NSString *text) {
    return text.length && fdmpv_has_any(text.UTF8String);
}

/** 把 NSDictionary 形状的播放状态变成 C 快照。
 *  键：enabled / song / artist / album / pos / dur / playing / lyric_on / lyric / lyric_prev / lyric_next
 *  值全部会在调用期间保持存活（函数内 @autoreleasepool 里用）。
 */
NSString *FDMPromptVarsResolveWithDict(NSString *text, NSDictionary *st) {
    if (!text) return nil;

    NSString *song    = [st[@"song"] isKindOfClass:[NSString class]] ? st[@"song"] : @"";
    NSString *artist  = [st[@"artist"] isKindOfClass:[NSString class]] ? st[@"artist"] : @"";
    NSString *album   = [st[@"album"] isKindOfClass:[NSString class]] ? st[@"album"] : @"";
    NSString *lrc     = [st[@"lyric"] isKindOfClass:[NSString class]] ? st[@"lyric"] : @"";
    NSString *lrcPrev = [st[@"lyric_prev"] isKindOfClass:[NSString class]] ? st[@"lyric_prev"] : @"";
    NSString *lrcNext = [st[@"lyric_next"] isKindOfClass:[NSString class]] ? st[@"lyric_next"] : @"";

    fdmpv_snap sn;
    memset(&sn, 0, sizeof(sn));
    sn.enabled    = [st[@"enabled"] respondsToSelector:@selector(boolValue)] ? [st[@"enabled"] boolValue] : 0;
    sn.song       = song.UTF8String;
    sn.artist     = artist.UTF8String;
    sn.album      = album.UTF8String;
    sn.pos_ms     = [st[@"pos"] respondsToSelector:@selector(longLongValue)] ? [st[@"pos"] longLongValue] : 0;
    sn.dur_ms     = [st[@"dur"] respondsToSelector:@selector(longLongValue)] ? [st[@"dur"] longLongValue] : 0;
    sn.playing    = [st[@"playing"] respondsToSelector:@selector(boolValue)] ? [st[@"playing"] boolValue] : 0;
    sn.lyric_on   = [st[@"lyric_on"] respondsToSelector:@selector(boolValue)] ? [st[@"lyric_on"] boolValue] : 0;
    sn.lyric      = lrc.UTF8String;
    sn.lyric_prev = lrcPrev.UTF8String;
    sn.lyric_next = lrcNext.UTF8String;

    return FDMPromptVarsResolve(text, &sn);
}

/**
 * ★ 发消息那一刻的入口：把系统提示词里的音乐变量替换成真值。
 *
 * 三种情况直接原样返回（**绝不改动用户文本**）：
 *   ① 总开关关着      ⇒ 功能不存在 ⇒ 连 `[[ ]]` 也不碰
 *   ② 文本里没有变量也没有 `[[` ⇒ 没什么可做
 *   ③ 引擎出错        ⇒ 宁可没替换，也不能让消息发不出去
 */
NSString *FDMPromptVarsApply(NSString *text) {
    if (!text.length) return text;
    @try {
        if (!FDMPromptVarsOn()) return text;
        if (!FDMPromptVarsHasAny(text) && ![text containsString:@"[["]) return text;

        NSMutableDictionary *st = [NSMutableDictionary dictionary];
        NSDictionary *src = gPvProvider ? gPvProvider() : nil;
        if ([src isKindOfClass:[NSDictionary class]]) [st addEntriesFromDictionary:src];
        st[@"enabled"] = @YES;
        st[@"lyric_on"] = @(FDMPromptVarsLyricOn());

        return FDMPromptVarsResolveWithDict(text, st);
    } @catch (NSException *e) {
        FLOGE(FC_MUSIC, @"[pvar] apply 异常（原样放行）: %@", e.reason);
        return text;
    }
}

/** 在 FDMProbe 的 6s 定时器里调用。 */
void FDMPromptVarsInstall(void) {
    char err[512] = {0};
    int bad = fdmpv_selftest(err, sizeof(err));
    if (bad) {
        FLOGE(FC_MUSIC, @"[pvar] 变量引擎自检失败 #%d\n%s", bad, err);
        return;
    }
    FLOGI(FC_MUSIC, @"[pvar] 变量引擎 ✓（20 条用例：空值/双开方括号/歌词闸门/未知花括号）");
    FDMPromptVarsReload();
    FLOGI(FC_MUSIC, @"[pvar] 开关 pvar_on=%d pvar_lyric=%d（Documents/fdm-debug.json）",
          gPvOn ? 1 : 0, gPvLyricOn ? 1 : 0);
}
