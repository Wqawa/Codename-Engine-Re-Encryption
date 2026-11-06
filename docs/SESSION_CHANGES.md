# 本轮改动记录（2026-11-02 ~ 11-04）

按功能分组，只记"改了什么、为什么"。格式与数值的细节看
[RE-ENCRYPTION.md](RE-ENCRYPTION.md) 和 [INTEGRITY.md](INTEGRITY.md)。

---

## 一、加密容器（CNEZ v2）

- **分块 tag**：载荷切成 1 MiB 一块，每块一个 HMAC，表在头部后面，再盖一个根 tag。
  打开一个 132 MB 的包从「全量重加密 7964 ms」降到「只读头部 1 ms」；代价是损坏
  在读到那一块时才暴露。
- **惰性读取**：`SysZip` 多了一个"密文来源"模式，按 range 解密。内存模式的峰值从
  "等于包大小"降到"等于正在读的分块"；低内存模式干脆不进内存，读的时候才 seek + 解密。
- **自检**：`ModPackSelfTest` 在内存里打包 → 解包 → 篡改 → 拒收，编辑器 Tools 菜单可跑。

早期那版单 tag 布局没有发布过，代码里也没有兼容分支，`VERSION` 保持 2。

---

## 二、完整性校验

- `integrity.dat`：`大小 + SHA256 + 路径` 的纯文本，末尾一行 HMAC-SHA256。
  覆盖 exe、同目录的 ndll/dll、`assets/**`；不覆盖 `mods/`、`saves/`、`.cne/`。
- 启动时在工作线程校验，`IntegrityScreen` 在密码框之前显示进度条和结果。
- 没有加密包的构建不走那个屏，由主菜单补显示一次。

细节和"防不住什么"见 [INTEGRITY.md](INTEGRITY.md)。

---

## 三、日志

引擎此前只有控制台输出。现在 `Logs.__showInConsole` 末尾镜像写 `.cne/logs/engine.log`，
每次运行重写；选项里加了 *Save Log To File*（默认开）。

---

## 四、警告对话框

`UIWarningSubstate` 原来那两个 bool（`isError` / 有没有输入框）换成了一个枚举加一个开关：

```haxe
new UIWarningSubstate(title, message, buttons, ?kind = ERROR, ?wantsInput = false, ?lines = null)
```

`kind` 是 `ERROR` / `WARNING` / `INFO`，枚举值就是图标文件名（`error.png`、`warning.png`、
`info.png`），类型和贴图不会对不上；面板皮肤也跟着选（`ERROR` 用 `normal-popup`，其余
`grayscale-popup`）。`wantsInput` 加一行 `UITextBox`，用 `inputValue()` 读，对话框本身不解释
内容。`keepOpen` 让按钮在验证失败时把窗口留住。`lines` 是后加的（见第七节）：给它一组带颜色的行，
正文就按行画，`message` 忽略。

第 4 参在运行期仍收 1.1.0 的 bool（`true` → `ERROR`、`false` → `WARNING`），`isError` 也作为属性
保留了读写，为的是让按旧签名写的 mod 继续能用（见第八节）。

---

## 五、构建与 CI

- `building/Build.bat` + `lazy-build.ps1`：找/装 Haxe、Neko、git，按 `libs.xml` 补库，
  检查 lime 原生库和 MSVC，编译，翻译报错；编完顺手生成完整性清单。
- `build-linux.sh` / `build-macos.sh`：同一套流程，六个 GitHub Actions workflow 都调这三个脚本。
- 换行符、库版本、`tools.n` 重编这些坑写在 [building/lazy-build.md](../building/lazy-build.md)。

---

## 六、11-04 的维护性重构

不改行为，只整理结构、注释和几处真 bug：

- **注释重写**：删掉大段"为什么这样设计"的自我论证，只留约束和坑。
  `ModPackCrypto` 顶部的格式说明还是 v1 的，已经改对。
- **`CnezV2`**：`open` 和 `openFile` 各写了一遍头部校验，合成 `magicProblem` + `parseHeader`；
  `openFile` 的句柄改成 try/catch 里一定关闭（原来是异常路径泄漏）。
- **`IntegrityCheck`**：拆出 `readManifest` / `exeDiffers` / `walkAssets`；删掉没人调用的
  `waitFor()`；`checked` 现在把跳过比对的 exe 也算进去，进度条能走到头。
