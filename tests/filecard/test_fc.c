#include "FDMFileCard.h"
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    char err[512];
    int r = fdmfc_selftest(err, sizeof(err));
    if (r) { printf("SELFTEST FAIL\n%s\n", err); return 1; }
    printf("FDMFileCard SELFTEST OK（20 组断言）\n\n");

    fdmfc_list l;
    fdmfc_defaults(&l);
    char *s = fdmfc_serialize(&l);
    printf("默认配置（这就是设置页文本框里的内容）:\n%s\n", s);
    free(s);
    fdmfc_free(&l);

    printf("宽容解析测试：\n");
    const char *cases[] = {
        "A|1",
        "A",
        "A|a|b",
        "  A  |  1  ",
        "A|1\r\nB|2",
        "A｜全角",
        "\n\n\n",
    };
    for (int i = 0; i < 7; i++) {
        fdmfc_list t;
        fdmfc_parse(cases[i], &t);
        printf("  「%-16s」→ %d 条: ", cases[i], t.count);
        for (int j = 0; j < t.count; j++) printf("[%s→%s] ", t.items[j].label, t.items[j].prompt);
        printf("\n");
        fdmfc_free(&t);
    }
    return 0;
}
