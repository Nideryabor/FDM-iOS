#include "FDMNoteModel.h"
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    char err[512];
    int r = fdmnote_selftest(err, sizeof(err));
    if (r) { printf("SELFTEST FAIL\n%s\n", err); return 1; }
    printf("FDMNoteModel SELFTEST OK（25 组断言）\n\n");

    fdmnote_state st;
    fdmnote_init(&st);
    fdmnote_set_text(&st, "买牛奶\n三点前");
    fdmnote_set_pos(&st, 120, 300);
    fdmnote_add(&st, "第二条：给主人看", 60, 400);
    char *js = fdmnote_serialize(&st);
    printf("存档 JSON:\n%s\n\n", js);

    fdmnote_state rt;
    fdmnote_parse(js, &rt);
    printf("往返 count=%zu idx=%d\n", rt.count, rt.idx);
    for (size_t i = 0; i < rt.count; i++)
        printf("  [%zu] x=%.0f y=%.0f  「%s」\n", i, rt.items[i].x, rt.items[i].y, rt.items[i].text);
    free(js);
    fdmnote_free(&st);
    fdmnote_free(&rt);
    return 0;
}