- **`ModPackCrypto`**：`keyWorks` 的缓存键原来是明文密码，改成 SHA256 前 32 位；
  重复的 `hasFailedBefore` 定义、错位的 `startPrepare` 文档注释、空的 `cache` 分节都清掉了。
- **`RuntimeDirs`**：`ensure` 现在会逐级建目录（`createDirectory` 只建一层，
  `.cne/mods/<mod>/` 在 `mods/` 不存在时其实建不出来）；`countFiles` 不再拼出 `//`。
- **`ZipEditCache`**：合并时按"分隔符归一 + 小写"匹配条目，但读写仍用原路径和原大小写，
  防止同一个文件在包里出现两条。
- **`IntegrityScreen` / `MainMenuState`**：校验结果原来只有"有加密包"时才可能显示，
  没有加密包的构建会算完就扔。现在主菜单兜底显示一次（`reported` 保证不重复）。
- **`UIWarningSubstate`**：去掉重复 import，模糊 shader 的构造从字段初始化块挪进函数。
- **`SysZip`**：中央目录解析拆成 `findEndOfCentralDirectory` / `readCentralDirectory`。
- **`ModPackMergeState`**：`next` 改名 `onDone`，和"下一个状态"区分开。

---

## 七、11-04 的界面、保存与自检

**界面统一**（`menus/PopupScreen`、`menus/PopupProgress`）

- 启动校验、密码输入、解密进度、清理、合并、进歌加载六个屏原来各画各的：近黑背景、黄色标题、
  灰正文、手搓蓝条。现在共用同一套外壳：原版 `normal-popup` 九宫格 + 30px 标题栏 + 25px 内边距 +
  `UIWarningSubstate` 那一排 160×30 按钮；进度条照 `UISlider` 画（浅灰描边 + `#140013` 槽 +
  紫色填充），只读并把自己的 alpha/visible 传给填充。
- 行高按 `UIText.height` 实测累加，面板建完再按内容居中，不再依赖 1280×720 坐标。
- `EncryptionEditor` 三页的实心面板换 `context-bg` 九宫格，黄标题/灰正文改白，两条任务进度条换
  `PopupProgress`，`jobBarBg` 那对重复精灵删掉。

**未保存提示**

- 试玩里的提示原来走 `PlayState.saveWarn` → 旧的 `PlaytestingWarningSubstate`（另一套外观），
  而 `triggerWarning` 在非 `UIState` 下还会再开一个通用对话框，两个叠在一起；连点两次 X 既会
  继续叠加，也会被 `WindowUtils` 的"第二次放行"规则绕过直接退出。现在只有一个对话框：
  试玩转调同一个 `triggerWarning`，提示开着时窗口关不掉，也不会出现第二个。
- 提示叠在暂停菜单上而不是顶掉它。`FlxState.openSubState` 会**销毁**已有的 substate，
  之前从暂停菜单关窗口会把暂停菜单销毁，点取消就等于取消暂停。

**保存进包**

- "保存并退出"只写暂存目录，压缩包永远不更新。关窗口的保存路径补上了合并
  （`ModPackMergeState`，异步带进度），顺序是"先合并 → 再清理解密 → 最后退出"。
- 未加密 `.zip` 的合并**从来没成功过**：资源库开着文件句柄，Windows 不允许 rename
  被打开的文件（实测 `Permission denied`）。现在合并前让库松手
  （`SysZip.releaseHandleForReplace` / `ZipFolderLibrary.releaseForReplace`），换完再重读新包。
- 打包 mod 的谱面保存不再经资源树推算，直接写 `Paths.getAssetsRoot()`（唯一可写位置）。
- 保存失败原来只弹一句没有路径的原生框；现在写明路径，并记到 `.cne/logs/save-errors.log`。

**自检结果**

- 结果弹窗按类型分段：缺失红、已修改琥珀、未列出蓝；段头带数量，段内先给 4 个文件名，
  其余折成 `... and N more`，说明文字用灰。完整列表写日志（每类上限 40 条）。
- 实现是 `UIWarningSubstate` 新增的 `lines` 参数（每行自带颜色/字号/间距），面板按实测行高
  撑开；普通单段消息仍走原来的 `message`，其他对话框不受影响。

**性能**

