#include "FDMGlassPolicy.h"
#include <stdio.h>

int main(void) {
    char err[512];
    int r = fdmgp_selftest(err, sizeof(err));
    if (r) { printf("SELFTEST FAIL\n%s\n", err); return 1; }
    printf("FDMGlassPolicy SELFTEST OK（39 组断言）\n\n");

    struct { const char *n; int c; long long m; int g; int lp; int sc; int gc; } cs[] = {
        {"iPhone 7P / A10 / 2G",        4, 2048, 3, 0, 0, 0},
        {"iPhone 7P · 低电量",           4, 2048, 3, 1, 0, 0},
        {"iPhone 7P · 滚动中",           4, 2048, 3, 0, 1, 0},
        {"iPhone 12 / A14 / 4G",        6, 4096, 7, 0, 0, 0},
        {"iPhone 12 · 滚动中",           6, 4096, 7, 0, 1, 0},
        {"iPhone 12 · 低电量",           6, 4096, 7, 1, 0, 0},
        {"iPhone 15P / A17 / 8G",       6, 8192, 9, 0, 0, 0},
        {"iPhone 15P · 40 块玻璃",       6, 8192, 9, 0, 0, 40},
        {"iPhone 15P · 降低透明度",      6, 8192, 9, 0, 0, 0},
    };
    printf("%-30s %-13s %-16s %s\n", "场景", "档位", "模糊/饱和/高光", "折射 理由");
    printf("--------------------------------------------------------------------------------\n");
    for (unsigned i = 0; i < sizeof(cs)/sizeof(cs[0]); i++) {
        fdmgp_profile p = {0};
        p.cpu_cores = cs[i].c; p.ram_mb = cs[i].m; p.gpu_family = cs[i].g;
        p.has_metallic = 1; p.user_tier = -1;
        p.low_power = cs[i].lp; p.scrolling = cs[i].sc; p.glass_count = cs[i].gc;
        if (i == 8) p.reduce_transparency = 1;
        fdmgp_plan pl; fdmgp_decide(&p, &pl);
        printf("%-30s %-13s %4.0f/%3.2f/%-4.2f  %-3s %s\n",
               cs[i].n, fdmgp_tier_name(pl.tier),
               (double)pl.blur_radius, (double)pl.blur_saturation, (double)pl.highlight_alpha,
               pl.refraction ? "是" : "否", pl.reason ? pl.reason : "");
    }
    return 0;
}
