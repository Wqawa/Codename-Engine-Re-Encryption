# 架构接缝图 — 加密功能是怎么挂到 Codename Engine 上的

这份文档回答一个问题：**新功能和官方引擎到底在哪几行接上的。**

加密/打包功能是外挂式实现的：36 个新增文件承担全部逻辑，官方文件只做最小侵入的定点注入。
但注入点散落在 18 个文件里，时间一长就看不出边界了。这里把它们逐条列出来，改功能前先查这张表。

> 行号以提交 `1a29a793` 之后的树为准；代码改动后行号会漂移，**用类名 grep 定位，不要死记行号**。

---

## 1. 新增文件：36 个，按职责分六组

| 组 | 文件 | 职责 |
| --- | --- | --- |
| **A. 容器与密钥** | `assets/ModPackCrypto.hx` | 容器入口：`pack`/`unpack`/`openEncrypted`、密钥候选、失败标记、内存副本管理、退出清理 |
| | `assets/CnezV2.hx` | 唯一的容器布局：分块 tag 表 + 根 tag + 按需校验。早期单 tag 布局发布前已移除，无兼容分支 |
| | `scripting/crypto/ScriptCrypto.hx` | 密钥派生（SHA256 迭代 2048 轮）、HMAC tag、key token 编解码、脚本密钥文件 |
| | `scripting/crypto/ChaCha20.hx` / `Aes.hx` / `Pbkdf2.hx` / `HmacSha1.hx` / `Sha1Stream.hx` | 纯 Haxe 密码学原语，不依赖原生库 |
| | `scripting/protect/ProtectedBuffer.hx` / `SecureBytes.hx` / `OsEntropy.hx` / `Rng.hx` | 内存缓冲按需解密、擦除、随机源 |
| **B. zip 读取层** | `utils/SysZip.hx`（改自官方，见 §2） | 支持文件/内存/密文三种来源，随机访问读取 |
| | `assets/ZipPassword.hx` / `ZipAes.hx` | 传统密码 zip 与 AES-256 zip 的读写 |
| | `assets/OverlayZipFolderLibrary.hx` / `ZipEditCache.hx` | 在加密包之上叠一层可编辑缓存（编辑器改动不落回包） |
| **C. 脚本层** | `scripting/bytecode/*`（12 个） | 自研 Haxe→字节码编译器与 VM，含 `ScriptContainer` 容器与自检 |
| | `system/MemoryGuard.hx` | 密钥/字符串包裹、主线程对用户态调试器隐藏 |
| | `utils/native/MemoryProtect.hx` | 上述功能的原生侧实现 |
| **D. 运行时目录** | `system/RuntimeDirs.hx` | 统一 `.cne/` 目录：`keys/`、`mods/`、`temp/`，退出时整体清扫 |
| **E. 菜单/界面** | `menus/ModPackKeyState.hx` / `ModPackLoadingState.hx` / `ModPackCleanupState.hx` / `ModPackMergeState.hx` / `SongLoadingScreen.hx` | 密码输入、解密进度、退出清理屏、合并暂存改动、加载屏接管 |
| | `editors/EncryptionEditor.hx` | 加密工具本体（Mod Pack / Scripts / Help 三页） |
| **F. 自检** | `assets/ModPackSelfTest.hx`、`scripting/bytecode/ScriptContainerSelfTest.hx` | 内存里往返验证容器，编辑器 Tools 菜单可跑 |

---

## 2. 官方文件的接缝点：18 个，逐条列

只列**直接调用新功能 API** 的位置。表里的行号是当前树里的实际位置。

