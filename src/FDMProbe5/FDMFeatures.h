// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用

#ifndef FDMFEATURES_H
#define FDMFEATURES_H

#import <Foundation/Foundation.h>
#import "FDMConfig.h"

/* ---- 配置组 id ---- */
extern NSString *const G_INJECT;    /* 系统提示词 */
extern NSString *const G_QUICK;     /* 快捷开关 */
extern NSString *const G_CHAT;      /* 对话增强 */
extern NSString *const G_UI;        /* 界面 */
extern NSString *const G_DEBUG;     /* 调试 */

/* ---- 页面 id（对齐安卓 Tree.kt） ---- */
extern NSString *const P_GRAY;
extern NSString *const P_CHAT;
extern NSString *const P_BEAUTY;
extern NSString *const P_NICK;
extern NSString *const P_AVATAR;
extern NSString *const P_HELLO;
extern NSString *const P_BG;
extern NSString *const P_ASSIST;    /* 助手图片 */
extern NSString *const P_BUBBLE;    /* 对话气泡设置 */
extern NSString *const P_FILECARD;  /* 文件快捷选项 */
extern NSString *const P_MISC;      /* 杂项（iOS 独有项） */
extern NSString *const P_NOTE;      /* 悬浮便签 */
extern NSString *const P_GLASS;     /* 液态玻璃 */
extern NSString *const P_DB;
extern NSString *const P_SUGGEST;
extern NSString *const P_RICH;
extern NSString *const P_ENV;
extern NSString *const P_DEBUG;
extern NSString *const P_DUMP;
extern NSString *const P_LOG;
extern NSString *const P_ABOUT;

void FDMFeaturesRegister(void);

/* 计算最终的服务端设置覆盖表 */
NSDictionary *FDMPatchTable(void);

/* 手动覆盖表（fdm-override.json） */
NSDictionary *FDMOverrideTable(void);

/* 回复建议改写（改 modelConfig 的 prompt_feature） */
BOOL FDMSuggestPatch(NSData **out, NSArray **outItems);
BOOL FDMApplyModelConfig(NSData **out, NSArray **outItems);

/* 提示词注入配置 */
void FDMInjectConfig(NSString **mode, NSString **text, BOOL *enabled);

/* 对话增强 */
BOOL FDMChatAppendEnabled(void);
NSString *FDMChatAppendText(void);

#endif /* FDMFEATURES_H */
