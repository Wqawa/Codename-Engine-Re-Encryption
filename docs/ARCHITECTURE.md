# 架构接缝图

这份文档回答一个问题：**加密功能和官方引擎到底在哪几处接上的。**

实现是外挂式的：42 个新增文件承担全部逻辑，官方文件只做定点注入。但改动散在几十个官方文件里，
时间一长就看不出边界了。这里按模块列一遍，改功能前先查这张表。

> 表里写**文件和函数名**，不写行号。行号每次改动都会漂，写死只会得到一份过期的表；
> 找调用点用 `grep -n "ModPackCrypto\." <文件>`。文件数同理，要现成的数字就跑
> `git diff --name-only baseline/upstream-1.1.0..HEAD -- source`。

---

## 1. 新增文件：42 个，按职责分七组

| 组 | 文件 | 职责 |
| --- | --- | --- |
| **A. 容器与密钥** | `assets/CnezV2.hx` | 唯一的容器布局：分块 tag + 根 tag，按需校验。早期单 tag 布局发布前已移除，没有兼容分支 |
| | `assets/ModPackCrypto.hx` | 容器入口：选密钥、内存副本、失败标记、退出清理 |
| | `scripting/crypto/ScriptCrypto.hx` | 密钥派生（SHA256 迭代 2048 轮）、HMAC tag、key token 编解码、脚本密钥文件 |
| | `scripting/crypto/{ChaCha20,Aes,Pbkdf2,HmacSha1,Sha1Stream}.hx` | 纯 Haxe 密码学原语，不依赖原生库 |
| | `scripting/protect/{ProtectedBuffer,SecureBytes,OsEntropy,Rng}.hx` | 缓冲按需解密、擦除、随机源 |
| **B. zip 读取层** | `utils/SysZip.hx` | 文件 / 内存 / 密文三种来源的随机访问读取 |
| | `assets/{ZipPassword,ZipAes}.hx` | 传统密码 zip 与 AES zip 的读写 |
| | `assets/{OverlayZipFolderLibrary,ZipEditCache}.hx` | 在加密包之上叠一层可编辑缓存（编辑器改动不落回包） |
| **C. 脚本层** | `scripting/bytecode/*`（12 个） | 自研 Haxe→字节码编译器与 VM，含脚本容器和自检 |
| | `system/MemoryGuard.hx` | 密钥/字符串包裹、主线程对用户态调试器隐藏 |
| | `utils/native/MemoryProtect.hx` | 上面这条的原生侧实现 |
| **D. 运行时目录** | `system/RuntimeDirs.hx` | 统一 `.cne/`：`keys/`、`mods/`、`temp/`、`logs/`，退出时按类别清扫 |
| **E. 菜单/界面** | `menus/{ModPackKeyState,ModPackLoadingState,ModPackCleanupState,ModPackMergeState,SongLoadingScreen,IntegrityScreen}.hx` | 密码输入、解密进度、退出清理、合并暂存改动、加载屏、启动校验 |
| | `menus/{PopupScreen,PopupProgress}.hx` | 上面六个屏共用的外壳：原版 `normal-popup` 弹窗（30px 标题栏、25px 内边距、160×30 按钮行）+ 按 `UISlider` 画的只读进度条 |
| | `editors/EncryptionEditor.hx` | 加密工具本体（Mod Pack / Scripts / Help 三页） |
| **F. 完整性校验** | `system/IntegrityCheck.hx` | 清单生成与校验：签名、逐条 SHA256、差异分类 |
| **G. 自检** | `assets/ModPackSelfTest.hx`、`scripting/bytecode/ScriptContainerSelfTest.hx` | 内存里往返验证容器，编辑器 Tools 菜单可跑 |

---

## 2. 官方文件的接缝点：20 个

只列**直接调用新功能 API** 的位置。

