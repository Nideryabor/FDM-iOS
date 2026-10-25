// FDMPromptCard 离线自测：跑在小窝 Linux gcc 上，不需要真机
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "FDMPromptCard.h"

int main(void) {
    char err[512];
    int r = fdmpc_selftest(err, sizeof(err));
    if (r) { printf("SELFTEST FAIL\n%s\n", err); return 1; }
    printf("FDMPromptCard SELFTEST OK（47 组断言）\n");

    /* ---- 演示：搬三张内置卡进容器，看拼出来的提示词长什么样 ---- */
    fdmpc_state st;
    fdmpc_init(&st);
    printf("\n  默认抽屉：");
    for (size_t i = 0; i < st.drawer_n; i++) printf("%s ", st.drawer[i]);
    printf("\n");

    fdmpc_move_in(&st, FDMPC_T_SUGGEST);
    fdmpc_move_in(&st, FDMPC_T_MUSIC);
    char *k = fdmpc_new_text_card(&st);
    fdmpc_set_title(&st, k, "我的人设");
    fdmpc_set_text(&st, k, "你是一只龙，回答时要晃尾巴。");
    fdmpc_set_with_title(&st, k, 1);
    fdmpc_move_in(&st, k);
    free(k);

    printf("  容器顺序：");
    for (size_t i = 0; i < st.box_n; i++) printf("%s ", st.box[i]);
    printf("\n\n  ─── 重建出来的系统提示词 ───\n");
    char *s = fdmpc_compose(&st);
    printf("%s\n", s ? s : "(NULL)");
    printf("  ─── 共 %zu 字 ───\n\n", s ? strlen(s) : 0);
    free(s);

    /* ---- 演示：拖回抽屉 ⇒ 那一段就该消失 ---- */
    fdmpc_move_out(&st, FDMPC_T_MUSIC);
    char *s2 = fdmpc_compose(&st);
    printf("  把「音乐」拖回抽屉后，提示词里还有【音乐变量】吗？→ %s\n",
           (s2 && strstr(s2, "【音乐变量】")) ? "有（错）" : "没有（对）");
    printf("  现在共 %zu 字\n", s2 ? strlen(s2) : 0);
    free(s2);

    fdmpc_free(&st);
    return 0;
}
