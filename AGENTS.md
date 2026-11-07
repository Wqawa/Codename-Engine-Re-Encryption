# AGENTS.md — 协作规则（本仓库）

本仓库是 Codename Engine 1.1.0（官方代码）+ 从用户 1.0.1 分支迁移来的加密/打包功能。
分支只有 `main`（本地与远端同名）；最早提交 `112aa91`（纯 1.1.0 快照，已打 tag `baseline/upstream-1.1.0`），
迁移提交 `e9ac49b`。上游 `main` 合过两次：2026-10-31（上游 `afe74668`，合并提交 `130391f4`）、
2026-11-06（上游 `450ab5b5`，压成单个提交）。

上游远端叫 `upstream`（`https://github.com/CodenameCrew/CodenameEngine`）。**历史是断的，而且要保持断**：
基线是文件快照、不是上游提交的后代；上游有 3500+ 个提交和大量资源，把它们接进历史意味着 push 要把
整段历史的对象都传上去（本仓库是 `blob:none` 部分克隆，这些 blob 本地根本没有），所以每次合上游
**只合树、不接历史**，压成一个普通提交。

三方合并用一次性的 graft 拿共同祖先：

```bash
git fetch upstream --filter=blob:none --no-tags
git replace --graft 99c24d9d <上次合过的上游 SHA>   # 99c24d9d 的树 = afe74668 的树
git merge --no-commit --no-ff upstream/main        # 正常出冲突标记
# 解冲突 → git replace -d 99c24d9d → git reset --soft HEAD（退回合并前）→ 一个普通提交
```

`git replace -l` 必须回到空。冲突处理：以官方为准，本 fork 必须保留的定点注入（`.temp` →
`.cne/temp`、`updateTitle` 的空窗口守卫等）记在 `docs/SESSION_CHANGES.md` 的合并章节里。

历史状态（2026-11-06 更新）：仓库仍是 `blob:none` 部分克隆，旧版本的文件内容在本机首次访问时
按需从远端拉取（`git show <旧提交>:<路径>` 会自动联网）。

## 0. 文档地图（改文档前先看这里）

| 文件 | 内容 | 归属 |
| --- | --- | --- |
| `README.md` | 仓库门面：本 fork 是什么、新增了什么、构建方法、上游 Usage Info / Credits | 本 fork 维护（英文） |
| `docs/RE-ENCRYPTION.md` | 加密功能说明书：容器格式、脚本四层、密钥与 token、编辑器用法、能力边界 | 本 fork 维护（中文，源码注释为英文） |
| `docs/ARCHITECTURE.md` | 架构接缝图：43 个新增文件的分组、21 个官方文件接缝点（文件 + 调用函数）、启动到播放的调用链、数据在磁盘/内存的位置、偏离量的 blob 复量法 | 本 fork 维护（中文）；改接缝点必须同步这张表 |
| `docs/INTEGRITY.md` | 完整性校验：清单格式与签名、启动校验流程、差异分类、**防得住什么/防不住什么** | 本 fork 维护（中文）；每次构建后要重新生成清单 |
| `docs/SESSION_CHANGES.md` | 本轮改动记录：按功能分组记"改了什么、为什么"，以及明确没做的项 | 本 fork 维护（中文） |
| `docs/CODE_MAP.md` / `CODE_MAP.html` | 代码地图：包结构与各层职责、fork 新增文件落在哪 | 本 fork 维护（中文） |
| `AGENTS.md` | 本文件：协作规则、交付清单、构建备忘、文档地图 | 本 fork 维护 |
| `FEATURES.md` / `CHANGELOG.md` / `PATCHNOTES.md` | 上游 1.1.0 原文 | **上游，不改正文** |
| `building/README.md` | 上游编译指南 | **上游，不改正文** |
| `building/generate-docs-windows.bat` / `libs.xml` | 上游文档生成脚本与库清单（`cne build/test/release/setup/run/optimize` 的库表在 `libs.xml`） | **上游，不改** |
| `building/cne-windows.bat` / `setup-windows.bat` | 上游 CLI 包装（各两行，`haxe -cp commandline --run Main ...`） | **本 fork 已删除**：职责由 `building/Build.bat` 接管（首参是 `setup/help/test/build/run/release/test-release/optimize` 时转交引擎命令行；缺库时自动跑 `setup`）。恢复：`git checkout baseline/upstream-1.1.0 -- building/cne-windows.bat building/setup-windows.bat` |
| `building/*-unix.sh` | 上游 unix 辅助脚本 | **本 fork 已删除**（职责由下面的 `build-linux.sh` / `build-macos.sh` 接管；恢复见下） |
| `source/funkin/menus/PlaytestingWarningSubstate.hx` | 上游的旧版未保存提示（Alphabet 标题 + 红黄文字选项） | **本 fork 已删除**：试玩退出也走 `SaveWarning` 的同一个对话框，它成了没人画的死代码。恢复：`git checkout baseline/upstream-1.1.0 -- source/funkin/menus/PlaytestingWarningSubstate.hx` |
| `building/lazy-build.md` + `building/{Build.bat,lazy-build.ps1}` | 一键编译包：双击即装工具链、按 `libs.xml`/`project.xml` 查库并调引擎 `setup` 命令补齐（只有真补过库才问一句是否编译）、检查库/ndll/MSVC、编译、报错翻译；另接管上游 `cne-windows.bat` 的子命令转交 | 本 fork 新增（中文说明，脚本注释为英文） |
| `building/build-{linux,macos}.sh` | 同一套六步流程的 Unix 版：找/下载工具链、按 `libs.xml` 补库、查 lime 原生库、查 g++/clang（macOS 查 Xcode）、编译、验收；`--bootstrap-tools` / `--arch` / `--yes` 供 CI 使用 | 本 fork 新增（脚本注释为英文） |
| `building/.gitignore` | 排除 `building/toolchain/`（下载的工具链）与 `building/logs/` | 本 fork 新增 |