| 文件 | 调用点 | 为什么必须在这里 |
| --- | --- | --- |
| `system/Main.hx` | `MemoryGuard.harden()` | 任何脚本解密之前，先把主线程藏起来 |
| | `ModPackCrypto.installCloseVeto()` / `ZipEditCache.installClosingPrompt()` | 解密或合并在跑时关窗口要先问 |
| | `IntegrityCheck.startVerify()` | 窗口一起来就开工，不挡用户 |
| | `IntegrityCheck.generate()`（`--generate-integrity`） | 构建钩子，写完清单退出 |
| | `needsCleanup()` / `cleaningUp` | 退出前必须等清理屏把内存副本和密钥擦完 |
| `system/MainState.hx` | `packsNeedingWork(libPaths)` | 加载前算出哪些库还没解密 |
| | `IntegrityScreen(work, locked)` | 先校验文件，再问密码 / 进解密屏 |
| | `pendingPackFor` | 启动期只探测，不在主线程解密 |
| | `retainZips(libPaths)` | 本次加载用不到的副本要放掉，否则反复解密死循环 |
| | `outgoingEncryptedPack` | 切 mod 时把上一个包解出来的视频一起清掉 |
| `assets/ModsFolder.hx` | `noteOutgoingMod` / `beginSwitchCleanup` | 离开加密包前先走清理屏，避免卡帧 |
| | `zipFor(packPath)` | 库加载时拿到内存 zip；拿不到就停下来等 |
| | `ensureCacheFolder` / `cacheFolder` | 包里自带的 `script_key.txt` 要复制到 `.cne/keys/` |
| `assets/Paths.hx` | `disableMods` | 玩家选"不加载 mod"后，路径解析要真的跳过 mod |
| | `ScriptCrypto.PROTECTED_SUFFIX` | 找资源时连带查 `.hxb` 版本 |
| `assets/ModsFolderLibrary.hx` | `PROTECTED_SUFFIX` | 库列表里识别受保护脚本 |
| `assets/ZipFolderLibrary.hx` | `SysZip` / `SysZipEntry` | 官方原本用 `haxe.zip.Reader`，这里换成可随机访问的 `SysZip` |
| | `releaseForReplace()` / `reopenAfterReplace()` | 合并要 rename 换包，Windows 不允许 rename 被打开的文件；由 `ZipEditCache.replaceWith` 先松手、换完重读新包 |
| `backend/chart/Chart.hx` | `ZipEditCache.isPackedMod` / `Paths.getAssetsRoot()` | 打包 mod 只有一个可写位置（暂存目录），保存不再经资源树推算 |
| `backend/scripting/HScript.hx` | `for (suffix in ["", PROTECTED_SUFFIX])` | 加载 `.hx` 时先找 `.hxb`，找到就走解密 |
| `system/modules/CrashHandler.hx` | `disableMods` | 崩溃后重启时先禁用 mod，避免同一个包反复搞崩 |
| `menus/ModSwitchMenu.hx` | `disableMods` / `isEncryptedMod` | 列表里标出哪些 mod 是加密的 |
| `menus/MainMenuState.hx` | `IntegrityScreen.reportOnMenu(this)` | 没有加密包时，校验结果在这里显示 |
| `editors/SaveWarning.hx` | `needsCleanup()` | 编辑器退出前同样要等清理 |
| `game/PlayState.hx` | `ScriptCrypto.unprotectName` | 脚本文件名还原（字节码容器里的名字是混淆的） |
| `game/Stage.hx` | `ScriptCrypto.unprotectName` | 同上，舞台脚本列表 |
| `editors/charter/CharterNoteTypesList.hx` | `ScriptCrypto.unprotectName` | 同上，谱面编辑器的脚本列表 |
| `backend/system/updating/AsyncUpdater.hx` | `RuntimeDirs.TEMP` | 更新器的临时文件并入统一目录 |
| `editors/character/CharacterEditor.hx` | `RuntimeDirs.TEMP` | 撤销/重做数据并入统一目录 |
| `editors/character/CharacterSpriteScreen.hx` | `RuntimeDirs.TEMP` | 同上 |
| `system/Logs.hx` | `RuntimeDirs.LOGS` | 日志文件写进 `.cne/logs/` |
| `backend/utils/CoolUtil.hx` | `RuntimeDirs.LOGS` | 保存失败的那条记录（路径 + 异常）写进 `.cne/logs/save-errors.log` |

**两类注入，性质不同：**

- `Main` / `MainState` / `ModsFolder` / `Paths` 是**流程注入**，改错会让游戏起不来，改前先看 §3。
- 其余是**工具替换**（临时目录、文件名还原、日志路径），出错只影响局部功能。

---

## 3. 启动到播放：调用链

