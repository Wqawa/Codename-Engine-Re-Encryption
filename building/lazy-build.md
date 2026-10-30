# 懒人编译包（Windows）

双击本文件夹里的 `Build.bat`（`building\` 在 `project.xml` 旁边），等它跑完，产物就在：

```
export\release\windows\bin\CodenameEngine.exe
```

不需要开命令行、不需要先装 Haxe、不需要 Developer Prompt。**前提**：仓库里自带的 `.haxelib` 文件夹还在（本仓库的第三方库是随仓库一起的，不重新下载）。

`Build.bat` 只是个转发器，真正干活的是同目录下的 `lazy-build.ps1`，日志与下载的工具链也都在 `building\` 下。

> 本文件是本 fork 新增的说明。上游原本的编译指南是同目录的 [`README.md`](README.md)，正文保持原样未改。

## 它会依次做六件事

| 步骤 | 做什么 | 缺东西时怎么办 |
| --- | --- | --- |
| 1/6 工具链 | 找 Haxe 4.3.x 和 Neko | 找不到就下载 haxe-4.3.7-win64.zip 和 neko-2.3.0-win64.zip 到 `building\toolchain\` 解压使用（**不需要装进系统**） |
| 2/6 库 | 把 haxelib 指向仓库自带的 `.haxelib` | 文件夹被删了会自动调上游的 `setup-windows.bat`（按 `libs.xml` 重新下载全部库）；连它也没有就报错，让你从仓库还原 | |
| 3/6 原生库 | 检查 `lime.ndll`（Windows64） | 缺失或加 `-RebuildLime` 时，执行 `lime rebuild windows -64` 现场编译 |
| 4/6 C++ 工具链 | 用 `vswhere` 查 MSVC | 没有就下载 VS Build Tools 安装器；**需要管理员权限**，没有就打印手动步骤 |
| 5/6 编译 | `haxelib run lime build windows -nocolor`，并打开 hxcpp 的编译缓存 | 顺带检测/关闭正在运行的 `CodenameEngine.exe`（否则链接器写不进 exe） |
| 6/6 验收 | 检查 exe 是否存在、时间戳是否比本次构建新、统计 warning | 失败时把日志里第一批 `error:` 行摘出来，并给出对应处理建议 |

## 双击前要知道的

- 第一次跑如果本机没有 Haxe：会下载 Haxe 11.5 MB + Neko 1.7 MB，缓存在 `building\toolchain\downloads\`。
- 如果本机没有 MSVC：会下载 VS Build Tools 安装器（`%TEMP%\vs_BuildTools.exe`），**必须用管理员权限运行它**，选"使用 C++ 的桌面开发"工作负载。这一步几个 GB，脚本不会偷偷替你装完——它只在管理员窗口里才会执行安装。
- 已经装好 Haxe 4.3.x 的机器（比如本机 `D:\FNF\Haxe\4.3.7`）会直接复用，不下载任何东西。
- 控制台里出现成片的 `Warning: ... is deprecated` 是上游代码的正常噪声，不影响产物。
- 脚本只写这几处：`export\`（lime 的产物）、`building\logs\`（日志）、`building\toolchain\`（下载的工具链）、
  `%LOCALAPPDATA%\cne-hxcpp-cache`（hxcpp 编译缓存，用 `-CacheDir` 可改位置）。不动机器上已有的 Haxe / 系统 PATH / 注册表。

## 为什么有时候要编 40 分钟

hxcpp 的增量判断看的是 `.obj` 与生成的 `.cpp` 谁更新。只要它认为"全都得重编"，就会把大约 3700 个翻译单元
从头编一遍（本机约 40 分钟）。触发条件包括：改了 `project.xml` 的 define、加/删了 `.hx` 文件（模块列表变了）、
PCH 失效、`-Clean`、换 Haxe / hxcpp 版本、`.haxelib` 里的库动过。**普通的改代码 + 增量只有几秒到一分钟**
（日志里只出现 4 个文件就是这种情况）。

脚本默认打开 hxcpp 的编译缓存（`-D HXCPP_COMPILE_CACHE=...`）：缓存键是"源文件内容 + 编译参数 + 依赖哈希 +
编译器版本"的 md5，所以即使 hxcpp 判定要全量重编，没变过的文件也只是从缓存里拷 `.obj`，不再跑 `cl.exe`。
第一次（缓存是空的）仍然要全量编一遍，之后就快了。

缓存目录默认 `%LOCALAPPDATA%\cne-hxcpp-cache`，可以随便删（删了下次会重新填，只是慢一次）。

## 参数

命令行用法（`Build.bat` 后面直接跟参数）：

```bat
Build.bat                     :: 正常增量构建（编译缓存默认开）
Build.bat -Clean              :: 清掉中间产物全量重编（改了 project.xml / 碰到诡异链接错误时用）
Build.bat -NoCache            :: 关掉编译缓存，排查"缓存里是旧的 obj"这类怪问题时用
Build.bat -CacheDir "D:\hxcpp-cache"   :: 把编译缓存放到别处
Build.bat -Debug              :: 编 debug 版，产物在 export\debug\windows\bin\
Build.bat -RebuildLime        :: 强制重编 lime 原生库（缺 MSVC 会失败）
Build.bat -DryRun             :: 只打印它会做什么，一个文件都不改
Build.bat -Yes                :: 所有询问都按默认答案（适合无人值守）
Build.bat -DownloadToolchain  :: 无视已装的 Haxe，强制下载解压一份到 toolchain\（做"绿色包"时用）
Build.bat -ForceToolchain     :: 只用 toolchain\ 里的那份 Haxe
Build.bat -HaxeHome "D:\Haxe\4.3.7\haxe"   :: 指定 Haxe 目录
```

`-DryRun` 是排查"脚本到底想干什么"的最快方式，安全。

也可以不用 bat，直接跑脚本（同样会自己切到仓库根）：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File building\lazy-build.ps1 -DryRun
```