文档规则：

- 上游文档**只允许在开头加一段"Upstream document, kept unmodified"来源说明**，正文一律不动——这样以后和上游 diff 时不会产生噪声。
- 上游文档描述的是基座引擎，不代表本 fork 有能力差异；fork 新增功能只写进 `README.md` 与 `docs/RE-ENCRYPTION.md`。
- `docs/RE-ENCRYPTION.md` 里的格式/数值/路径必须能在源码注释里找到对应（容器布局、KDF 轮数、缓存目录名等），改了源码就同步改文档。

## 1. 不要大动官方代码

- 优先把功能做成**新增文件/新增分支**（如 `ModPackCrypto.hx`、`ZipPassword.hx`），而不是重写官方实现。
- 必须修改官方文件时，**只做最小侵入的定点修改**：能加守卫、加一层 fallback、加一个可选分支，就不要重构、不要改名、不要搬代码。
- 官方文件里被改动的位置要用简短注释说明"为什么"（一句即可），方便以后对上游 diff。
- 注释写**约束和坑**，不写设计自证。一句话能说清的就不要写成一段；不要用注释解释"我为什么这么设计"，
  除非不写清楚下一个人一定会踩。源码注释英文，文档中文。
- 绝不为了"整洁"顺手格式化/重排官方代码。

## 2. 改了官方代码必须显式告知

每次交付都要列出：

- 改了哪些**官方文件**（完整路径 + 行号）与哪些**新增文件**；
- 每个改动的**原因**，以及**不改会怎样**；
- 行为变化矩阵：旧行为 → 新行为，覆盖到所有相关入口；
- 回滚方式（`git revert <sha>` 或 `git checkout <sha> -- <file>`）。

## 3. 交付检查清单（防"AI 幻觉/屎山"）

在报告"完成"之前，逐条自查并把结果写进回复：