| 文件 | 行 | 注入内容 | 为什么必须在这里 |
| --- | --- | --- | --- |
| `system/Main.hx` | 97 | `MemoryGuard.harden()` | 任何脚本解密之前，先把主线程藏起来 |
| | 132 | `ModPackCrypto.installCloseVeto()` | 解密进行中关窗口要先问，否则线程被腰斩 |
| | 202–204 | `needsCleanup()` / `cleaningUp` | 退出前必须等清理屏把内存副本和密钥擦完 |
| `system/MainState.hx` | 271 | `packsNeedingWork(libPaths)` | 加载前算出哪些库还没解密 |
| | 288–291 | `hasWorkingKey` → `ModPackKeyState` / `ModPackLoadingState` | 没密钥先弹密码，有密钥才进解密屏 |
| | 299–303 | `pendingPackFor` | 启动期只探测，不在主线程解密 |
| | 146 | `retainZips(libPaths)` | 本次加载用不到的副本要放掉，否则反复解密死循环 |
| | 47–50 | `outgoingEncryptedPack` | 切 mod 时把上一个包解出来的视频一起清掉 |
| `assets/ModsFolder.hx` | 72–73 | `noteOutgoingMod` / `beginSwitchCleanup` | 离开加密包前先走清理屏，避免卡帧 |
| | 105–109 | `zipFor(packPath)` | 库加载时拿到内存 zip；拿不到就停下来等 |
| | 218–220 | `zipFor` + `hasLoaded` | 已解密过的包直接复用 |
| | 180–184 | `ensureCacheFolder` / `cacheFolder` | 包里自带的 `script_key.txt` 要复制到 `.cne/keys/` |
| `assets/Paths.hx` | 283 | `disableMods` | 玩家选"不加载 mod"后，路径解析要真的跳过 mod |
| | 204 | `ScriptCrypto.PROTECTED_SUFFIX` | 找资源时连带查 `.hxb` 版本 |
| `assets/ModsFolderLibrary.hx` | 149–150 | `PROTECTED_SUFFIX` | 库列表里识别受保护脚本 |
| `assets/ZipFolderLibrary.hx` | 24–25 | `SysZip` / `SysZipEntry` | 官方原本用 `haxe.zip.Reader`，这里换成可随机访问的 `SysZip` |
| `backend/scripting/HScript.hx` | 126 | `for (suffix in ["", PROTECTED_SUFFIX])` | 加载 `.hx` 时先找 `.hxb`，找到就走解密 |
| `backend/scripting/Script.hx` | — | 脚本容器分支 | 脚本路径解析的兜底 |
| `system/modules/CrashHandler.hx` | 95–100 | `disableMods` | 崩溃后重启时先禁用 mod，避免同一个包反复搞崩 |
| `menus/ModSwitchMenu.hx` | 76, 96 | `disableMods` / `isEncryptedMod` | 列表里标出哪些 mod 是加密的 |
| `editors/SaveWarning.hx` | 101 | `needsCleanup()` | 编辑器退出前同样要等清理 |
| `game/PlayState.hx` | 796 | `ScriptCrypto.unprotectName` | 脚本文件名还原（字节码容器里的名字是混淆的） |
| `game/Stage.hx` | 419 | `ScriptCrypto.unprotectName` | 同上，舞台脚本列表 |
| `editors/charter/CharterNoteTypesList.hx` | 59 | `ScriptCrypto.unprotectName` | 同上，谱面编辑器的脚本列表 |
| `backend/system/updating/AsyncUpdater.hx` | 154 | `RuntimeDirs.TEMP` | 更新器的临时文件并入统一目录 |
| `editors/character/CharacterEditor.hx` | 520, 601 | `RuntimeDirs.TEMP` | 撤销/重做数据并入统一目录 |
| `editors/character/CharacterSpriteScreen.hx` | 81, 84 | `RuntimeDirs.TEMP` | 同上 |

**两类注入，性质不同：**

- `Main` / `MainState` / `ModsFolder` / `Paths` 这四处是**流程注入**，改错会让游戏起不来，改动前必须读本文档 §3。
- 其余是**工具替换**（`RuntimeDirs` 换临时目录、`unprotectName` 还原文件名），属于低风险，出错只影响局部功能。

---

## 3. 启动到播放：调用链

