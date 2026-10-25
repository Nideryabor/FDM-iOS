// FDMMusicModel 离线自测：跑在小窝 Linux gcc 上，不需要真机
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "FDMMusicModel.h"

int main(void) {
    char err[512];
    int r = fdmmusic_selftest(err, sizeof(err));
    if (r) { printf("SELFTEST FAIL\n%s\n", err); return 1; }
    printf("FDMMusicModel SELFTEST OK（47 组断言）\n");

    /* ---- 真值表演示：三种循环 × 手动/自动，队列 3 首、当前在第 3 首 ---- */
    fdmmusic_queue q;
    fdmmusic_init(&q);
    for (int i = 0; i < 3; i++) {
        fdmmusic_track t;
        memset(&t, 0, sizeof(t));
        t.id = 100 + i;
        char nm[16];
        snprintf(nm, sizeof(nm), "歌%d", i + 1);
        t.name = nm;
        t.artist = "某龙";
        t.album = "小窝";
        t.duration_ms = 200000 + i * 1000;
        fdmmusic_push(&q, &t);
    }
    q.idx = 2;
    q.repeat = FDMMR_ALL;
    printf("  ALL 第3首 自动→ %d（期望 0 绕回）\n", fdmmusic_next_index(&q, 0));
    q.repeat = FDMMR_ONE;
    printf("  ONE 第3首 自动→ %d（期望 2 原地）\n", fdmmusic_next_index(&q, 0));
    printf("  ONE 第3首 手动→ %d（期望 0 换歌）\n", fdmmusic_next_index(&q, 1));
    q.repeat = FDMMR_OFF;
    printf("  OFF 第3首 自动→ %d（期望 -1 停）\n", fdmmusic_next_index(&q, 0));

    /* ---- 存档往返演示 ---- */
    q.repeat = FDMMR_ONE;
    q.pos_ms = 88000;
    char *js = fdmmusic_to_json(&q);
    printf("  state.json = %s\n", js);

    fdmmusic_queue back;
    fdmmusic_init(&back);
    if (fdmmusic_from_json(&back, js) == 0) {
        printf("  回读：%zu 首 / idx=%d / pos=%lldms / repeat=%d / state=%d(3=PAUSED)\n",
               back.count, back.idx, back.pos_ms, back.repeat, back.state);
    }
    free(js);
    fdmmusic_free(&back);
    fdmmusic_free(&q);
    return 0;
}
