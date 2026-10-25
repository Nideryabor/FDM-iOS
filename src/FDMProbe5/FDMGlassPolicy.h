// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMGlassPolicy —— 「液态玻璃」的**性能分级决策内核**（纯 C11，零依赖）
//
// ═══════════════════════════════════════════════════════════════════════════
//  为什么要单独一个内核
//
//  iOS 26 的 Liquid Glass 是系统级材质（UIGlassEffect），
//  iOS 15 上**没有**这个东西 —— 只能自己合成。而自己合成就要回答：
//    「这台机器、这一刻、这个界面，能开到第几档？」
//
//  这个问题的答案不该散落在各个 UIView 的 if 里，那样永远调不平。
//  所以把它抽成纯函数：输入结构化画像 → 输出一整套渲染参数 + 档位 + 理由。
//  好处：
//    · 能在小窝里跑 50 条断言，覆盖 A8~A18 / 2G~12G / 低电量 / 辅助功能
//    · 真机上出问题，日志里能看到「为什么是这个档」
//    · 换机型只要改权重，不用满地找 if
//
// ═══════════════════════════════════════════════════════════════════════════
//  五档（0 最低）
//
//  T0 OFF          完全不动。辅助功能「降低透明度」开启时是**义务**，不是优化。
//  T1 HIGHLIGHT    只画边缘高光 + 内部透光渐变，**不碰模糊**。
//                  成本 ≈ 两个 CAGradientLayer 合成，A7 都能全开。
//  T2 BLUR+        T1 + 用 _UICustomBlurEffect 调 radius/saturation。
//                  ★ 这是默认档 —— 因为宿主本来就在用 UIBlurEffect，
//                    我们只是把参数调成「玻璃该有的样子」，增量成本≈0。
//  T3 REFRACT      T2 + 更强的双层高光 + 背景采样微放大 + 触摸响应动效。
//                  需要 A12/4GB 以上；**滚动时自动退回 T2**。
//  T4 NATIVE       iOS 26+ 直接用系统 UIGlassEffect。只有系统真的给了才走这条。
//
// ═══════════════════════════════════════════════════════════════════════════
//  ⚠️ 诚实边界
//
//  iOS 15 的 GPU 管线里**没有屏幕空间折射**（那是 RuntimeShader / Metal shader
//  才能做的事，而 UIKit 层拿不到宿主合成好的背景纹理去扭曲）。
//  T3 能做到的「折射感」只有两件事：
//    ① 背景采样略放大（1.02~1.05）—— 真实的透镜放大，但不是弯曲的
//    ② 边缘高光模拟「光线在玻璃边缘的折射增亮」
//  这两条加起来视觉上接近，但**不是** iOS 26 的真折射。不要谎报。
// ═══════════════════════════════════════════════════════════════════════════
#ifndef FDM_GLASS_POLICY_H
#define FDM_GLASS_POLICY_H

#ifdef __cplusplus
extern "C" {
#endif

/* ── 档位 ── */
typedef enum {
    FDMGlassTierOff       = 0,
    FDMGlassTierHighlight = 1,
    FDMGlassTierBlur      = 2,
    FDMGlassTierRefract   = 3,
    FDMGlassTierNative    = 4,
} FDMGlassTier;

/**
 * 设备画像 + 运行时状态。**全部由调用方填，内核不自己探测** ——
 * 这样它才能在 Linux 上被单测。
 */
typedef struct {
    /* ── 设备（进程内一次性，填好后不变）── */
    int       cpu_cores;        /**< hw.ncpu */
    long long ram_mb;           /**< hw.memsize / 1MB */
    int       gpu_family;        /**< Metal supportsFamily: Apple1..9 → 1..9；0=不知道 */
    int       has_metallic;      /**< 1 = 至少有 Metal（iOS 15 设备恒 1） */

    /* ── 运行时开关（每次决策重读，很便宜）── */
    int low_power;               /**< NSProcessInfo.isLowPowerModeEnabled */
    int reduce_transparency;     /**< UIAccessibilityIsReduceTransparencyEnabled() */
    int reduce_motion;           /**< UIAccessibilityIsReduceMotionEnabled() */

    /* ── 场景（每次决策算）── */
    int scrolling;               /**< 正在滚动 / 拖拽 / 动画中 */
    int glass_count;             /**< 当前同屏玻璃控件数（填充率保护）*/
    int keyboard_up;             /**< 键盘弹出（输入区附近别做重活）*/

    /* ── 用户偏好 ── */
    int user_tier;               /**< -1=自动；0..4=强制（仍受 T0 义务约束）*/
    int force_tier;              /**< 1 = **无视硬件上限**，用户说几档就几档
                                      （真机教训：A10 手动选 T3 被静默钳到 T2，
                                       用户看不到任何变化还以为功能坏了）*/

    /* ── 自适应学习（内核会回写）── */
    int penalty;                 /**< 每超一次帧预算 +1，本会话不恢复 */
} fdmgp_profile;

/** 决策结果 */
typedef struct {
    int         tier;
    /* 模糊 */
    float       blur_radius;      /**< 0 = 不做模糊 */
    float       blur_saturation;  /**< 1.0 = 原色 */
    float       blur_scale;       /**< _UICustomBlurEffect.scale，>1 = 采样放大 */
    /* 高光 / 透光 */
    float       highlight_alpha;  /**< 边缘高光不透明度 0..1 */
    float       highlight_width;  /**< 描边宽度（pt）*/
    int         highlight_double; /**< 1 = 双层（外亮内淡）*/
    float       inner_grad_alpha; /**< 内部透光渐变强度 */
    /* 折射 */
    int         refraction;       /**< 1 = 背景采样放大 */
    float       refraction_scale; /**< 1.00..1.06 */
    float       refraction_alpha; /**< 0..1 */
    /* 动效 */
    int         animated;         /**< 1 = 允许触摸响应 */
    /* 诊断 */
    int         score;            /**< 硬件评分（0..9）*/
    const char *reason;           /**< 为什么是这个档（静态字符串，别 free）*/
} fdmgp_plan;

/** 硬件评分（0..9）—— 只看硬件，不看运行时。 */
int fdmgp_hardware_score(const fdmgp_profile *p);

/**
 * 决策。
 * @return 0 正常；-1 plan 为 NULL
 */
int fdmgp_decide(const fdmgp_profile *in, fdmgp_plan *out);

/**
 * 自适应：上报一帧耗时。超过预算就把 penalty +1（最多 4）。
 * @param budget_ms 该档的预算；传 0 用默认（T2/T3=16.7，T1=33.3）
 * @return 1 = 刚降级（调用方该重建视图），0 = 没变
 */
int fdmgp_note_frame_ms(fdmgp_profile *inout, double frame_ms, double budget_ms);

/** 档位名（日志用） */
const char *fdmgp_tier_name(int tier);

/** 内置用例自检。@return 0 = 全通过；否则第一个失败用例号。 */
int fdmgp_selftest(char *errbuf, int errlen);

#ifdef __cplusplus
}
#endif

#endif /* FDM_GLASS_POLICY_H */
