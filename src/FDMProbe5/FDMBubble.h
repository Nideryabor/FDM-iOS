// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMBubble.h —— 对话气泡设置（颜色 / 圆角 / 图片底 / 缩放 / 锚点）
#ifndef FDM_BUBBLE_H
#define FDM_BUBBLE_H

#import <UIKit/UIKit.h>

/** 装（FDMProbe 6s 定时器里调）。内部自己判断开关。 */
void FDMBubbleInstall(void);

/** 配置改完调一次（热生效）。 */
void FDMBubbleReload(void);

/** 扫全窗口重画（不用等宿主下次布局）。 */
void FDMBubbleRefreshAll(void);

#endif /* FDM_BUBBLE_H */