1. **真实性**：回复里提到的每个路径/行号/函数名/数值，都是本次真正读过或实证过的，不是猜的；不确定就写"未验证"。
2. **编译**：`haxelib run lime build windows -nocolor` 通过（日志里无 `error:`），产物 `export/release/windows/bin/CodenameEngine.exe` 时间戳已更新。
3. **API 存在性**：新调用的每个 API 都在源码/lime/hxcpp 里确认真实存在且签名匹配（不要凭记忆写 Flixel/Haxe API）。
4. **调用点全覆盖**：grep 确认同类问题/同类调用是否还有别处（例如多处保存入口），一并说明是修复还是刻意不改。
5. **边界情况**：null / 空字符串 / 目录不存在 / 路径是文件 / 跨分支 (#if sys 等) / 压缩包内虚拟路径，逐一说明走哪条分支。
6. **副作用**：确认没有改到存档格式、配置键、默认行为；若改了，单独列出并说明兼容性。
7. **回归面**：明确哪些旧功能可能受影响（列出具体功能点），并说明如何手工验证。
8. **实测**：只做**编译验证**（haxelib run lime build windows -nocolor 无 error、exe 时间戳更新）即可交付（用户 2026-10 的要求，眼睛和手由用户来验）；游戏内操作一律交给用户，明确列出"待用户验证"的步骤。
9. **提交**：一个逻辑改动一个 commit，message 说明根因与修法；工作区无遗漏的临时文件。
10. **推送**（用户 2026-10 的要求）：**编译通过之后才 `git push`**。编译没过就不上传，先在本地修好；
    宁可留在本地工作区，也不要让远端出现编不过的提交。
11. **不吹**：不写"已完全修复/100% 安全"这类无依据的结论。
12. **偏离可量化**：改动官方文件后，用 `docs/ARCHITECTURE.md` §2 末尾的 blob 对比法核一次
    ——确认偏离集合里只有你想改的文件，且每个文件只差你写的那几行。合并上游之后尤其要做，
    冲突解错的典型表现是"文件还是那个文件，逻辑被悄悄换回了旧版"。

## 4. 构建备忘

**编译一律走 `building/Build.bat`（用户 2026-11-07 的要求），不要直接敲 `haxelib run lime build`。**
它会自己找/装 Haxe+Neko、按 `libs.xml` 补库、查 lime 原生库与 MSVC，然后编译；缓存目录默认
`%LOCALAPPDATA%\cne-hxcpp-cache`。

```powershell
building\Build.bat -Yes      # 非交互；自动化/助手用这个
building\Build.bat -Clean    # 忽略 hxcpp 中间产物，整编
```

Linux / macOS 用 `building/build-linux.sh` / `building/build-macos.sh`（同一套六步，参数见 `building/lazy-build.md`）；
CI 也是调这三个。

## 5. 回滚

- 引擎仓库：回退单个提交用 `git revert <sha>`；整树回到纯 1.1.0 用 `git reset --hard baseline/upstream-1.1.0`（tag 可用，指向 `112aa91`）。
- 远端只保留 `main`（2026-10 清理）。原先记录的 17 个远端分支（`archive/*`、`al-mobile`、`old`、`strum-divorce` 等）用本地 tag `backup/remote/<原分支名>` 存 SHA，但**这批 tag 已丢失**（2026-11-01 仓库就地重建时未保留，远端也没有推送过），现在没有 SHA 就无法定位恢复，不要再去找这批 tag。
- 迁移来源仓库 `D:/FNF/FNF code/_mig`（`558aa9a` = upstream v1.0.1，`7cd0863` = 用户改动树）、用户 1.0.1 参考树 `D:/FNF/FNF code/old`：**本机已不存在**，此处只作历史记录。

## 6. 发版

- 版本号只有一处：`source/funkin/backend/system/Flags.hx` 的 `FORK_VERSION`（主界面左下角
  `CNE Re-Encryption vX.Y.Z`）。引擎自己的 `VERSION`（`project.xml` 的 1.1.0）**不要动**——
  它喂给脚本 define `CODENAME_VER` 和更新器的 tag 比较。
- tag 用轻量的 `re_vX.Y.Z`，指在发版那次提交上（参照 `re_v0.0.1` / `re_v0.0.2`）。
- 包名 `CNE-Re-Encryption-vX.Y.Z-Windows.zip`，内容取 `export/release/windows/bin`：
  `CodenameEngine.exe`、`lime.ndll`、`libvlc*.dll`、`assets/`、`plugins/`、`manifest/`、
  `mods/readme.txt`。**不带** `mods/` 里的测试包、`.cne/`、`*.dmp`、`imgui.ini`；
  文件平铺在压缩包根，和 0.0.1 一致。
- 打包前在**发布目录里**跑一次 `CodenameEngine.exe --generate-integrity`，让 `integrity.dat`
  描述的就是这一份文件，否则首启报"exe 与清单不符"（`exeDiffers` 只跳过 exe 那一行，不会静默）。
- 发布说明分四块：新增 / 修复（按主题分组）/ 性能 / 已知限制，末尾给
  `compare/<上一版 tag>...<本版 tag>` 链接。