- 调试 HUD 六个面板不再每帧重建字符串并重排文本（按 1–15 Hz 刷新），内存计数也不再每帧查
  一次系统调用；编辑器控件层去掉每帧的数组分配和重复的鼠标坐标变换；日志文件从"每行开→写→关"
  改成常开句柄 + 每行 flush。

---

## 八、11-05 的调试界面、自检界面与 API 兼容

**调试界面（ImGui 控制台 / 检查器）**

- 工具窗口掉到游戏窗口后面：多视口开着时，不完全落在游戏视口内的 ImGui 窗口会变成独立系统窗口，
  点回游戏就被压下去（调整手柄拖到边缘最明显）。`ImGuiUtil.pinCurrentWindowOnTop()` 给检查器、
  属性面板、2D/3D 手柄、控制台各窗口补 `ImGuiViewportFlags.TopMost`。两个前提决定了它必须每帧
  在 `begin()` 之后调用：ImGui 每帧会用窗口自身的标志重写 viewport flags；SDL 后端只在**创建**
  系统窗口时读这个标志（`SDL_WINDOW_ALWAYS_ON_TOP`），之后再改无效。
- 检查器掉帧：对象树原来每帧遍历所有状态的成员表（运行中的 `PlayState` 有几百个成员），改成
  10 Hz，并且只在 `ImGui.begin()` 里面重建——收起到标题栏时不做任何事；展开的组走同一预算。
- 控制台：`Settings` / `Copy Log` 的宽度不再每帧量字体；每帧的 `setScrollHereY` 去掉（它同时
  是"滚不上去"的原因），改成打开时滚到底一次。
- 检查器在状态切换时崩（`FlxObject.getScreenPosition` 空相机）：切歌/关游戏会把相机全拆掉，而
  选中的对象还留着。现在 `FlxG.state` 一变就清空选中并当帧重建，`camera == null` 直接不画。

**自检界面（`IntegrityScreen`）**

- 检查时整块面板轻微上下浮动（`PopupScreen.setContentOffset`，±5px、`sin(t * 1.5)`，和崩溃屏
  同一个参数），旁边的小窗显示已查到的问题总数，用另一组相位（`placeSide` / `setSideOffset`，
  差 2.1 rad），两个窗口不会像一块板一起滑。
- 副窗口位置踩了个坑：`UISliceSprite.resize()` 只写 `bWidth` / `bHeight`，`width` / `height` 还是
  九宫格贴图帧的尺寸，拿它算 x 会让窗口落在主面板里面。布局一律用 `bWidth` / `bHeight`。
- 进度条每帧更新，文字类标签（百分比 / `N / M` / 计数）10 Hz——每改一次文本都要重排字形，
  那是这个界面"卡"的主要来源。
- 结果弹窗按严重度分段：Missing（warning，琥珀）/ Added（info，蓝）/ Modified（error，红）；
  弹窗本身取最严重的那类，面板染色和图标跟着变，清单读不出来按 error。`unlisted` 在 summary、
  日志行、弹窗里统一改叫 `added`。

**与上游 1.1.0 的公开 API 差异（脚本会碰到的）**

| 变更 | 旧写法会怎样 | 现在 |
| --- | --- | --- |
| `UIWarningSubstate` 第 4 参 `isError:Bool` → `kind:UIWarningKind` | `(title, msg, buttons, true)` 类型不符 | 第 4 参收 `Dynamic`，`true/false` 映射回 `ERROR/WARNING`（和旧版的两种外观一一对应）；另补 `isError` 属性，读写都映射到 `kind` |
| `SaveWarning.warningFunc` 删掉 | 赋值报“字段不存在” | 字段保留但**不再调用**（它原来会在弹窗之外再插一手，正是双弹窗的来源）；保存钩子用 `saveFunc` |
| `PlaytestingWarningSubstate` 删掉 | `new` 找不到类 | 不恢复（内部弹窗，仓库内无引用）；恢复命令在 `AGENTS.md` 的“已删除的上游文件”表 |
| `Flags.SHADERS_CACHE_RESET_ON_SWITCH_STATE` 删掉 | mod 的 `config` 里写它会被当成未知 flag，静默失效 | 恢复该 flag 与 `GlobalScript` 里 `Main.refreshShaders()` 的调用 |
| `UIWarningSubstate` 第 5 参及以后 | — | 第 5 参仍是 `wantsInput`，第 6 参新增 `lines`；旧调用不受影响 |

