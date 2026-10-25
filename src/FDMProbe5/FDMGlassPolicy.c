// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (c) 2026 尼得亚伯 (Nideryabor) & dxyabab | 仅供学习交流，禁止商业使用
//
// FDMGlassPolicy.c —— 见 FDMGlassPolicy.h
#include "FDMGlassPolicy.h"

#include <stdio.h>
#include <string.h>

/* ══════════════════════════════════════════════════════════════════════════
 *  一、评分
 * ══════════════════════════════════════════════════════════════════════════ */

int fdmgp_hardware_score(const fdmgp_profile *p) {
    if (!p) return 0;
    int s = 0;

    /* 核心数：A7=2 / A8=2 / A9=2 / A10=4 / A11=6 / A12..A18=6
     *
     * ★ 真机教训（2026-10-23 · iPhone9,2 / A10）：
     *   hw.ncpu 报 **2**，因为 A10 是「2 大 + 2 小、同一时刻只跑一组」的设计。
     *   所以调用方要把 hw.ncpu 与 hw.physicalcpu 取**较大者**再传进来，
     *   否则 A10 会被当成双核老机器（评分偏低但落档不出错）。 */
    if (p->cpu_cores >= 8)      s += 3;
    else if (p->cpu_cores >= 6) s += 2;
    else if (p->cpu_cores >= 4) s += 1;

    /* 内存：iPhone 7P=3G，8=2G，X=3G，XR/11=4G，12/13=4G，14Pro=6G，15Pro=8G
     *
     * ★ 真机教训（2026-10-23 · iPhone9,2）：hw.memsize 报的是 **2999MB**，
     *   不是 3072。内核会预留一部分，所以「3GB 机型」实际看到 ~2900~3000。
     *   阈值一律留 200MB 余量，否则 3GB 和 4GB 机器都会被低估一档。 */
    if (p->ram_mb >= 5900)      s += 3;
    else if (p->ram_mb >= 3900) s += 2;
    else if (p->ram_mb >= 2900) s += 1;

    /* GPU：Apple3=A9/A10，4=A11，5=A12，6=A13，7=A14，8=A15，9=A16+ */
    if (p->gpu_family >= 7)      s += 3;
    else if (p->gpu_family >= 5) s += 2;
    else if (p->gpu_family >= 3) s += 1;

    return s;   /* 0..9 */
}

