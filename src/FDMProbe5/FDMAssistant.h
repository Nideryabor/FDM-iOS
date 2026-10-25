// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMAssistant.h —— 修改助手图片（AI 回复旁的头像）
#ifndef FDM_ASSISTANT_H
#define FDM_ASSISTANT_H

#import <UIKit/UIKit.h>

/** 装（FDMProbe 6s 定时器里调）。 */
void FDMAssistantInstall(void);

/** 配置改完调一次（热生效）。 */
void FDMAssistantReload(void);

/** 扫全窗口重画。 */
void FDMAssistantRefreshAll(void);

#endif /* FDM_ASSISTANT_H */
