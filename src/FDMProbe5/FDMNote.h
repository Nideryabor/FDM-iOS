// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMNote.h —— 悬浮便签（零权限，贴在宿主窗口最上层）
#ifndef FDM_NOTE_H
#define FDM_NOTE_H

#import <UIKit/UIKit.h>

/** #RRGGBB / #AARRGGBB → UIColor。解析失败用 fallback（0xAARRGGBB）。 */
UIColor *FDMRGBAColor(NSString *hex, unsigned int fallback);

/** 装（FDMProbe 6s 定时器里调）。内部自己判断开关。 */
void FDMNoteInstall(void);

/** 配置改完调一次（热生效，不用重启）。 */
void FDMNoteReload(void);

/** 立刻显示/隐藏。 */
void FDMNoteSetVisible(BOOL on);

/** 当前是否在显示。 */
BOOL FDMNoteVisible(void);

/** 无参数：显示。 */
void FDMNoteShow(void);

/** 无参数：隐藏。 */
void FDMNoteHide(void);

/** 便签视图（供调试 dump 用）。 */
@interface FDMNoteView : UIView
- (void)refreshAll;
@end

#endif /* FDM_NOTE_H */