```
Main.hx                 MemoryGuard.harden()            藏主线程
      ↓
Main.hx                 IntegrityCheck.startVerify()    工作线程开始算哈希
      ↓
MainState.hx            packsNeedingWork(libPaths)       哪些库要解密
      ↓
      ├─ 有要解密的包 → IntegrityScreen(work, locked)   ← 先看校验进度和结果
      │                      ↓
      │                 没有可用密钥 → ModPackKeyState  ← 玩家在这里输密码
      │                      ↓
      │                 ModPackLoadingState → startPrepare(packs)（工作线程）
      │                      └→ zipFor() → openEncrypted()（只校验头）
      │                                    → SysZip.fromChunked()
      ↓
MainState.hx            retainZips(libPaths)             放掉本次用不到的副本
      ↓
ModsFolder.hx           ModPackCrypto.zipFor(packPath)   库加载时取内存 zip
      ↓
ZipFolderLibrary → SysZip.readBytes(pos, len)            读哪个资源就解哪段
      ↓
HScript.hx              先试 .hxb → ScriptCrypto 解密脚本
      ↓
Main.hx                 退出时 needsCleanup() → ModPackCleanupState 逐帧擦除
```

没有加密包的构建跳过中间那一段，直接进 `WarningState`；校验结果由主菜单补显示一次。

关键设计：**解密发生在工作线程，主线程只读已经就绪的缓冲**。这也是 `zipFor` 里到处是
`hasLoaded` / `stale` / `released` 判断的原因——三个状态分别是"可用""文件被合并改写过了""已经擦掉了"。

---

## 4. 数据在哪，什么时候消失

| 数据 | 位置 | 生命周期 |
| --- | --- | --- |
| 加密包本体 | `mods/*.zip` | 永久，只读 |
| 解密后的包 | 内存（默认 `SysZip` + `ProtectedBuffer`），或按需读原加密文件（低内存模式） | 退出时释放缓冲 / 关闭文件句柄 |
| 包内自带密钥 | `.cne/keys/.CNE_<包名>_key.txt` | 退出时删除；切 mod 时保留 |
| 解出来的视频 | `.cne/mods/<mod>/videos/` | 退出 / 切 mod 时删除 |
| 编辑器暂存改动 | `.cne/mods/<mod>/` | **不删**，等合并或玩家丢弃 |
| 编辑器撤销数据 | `.cne/temp/` | 退出时删除 |
| 日志 | `.cne/logs/engine.log` | 每次启动重写 |
| 玩家输入的密码 | 内存（`MemoryGuard` 包裹） | 会话内有效 |

`.cne/` 在 Windows 上带隐藏属性。退出时清掉 keys / temp / videos 和内存缓冲，
留下暂存改动与日志——那两样是玩家会找的东西。

---

## 5. 另外 64 个官方文件也被改过

相对 `baseline/upstream-1.1.0`，一共 84 个官方文件有改动（+14000 / −900 行上下，含删除）。
上面 §2 覆盖了 20 个直接引用加密 API 的，**剩下 64 个没有逐一核实**，已知至少混着三类：

- **周边功能**：例如 `shaders/FunkinShader.hx` 让编辑器改了 shader 后缓存失效，服务的是
  "在加密包里编辑资源"（`ZipEditCache`），和 §2 是同一套体系但没直接调加密 API。
- **界面改造**：`editors/ui/*` 一批（`UITopMenu`、`UISliceSprite`、`UIPopup` 相关）是编辑器
  交互的一部分，和加密无直接关系。
- **1.0.1 → 1.1.0 迁移差异**：例如 `events/gameplay/RatingsShowEvent.hx`、`editors/ui/UISprite.hx`，
  看改动形状像是从 1.0.1 分支带过来的行为差异，**未逐行确认**。

要理清这部分，用：

```bash
git diff --stat baseline/upstream-1.1.0 HEAD -- source/
git diff baseline/upstream-1.1.0 HEAD -- <单个文件>
```

把 20 个之外的逐个过一遍，确认是"周边功能"还是"迁移差异"，再决定是留、是改回上游、还是单独记录。

---

## 6. 怎么验证没走样

- **容器层**：编辑器 F7 → Tools → `Self test: containers (scripts + mod packs)`。
  校验 CNEZ 布局、往返一致性、错误密钥被拒、篡改被拒，以及惰性读取路径。
- **编译**：`building/Build.bat`（Windows）或 `build-linux.sh` / `build-macos.sh`，日志无 `error:`。
- **行为**：加密包启动、密码错误、切 mod、退出清理，这四条路径只能人工验。

---

*本文件由本 fork 维护，格式与数值必须能在源码里找到对应；改了接缝点就回来改这张表。*