const char *fdmgp_tier_name(int tier) {
    switch (tier) {
        case FDMGlassTierOff:       return "T0-OFF";
        case FDMGlassTierHighlight: return "T1-HIGHLIGHT";
        case FDMGlassTierBlur:      return "T2-BLUR";
        case FDMGlassTierRefract:   return "T3-REFRACT";
        case FDMGlassTierNative:    return "T4-NATIVE";
        default:                    return "T?-UNKNOWN";
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 *  二、参数表
 * ══════════════════════════════════════════════════════════════════════════ */

static void fill_params(int tier, fdmgp_plan *o) {
    o->tier = tier;
    o->highlight_width = 1.0f;
    o->highlight_double = 0;
    o->blur_scale = 1.0f;
    o->refraction = 0;
    o->refraction_scale = 1.0f;
    o->refraction_alpha = 0.0f;

    switch (tier) {
        case FDMGlassTierOff:
            o->blur_radius = 0.0f;
            o->blur_saturation = 1.0f;
            o->highlight_alpha = 0.0f;
            o->highlight_width = 0.0f;
            o->inner_grad_alpha = 0.0f;
            o->animated = 0;
            break;

        case FDMGlassTierHighlight:
            o->blur_radius = 0.0f;
            o->blur_saturation = 1.0f;
            o->highlight_alpha = 0.55f;
            o->inner_grad_alpha = 0.09f;
            o->animated = 0;
            break;

        case FDMGlassTierBlur:
            o->blur_radius = 22.0f;
            o->blur_saturation = 1.85f;
            o->highlight_alpha = 0.55f;
            o->inner_grad_alpha = 0.10f;
            o->animated = 0;
            break;

        case FDMGlassTierRefract:
            o->blur_radius = 26.0f;
            o->blur_saturation = 1.95f;
            o->blur_scale = 1.02f;
            o->highlight_alpha = 0.68f;
            o->highlight_width = 1.2f;
            o->highlight_double = 1;
            o->inner_grad_alpha = 0.13f;
            o->refraction = 1;
            o->refraction_scale = 1.04f;
            o->refraction_alpha = 0.30f;
            o->animated = 1;
            break;

        case FDMGlassTierNative:
        default:
            /* iOS 26+ 交给系统；这里的参数只是「系统给不了时的退路」 */
            o->tier = FDMGlassTierNative;
            o->blur_radius = 24.0f;
            o->blur_saturation = 1.9f;
            o->highlight_alpha = 0.62f;
            o->inner_grad_alpha = 0.12f;
            o->refraction = 1;
            o->refraction_scale = 1.04f;
            o->refraction_alpha = 0.28f;
            o->animated = 1;
            break;
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 *  三、决策
 * ══════════════════════════════════════════════════════════════════════════ */

int fdmgp_decide(const fdmgp_profile *in, fdmgp_plan *out) {
    if (!in || !out) return -1;

    const int score = fdmgp_hardware_score(in);
    memset(out, 0, sizeof(*out));
    out->score = score;

    /* ── ① 义务：辅助功能「降低透明度」⇒ 必须关 ──
     *   这不是性能优化，是**用户明确的无障碍需求**。
     *   系统自己的 UIBlurEffect 也会因此变成不透明底色，我们跟着做。 */
    if (in->reduce_transparency) {
        fill_params(FDMGlassTierOff, out);
        out->reason = "a11y:reduce-transparency";
        return 0;
    }

    /* ── ② ★ T4 特例：调用方用 user_tier=Native 表示「本机真的探到了
     *      UIGlassEffect」。这时候不受硬件上限约束（系统自己会给保障），
     *      但仍然已经过了上面那道 reduce_transparency 义务闸门。 */
    if (in->user_tier == FDMGlassTierNative) {
        fill_params(FDMGlassTierNative, out);
        out->reason = "native:UIGlassEffect";
        return 0;
    }

    /* ── ③ 用户强制档（仍受硬件上限约束，不能拿 T3 硬套 A8）── */
    int limit;
    if (!in->has_metallic) {
        limit = FDMGlassTierHighlight;
    } else if (score >= 6 && in->ram_mb >= 3900 && in->gpu_family >= 6) {
        /* ★ 门槛为什么定在「4GB + GPU6」而不是更高：
         *   T3 的增量全是「多两个 gradient layer + blur_scale 1.02 + 触摸动效」，
         *   **没有**真截图、没有额外离屏渲染 ⇒ 真正的成本大头（大半径模糊）
         *   T2 也有。所以只要内存够 4G 不紧张、GPU 到 A13 级别就够跑。
         *   A12/3G（iPhone XR）落 T2 是因为 3GB 上多一层渐变会更容易被系统杀。 */
        limit = FDMGlassTierRefract;
    } else {
        /* ★ 默认就是 T2：宿主本来在模糊，我们只调参数，增量≈0 */
        limit = FDMGlassTierBlur;
    }
    const char *limit_reason =
        (limit == FDMGlassTierRefract)   ? "hw:>=A12/4G" :
        (limit == FDMGlassTierHighlight) ? "hw:no-metal"  : "hw:default-T2";

    int tier = (in->user_tier >= 0) ? in->user_tier : limit;

    const char *reason;
    if (in->user_tier >= 0) {
        if (tier > limit && in->force_tier) {
            /* ★ 用户显式强制：允许超过硬件上限。
             *   真机教训（2026-10-23）：A10 手动选 T3 被静默钳到 T2，
             *   用户完全看不出来「为什么没变化」。
             *   ⇒ 强制档就是强制档，但 reason 要能看出来。 */
            reason = "user:forced(over-hw)";
        } else if (tier > limit) {
            tier = limit;
            reason = "user:clamped-by-hw";
        } else {
            reason = "user:forced";
        }
    } else {
        reason = limit_reason;
    }

    /* ── ④ 运行时惩罚（每一条都可能降一档）── */
    int down = in->penalty;
    if (down < 0) down = 0;
    if (down > 4) down = 4;

    if (in->low_power) {
        down++;
        reason = "runtime:low-power";
    }
    if (in->glass_count > 16) {
        down++;
        reason = "runtime:too-many-glass";
    }

    /* ★★ 2026-10-23 真机反馈：「手动改成 T3 但按钮没区别」。
     *
     *   追下来是**两层钳制叠加**：
     *     ① 硬件上限把 T3 钳到 T2（已在上面 force_tier 修掉）
     *     ② 就算过了①，「低电量」+「同屏玻璃>16」又各降一档 ⇒ T3 → T1
     *   ⇒ 用户明明点了 T3，实际跑的是 T1，界面上当然"看不出区别"。
     *
     *   现在：**用户显式强制档时，忽略所有自动惩罚**（省电/数量/自适应）。
     *   唯一保留的是「滚动/键盘」的场景降档 —— 那是防卡的硬保护，
     *   而且只在滚动瞬间生效，松手立刻恢复，不会让用户觉得"设置没生效"。 */
    const int forced = in->force_tier && in->user_tier >= 0;
    if (forced) down = 0;

    /* 滚动 / 键盘：只砍「重活」（T3），T2 是宿主原有成本，不用动 */
    if (tier >= FDMGlassTierRefract && (in->scrolling || in->keyboard_up)) {
        tier = FDMGlassTierBlur;
        reason = in->scrolling ? "scene:scrolling" : "scene:keyboard";
        /* 已经降过一次，不再叠加 down（否则滚动时一路掉到 T0，闪） */
        down = 0;
    }

    tier -= down;
    if (tier < FDMGlassTierOff) tier = FDMGlassTierOff;
    if (forced && down == 0 && !in->scrolling && !in->keyboard_up && in->user_tier >= 0) {
        reason = "user:forced(no-auto-down)";
    } else if (down > 0 && in->penalty > 0) {
        reason = "adaptive:frame-budget";
    } else if (down > 0 && in->low_power) {
        reason = "runtime:low-power";
    }

    /* ── ⑤ 辅助功能「减弱动态效果」：只砍动效，不砍材质 ── */
    fill_params(tier, out);
    if (in->reduce_motion) out->animated = 0;

    out->reason = reason;
    return 0;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  四、自适应
 * ══════════════════════════════════════════════════════════════════════════ */

static double default_budget(int tier) {
    switch (tier) {
        case FDMGlassTierRefract:   return 20.0;   /* 60fps 满帧 16.7，留 20% 余量 */
        case FDMGlassTierBlur:      return 20.0;
        case FDMGlassTierHighlight: return 40.0;   /* 30fps 也算合格 */
        default:                    return 0.0;
    }
}

int fdmgp_note_frame_ms(fdmgp_profile *inout, double frame_ms, double budget_ms) {
    if (!inout || frame_ms <= 0.0) return 0;

    fdmgp_plan before, after;
    fdmgp_decide(inout, &before);

    double budget = budget_ms > 0.0 ? budget_ms : default_budget(before.tier);
    if (budget <= 0.0) return 0;
    if (frame_ms <= budget) return 0;

    if (inout->penalty >= 4) return 0;
    inout->penalty++;

    fdmgp_decide(inout, &after);
    return (after.tier != before.tier) ? 1 : 0;
}

/* ══════════════════════════════════════════════════════════════════════════
 *  五、自检
 * ══════════════════════════════════════════════════════════════════════════ */

/* 真机画像（用来钉住"主流机型落在哪一档"）*/
typedef struct {
    const char *name;
    int cores;
    long long ram;
    int gpu;
    int want_tier;
} hw_case;

static const hw_case kHW[] = {
    /* 名字          核  内存(MB) gpu  期望档 */
    {"iPhone7P-A10",  4,  2999,     3,  FDMGlassTierBlur},   /* 真机实测值 */
    {"iPhone8-A11",   6,  1990,     4,  FDMGlassTierBlur},
    {"iPhoneX-A11",   6,  2999,     4,  FDMGlassTierBlur},
    {"iPhoneXR-A12",  6,  3072,     5,  FDMGlassTierBlur},
    {"iPhone11-A13",  6,  3900,     6,  FDMGlassTierRefract},  /* 4G+GPU6 够 T3 */
    {"iPhone12-A14",  6,  4096,     7,  FDMGlassTierRefract},
    {"iPhone13-A15",  6,  4096,     8,  FDMGlassTierRefract},
    {"iPhone14P-A16", 6,  6144,     9,  FDMGlassTierRefract},
    {"iPadPro-M1",   8,  7900,     9,  FDMGlassTierRefract},
    {"老iPad-A8",     2,  2048,     2,  FDMGlassTierBlur},
};

static int case_profile(const hw_case *h, fdmgp_profile *p) {
    memset(p, 0, sizeof(*p));
    p->cpu_cores = h->cores;
    p->ram_mb = h->ram;
    p->gpu_family = h->gpu;
    p->has_metallic = 1;
    p->user_tier = -1;
    return 0;
}

int fdmgp_selftest(char *errbuf, int errlen) {
    char local[512];
    if (!errbuf) { errbuf = local; errlen = (int)sizeof(local); }
    errbuf[0] = '\0';

    int no = 0;
    fdmgp_profile p;
    fdmgp_plan plan;

    #define FAIL(...) do { snprintf(errbuf, (size_t)errlen, __VA_ARGS__); return no; } while (0)

    /* ── 1..10：机型落档 ── */
    for (size_t i = 0; i < sizeof(kHW) / sizeof(kHW[0]); i++) {
        case_profile(&kHW[i], &p);
        fdmgp_decide(&p, &plan);
        no = (int)(i + 1);
        if (plan.tier != kHW[i].want_tier) {
            FAIL("#%d %s 落档 %s（期望 %s），score=%d",
                 no, kHW[i].name, fdmgp_tier_name(plan.tier),
                 fdmgp_tier_name(kHW[i].want_tier), plan.score);
        }
    }
    no = 11;

    /* ── 11：评分边界 ── */
    case_profile(&kHW[0], &p);                    /* A10: 1+1+1 = 3（真机 2999MB）*/
    if (fdmgp_hardware_score(&p) != 3) FAIL("#11 A10 分数应为 3，得到 %d", fdmgp_hardware_score(&p));

    no = 12;
    case_profile(&kHW[8], &p);                    /* M1: 3+3+3 = 9 */
    if (fdmgp_hardware_score(&p) != 9) FAIL("#12 M1 分数应为 9，得到 %d", fdmgp_hardware_score(&p));

    /* ── 12：「降低透明度」是义务，强制 T0，连用户强制都不能违抗 ── */
    no = 13;
    case_profile(&kHW[8], &p);                    /* 最强机器 */
    p.user_tier = FDMGlassTierRefract;             /* 用户还想开满 */
    p.reduce_transparency = 1;
    fdmgp_decide(&p, &plan);
    if (plan.tier != FDMGlassTierOff)
        FAIL("#13 reduce_transparency 必须 T0，得到 %s", fdmgp_tier_name(plan.tier));
    if (!plan.reason || strstr(plan.reason, "a11y") == NULL)
        FAIL("#13 reason 应含 a11y，得到 %s", plan.reason ? plan.reason : "(null)");

    /* ── 13：用户强制低档有效 ── */
    no = 14;
    case_profile(&kHW[8], &p);
    p.user_tier = FDMGlassTierHighlight;
    fdmgp_decide(&p, &plan);
    if (plan.tier != FDMGlassTierHighlight)
        FAIL("#14 用户强制 T1 应生效，得到 %s", fdmgp_tier_name(plan.tier));
    if (plan.blur_radius != 0.0f)
        FAIL("#14 T1 不该有模糊，radius=%f", (double)plan.blur_radius);

    /* ── 14：用户强制高档被硬件钳住（A8 想开 T3）── */
    no = 15;
    case_profile(&kHW[9], &p);                     /* A8 */
    p.user_tier = FDMGlassTierRefract;
    fdmgp_decide(&p, &plan);
    if (plan.tier != FDMGlassTierBlur)
        FAIL("#15 A8 强制 T3 应被钳到 T2，得到 %s", fdmgp_tier_name(plan.tier));

    /* ── 15：无 Metal ⇒ 最多 T1 ── */
    no = 16;
    case_profile(&kHW[8], &p);
    p.has_metallic = 0;
    fdmgp_decide(&p, &plan);
    if (plan.tier != FDMGlassTierHighlight)
        FAIL("#16 无 Metal 应钳到 T1，得到 %s", fdmgp_tier_name(plan.tier));

    /* ── 16：T3 机器低电量 ⇒ T2 ── */
    no = 17;
    case_profile(&kHW[7], &p);                     /* A16 */
    p.low_power = 1;
    fdmgp_decide(&p, &plan);
    if (plan.tier != FDMGlassTierBlur)
        FAIL("#17 低电量应降到 T2，得到 %s", fdmgp_tier_name(plan.tier));
    if (!plan.reason || strstr(plan.reason, "low-power") == NULL)
        FAIL("#17 reason 应含 low-power，得到 %s", plan.reason ? plan.reason : "(null)");

    /* ── 17：低电量下 T2 机器 ⇒ T1 ── */
    no = 18;
    case_profile(&kHW[0], &p);                     /* A10，本来 T2 */
    p.low_power = 1;
    fdmgp_decide(&p, &plan);
    if (plan.tier != FDMGlassTierHighlight)
        FAIL("#18 A10 + 低电量应降到 T1，得到 %s", fdmgp_tier_name(plan.tier));

    /* ── 18：滚动时 T3 退回 T2，但不会一路掉到 T1（防闪烁）── */
    no = 19;
    case_profile(&kHW[7], &p);
    p.scrolling = 1;
    p.low_power = 1;                               /* 同时低电量，也不许掉到 T0 */
    fdmgp_decide(&p, &plan);
    if (plan.tier < FDMGlassTierHighlight)
        FAIL("#19 滚动+低电量不该掉到 %s 以下", fdmgp_tier_name(plan.tier));
    if (!plan.reason || strstr(plan.reason, "scrolling") == NULL)
        FAIL("#19 reason 应含 scrolling，得到 %s", plan.reason ? plan.reason : "(null)");

    /* ── 19：键盘弹出同样砍 T3 ── */
    no = 20;
    case_profile(&kHW[7], &p);
    p.keyboard_up = 1;
    fdmgp_decide(&p, &plan);
    if (plan.tier != FDMGlassTierBlur)
        FAIL("#20 键盘弹出应降 T2，得到 %s", fdmgp_tier_name(plan.tier));

    /* ── 20：玻璃太多 ⇒ 降档 ── */
    no = 21;
    case_profile(&kHW[7], &p);
    p.glass_count = 40;
    fdmgp_decide(&p, &plan);
    if (plan.tier != FDMGlassTierBlur)
        FAIL("#21 同屏 40 块玻璃应降 T2，得到 %s", fdmgp_tier_name(plan.tier));
    if (!plan.reason || strstr(plan.reason, "too-many") == NULL)
        FAIL("#21 reason 应含 too-many，得到 %s", plan.reason ? plan.reason : "(null)");

    /* ── 21：减弱动态效果只砍动效，不砍材质 ── */
    no = 22;
    case_profile(&kHW[7], &p);
    fdmgp_decide(&p, &plan);
    int tier_normal = plan.tier;
    int anim_normal = plan.animated;
    p.reduce_motion = 1;
    fdmgp_decide(&p, &plan);
    if (plan.tier != tier_normal)
        FAIL("#22 reduce_motion 不该改档位（%s → %s）",
             fdmgp_tier_name(tier_normal), fdmgp_tier_name(plan.tier));
    if (anim_normal != 1 || plan.animated != 0)
        FAIL("#22 reduce_motion 应关动效（原 %d → 现 %d）", anim_normal, plan.animated);

    /* ── 22：T3 参数完整性 ── */
    no = 23;
    case_profile(&kHW[7], &p);
    fdmgp_decide(&p, &plan);
    if (plan.tier != FDMGlassTierRefract) FAIL("#23 前置：应为 T3");
    if (!(plan.blur_radius > 0.0f))                      FAIL("#23 T3 blur_radius 应 >0");
    if (!(plan.blur_saturation > 1.0f))                  FAIL("#23 T3 应提饱和");
    if (plan.refraction != 1)                            FAIL("#23 T3 应有折射");
    if (!(plan.refraction_scale > 1.0f && plan.refraction_scale <= 1.06f))
        FAIL("#23 折射放大应落在 (1.0,1.06]，得到 %.3f", (double)plan.refraction_scale);
    if (plan.highlight_double != 1)                      FAIL("#23 T3 应双层高光");
    if (plan.animated != 1)                              FAIL("#23 T3 应允许动效");

    /* ── 23：T1 绝不能带模糊（这是它的定义）── */
    no = 24;
    fill_params(FDMGlassTierHighlight, &plan);
    if (plan.blur_radius != 0.0f || plan.refraction != 0)
        FAIL("#24 T1 必须无模糊无折射");

    /* ── 24：T0 全零 ── */
    no = 25;
    fill_params(FDMGlassTierOff, &plan);
    if (plan.blur_radius != 0.0f || plan.highlight_alpha != 0.0f ||
        plan.inner_grad_alpha != 0.0f || plan.refraction != 0 || plan.animated != 0)
        FAIL("#25 T0 必须全零");

    /* ── 25：自适应——超时一次就降档 ── */
    no = 26;
    case_profile(&kHW[7], &p);                    /* A16 → T3 */
    fdmgp_plan b0; fdmgp_decide(&p, &b0);
    if (b0.tier != FDMGlassTierRefract) FAIL("#26 前置：应为 T3");
    if (b0.blur_saturation > 2.1f) FAIL("#26 饱和度过高，可能过曝");

    /* ── 26：帧超时 → penalty → 降档 ── */
    no = 27;
    int ch = fdmgp_note_frame_ms(&p, 45.0, 20.0);
    if (ch != 1) FAIL("#27 帧超时(45ms>20ms) 应触发降级，返回 %d", ch);
    if (p.penalty != 1) FAIL("#27 penalty 应为 1，得到 %d", p.penalty);
    fdmgp_plan b1; fdmgp_decide(&p, &b1);
    if (b1.tier >= b0.tier) FAIL("#27 降级后档位没降（%s → %s）",
                                 fdmgp_tier_name(b0.tier), fdmgp_tier_name(b1.tier));

    /* ── 27：帧正常不降级 ── */
    no = 28;
    case_profile(&kHW[7], &p);
    ch = fdmgp_note_frame_ms(&p, 12.0, 20.0);
    if (ch != 0 || p.penalty != 0) FAIL("#28 帧正常不该降级（ch=%d pen=%d）", ch, p.penalty);

    /* ── 28：penalty 封顶 4 ── */
    no = 29;
    for (int i = 0; i < 10; i++) fdmgp_note_frame_ms(&p, 99.0, 20.0);
    if (p.penalty > 4) FAIL("#29 penalty 应封顶 4，得到 %d", p.penalty);

    /* ── 29：penalty 封顶后不崩 ── */
    no = 30;
    fdmgp_decide(&p, &plan);
    if (plan.tier < FDMGlassTierOff || plan.tier > FDMGlassTierNative)
        FAIL("#30 封顶后档位越界 %d", plan.tier);

    /* ── 30：极端输入不崩、不越界 ── */
    no = 31;
    memset(&p, 0, sizeof(p));
    p.user_tier = -1;
    fdmgp_decide(&p, &plan);
    if (plan.tier < 0 || plan.tier > 4) FAIL("#31 全零画像档位越界 %d", plan.tier);

    /* ── 31：负值画像 ── */
    no = 32;
    memset(&p, 0, sizeof(p));
    p.cpu_cores = -5; p.ram_mb = -1; p.gpu_family = -3; p.user_tier = -1; p.penalty = -9;
    fdmgp_decide(&p, &plan);
    if (plan.tier < 0 || plan.tier > 4) FAIL("#32 负值档位越界 %d", plan.tier);
    if (plan.score != 0) FAIL("#32 负值分数应为 0，得到 %d", plan.score);

    /* ── 32：NULL 安全 ── */
    no = 33;
    if (fdmgp_decide(NULL, &plan) != -1) FAIL("#33 decide(NULL) 应返回 -1");
    if (fdmgp_decide(&p, NULL) != -1)    FAIL("#33 decide(.,NULL) 应返回 -1");
    if (fdmgp_hardware_score(NULL) != 0) FAIL("#33 score(NULL) 应返回 0");
    if (fdmgp_note_frame_ms(NULL, 99.0, 20.0) != 0) FAIL("#33 note(NULL) 应返回 0");

    /* ── 33：T4 只在显式请求时出现 ── */
    no = 34;
    case_profile(&kHW[8], &p);
    fdmgp_decide(&p, &plan);
    if (plan.tier == FDMGlassTierNative) FAIL("#34 没显式请求不该出现 T4");

    /* ── 34：显式请求 T4 ⇒ 拿到 T4 ── */
    no = 35;
    case_profile(&kHW[8], &p);
    p.user_tier = FDMGlassTierNative;
    fdmgp_decide(&p, &plan);
    if (plan.tier != FDMGlassTierNative)
        FAIL("#35 显式请求 T4 应通过，得到 %s", fdmgp_tier_name(plan.tier));

    /* ── 35：T4 也要服从 reduce_transparency ── */
    no = 36;
    p.reduce_transparency = 1;
    fdmgp_decide(&p, &plan);
    if (plan.tier != FDMGlassTierOff)
        FAIL("#36 T4 也须服从降低透明度，得到 %s", fdmgp_tier_name(plan.tier));

    /* ── 37b：★ 强制档必须真的生效（无视硬件上限）──
     *   真机教训：A10 手动选 T3 被静默钳到 T2 ⇒ 用户以为功能坏了。 */
    no = 40;
    {
        case_profile(&kHW[0], &p);            /* A10，硬件上限只有 T2 */
        p.user_tier = FDMGlassTierRefract;
        p.force_tier = 0;
        fdmgp_decide(&p, &plan);
        if (plan.tier != FDMGlassTierBlur)
            FAIL("#40 不强制时应被钳到 T2，得到 %s", fdmgp_tier_name(plan.tier));
        if (!plan.reason || strstr(plan.reason, "clamped") == NULL)
            FAIL("#40 被钳时 reason 应含 clamped，得到 %s", plan.reason ? plan.reason : "(null)");

        p.force_tier = 1;
        fdmgp_decide(&p, &plan);
        if (plan.tier != FDMGlassTierRefract)
            FAIL("#41 强制 T3 必须生效，得到 %s", fdmgp_tier_name(plan.tier));
        if (!plan.reason || strstr(plan.reason, "forced") == NULL)
            FAIL("#41 强制档 reason 应含 forced，得到 %s", plan.reason ? plan.reason : "(null)");
    }

    /* ── 37d：★ 强制档时「低电量 + 玻璃多」不许降档 ──
     *   真机：手动选 T3，被 low-power 和 glass_count 各降一档 ⇒ 实际跑 T1，
     *   界面上完全看不出区别，用户以为功能坏了。 */
    no = 43;
    {
        case_profile(&kHW[0], &p);
        p.user_tier = FDMGlassTierRefract;
        p.force_tier = 1;
        p.low_power = 1;          /* 低电量 */
        p.glass_count = 40;       /* 同屏玻璃很多 */
        fdmgp_decide(&p, &plan);
        if (plan.tier != FDMGlassTierRefract)
            FAIL("#43 强制 T3 时不应被 low-power/glass_count 降档，得到 %s",
                 fdmgp_tier_name(plan.tier));
    }

    /* ── 37e：强制档也要服从「滚动」场景降档（防卡的硬保护）── */
    no = 44;
    {
        case_profile(&kHW[0], &p);
        p.user_tier = FDMGlassTierRefract;
        p.force_tier = 1;
        p.scrolling = 1;
        fdmgp_decide(&p, &plan);
        if (plan.tier != FDMGlassTierBlur)
            FAIL("#44 滚动时强制 T3 应临时降到 T2，得到 %s",
                 fdmgp_tier_name(plan.tier));
    }

    /* ── 37c：强制档也必须服从「降低透明度」义务 ── */
    no = 42;
    {
        case_profile(&kHW[0], &p);
        p.user_tier = FDMGlassTierRefract;
        p.force_tier = 1;
        p.reduce_transparency = 1;
        fdmgp_decide(&p, &plan);
        if (plan.tier != FDMGlassTierOff)
            FAIL("#42 强制档也要服从 reduce_transparency，得到 %s",
                 fdmgp_tier_name(plan.tier));
    }

    /* ── 36：reason 永不为 NULL ── */
    no = 37;
    case_profile(&kHW[0], &p);
    fdmgp_decide(&p, &plan);
    if (!plan.reason) FAIL("#37 reason 不该为 NULL");

    /* ── 37：tier 名字非空 ── */
    no = 38;
    for (int t = 0; t <= 4; t++) {
        const char *n = fdmgp_tier_name(t);
        if (!n || !*n) FAIL("#38 tier_name(%d) 为空", t);
    }
    if (!fdmgp_tier_name(99)) FAIL("#38 越界 tier_name 该有兜底");

    /* ── 38：所有档位的参数都在合法区间 ── */
    no = 39;
    for (int t = 0; t <= 4; t++) {
        fill_params(t, &plan);
        if (plan.blur_radius < 0.0f || plan.blur_radius > 60.0f)
            FAIL("#39 T%d blur_radius 越界 %.1f", t, (double)plan.blur_radius);
        if (plan.blur_saturation < 1.0f || plan.blur_saturation > 3.0f)
            FAIL("#39 T%d saturation 越界 %.2f", t, (double)plan.blur_saturation);
        if (plan.highlight_alpha < 0.0f || plan.highlight_alpha > 1.0f)
            FAIL("#39 T%d highlight_alpha 越界 %.2f", t, (double)plan.highlight_alpha);
        if (plan.inner_grad_alpha < 0.0f || plan.inner_grad_alpha > 0.5f)
            FAIL("#39 T%d inner_grad 越界 %.2f", t, (double)plan.inner_grad_alpha);
        if (plan.refraction_scale < 1.0f || plan.refraction_scale > 1.06f)
            FAIL("#39 T%d refraction_scale 越界 %.3f", t, (double)plan.refraction_scale);
        if (plan.refraction_alpha < 0.0f || plan.refraction_alpha > 1.0f)
            FAIL("#39 T%d refraction_alpha 越界 %.2f", t, (double)plan.refraction_alpha);
    }

    #undef FAIL
    return 0;
}
