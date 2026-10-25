// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMGlass.h —— 「液态玻璃」iOS 落地（iOS 26 以下的合成方案 + 性能分级）
//
// ═══════════════════════════════════════════════════════════════════════════
//  一句话：iOS 26 有系统材质，iOS 15 没有 ⇒ 我们自己叠三层去逼近它，
//          并且按设备/场景自动决定「叠到第几层」。
//
//  分层（自下而上）
//   1 模糊层  复用宿主自己的 UIVisualEffectView，只把参数换成玻璃该有的
//             （_UICustomBlurEffect: radius 22 / saturation 1.85）
//   2 透光层  上亮下暗的极淡渐变，模拟玻璃厚度
//   3 高光层  45 度渐变 + 圆角描边 mask，模拟光线在边缘的折射增亮
//   4 折射层  只有 T3 有：blur_scale 1.02 + 内缘反光线
//             （真实透镜放大，但不是弯曲折射 —— 见下）
//
//  T4 走系统：探测 UIGlassEffect 类是否存在（iOS 26+），有就直接用，
//  没有就自动退回 T3。不硬编码 iOS 26 的 API 名，只按类名探测。
//
// ═══════════════════════════════════════════════════════════════════════════
//  ⚠️ 诚实边界：iOS 15 做不到真折射
//
//  iOS 26 的 Liquid Glass 是系统在合成阶段做的屏幕空间折射；
//  iOS 15 的 UIKit 层拿不到宿主合成好的背景纹理，没法扭曲它
//  （那要 Metal shader / RuntimeShader，而 UIKit 层没有这个入口）。
//
//  所以 T3 的「折射」= 采样放大（真）+ 内缘反光（视觉近似）。
//  看着像，但不是同一件事。不要对用户谎报。
//
// ═══════════════════════════════════════════════════════════════════════════
//  为什么只增强「宿主已有的」玻璃，而不是给所有控件硬加
//
//  宿主本来就在用 UIVisualEffectView（导航栏 / 顶部 VariableBlurView 等），
//  它们已经在付模糊的代价 —— 我们只是把那份代价改造成玻璃。
//  反过来给几百个 UIButton 硬塞模糊层，在 A10 + 2GB 上就是找死。
//  ⇒ 「原地升级」而不是「遍地新建」，这是这一版最重要的取舍。
// ═══════════════════════════════════════════════════════════════════════════
#ifndef FDM_GLASS_H
#define FDM_GLASS_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "FDMGlassPolicy.h"

/* ══════════════════════════════════════════════════════════════════════════
 *  ★ 三阶段注入（2026-10-23 架构调整）
 *
 *    ① 构造函数（dyld，早于 main）→ FDMGlassEarlyInstall()
 *       只 swizzle UIView.didMoveToWindow，纯 runtime，不碰 Foundation。
 *       宿主之后创建的**每一个**视图上屏时我们都会知道。
 *
 *    ② 配置就绪（6s）→ FDMGlassInstall()
 *       读配置、装其它 hook、开始巡检。
 *
 *    ③ 巡检（3s）→ 处理早期队列 + 增量
 * ══════════════════════════════════════════════════════════════════════════ */

/** ① 早期注入层：在构造函数里调，只装 hook 不做业务。 */
void FDMGlassEarlyInstall(void);

/** ② 把早期缓冲的控件补处理一遍，并切到实时模式。 */
int  FDMGlassEarlyFlush(void);

/** 早期层用：处理一个刚上屏的控件。@return 1 = 已入队 */
int  FDMGlassEarlyHandleView(UIView *v);

/** 早期层用：总开关是否已打开。 */
int  FDMGlassIsEnabled(void);

/** 早期层用：把控件排进待装饰队列。 */
void FDMGlassQueueView(UIView *v);

/** 安装（在 FDMProbe 的 6s 定时器里调）。 */
void FDMGlassInstall(void);

/** 装 hook（单独导出，方便自检时跳过）。 */
void FDMGlassHookInstall(void);

/** 当前决策（内部 1 秒缓存；场景一变立刻重算）。 */
fdmgp_plan FDMGlassCurrentPlan(void);

/** 供设置页/日志显示的一行状态。 */
NSString *FDMGlassStatusLine(void);

/** 用户手动定档（-1 = 自动）。立即生效并重建所有已增强的玻璃。 */
void FDMGlassSetUserTier(int tier);

/** 读回用户定档（-1 = 自动）。 */
int FDMGlassUserTier(void);

/** 把已经挂上玻璃的控件全部按新档位重建。 */
void FDMGlassRefreshAll(void);

/** 场景通知（键盘 / 滚动）。滚动目前由帧监测间接处理，这里留给以后用。 */
void FDMGlassNoteScrolling(BOOL scrolling);
void FDMGlassNoteKeyboard(BOOL up);

/** 对一个已有的 UIVisualEffectView 应用玻璃。幂等：重复调用只更新参数。 */
void FDMGlassApply(UIVisualEffectView *effectView);

/** 装饰层的 layer.name（CALayer 没有 tag 属性，只有 name）。
 *  用字符串而不是数字，是方便真机日志里一眼看出「这是我们的层」。 */
#define FDM_GLASS_NAME_HIGHLIGHT @"fdm.glass.highlight"
#define FDM_GLASS_NAME_INNER     @"fdm.glass.inner"
#define FDM_GLASS_NAME_GLOW      @"fdm.glass.glow"

#endif /* FDM_GLASS_H */