其余公开签名变化都是“追加可选参数”（`ZipFolderLibrary.new`、`ModsFolder.loadLibraryFromZip`），
`WarningButton` / `triggerWarning` / `Logs` 的签名没动。

---

## 九、11-06 的安全修复（评估报告 V5 / V6）

报告来自一次针对 `2hotBFmix_password.zip` 的逆向评估（在仓库外）。V1/V2（加密包里混明文条目）
的处理见上一节，这里只记 V5、V6。

**V5：内置口令只能读，不能封**

- `ScriptCrypto.isBuiltInKey()` / `warnBuiltInKey()`：读到用内置密钥封的包时，日志点名警告一次
  （每个包一次运行只提醒一次）。
- 封包路径拒绝它：`EncryptionEditor.sealProblem()` 拦住导出（单包、批量、带 key 的脚本保护），
  `CnezV2.pack` / `ZipAes.encryptZip` 各自也会抛错；唯一例外是 `ZipEditCache` 合并时按原密钥
  重封（`allowBuiltInKey`），否则用旧密钥封的包一旦有改动就再也合并不回去。
- 加密工具的 Key 字段不再预填内置密钥（`defaultKeyField()`：没有真 key 就留空）。

**V6：KDF 换成 PBKDF2-HMAC-SHA256**

- 新增 `Pbkdf2.deriveSHA256`（ipad/opad 只算一次，比每轮重算 HMAC 少三分之一开销），
  用 RFC 7914 的 `password`/`salt` 向量核对过 c=1/2/4096 与 dkLen=32/40。
- CNEZ 容器版本升到 **3**（读 2 和 3）：版本 2 仍走旧的 2048 轮 SHA-256，版本 3 走 PBKDF2 20 万轮。
  头部布局一个字节没动，版本字节本身在根 tag 覆盖范围内，所以旧包不会被误判成新包。
- 脚本容器（CNX2）同样升到版本 3，v2 容器仍可读。
- 代价：解锁多约 1.3 s（hxcpp 实测 6.3 µs/轮）；攻击者每次尝试的代价抬约 100 倍。

**仍开着的**：V3（发布目录里源包与密封包并放）、V4（解密视频落盘、只在正常退出时清）、
V7（key token 只是混淆，不是分发密钥的安全手段）。

---

## 十、11-06 的新界面背景与浮动

**背景图**

- `assets/images/editors/bgs/` 新增两张：`cmd.png`（终端窗口）、`lock.png`（挂锁）。
  都是 408×389、黑底、描边 38 灰，和 `charter.png` / `default.png` 同一套参数。
  排布**直接用的是 `default.png` 自己的 16 个槽位**（位置、抖动、四个朝向各四个、外加
  同一层小圆环），所以布局节奏和它完全一致，不是另外设计一套。
- `PopupScreen` 新增 `bgType`：设了就在遮罩之上铺一层 `FlxBackdrop`，倾斜 −5°、85 px/s
  平移，和 `EditorTreeMenu` 的编辑器背景同一套参数。分层顺序是"遮罩 → 背景 → 面板"：
  背景本身已经是 15% 灰，压在 70% 遮罩下面会被压到 4%，等于看不见。
- 分配：自检屏 `cmd`；密码框、解密屏 `lock`；清理屏 `default`。合并屏、进歌加载屏没动。

**上下浮动**

- 浮动从 `IntegrityScreen` 搬进 `PopupScreen`（`bobAmplitude` / `bobTime`，速度仍是 1.5 rad/s），
  子类只设幅度：自检屏 5px（旁边的计数窗仍用同一时钟错开 2.1 rad）、密码框 1px、解密屏 2px。
  密码框只有 1px 是因为那个输入框是焦点：幅度再大，光标会在玩家看自己打的字时上下飘。

---

## 十一、没做的

| 项 | 状态 |
| --- | --- |
| `UIWarningSubstate.wantsInput` | 接口在，目前没有调用方 |
| 加密包内部条目被增删 | 检测不到。清单按文件校验，`mods/x.zip` 整体算一个文件 |
| `assets/` 之外的文件 | 不校验。`saves/`、`options/` 是玩家数据，`mods/` 是玩家内容 |
| "保存并退出到菜单"当场合并 | 不做。运行中的 mod 正被资源库读着（文件句柄或内存里的解密副本），当场重写会让之后读到的资源和包对不上；合并只在关闭游戏或切换 mod 时做，暂存目录在那之前就是可读的 |
