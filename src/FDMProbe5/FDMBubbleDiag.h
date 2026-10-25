// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMBubbleDiag.h —— 对话气泡「纯诊断模式」入口
//
// 只读、只打印、不修改。开关：fdm-bubble.json 里 {"diag": true}
//
#ifndef FDM_BUBBLE_DIAG_H
#define FDM_BUBBLE_DIAG_H

#ifdef __cplusplus
extern "C" {
#endif

/** 读配置；diag=true 时装诊断 hook（与气泡功能开关互相独立）。 */
void FDMBubbleDiagInstall(void);

/** 配置热更新后重新判断开关。 */
void FDMBubbleDiagReload(void);

/** 已经 dump 过几个容器（给日志用）。 */
int FDMBubbleDiagCount(void);

#ifdef __cplusplus
}
#endif

#endif /* FDM_BUBBLE_DIAG_H */