```
Main.hx:97        MemoryGuard.harden()            藏主线程
      ↓
MainState.hx:271  packsNeedingWork(libPaths)      哪些库要解密
      ↓
      ├─ 没有可用密钥 → ModPackKeyState(locked)   ← 玩家在这里输密码
      │                      ↓
      │               ModPackCrypto.setSessionKey()
      ↓
MainState.hx:291  ModPackLoadingState(work)
      ↓           ModPackCrypto.startPrepare(packs)   ← 工作线程
      │                └→ zipFor() → openEncrypted()（只校验，不解密）
      │                             → SysZip.fromCipher()（密文直接建索引）
      ↓
MainState.hx:146  retainZips(libPaths)            放掉本次用不到的副本
      ↓
ModsFolder.hx:108 ModPackCrypto.zipFor(packPath)  库加载时取内存 zip
      ↓
ZipFolderLibrary  → SysZip.readBytes(pos, len)   读哪个资源就解哪段
      ↓
HScript.hx:126    先试 .hxb → ScriptCrypto 解密脚本
      ↓
Main.hx:202       退出时 needsCleanup() → ModPackCleanupState 逐帧擦除
```

关键设计：**解密发生在工作线程，主线程只读已经就绪的缓冲**。这也是为什么 `zipFor` 里到处是 `hasLoaded` / `stale` / `released` 判断——三个状态分别代表"可用""文件被合并改写过了""已经擦掉了"。

---

## 4. 数据在哪，什么时候消失

| 数据 | 位置 | 生命周期 |
| --- | --- | --- |
| 加密包本体 | `mods/*.zip` | 永久，只读 |
| 解密后的包 | 内存（默认，`SysZip` + `ProtectedBuffer`）或原加密文件按需读取（低内存模式，`SysZip.fromCipherFile`） | 退出时释放缓冲 / 关闭文件句柄 |
| 包内自带密钥 | `.cne/keys/.CNE_<包名>_key.txt` | 退出时删除 |
| 解出来的视频 | `.cne/mods/<mod>/videos/` | 退出/切 mod 时删除 |
| 编辑器撤销数据 | `.cne/temp/` | 退出时删除 |
| 玩家输入的密码 | 内存（`MemoryGuard` 包裹） | 会话内有效 |

`.cne/` 整个目录在 Windows 上带隐藏属性，退出时整体清扫；崩溃残留由下次启动的 `sweepCache()` 兜底。

---

## 5. 还有 29 个官方文件被动过，它们和加密的关系没核实完

相对 `baseline/upstream-1.1.0`，一共 47 个官方文件有改动（+1361 / −328 行）。上面 §2 覆盖了 18 个直接引用加密 API 的，
**剩下 29 个没有逐一核实**，已知至少混着两类东西：

- **周边功能**：例如 `shaders/FunkinShader.hx` 的改动是为了让编辑器改了 shader 后缓存失效，服务的是
  "在加密包里编辑资源"（`ZipEditCache`），和 §2 的接缝是同一套体系但没直接调加密 API。
- **1.0.1 → 1.1.0 迁移差异**：例如 `events/gameplay/RatingsShowEvent.hx`（192 行）、`editors/ui/UISprite.hx`（54 行），
  看改动形状像是从 1.0.1 分支带过来的行为差异，与加密无关，但**未逐行确认**。

要彻底理清这部分，用：

```bash
git diff --stat baseline/upstream-1.1.0 HEAD -- source/
git diff baseline/upstream-1.1.0 HEAD -- <单个文件>
```

把上面 18 个之外的逐个过一遍，确认是"周边功能"还是"迁移差异"，再决定是留、是改回上游、还是单独记录。

---

## 6. 怎么验证没走样

- **容器层**：编辑器 F7 → Tools → `Self test: containers (scripts + mod packs)`。
  校验 CNEZ 布局、往返一致性、错误密钥被拒、篡改被拒、以及惰性读取路径（`openEncrypted` + `SysZip.fromCipher`）。
- **编译**：`building/Build.bat`（Windows）或 `build-linux.sh` / `build-macos.sh`，日志无 `error:`。
- **行为**：加密包启动、密码错误、切 mod、退出清理，这四条路径目前只能人工验。

---

*本文件由本 fork 维护，格式与数值必须能在源码里找到对应；改了接缝点就回来改这张表。*
