# Re-Encryption 功能说明

本文件描述 **Codename Engine Re-Encryption** 相对上游 Codename Engine 1.1.0（基线 `112aa91`，
当前已并入上游 `afe74668`）
新增的内容保护功能：加密的 mod 包、带密码的 zip、受保护的脚本，以及打包/解包它们的游戏内工具。

> **先读这一条**：本功能提供的是 **静态保护**，不是运行时保护。
> 引擎要加载内容就必须解密，所以游戏运行时明文一定存在于内存里（可选整包会话流包裹，见 2.2），
> 但不会再落到磁盘上；内置默认密钥编译在 exe 里，反汇编就能拿到。它挡住的是"随手打开压缩包看一眼"
> 和"从进程内存里捞明文"的人，挡不住有工具和耐心的人。详见文末 [能力边界](#能力边界)。

---

## 1. 总览

| 需要保护的东西 | 格式 | 阅读方 | 实现 |
| --- | --- | --- | --- |
| mod 包（zip） | `CNEZ` 容器 | 只有本引擎 | `source/funkin/backend/assets/ModPackCrypto.hx` |
| mod 包（zip） | 传统 ZipCrypto 密码 zip | 本引擎 + 任意 zip 工具 | `assets/ZipPassword.hx` |
| mod 包（zip） | WinZip AES-128/192/256（method 99） | 本引擎 + 7-Zip / WinRAR / Bandizip | `assets/ZipAes.hx` |
| 脚本（`.hx`） | `CNX2` 容器，扩展名 `.hxb` | 只有本引擎 | `scripting/bytecode/ScriptContainer.hx` |

制作与解包都在游戏内完成：编辑器选择菜单（主菜单按 `F7`）里的 **Encryption Tool**
（`source/funkin/editors/EncryptionEditor.hx`，i18n id `scriptEncryption`）。

---

## 2. 加密的 mod 包

### 2.1 CNEZ 容器布局

小端，固定 40 字节头 + 密文 + 32 字节 HMAC：

| 偏移 | 长度 | 内容 |
| --- | --- | --- |
| 0..3 | 4 | magic `"CNEZ"`（`0x43 0x4E 0x45 0x5A`） |
| 4 | 1 | 格式版本（当前 `1`） |
| 5..7 | 3 | 保留 |
| 8..23 | 16 | 随机 salt |
| 24..35 | 12 | 随机 nonce |
| 36..39 | 4 | 明文（zip）长度 |
| 40.. | n | 原始 `.zip` 字节的 ChaCha20 密文 |
| 末尾 | 32 | 覆盖以上全部内容的 HMAC-SHA256 tag |

magic 与脚本容器的 magic 刻意不同，脚本不可能被当成 mod 包读、反之亦然。
密钥规则与脚本加密完全相同（见第 4 节「密钥与 key token」）。

### 2.2 运行时流程

1. `mods/` 下的 `*.zip` 被识别为受保护包时，`ModPackCrypto` 用可用密钥尝试解封；
2. 密钥可用时，解出的 zip **只留在内存里**（`ModPackCrypto.zipFor` → `SysZip` →
   `scripting/protect/ProtectedBuffer.hx`），一个字节都不写盘。资源库照常按条目解压/读取，
   只是数据来源从文件换成了内存缓冲；
3. 缓冲有两种模式，可在设置里切（Misc → *Shield Loaded Mods*）：
   - **包裹模式（默认）**：整包用一条每会话随机的 ChaCha20 流盖住，只有被读取的那一段才解出来。
     内存扫描器看不到 zip 头、文件名或音频；
   - **明文模式**：缓冲原样放在内存里，读取就是一次内存拷贝，速度略快。
   切换 mod 时，本次不再使用的包被擦除（`retainZips`）；正在用的那个保留，否则加载器
   会把刚解出来的副本当成没解过，再走一遍解密；
4. 没有可用密钥时，加载器停下来并打开 `ModPackKeyState`（`source/funkin/menus/ModPackKeyState.hx`）：
   玩家输入发布者给的密钥或 `CNEK1-` token，输错则会显示错误并保留"不用 mod 启动"的选项；
5. 关闭游戏时，只要本次运行解过包，窗口**不会立刻关**：`ModPackCleanupState` 接管，
   在后台擦掉内存缓冲、释放 zip 句柄、删除复制出来的密钥文件和视频缓存，
   完成后等待 3 秒自动退出（也可以点 *Close now* 立即退出）。
   清理期间关闭请求一直被拒绝，避免"擦到一半窗口就没了"。

> 代价：解密只在本次运行内有效，**每次启动都要重新解一遍**（以前有磁盘缓存，第二次启动是秒开）。
> 包大小的内存占用是实打实的，包越大占用越高。

### 2.3 带密码的普通 zip

- **ZipCrypto（传统 PKWARE 加密）**：引擎自带的 zip 读取器会拒绝带加密标志的条目。
  `ZipPassword` 只解密 12 字节加密头来便宜地校验密码，然后在**内存里**重建成一份可读副本
  （`readableCopyBytes`，不落盘）。重建**只剥掉加密头，保留每个条目原有的 deflate 压缩块和压缩方法**，
  所以副本大小和原包接近，重建过程也不解压。
  唯一例外：AE-2 条目的 CRC 字段是 0，为了给普通读取器一个可校验的 CRC，这类条目仍会解压一次。
  小条目（≤1 MB，脚本/谱面/配置都在这个范围）会顺带做一次 CRC 校验，大媒体文件不做——
  它们由引擎读取时自然校验。
- **WinZip AES（method 99）**：条目带 `0x9901` extra 字段，载荷为
  `salt(8/12/16) + 密码校验(2) + AES-CTR 密文 + 认证(10)`，密钥来自 PBKDF2-HMAC-SHA1（1000 轮），
  完整性用截断的 HMAC-SHA1。`ZipAes` 既能读也能写——加密工具导出的"AES 密码 zip"就是它写的，
  所以玩家只需要输一次密码，7-Zip / WinRAR / Bandizip 也能直接打开。
- **包内自带的 key 文件**：`ScriptCrypto` 只认磁盘上的文件，而 zip 条目不是文件，所以打包 mod 加载时
  `ModsFolder.registerKeyFilesFromPack` 会把包里的 `data/script_key.txt` / `script_key.txt` 复制到
  `.cne/keys/` 并注册。没有这一层，包内脚本用了自定义 key 时就只能把 `script_key.txt` 放到 exe 旁边。

### 2.4 运行时目录：`./.cne/`

引擎运行期需要落盘的东西全部收在一个 exe 同级的隐藏文件夹里（`backend/system/RuntimeDirs.hx`）：

```
.cne/
  keys/                包内 script_key.txt 的副本（原 .CNE_mods/）
  mods/<mod>/          编辑器为打包 mod 暂存的改动（原 [zip]temp/<mod>/）
  mods/<mod>/videos/   从包里提取的视频（原 .temp/ 的 *-zipvideo-*）
  temp/                编辑器 undo/redo、更新器临时数据（原 .temp/ 的其余部分）
```

拆成三个目录时它们都为了同一件事存在——zip 不能原地读写——但放在一起谁也分不清谁。
旧目录在首次启动时合并：`[zip]temp/<mod>/` 里的改动会**搬**进 `.cne/mods/<mod>/`（那是玩家没合并的工作），
`.CNE_mods/` 和 `.temp/` 里只有可重建的缓存，直接删。

其中给**打包 mod** 暂存的改动（`assets/ZipEditCache.hx`）：

- 引擎读资源时通过 `OverlayZipFolderLibrary` 把这层文件夹叠在包上——文件夹里有就优先用它；
- 关闭游戏时若这个目录还有文件，走的还是引擎自带的那套"未保存"提示：`WindowUtils` 新增的
  **关闭否决**（`onCloseVeto`）把窗口留住，`SaveWarning` 弹它原本的**取消 / 不保存退出 / 保存并退出**，
  其中"保存"这一步就是合并——没有另造对话框，编辑器的未保存提示也照旧走同一套；
- 选合并就重写压缩包：包内同名条目被替换、其余条目原样复制（保留压缩字节，不解压重压）、
  暂存目录里的新文件追加进去；之后按包原本的加密方式与密钥重新加密（CNEZ / AES zip / 明文各走各的）；
- 原包先改名成 `.old` 再换新的，替换失败会还原，暂存文件保持不动——失败不会丢东西。

> 注：`mods/Name/` 与包并存时仍然优先读文件夹（兼容旧布局），只是新保存的内容不再写进去。
> `.cne/mods/<mod>/videos/` 是只读缓存，合并时会被跳过，不会把整段过场动画重新写进包。

---

## 3. 受保护的脚本（`.hxb` / CNX2）

### 3.1 一个保护模式（二选一）+ 两个可选附加层

**保护模式 —— 必须且只能选一个：**

| 模式 | 作用 | 源码 |
| --- | --- | --- |
| **KEY** | ChaCha20 加密 + HMAC-SHA256 tag，运行时需要密钥 / token | 留在容器里，加密后可 Decrypt 还原 |
| **VM** | 源码编译为字节码，每个操作码字节按**该文件专属的随机排列**替换（见 `bytecode/OpMap.hx`） | **被丢弃**，只剩字节码，不可还原为 `.hx` |

**附加层 —— 可选，叠加在上面的模式之上：**

| 层 | 作用 |
| --- | --- |
| **OFFSET** | 整个载荷按随机位数循环移位，破坏字节对齐和文件签名 |
| **SPLIT** | 载荷切成 N 段、打乱顺序，段间插入随机填充 |

OFFSET / SPLIT 是纯字节洗牌，参数（位数、段数、种子）就明文存在 64 字节头里，
所以它们**永不阻碍解密还原**——能不能还原只取决于上面的模式里有没有留下源码。

打包顺序是 `encrypt → split → rotate`（源码里表述为 `payload -> [SPLIT] -> [OFFSET]`），
解包时逆序撤销。读取所需的一切（密钥除外）都在固定的 64 字节头里。

### 3.2 命名与加载

- 编辑器输出 `name_protected.hxb`，放在源文件旁边；
- 引擎按名字找脚本时会剥掉 `_protected` 后缀（`Paths.hx`、`HScript.hx`、`ModsFolderLibrary.hx`、
  `ZipFolderLibrary.hx`、`ScriptCrypto.hx` 都有对应处理），所以 `data/notes/foo_protected.hxb` 能替 `foo` 应答；
- 因此 `.hx` 可以在保护完成后删除，受保护文件接管它的位置；
- 一个 `.hxb` 里只会放源码或只放字节码，取决于打包时选的模式：KEY 模式放（加密的）源码，
  VM 模式放字节码。编辑器不再同时内嵌两者——源码副本必须与密钥一起加密才安全，
  而两种模式互斥后这个组合就不存在了，所以字节码失败时没有源码可回落，
  VM 模式的文件"解密"也会报错（没有源码可写）。

### 3.3 字节码版本

头部字节 10 存编译器 revision。revision 0 表示该字节出现之前写的包：那时的编译器会丢掉
空字面量上的 Map 类型提示（`var m:Map<String, T> = []` 变成 Array），使 VM 以 "Null Function Pointer" 死掉；
这类包会改走源码回落。字节码语义变化时必须递增该 revision（见 `ScriptContainer.hx` 注释）。

---

## 4. 密钥与 key token

### 4.1 密钥来源与优先级

`ScriptCrypto`（`source/funkin/backend/scripting/crypto/ScriptCrypto.hx`）按此顺序解析：

1. `ScriptCrypto.setPassword()` 设置的值（`public static var password`）；
2. `script_key.txt`：候选路径 `script_key.txt`、`./script_key.txt`、`assets/data/script_key.txt`，
   另外 `ModsFolder` 会把 `<mod>/data/script_key.txt` 与 `<mod>/script_key.txt` 加入候选；
3. 内置常量 `DEFAULT_PASSWORD = "CNE::script::v1::d0nt_t0uch_th3_sky"`。

KDF 是自制的迭代 SHA-256（`KDF_ROUNDS = 2048`），**不是** PBKDF2 / Argon2，未经密码学审计。
它足以让脚本对普通用户不可读；若密钥必须抵抗离线爆破，请换成标准 KDF。

salt / nonce 来自系统熵源：Windows 用 `RtlGenRandom`（`SystemFunction036`，经
`scripting/protect/OsEntropy.hx` → `utils/native/Windows.hx` 的 `GetProcAddress` 调用，
不新增头文件与链接库），其它平台读 `/dev/urandom`；两者都不可用时才回落到 ChaCha20 DRBG
（时间 / 环境变量 / `Std.random` 播种，强度较弱，只作为兜底）。

### 4.2 `script_key.txt` 格式

- 首行一个 key = 全局默认；
- 或每行 `name = key`，其中 name 可以是文件名、无扩展名名字、mod 相对路径或 `*` 作为兜底；
- `#` 和 `//` 开始注释。

自定义 key 必须同时写进 `script_key.txt`（或调用 `setPassword()`），否则引擎自己都打不开这个包。
编辑器里 **File > Reload Key File** 可以不重启重读该文件。

### 4.3 key token

`CNEK1-` 前缀的 token 是密钥换了个说法的文本：`encodeKeyToken` / `decodeKeyToken` 用固定流 XOR 后做 URL-safe Base64。
**它不是密码学**——任何人拿到引擎都能反推。玩家把 token 粘进 `ModPackKeyState` 的输入框即可，引擎自动还原。

---

## 5. Encryption Tool 用法

主菜单按 `F7` → 编辑器列表 → **Encryption Tool**。三个页签：

- **Mod Pack**
  - 把一个 zip mod 封成 CNEZ 容器，或导出成 AES-256 密码 zip；
  - 把已封的包解回普通 zip；
  - token 工具：把 key 换成 token / 换回来，以及复制到剪贴板。
  - 输出命名：`name_encrypted.zip`、`name_password.zip`、`name_decrypted.zip`。
- **Scripts**
  - 选一个或多个 `.hx`；
  - **先选一个保护模式（必选，二选一）**：`Key encryption`（可还原）或 `VM bytecode`（只剩字节码）；
  - 再按需勾选附加层 OFFSET / SPLIT（可选，两者都是纯字节洗牌，不影响能否还原）；
  - 输出 `name_protected.hxb`；
  - 选 `.hxb` 点 Decrypt 可以还原——**前提是当初用 KEY 模式打包**，VM 模式没有源码可写。
- **Help**
  - 就是上面这些说明的原始英文版（`EncryptionEditor.HELP_BODY`）。

加解密都在后台跑，带一条进度条。小提示：文本框获得焦点时 `Backspace` 是编辑文本，`ESC` 只丢焦点，
再按一次 `ESC` 才退出编辑器；Help 页用鼠标滚轮滚动。

---

## 6. 能力边界

**能做**

- 让包和脚本在磁盘上不可读、不能被普通压缩工具打开；
- 用 HMAC-SHA256 检出篡改（脚本）／HMAC-SHA256 tag（CNEZ 容器）；
- 每个脚本一份随机 opcode 排列，反汇编一个脚本不能直接描述下一个；
- 运行期把密钥/源码包在 ChaCha20 会话流里并擦除缓冲，让内存扫描看不到静态字段里的明文；
  解密后的 mod 包同样只存在内存里，可选整包被会话流包裹、按需解段；
  对用户态调试器隐藏主线程（`backend/system/MemoryGuard.hx` + `utils/native/MemoryProtect.hx`）。

**不能做**

- 阻止读另一进程内存的 dumper 或内核态调试器——Haxe 无法锁定页或保护堆，这只是"提高门槛"；
  包裹模式让扫描器看不到结构，但拿到进程内存后耐心拼装仍然可行；
- 保护内置默认密钥（编译进 exe，可被反汇编读出）；
- 替代原生壳/VMProtect 一类的方案；这些容器**不是**真正的 AEAD。

> 不写"已完全加密 / 100% 安全"这类结论。要判断某项内容是否够安全，请按上面两条清单逐项对照。

---

## 7. 已知限制 / 兼容性

- 纯字节码的 `.hxb` 无法还原源码（Decrypt 报错），这是设计使然；
- revision 0 的旧包（空字面量 Map 提示丢失）走源码回落，性能与保护强度都低于新包，建议用新版本重新打包；
- 解密后的包只在内存里：**每次启动都要重新解密**（没有磁盘缓存了），大包启动慢几秒；
- 内存占用等于包大小（包裹模式下另加解密时的临时缓冲），32 位构建上大包要注意；
- 唯一的落盘产物是包内附带的 `script_key.txt`（复制到 `./.cne/keys/` 供 `ScriptCrypto` 读取，
  退出时删除）；视频走的是上游原本的做法——`ZipFolderLibrary.getVideoRemap` 把它解到磁盘，
  现在落在 `./.cne/mods/<mod>/videos/`；
- 密码 zip / AES zip 需要玩家在启动时输入一次密码；
- 未使用上述功能的项目行为与上游 1.1.0 一致（默认不加密任何东西）。

---

*本文件由本 fork 维护；上游功能文档见 [FEATURES.md](../FEATURES.md)、[CHANGELOG.md](../CHANGELOG.md)、[PATCHNOTES.md](../PATCHNOTES.md)，
协作与交付规则见 [AGENTS.md](../AGENTS.md)。*
