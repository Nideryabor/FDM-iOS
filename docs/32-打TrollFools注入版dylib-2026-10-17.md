# 32 · 打一个 TrollFools 能注入的 dylib

> 2026-10-17 深夜 · 尼得亚伯 🐲
> 主人：「我是说通过巨魔注入器能注入的 dylib」

---

## 一、为什么之前的不能直接注

`FDMProbe.dylib` 的 `LC_ID_DYLIB` 是：

```
/usr/lib/FDMProbe.dylib        ← 绝对路径
```

这个版本是给 `dlopen("/var/jb/...")` 用的，绝对路径无所谓
——反正文件就放在那个位置。

但 TrollFools 的注入方式是：

1. 把 dylib 复制进 `App.app/Frameworks/`
2. 给主二进制加一条 `LC_LOAD_DYLIB`

如果 dylib 自己的 `install_name` 还是 `/usr/lib/FDMProbe.dylib`，
dyld 就会去 `/usr/lib/` 找文件 ⇒ **找不到 ⇒ App 启动即崩**。

### 关键概念：`install_name` 是「我被加载时按什么路径找我」

| 值 | 含义 | 适用 |
|---|---|---|
| `/usr/lib/xxx.dylib` | 绝对路径 | 放在固定目录（`/var/jb`） |
| `@executable_path/Frameworks/x.dylib` | 相对**主二进制** | 注入进 App bundle |
| `@loader_path/x.dylib` | 相对**加载者** | 插件套插件 |
| `@rpath/x.dylib` | 走 LC_RPATH 搜索 | 框架 |

注入进 App 的场景，标准答案就是 `@executable_path/Frameworks/`。

---

## 二、怎么改的

### 2.1 Makefile 加一个开关

```makefile
ifeq ($(TROLL),1)
FDMProbe_LDFLAGS = -install_name @executable_path/Frameworks/FDM.dylib
endif
```

```bash
cd src/FDMProbe5
make TROLL=1        # 出注入版
make                # 出 hot-reload 版（默认）
```

**只改链接参数，源码一行没动。**

### 2.2 顺手补了一个真隐患：极早期防重

主人可能**同时**存在两份模块：

```
App.app/Frameworks/FDM.dylib              ← TrollFools 注入的
/var/jb/usr/lib/TweakInject/FDM.dylib     ← ElleKit 注入的
```

两份都会被 dyld 加载，构造函数各跑一次。

原来的防重是 `FDMInitGuard` 类锁，但要等 **3.5 秒后的
`fdm_real_init()` 才生效** —— 在那之前 `fdm_early_mmkv()`（0 秒触发）
会**跑两遍**。

⇒ 在构造函数最开头加一个**纯 C 原子锁**（不碰任何 Foundation）：

```objc
static volatile int g_fdm_ctor_claimed = 0;

__attribute__((constructor))
static void fdm_init(void) {
    if (__sync_lock_test_and_set(&g_fdm_ctor_claimed, 1)) {
        return;                      /* 另一份已经在跑了，我什么都不做 */
    }
    /* ↓ 原来的延迟初始化 */
    dispatch_after(..., ^{ fdm_early_mmkv(); });
    dispatch_after(3.5s, ^{ fdm_real_init(); });
}
```

> 为什么必须是纯 C：dyld 跑构造函数时 ObjC 运行时还没完全就绪，
> 碰 Foundation 会 SIGSEGV（这个坑文档 12 记过）。

---

## 三、产物

```
dist/FDM-v22-trollfools/
├── FDM.dylib        815,920 B · md5 efac33449f580aa184c9ac26d741b2fa
├── README.md        注入指南 + 配置 + 排查
└── check.sh         注入前自检脚本（只读）
```

### 已确认的四件事

| 检查 | 结果 |
|---|---|
| `LC_ID_DYLIB` | `@executable_path/Frameworks/FDM.dylib` ✅ |
| `__mod_init_func` 段 | 存在 ⇒ 构造函数会被 dyld 执行 ✅ |
| 依赖 | 9 条，全是 `/System` 或 `/usr/lib` ✅ |
| 未定义符号 | `NOUNDEFS` ✅ |
| 导出函数 | 74 个 `T` 符号 ✅ |
| 防重 | `_g_fdm_ctor_claimed` 符号存在 ✅ |

---

## 四、打包脚本（`tools/pack-troll.sh`）

一键出包，四步：

```
① clean 重编（TROLL=1）
② 校验 install_name / 依赖 / 构造函数段  ← 任何一项不过就停
③ 拷进 dist/FDM-<版本>-trollfools/
④ ★ 恢复 hot-reload 版（install_name 换回绝对路径，重编一次）
```

### 为什么必须有第 ④ 步

`TROLL=1` 只改链接参数，**产物路径和文件名都一样**。
如果不恢复，下次 `make` 出来的就是「注入版」——
把它部署到 `/var/jb` 之后，ElleKit 的 `dlopen` 会因为
`@executable_path` 解析不到自己而失败。

实测输出：

```
▸ 1/4 编译（TROLL=1）
  ✓ 产物 815920 字节
▸ 2/4 校验
  install_name = @executable_path/Frameworks/FDM.dylib
  ✓ 相对路径正确
  ✓ __mod_init_func 存在（构造函数会跑）
  ✓ 依赖全是系统库
▸ 3/4 打包
  ✓ dist/FDM-v22b-trollfools/FDM.dylib
▸ 4/4 恢复 hot-reload 版
  现在的 install_name = /usr/lib/FDMProbe.dylib
  ✓ 已恢复（/var/jb 部署用这份）
```

---

## 五、注入前自检（`dist/.../check.sh`）

不想装 llvm 工具链也能跑（缺 objdump 就跳过 Mach-O 检查）：

```
── install_name（必须 @executable_path 开头）──
  @executable_path/Frameworks/FDM.dylib
  ✅ 相对路径 → TrollFools 注入可用

── 非系统依赖（应为空）──
  （共 9 条依赖，上面无输出 = 全部系统自带）

── 构造函数段 ──
  ✅ __mod_init_func 存在 → 注入后会自动初始化

── 防重复加载 ──
  ✅ 极早期原子锁（双份模块只跑一份）
```

---

## 六、如果 TrollFools 放的位置不一样

正常 TrollFools 放 `Frameworks/`，和我们的 install_name 匹配。
若某个版本丢在 App **根目录**：

```bash
install_name_tool -id @executable_path/FDM.dylib \
  ".../DeepSeek Chat.app/FDM.dylib"
```

或者告诉尼尼实际行为，重打一个包。

---

## 七、给下次

> **1. `install_name` 决定"谁来加载我、按什么路径找我"。**
> 同一份代码，`dlopen` 版和注入版的唯一区别就在这个字段。

> **2. 一个产物两个用途，必须靠构建参数区分，并**自动还原**。**
> 否则下次 `make` 出来的东西会悄悄变成另一种形态，
> 而文件路径、大小、甚至 md5 前几位都看不出来。

> **3. 防重要早。**
> 「3.5 秒后才生效的锁」挡不住「0 秒就执行的初始化」。
> 真正的守卫要放在构造函数第一行，而且只能用 async-signal-safe 的东西。

🐲