## 离线 / 内网机器

把这两个 zip 提前放进 `building\toolchain\downloads\`，脚本会直接复用，不再联网：

- `haxe-4.3.7-win64.zip`（https://github.com/HaxeFoundation/haxe/releases/tag/4.3.7）
- `neko-2.3.0-win64.zip`（https://github.com/HaxeFoundation/neko/releases/tag/v2-3-0）

MSVC 与 VS Build Tools 无法离线绕过，内网机器请提前装好"使用 C++ 的桌面开发"。

## 常见意外情况对照

| 症状（日志里） | 原因 | 处理 |
| --- | --- | --- |
| `'haxe' 不是内部或外部命令` / 脚本说找不到 Haxe | 本机没装或不认识 | 什么都不用做，脚本会下载；或 `-HaxeHome` 指过去 |
| `Could not find haxelib "flixel" ...` | 不在仓库根编译，或 `.haxelib` 被删 | 确认双击的是 `building\Build.bat`（脚本会自己 `cd` 到仓库根）；`.haxelib` 丢了要从仓库还原 |
| `LNK1104: cannot open file ... CodenameEngine.exe` | 游戏正在运行，exe 被占用 | 关掉游戏，或让脚本帮你关（它会问一句） |
| `Could not load lime.ndll` / `lime.n: ... not found` | 原生库缺失或架构不符 | `Build.bat -RebuildLime` |
| `cl.exe` 找不到 / `Cannot find msvc` | 没装 C++ 工具链 | 装 VS Build Tools 的"使用 C++ 的桌面开发" |
| `系统禁止运行脚本` / `UnauthorizedAccess` | PowerShell 执行策略 | 不用管，`Build.bat` 已经带 `-ExecutionPolicy Bypass` |
| 编译成功但 exe 时间戳没变 | lime 判定无需重编 | `Build.bat -Clean` |
| 卡在 `Downloading` 很久 | 网络慢/被墙 | 按上面的离线办法手工放 zip；GitHub 不通时也可用代理 |

## 日志

每次运行写一份 `building\logs\build-<日期>-<时间>.log`，包含脚本决策、完整命令、lime/hxcpp 原始输出。反馈问题请带上这份日志。

## 手动等价命令（脚本坏了时兜底）

```powershell
$env:Path='D:\FNF\Haxe\4.3.7\haxe;D:\FNF\Haxe\4.3.7\neko;'+$env:Path
cd 'D:\FNF\FNF code\Codename-Engine_Re-Encryption'
haxelib run lime build windows -nocolor
```

## 和上游 `cne` 命令行（`cne-windows.bat`）的关系

`building\cne-windows.bat` 是上游自带的 CLI 入口（两行，跑 `commandline\Main.hx`），子命令：

| 子命令 | 实际执行 | 说明 |
| --- | --- | --- |
| `setup` | 按 `building\libs.xml` 安装所有库 | 本脚本在 `.haxelib` 缺失时会自动调它（`setup-windows.bat`） |
| `release` | `haxelib run lime build windows` | **等价于 `Build.bat` 不带参数时做的事** |
| `build` / `test` | `lime build`/`test` + `-DTEST_BUILD` | 开发构建：不拷资源，直接从源码目录读 assets，只能在源码目录里跑 |
| `run` | `lime run windows` | 跑上一次的构建 |
| `optimize` | 压缩 JSON | 与编译无关 |

- `Build.bat` ≈ `cne-windows.bat release`，但多了五件事：找/装 Haxe+Neko、查 `.haxelib`、查 `lime.ndll`、查 MSVC、把输出写进日志并翻译报错。它**不需要** `haxe` 在 PATH 里。
- `cne-windows.bat` 自己**不找工具链**，里面直接写 `@haxe ...`，所以必须先把 Haxe 放进 PATH。用本脚本下过工具链的话，这样临时加上：

  ```bat
  set "PATH=%~dp0toolchain\haxe-4.3.7\haxe_20250509143529_e0b355c;%~dp0toolchain\neko-2.3.0\neko-2.3.0-win64;%PATH%"
  building\cne-windows.bat release
  ```

- 本 fork 只维护 Windows：上游的 `cne-unix.sh`、`setup-unix.sh`、`generate-docs-unix.sh` 已删除（要恢复：`git checkout 012a6423 -- building/*.sh`）。因此 `building\README.md` 里提到 `setup-unix.sh` 的 Linux/macOS 步骤在本仓库不能照抄。

## 已知限制

- 只支持 Windows 目标（`windows`）。其它平台走 lime 官方流程。
- 只认 Haxe 4.3.x；4.2.x 会被提示"需要 4.3.x"并改建自己的工具链（本项目现有依赖按 4.3.x 验证过）。
- 不自动 `haxelib install` 缺失的第三方库：库随仓库走，凭空重建一份可能版本对不上，宁可报错让你还原 `.haxelib`。
- 32 位（`-x86_32`）构建脚本不处理 `ndll\Windows\lime.ndll` 的检查，只检查 `Windows64`。
- `building\toolchain\` 与 `building\logs\` 已被 `building\.gitignore` 排除，删掉它们不影响仓库（下次运行会重新下载）。
