# AGENTS.md — 协作规则（本仓库）

本仓库是 Codename Engine 1.1.0（官方代码）+ 从用户 1.0.1 分支迁移来的加密/打包功能。
分支只有 `main`（本地与远端同名）；baseline 提交 `112aa91`（纯 1.1.0，已打 tag `baseline/upstream-1.1.0`），迁移提交 `e9ac49b`；上游 `main` 已在 `130391f4` 并入（`afe74668`，2026-10-31）。

## 0. 文档地图（改文档前先看这里）

| 文件 | 内容 | 归属 |
| --- | --- | --- |
| `README.md` | 仓库门面：本 fork 是什么、新增了什么、构建方法、上游 Usage Info / Credits | 本 fork 维护（英文） |
| `docs/RE-ENCRYPTION.md` | 加密功能说明书：容器格式、脚本四层、密钥与 token、编辑器用法、能力边界 | 本 fork 维护（中文，源码注释为英文） |
| `AGENTS.md` | 本文件：协作规则、交付清单、构建备忘、文档地图 | 本 fork 维护 |
| `FEATURES.md` / `CHANGELOG.md` / `PATCHNOTES.md` | 上游 1.1.0 原文 | **上游，不改正文** |
| `building/README.md` | 上游编译指南 | **上游，不改正文** |
| `building/cne-windows.bat` / `setup-windows.bat` / `generate-docs-windows.bat` / `libs.xml` | 上游 CLI 与库清单（`cne build/test/release/setup/run/optimize`） | **上游，不改** |
| `building/*-unix.sh` | 上游 unix 辅助脚本 | **本 fork 已删除**（只维护 Windows；恢复见下） |
| `building/lazy-build.md` + `building/{Build.bat,lazy-build.ps1}` | 一键编译包：双击即装工具链、检查库/ndll/MSVC、编译、报错翻译 | 本 fork 新增（中文说明，脚本注释为英文） |
| `building/.gitignore` | 排除 `building/toolchain/`（下载的工具链）与 `building/logs/` | 本 fork 新增 |

文档规则：

- 上游文档**只允许在开头加一段"Upstream document, kept unmodified"来源说明**，正文一律不动——这样以后和上游 diff 时不会产生噪声。
- 上游文档描述的是基座引擎，不代表本 fork 有能力差异；fork 新增功能只写进 `README.md` 与 `docs/RE-ENCRYPTION.md`。
- `docs/RE-ENCRYPTION.md` 里的格式/数值/路径必须能在源码注释里找到对应（容器布局、KDF 轮数、缓存目录名等），改了源码就同步改文档。

## 1. 不要大动官方代码

- 优先把功能做成**新增文件/新增分支**（如 `ModPackCrypto.hx`、`ZipPassword.hx`），而不是重写官方实现。
- 必须修改官方文件时，**只做最小侵入的定点修改**：能加守卫、加一层 fallback、加一个可选分支，就不要重构、不要改名、不要搬代码。
- 官方文件里被改动的位置要用简短注释说明"为什么"（一句即可），方便以后对上游 diff。
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
10. **不吹**：不写"已完全修复/100% 安全"这类无依据的结论。

## 4. 构建备忘

一键（推荐，会自己找/装 Haxe+Neko、查库与 ndll、查 MSVC）：双击 `building/Build.bat`，详见 `building/lazy-build.md`。

手动：

```powershell
$env:Path='D:\FNF\Haxe\4.3.7\haxe;D:\FNF\Haxe\4.3.7\neko;'+$env:Path
haxelib run lime build windows -nocolor   # 构建前先关掉运行中的 CodenameEngine.exe
```

## 5. 回滚

- 引擎仓库：回退单个提交用 `git revert <sha>`；整树回到纯 1.1.0 用 `git reset --hard baseline/upstream-1.1.0`。
- 远端只保留 `main`（2026-10 清理）。原 17 个远端分支（`archive/*`、`al-mobile`、`old`、`strum-divorce` 等）的 SHA 已保存为本地 tag `backup/remote/<原分支名>`；需要恢复某个分支时执行 `git push origin backup/remote/<原分支名>:refs/heads/<原分支名>`。
- 迁移来源仓库：`D:/FNF/FNF code/_mig`（`558aa9a` = upstream v1.0.1，`7cd0863` = 用户改动树）。
- 用户 1.0.1 参考树：`D:/FNF/FNF code/old`。
