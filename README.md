# ios-port · FuckDSManger iOS 移植

把安卓 LSPosed 模块 **FuckDSManger** 移植到 iOS。

**宿主**：DeepSeek Chat · `com.deepseek.chat`
**设备**：iPhone 7P (A10/iPhone9,2) · iOS 15.8.4 · Dopamine（rootless）
**方式**：小窝交叉编译 → TrollFools 注入 Loader → hot-reload

> 许可证：[PolyForm Noncommercial 1.0.0](LICENSE) —— 与安卓版一致，**禁止商业使用**
> 三方声明：[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)
> 作者：尼得亚伯 (Nideryabor) & dxyabab

---

## 📦 安装（TrollFools 注入）

去 [Releases](https://github.com/Nideryabor/FDM-iOS/releases) 下最新版的
`FDM.dylib`（或整个 `FDM-xxx-trollfools.tar.gz`，里面带注入说明）。

1. 把 `FDM.dylib` 传到手机（Filza / 文件 App）
2. 打开 **TrollFools** → 选 `DeepSeek Chat` → `+` → 选这个 dylib → 注入
3. **完全退出** App（上滑杀掉）再打开
4. 进「设置」页，列表底部应出现「FDM 模块设置」

> ⚠️ **两条路线不要同时开**。本仓早期用的是 ElleKit 路线
> （`/var/jb/usr/lib/TweakInject/FDM.dylib`）。
> 现在统一走 TrollFools 直注 —— 那个旧文件要停用/删掉，
> 否则两边抢着加载（虽然模块有单实例锁，但配置会被读两遍，行为很难懂）。

**装好没怎么验**：`Documents/fdm.log` 里应该有

```
[sys] FDM v7.1 已加载  pid=xxxxx
[cfg] 功能注册完成：26 页 / 266 项
```

---

## 🎯 现状（2026-10-24）

| 环节 | 状态 |
|---|---|
| 交叉编译环境（Ubuntu aarch64 → iOS arm64） | ✅ 跑通 |
| 宿主静态勘察 / 架构全解 | ✅ 完成 |
| 系统提示词注入（零宽字符） | ✅ **真机验通** |
| 服务端设置覆盖 | ✅ **真机验通** |
| 回复建议 / 招呼用语 | ✅ modelConfig 改写生效 |
| 原生设置界面（树形，对齐安卓 Tree.kt） | ✅ 上线 |
| **hot-reload 自动迭代闭环** | ✅ **30 秒一轮** |
| 账号头像（本地图 / URL） | ✅ **真机验通** |
| **音乐加密层（eapi/weapi/linuxapi）** | ✅ 与 Java 版**逐字节对拍**通过（无需真机） |
| **音乐 API（搜索/播放地址/歌词/详情）** | ✅ 协议已真请求验证 |
| **音乐播放全链（v64 · 队列/循环/降级/存档）** | ✅ 内核 47 条断言 · ⏳ 待真机 |
| **悬浮迷你卡（播放页 + 搜索页）** | ✅ 代码完成 · ⏳ 待真机 |
| **点歌 `⟦DJ:歌名-歌手⟧`（15 秒去重）** | ✅ 已接进富文本 · ⏳ 待真机 |
| **{music}/{lyric} 变量供数** | ✅ **v64 接上**（v63 之前永远是空串） |
| **提示词变量引擎 / LRC 解析** | ✅ 35 条离线断言全过 |
| **液态玻璃（iOS 26 材质强开）** | ✅ **真机可用**（T3 + 早期注入 + cell 复用补叠） |
| 气泡纯诊断模式 | ✅ 真机可用（`fdm-bubble.json` 里 `diag:true`，输出几何 dump） |
| **助手图片** | ✅ **真机可用**（v62 · 22px 塞在实测的 24px 缝里，见 docs/39）|
| **对话气泡设置** | ✅ **真机可用**（v61 · 颜色/圆角，见 docs/37） |
| 悬浮便签 | ✅ 真机可用（可拖/编辑/缩放/最小化） |
| 文件快捷选项 | ⏸ 主人说不需要 |
| **账号名（内存缓存修复）** | ✅ **真机验通**（改 `nameLabel` 绕过内存缓存） |
| 播放器 / 迷你卡 | ✅ 代码完成（v64）· ⏳ 待真机 |
| 网易云登录 UI（短信/密码） | ❌ 未做（现在只能塞 cookie） |
| 防撤回 / 设备伪装 | ❌ 按要求跳过 |

---

## 🚀 一键迭代（推荐）

**没有真机时**（纯离线自证）：

```bash
bash tests/run-all.sh              # 8 套 188 条断言（音乐×3/玻璃/气泡/便签/文件快捷）
```

**有真机时**（一键迭代）：

```bash
bash tools/cyc.sh                  # 编译→部署→校验→重启→进会话→截图→捞日志
bash tools/cyc.sh -t v5 -c 2       # 换标签、进第 2 个会话
bash tools/cyc.sh -g 'sug|补扫'    # 只捞匹配的日志
bash tools/cyc.sh -l D             # 先把设备日志级别热切到 D（不用重启）
bash tools/cyc.sh -s               # 只截图 + 捞日志（不编不部署）
bash tools/cyc.sh -S               # 强制重编（make 认为没变时用）
```

> ⚠️ **别把编译和部署并行跑** —— dep.sh 会拿到上一版产物（血泪两次）。
> cyc.sh 已经用「产物 mtime + 设备回读大小」串成串，一步不过就停。

底层小工具（都是能单独用的）：

| 脚本 | 作用 |
|---|---|
| `tools/dep.sh` | 编译产物 → 设备 + 回读校验 |
| `tools/rc.py "命令"` | 在设备上跑 shell（参数原样传，不用跟引号打架） |
| `tools/shot.py 文件.png` | 截屏存本地 |
| `tools/mcp2.py <工具> [json]` | 直接调 ios-mcp 的 46 个工具 |

**日志级别热切换**（2026-10-17 新增）：

```bash
echo D > Documents/fdm-log.txt     # 2 秒内生效，无需重启
echo W > Documents/fdm-log.txt     # 切回
```

**建议按钮诊断**（默认关）：

```bash
echo 1 > Documents/fdm-sugdiag.txt  # 打开锚点/矩形/扫描日志
```

---

## 🏗 架构

```
App bundle（TrollFools 注入，已冻结）
  └─ FDMLoader.dylib → dlopen("/var/jb/usr/lib/TweakInject/FDM.dylib")
                            ↓
/var/jb/usr/lib/TweakInject/FDM.dylib  ← 尼尼随便换（就是它）
  ├─ FLog        日志框架（5级+9分类+崩溃保护）
  ├─ FDMConfig   配置树（缓存+已修改追踪）
  ├─ FDMFeatures 功能声明（加功能=加一行）
  ├─ FDMBeauty   UI 美化 hook
  ├─ FDMUI       原生设置界面
  └─ FDMProbe    主探针
```

---

## 📁 目录

```
ios-port/
├── README.md                    ← 本文件
├── docs/
│   ├── 00-索引.md               ⭐ 32 篇日记的分类索引
│   ├── 01~24                    分阶段勘察 / 血案记录
│   ├── 25-建议按钮v4-问UITextView要矩形.md   ⭐ 矩形从哪来
│   ├── 26-流水线脚本与三个底噪修复.md  ⭐ cyc.sh / 热切换日志 / 补扫
│   ├── 27-设置页导航栏与会滚的壁纸.md  ⭐ 透明导航栏的边界
│   ├── 28-模块入口搬进宿主设置列表.md  ⭐ tableFooterView 方案
│   ├── 29-账号头像-只换图不动名字.md  ⭐ FooterView 的 avatar ivar
│   ├── 30-今夜总结-v21.md       ⭐ 最新状态 + 方法论
│   ├── 31-密钥集中到env.md      ⭐ 口令搬家 + git 历史查证
│   └── 12-项目总总结.md         整体视角（v7.1 阶段）
├── src/
│   ├── FDMLoader/               ⭐ TrollFools 注入这一个
│   ├── FDMProbe5/               ⭐ 当前主线（hot.dylib）
│   └── FDMProbe~4/              历史版本（v0.2~v0.6）
├── tools/
│   ├── cyc.sh            ⭐ 一键迭代（编→部署→校验→重启→截图→日志）
│   ├── dep.sh                   编译产物 → 设备 + 回读校验
│   ├── mcp2.py                  直接调设备 ios-mcp（46 工具）
│   ├── shot.py                  截屏存本地
│   ├── rc.py                    在设备上跑 shell
│   ├── mcp.sh                   老的 MCP 包装（shell 版）
│   ├── iphone.sh                SSH 远程控制
│   ├── free.sh                  腾内存（7P 只有 2G）
│   ├── mmkv_patch.py            MMKV 离线改写（★ 别删 .crc）
│   ├── wd.py                    WebDAV 客户端
│   ├── pull.sh                  拉日志
│   └── sync.sh                  编译+推送
├── out/                         各版本 dylib
├── analysis/                    静态分析产物 + 自研工具
│   ├── ios-settings-full.json   59 项设置表
│   ├── mmkv-dump/               解析出的 KV
│   ├── raw-evidence/            原始证据
│   └── mstr.py / xref.py / selref.py   Mach-O 分析工具
├── app/                         解压后的宿主
└── env.sh / setup-toolchain.sh  环境
```

---

## 🔑 关键结论速查

| 问题 | 答案 |
|---|---|
| 宿主架构 | arm64 thin · minOS 15.0 |
| MMKV | ✅ 1.3.9，两个实例（`mmkv.default` + 用户 UUID） |
| `kv_settings_` 前缀 | ❌ 不存在（裸名） |
| 服务端设置 | 一个 **43KB blob** `app.ab.serverValues`（59 项 / version 93） |
| 模型配置 | `modelConfig_N`（JSON 数组，含 welcome_msg / prompt_feature） |
| 协议有 system 通道吗 | ❌ 没有 → 零宽字符是唯一路 |
| 沙盒能 dlopen 哪 | **只有 `/var/jb/`**（Documents 被 block mmap） |
| sudo 能写什么 | ✅ `/var/mobile` `/var/jb` ❌ `/System`（SSV 保护） |
| 崩溃最常见原因 | Hook 太重 / Swap 不幂等 / `%@` 传 char* |
| 宿主允许 http 吗 | ❌ `NSAllowsArbitraryLoads=false` ⇒ 播放/图片地址必须换 https |
| 网易云播放地址协议 | 返回 http，但**同路径 https 也能 206** ⇒ 客户端换掉即可 |
| 网易云 eapi 的 key | `e82ckenh8dichen8`，分隔符 `-36cd479b6b5-` |

---

## ⚠️ 安全提醒

| 项 | 建议 |
|---|---|
| **WebDAV `:8080` 无认证** | ⚠️ **建议加密码**或不用时关闭 |
| SSH `:2222` + sudo 无限制 | 只在局域网，密码别外泄 |
| `/var/mobile` 全可读写 | 尼尼承诺只碰本项目的 App |

---

## 🐲 环境

| 项 | 值 |
|---|---|
| 小窝 | Ubuntu 24.04 aarch64 |
| iPhone SSH / WebDAV / 沙盒路径 | **全部在 `.env`**（见下） |
| 模块本体 | `/var/jb/usr/lib/TweakInject/FDM.dylib` |

---

## 🔐 配置（第一次用必看）

脚本里**不含任何口令**，全部从项目根的 `.env` 读。

```bash
cd /workspace/ios-port
cp .env.example .env
chmod 600 .env          # ★ 一定要收紧权限
$EDITOR .env            # 改 IPHONE_PW 等
```

`.env` 已被 `.gitignore` 挡住，不会进版本库。

| 变量 | 说明 |
|---|---|
| `IPHONE_HOST` / `IPHONE_PORT` / `IPHONE_USER` | SSH 目标 |
| `IPHONE_PW` | ★ SSH 口令（必填，脚本里没有默认值） |
| `IOS_MCP_HOST` / `IOS_MCP_PORT` | 设备上的 ios-mcp |
| `APP_DOCS` | 宿主 App 的 Documents 绝对路径（重装会变） |

自检：

```bash
./tools/env.py          # 打印读到的配置（口令只显示长度）
```

> 找不到 `.env` 或关键项缺失时，脚本会**直接报错退出**，
> 绝不回退到任何内置默认口令 —— 「悄悄用旧密码」比「直接失败」危险得多。
