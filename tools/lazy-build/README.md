# 懒人编译包（Windows）

双击仓库根目录的 `Build.bat`（就在 `project.xml` 旁边），等它跑完，产物就在：

```
export\release\windows\bin\CodenameEngine.exe
```

不需要开命令行、不需要先装 Haxe、不需要 Developer Prompt。**前提**：仓库里自带的 `.haxelib` 文件夹还在（本仓库的第三方库是随仓库一起的，不重新下载）。

`Build.bat` 只是个转发器，真正干活的是同目录下的 `tools\lazy-build\lazy-build.ps1`，说明和日志也都在 `tools\lazy-build\`。

## 它会依次做六件事

| 步骤 | 做什么 | 缺东西时怎么办 |
| --- | --- | --- |
| 1/6 工具链 | 找 Haxe 4.3.x 和 Neko | 找不到就下载 haxe-4.3.7-win64.zip 和 neko-2.3.0-win64.zip 到 `tools\lazy-build\toolchain\` 解压使用（**不需要装进系统**） |
| 2/6 库 | 把 haxelib 指向仓库自带的 `.haxelib` | 文件夹被删了就报错并停下（不会偷偷去下载一堆库） |
| 3/6 原生库 | 检查 `lime.ndll`（Windows64） | 缺失或加 `-RebuildLime` 时，执行 `lime rebuild windows -64` 现场编译 |
| 4/6 C++ 工具链 | 用 `vswhere` 查 MSVC | 没有就下载 VS Build Tools 安装器；**需要管理员权限**，没有就打印手动步骤 |
| 5/6 编译 | `haxelib run lime build windows -nocolor` | 顺带检测/关闭正在运行的 `CodenameEngine.exe`（否则链接器写不进 exe） |
| 6/6 验收 | 检查 exe 是否存在、时间戳是否比本次构建新、统计 warning | 失败时把日志里第一批 `error:` 行摘出来，并给出对应处理建议 |

## 双击前要知道的

- 第一次跑如果本机没有 Haxe：会下载约 12 MB + Neko 约 3 MB，缓存在 `tools\lazy-build\toolchain\downloads\`。
- 如果本机没有 MSVC：会下载 VS Build Tools 安装器（`%TEMP%\vs_BuildTools.exe`），**必须用管理员权限运行它**，选"使用 C++ 的桌面开发"工作负载。这一步几个 GB，脚本不会偷偷替你装完——它只在管理员窗口里才会执行安装。
- 已经装好 Haxe 4.3.x 的机器（比如本机 `D:\FNF\Haxe\4.3.7`）会直接复用，不下载任何东西。
- 控制台里出现成片的 `Warning: ... is deprecated` 是上游代码的正常噪声，不影响产物。
- 脚本只写这三处：`export\`（lime 的产物）、`tools\lazy-build\logs\`（日志）、`tools\lazy-build\toolchain\`（下载的工具链）。不动机器上已有的 Haxe / 系统 PATH / 注册表。

## 参数

命令行用法（`Build.bat` 后面直接跟参数）：

```bat
Build.bat                     :: 正常增量构建
Build.bat -Clean              :: 清掉中间产物全量重编（改了 project.xml / 碰到诡异链接错误时用）
Build.bat -Debug              :: 编 debug 版，产物在 export\debug\windows\bin\
Build.bat -RebuildLime        :: 强制重编 lime 原生库（缺 MSVC 会失败）
Build.bat -DryRun             :: 只打印它会做什么，一个文件都不改
Build.bat -Yes                :: 所有询问都按默认答案（适合无人值守）
Build.bat -DownloadToolchain  :: 无视已装的 Haxe，强制下载解压一份到 toolchain\（做"绿色包"时用）
Build.bat -ForceToolchain     :: 只用 toolchain\ 里的那份 Haxe
Build.bat -HaxeHome "D:\Haxe\4.3.7\haxe"   :: 指定 Haxe 目录
```

`-DryRun` 是排查"脚本到底想干什么"的最快方式，安全。

## 离线 / 内网机器

把这两个 zip 提前放进 `tools\lazy-build\toolchain\downloads\`，脚本会直接复用，不再联网：

- `haxe-4.3.7-win64.zip`（https://github.com/HaxeFoundation/haxe/releases/tag/4.3.7）
- `neko-2.3.0-win64.zip`（https://github.com/HaxeFoundation/neko/releases/tag/v2-3-0）

MSVC 与 VS Build Tools 无法离线绕过，内网机器请提前装好"使用 C++ 的桌面开发"。

## 常见意外情况对照

| 症状（日志里） | 原因 | 处理 |
| --- | --- | --- |
| `'haxe' 不是内部或外部命令` / 脚本说找不到 Haxe | 本机没装或不认识 | 什么都不用做，脚本会下载；或 `-HaxeHome` 指过去 |
| `Could not find haxelib "flixel" ...` | 不在仓库根编译，或 `.haxelib` 被删 | 确认双击的是仓库根目录的 `Build.bat`（脚本会自己 `cd` 到仓库根）；`.haxelib` 丢了要从仓库还原 |
| `LNK1104: cannot open file ... CodenameEngine.exe` | 游戏正在运行，exe 被占用 | 关掉游戏，或让脚本帮你关（它会问一句） |
| `Could not load lime.ndll` / `lime.n: ... not found` | 原生库缺失或架构不符 | `Build.bat -RebuildLime` |
| `cl.exe` 找不到 / `Cannot find msvc` | 没装 C++ 工具链 | 装 VS Build Tools 的"使用 C++ 的桌面开发" |
| `系统禁止运行脚本` / `UnauthorizedAccess` | PowerShell 执行策略 | 不用管，`Build.bat` 已经带 `-ExecutionPolicy Bypass` |
| 编译成功但 exe 时间戳没变 | lime 判定无需重编 | `Build.bat -Clean` |
| 卡在 `Downloading` 很久 | 网络慢/被墙 | 按上面的离线办法手工放 zip；GitHub 不通时也可用代理 |

## 日志

每次运行写一份 `tools\lazy-build\logs\build-<日期>-<时间>.log`，包含脚本决策、完整命令、lime/hxcpp 原始输出。反馈问题请带上这份日志。

## 手动等价命令（脚本坏了时兜底）

```powershell
$env:Path='D:\FNF\Haxe\4.3.7\haxe;D:\FNF\Haxe\4.3.7\neko;'+$env:Path
cd 'D:\FNF\FNF code\Codename-Engine_Re-Encryption'
haxelib run lime build windows -nocolor
```

## 已知限制

- 只支持 Windows 目标（`windows`）。其它平台走 lime 官方流程。
- 只认 Haxe 4.3.x；4.2.x 会被提示"需要 4.3.x"并改建自己的工具链（本项目现有依赖按 4.3.x 验证过）。
- 不自动 `haxelib install` 缺失的第三方库：库随仓库走，凭空重建一份可能版本对不上，宁可报错让你还原 `.haxelib`。
- 32 位（`-x86_32`）构建脚本不处理 `ndll\Windows\lime.ndll` 的检查，只检查 `Windows64`。
