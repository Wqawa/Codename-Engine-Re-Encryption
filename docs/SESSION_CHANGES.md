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
- CNEZ 容器版本升到 **3**（当时读 2 和 3；11-07 起 v1 也回来了，见第十四节）：版本 2 仍走旧的 2048 轮 SHA-256，版本 3 走 PBKDF2 20 万轮。
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
- 排布**照 `charter.png`**：严格的 4×4 网格（格 102×97.25，字形 94px，几乎顶满格子），
  每格朝向是 `base[(r + c) % 4]`（`base = [0°, 90°, 270°, 180°]`），也就是同一个方向沿反对角线
  连成一条——和 `charter.png` 量出来的规律逐格一致（生成后又用同一套检测反查过）。
  没有 `default.png` 那层小圆环，也没有随机抖动。
- `PopupScreen` 新增 `bgType`：设了就在遮罩之上铺一层 `FlxBackdrop`，倾斜 −5°、85 px/s
  平移，和 `EditorTreeMenu` 的编辑器背景同一套参数。分层顺序是"遮罩 → 背景 → 面板"：
  背景本身已经是 15% 灰，压在 70% 遮罩下面会被压到 4%，等于看不见。
- 分配：自检屏 `cmd`；密码框、解密屏 `lock`；清理屏 `default`。合并屏、进歌加载屏没动。

**上下浮动**

- 浮动从 `IntegrityScreen` 搬进 `PopupScreen`（`bobAmplitude` / `bobTime`，速度仍是 1.5 rad/s），
  子类只设幅度：自检屏 5px（旁边的计数窗仍用同一时钟错开 2.1 rad）、密码框 1px、解密屏 2px。
  密码框只有 1px 是因为那个输入框是焦点：幅度再大，光标会在玩家看自己打的字时上下飘。

---

## 十一、11-06 合上游（afe74668 → 450ab5b5）

上游 35 个提交、47 个文件。本仓库和上游没有共同祖先（基线是文件快照），所以先给上次的 vendor
提交 `99c24d9d` 临时 graft 到 `afe74668`，做了一次正常的三方合并；graft 用完已删
（`git replace -l` 为空）。

**结果没有以合并提交的形式保留**：把上游接进历史意味着 push 要把它 3500+ 个提交的对象全部上传
（本仓库是 `blob:none` 部分克隆，这些 blob 本地都没有），代价远大于收益。所以最终落地的是一个
普通提交，内容等于三方合并的结果，历史仍是单线。下次合上游的做法写在 `AGENTS.md` 开头。

**带进来的（按块）**

| 块 | 内容 |
| --- | --- |
| 构建 / 文档 | FlxAnimate → flixel-animate（仓库搬家，README 与编译说明）、`format` 库从 `project.xml` 移除、`dd17dcda` lime_disable_assets_version、release workflow 修复 |
| 帧率 | FramePacer 配置项（`Options.framePacerMode`）、"More optimization with gc"、顺手回退了之前那个分数标签优化 |
| 角色 / 舞台 | 角色编辑器拖拽与手柄修复、`DEBUG_HITBOX` 换色、`characterPosGuide.frag`、`applyStageMatrix` 默认改由 `USE_LEGACY_FLXANIMATE_STAGE_MATRIX` 决定（`MOD_API_VERSION < 3` 才是 true） |
| freeplay | 歌曲列表 addon 支持及后续修补、上下键 turbo 控制、预览音乐修复、列表滚动加速 |
| 播放 | `StrumLine` 与 `PlayState` 解耦、`ignoreInactive` 与 `ignoreInvisible` 接到 `getStrumlineCamPos` / `getCharactersCamPos`、`Flags.FORCE_CAM_ZOOM_EVERY_MEASURE`。**注意：上游 `064d91b` 把两个 ignore 条件写反，本轮已修回** |
| 其它 | `ScriptableShader` / `ShaderResizeFix` 弃用修复、`SaveSubstate` 取消时崩溃、`ModSwitchMenu` addon 迭代、`WindowUtils` 旧兼容 API 恢复、`DEFAULT_GITAROO` 默认 false |

**冲突（3 处，都以官方为准，只保留本 fork 必须的注入）**

| 文件 | 官方改了什么 | 处理 |
| --- | --- | --- |
| `README.md` | 换掉 FlxAnimate 的仓库链接 | 采用官方的四条 credits，保留本 fork 自己的 "Re-Encryption additions" 段落 |
| `source/funkin/backend/system/MainState.hx` | 把隐藏 `./.temp` 包进 try/catch 并 warn | **保留本 fork 的 `RuntimeDirs.ensure(.cne/temp)`**：那个目录在本 fork 叫 `.cne/temp`，`ensure()` 已经建目录、隐藏目录、并且吞掉异常，官方的写法在这里没有对象 |
| `source/funkin/backend/utils/WindowUtils.hx` | 恢复 `endfix` / `winTitle` 兼容属性，`updateTitle` 改回 `inline` | 兼容属性照收；`updateTitle` 保留本 fork 的空窗口守卫（启动早期 `Lib.application.window` 还不存在），因此不是 `inline` |

**行为变化，值得留意的两条**

- `applyStageMatrix` 不再默认 true：`MOD_API_VERSION < 3` 的 mod 维持旧行为，声明 3 及以上的 mod
  不再套舞台矩阵。老 mod 不受影响，新 mod 的站位可能与之前不同。
- `WindowUtils` 的老兼容 API 回来了（`endfix`、`winTitle`），脚本里写过的旧名字重新可用。

---

## 十二、11-06 语言包

本 fork 的界面原来全是硬编码英文。现在所有文案都走 `TU.translate(id, params, 默认英文)`，
语言包里没有对应键时**原样显示英文**，所以英文玩家看到的东西和之前一模一样。

- 键按引擎自己的分类放，不另起文件：玩家能看到的屏（密码框、解密、清理、合并）和自检的键进
  `assets/languages/<lang>/Main.xml`，加密工具的键进同语言的 `Editors.xml`，各新增一组
  `Mod Pack Screens` / `File Check` / `Encryption Tool`。共 141 个键。
- 五种语言（`en` / `es` / `it` / `pl` / `pt`）都补齐了，各 140 个——唯一没翻的是
  `encTool.help.body`（整页帮助正文，三千多字符的技术说明），其余语言回退英文；
  要翻的时候把那段补上即可。
- 有一处不能直接在原地翻译：`ZipEditCache` 的合并提示是在**工作线程**里拼的，而翻译查表用的
  静态缓存不是线程安全的。所以线程只记 `mergeKey` / `mergeParams`，由合并屏在界面线程翻译。
- `EncryptionEditor.HELP_BODY` 改成 `get` 属性，切换语言后重新打开帮助页就是新语言。

---

## 十三、没做的

| 项 | 状态 |
| --- | --- |
| `UIWarningSubstate.wantsInput` | 接口在，目前没有调用方 |
| 加密包内部条目被增删 | 检测不到。清单按文件校验，`mods/x.zip` 整体算一个文件 |
| `assets/` 之外的文件 | 不校验。`saves/`、`options/` 是玩家数据，`mods/` 是玩家内容 |
| "保存并退出到菜单"当场合并 | 不做。运行中的 mod 正被资源库读着（文件句柄或内存里的解密副本），当场重写会让之后读到的资源和包对不上；合并只在关闭游戏或切换 mod 时做，暂存目录在那之前就是可读的 |

---

## 十四、11-06 压缩包 mod "能读贴图、没有歌"的两个原因

现象：`mods/<name>.zip` 进游戏后角色、图标、图片都正常，歌单是空的，日志里一行错都没有；
同一份内容解压成文件夹就全对。两条独立的原因，撞在同一个症状上。

**1. 歌单扫描把 zip 库强转成文件夹库（CNE 本体，上游 450ab5b5 引入）**

- `source/funkin/menus/FreeplayState.hx` 的 `FreeplaySonglist.getSongsFromSource` 逐库扫描时写的是
  `final modLib:ModsFolderLibrary = cast mods[i++];`，而 zip 包挂的是 `ZipFolderLibrary`
  （`extends AssetLibrary implements IModsAssetLibrary`，和 `ModsFolderLibrary` 没有继承关系）。
- `ModsFolderLibrary.getFolders` 走磁盘 `FileSystem.readDirectory(getAssetPath())`，对 zip 库来说
  那个路径不存在，异常被吞掉后 `return []`，于是 `songsFound` 为空、没有歌、没有报错。
  这正是"贴图都在、就是没歌"：图片走 `Assets` 的库派发，歌单走的是这条被强转的磁盘枚举。
- 上游基线是对的：`git show baseline/upstream-1.1.0:source/funkin/menus/FreeplayState.hx` 用
  `Paths.getFolderDirectories(...)` → `assetsTree.getFolders` → 接口派发。逐库扫描出现在
  `ebc621ce`（合上游 450ab5b5）里，它的父提交 `c7bda431` 中 `getLoadedModsLibs` 出现 0 次。
- 修法是**最小规避**，没有重写这段：类型改成接口 `IModsAssetLibrary`，`exists` 不在接口里，
  用一个 `libExists()` 走 `cast(lib, openfl.utils.AssetLibrary).exists(path, "TEXT")`。
  `Paths.txt()` 已经返回 `assets/...` 路径，早期版本又拼了一次 `assets/`，会把
  `data/config/freeplaySonglist/LIB_<mod>.txt` 变成永远不存在的双前缀路径；本轮已改正。
- 同时把原来的 `while (mods[0]...)` 轮转换成先查下标再 `splice`：目标 mod 不在列表里时，
  旧写法会原地旋转到死；空列表也先返回，不再访问 `mods[0]`。

**2. CNEZ 版本 1 的包读不了（本 fork 自己的回归）**

- 现场那个 `2hotBfmix_encrypted.zip` 头部是 `CNEZ 01`：0..3 magic、4 版本、8..23 salt、24..35 nonce、
  36..39 payload 长度、40.. 单条 ChaCha20 密文、尾 32 字节 HMAC-SHA256（覆盖头和密文）。
  实测 `40 + 132670632 + 32 = 132670704` 正好等于文件大小。
- 版本 1 是 1.0.1 分支的写法（`e9ac49b8` 的 `ModPackCrypto.VERSION = 1`）。11-02 `9d9d21d9` 换成
  分块布局的版本 2，11-06 `80d406af` 提版本 3 时把 `VERSION_MIN` 设成 2：**旧包从此被判成普通 zip**，
  没有 EOCD → 0 条目 → 库是空的但"加载成功"，日志一行不报。用户以为那是 v2 包，其实是 v1。
- 修法：新增 `source/funkin/backend/assets/CnezV1.hx`（只读，不写信）：`isV1` / `isV1File` /
  `verifyKeyFile`（解前 4 字节看 `PK`，和旧代码同一套廉价探针）/ `unpack`（长度校验 + 常时 HMAC 比较）。
  `ModPackCrypto` 侧的接线：`isEncryptedPack` 认 v1，`isEncryptedPackFile` 改成版本区间 1..3，
  `containerVersion()` 把"是 CNEZ 但版本不认识"报给加载器，`zipFor` 里 v1 走整包解密后
  `SysZip.fromBytes`（单条密文流没有块表，没法按需 seek），`keyWorksUncached` 用 v1 的探针。
- 版本 1 的 KDF 与现在 `ScriptCrypto.deriveKeys(pass, salt, kdf = 1)` 的分支逐字相同（sha256(pass + "|" +
  salt 十六进制) 再 2048 轮 sha256(h + salt)），所以不需要第二个 KDF 实现。
- 附带：`ModsFolder.loadModLib` 现在对"CNEZ 魔数但版本不认识"的包 `Logs.error` 并跳过，
  不再静默当成空 zip（版本 4 或更旧的包也是这个待遇，而不是"加载成功但没内容"）。

**验证**：完整编译 `haxelib run lime build windows -nocolor -DHXCPP_COMPILE_CACHE=C:\Users\36369\AppData\Local\cne-hxcpp-cache`
于 2026-11-07 00:38:35 通过，`export/release/windows/bin/CodenameEngine.exe` 70,212,608 字节，
日志无 `error:`；没有启动 exe。发布目录的 `integrity.dat` 用离线脚本重算 exe 条目并重签，
共 937 条。

真包端到端（密码由包作者提供）：对现场那个 `2hotBfmix_encrypted.zip` 做了三路互相独立的验证——

1. Python 按 v1 规格独立实现 KDF（sha256(pass + "|" + salt.toHex()) 再 2048 轮 sha256(h + salt)）
   算 HMAC-SHA256，与包里尾部 32 字节一致 → 密码、头布局、长度公式全对；
2. openssl 独立解密：IV 用 `01000000`（counter = 1 的 IETF ChaCha20）+ nonce，`enc -chacha20 -d`
   得到 132,670,632 字节，sha256 `bc531b2bbd560d836092b9cfd9b40d25ce0d32c6cb9d8e7b46b66b120052ee12`；
3. 本仓库的 `CnezV1.unpack`（编译成 neko 跑真包，不是 python 复刻）解出同样字节数、同样 sha256
   → 与 openssl 逐字节相同。

解出来的 zip 有 186 个条目；和 `2hotBFmix (1).zip` 比，156 个文件内容完全相同，差异是加密包里
脚本被编译成了 `data/events/*_protected.hxb`、`data/notes/*_protected.hxb`（明文包是对应的 .hx），
外加更新过的 `data/config/modpack.ini` 与 `songs/2hot-(bf-mix)/charts/hard.json` → 它是这份 mod
的较新构建，不是同一份字节的副本，所以整文件 sha256 不同属正常。

注意：纯 Haxe 的 ChaCha20 在 neko 上大约 0.06 MB/s，132 MB 跑了两千多秒。这条路只在需要
"用引擎自己的代码验证真实包"时走，平时用 Python/openssl 对拍就够。

---

## 十五、11-06 RC4 之后的复查

**先纠正一个前提：本次实际合的不是 RC4。** 上游 `v1.1.0-rc4` 是 `2dd7d811`，而 `ebc621ce`
合的是 `450ab5b5`；两者相差 17 个提交，歌单强转（`d7c70cf6`）和其他几处回归都在 RC4 之后。
以后说“只合了 RC4”时，要先看 `git show -s` 的目标 SHA，不能拿 tag 名当基线。

在这批上游改动和本 fork 的接缝上，本轮又确认并修掉了这些问题：

| 位置 | 问题 | 修法 |
| --- | --- | --- |
| `game/PlayState.hx` | 上游 `064d91b` 把 `ignoreInvisible` / `ignoreInactive` 的条件写反：默认 true 时反而把隐藏、失活角色算进相机平均值 | 恢复 `ignoreInvisible && (...)` / `ignoreInactive && ...`，并留一句上游提交号 |
| `game/StrumLine.hx` | `__dispatchOnMiss` 的 `directionID` 默认 0，`if (directionID == null)` 永远不成立，非 0 方向的 miss 全报成 0 | 默认值改成 `Null<Int> = null`，事件方向兜底 0 |
| `editors/character/CharacterEditor.hx` | 上游把保存路径改成 `assetsTree.getPath(...)`；zip 包的路径是虚拟路径，写不进去，且 `Paths.getAssetsRoot()` 本来就会落到暂存目录 | 用 `Chart.isWritablePath()` 判断，不可写就回退 `Paths.getAssetsRoot()`，与 `Chart.save()` 同一套规则 |
| `editors/character/CharacterEditor.hx` | 三个姿态引导角色在 `changeStage(null)` 后只是被 `remove`，关闭编辑器时仍持有纹理和共享 shader | `destroy()` 里逐个 `remove` + `destroy`；shader 本身由 GC 回收 |
| `menus/FreeplayState.hx` | 目标 mod 不在列表时 `while (mods[0]...)` 无限旋转；空列表 NPE；`i++` 后再 `i++` 会跳过一项 | 先查下标再 `splice`；空列表直接返回；删掉二次自增 |
| `backend/assets/ModPackCrypto.hx` | `containerVersion` 用 0 兼作“不是 CNEZ”，版本 0 的 CNEZ 会漏报 | 哨兵改成 -1，`ModsFolder` 用 `>= 0` 判断 |
| `backend/shaders/ScriptableShader.hx` | 没有 `scriptName` 且 shader 没有源文件路径时，新代码会拿空字符串去 `Paths.script`，悄悄退化成 DummyScript（1.1.0 原本是抛异常） | 恢复明确的 “Missing name” 异常 |

**没有改的**：`UIButtonList` 把滚轮步长乘以按钮数（上游有意“加速滚动”），这不是本轮回归，
但列表很长时手感会变得很跳，是否恢复固定步长需要实机确认；`getCharactersCamPos` 新增的
`?ignoreInactive` 插在 `?out` 前面，旧的 4 参数脚本调用会受影响，属于上游 API 变更，
当前仓库内没有调用点，暂不额外加兼容层。

## 十六、11-07 复审：撤掉兼容层，修回被合并改坏的逻辑

起因是上一轮的交付里混进了几处"为了兼容而兼容"的写法。先把偏离量出来，再逐条判性质。

**偏离量（以 `450ab5b5` 的树为基准，比 blob SHA）**：`source/` 下 417 个文件里
**311 个与上游逐字相同**，63 个被本 fork 改过，43 个新增，1 个刻意删除
（`PlaytestingWarningSubstate.hx`）。这是一棵"上游主干 + 定点接缝"的树，不是 1.1.0 与 RC4
拼起来的混合体。复量的命令写在 `docs/ARCHITECTURE.md` §2 末尾。

顺带把"基地是哪一版"也量了：仓库最早的快照 `112aa91`（tag `baseline/upstream-1.1.0`）
在 `source/` 下与 **`afe74668`（10-28）相同 361/375 = 96%**，与 `v1.1.0-rc3`（09-13）只有 79%，
与 `v1.1.0-rc4`（11-01）是 93%。所以基座不是 rc3，是 rc3 之后一个多月的主干；这次合的是
RC4 之后 3 天的 `450ab5b5`。两头都不是 tag，差的都是主干提交。

**撤掉的三处兼容层**（仓库里没有任何使用方，留着只是把旧约定续命）：

| 位置 | 撤掉的写法 | 为什么撤 |
| --- | --- | --- |
| `backend/utils/ControlsUtil.hx`、`options/keybinds/KeybindsOptions.hx` | 在 per-addon 的 `LIB_*.xml` 之外，额外读全局 `data/config/controls.xml` | 引擎自己不写这个文件，`assets/` 里没有，现场两个 mod 包（`2hot/`、`2hotBFmix (1).zip`）里也没有 |
| `options/Options.hx` | `CharacterDragMode` 上的 `@:from Bool` / `@:to Bool` / `from Int to Int` | 上游只声明 `enum abstract(Int)`；仓库里没有任何把 Bool 赋给它的脚本。要赋值应该改脚本，不是给枚举加转换 |

撤完后 `ControlsUtil.hx`、`KeybindsOptions.hx` 与上游逐字一致。

**修回被合并改坏的三处**（`menus/FreeplayState.hx`）：这三处不是上游的现状，是 `ebc621ce`
解冲突时写歪的，与 zip/加密无关，普通 mod 也会中：

1. `source == SOURCE` 分支被改成"只剔除当前 mod"，等于把其它 mod 的歌也算进基础资源；
   恢复成上游的"剔除所有非 `assets` 库"。
2. `scanForSongs` 递归时少一个结尾斜杠（上游是 `'$startDir$i/'`）；两个库都会补斜杠，
   所以行为没变，但这是一处没理由的偏离。
3. `get()` 的 `default` 分支少了 `currentModFolder == null` 时先 SOURCE 再 MODS 的那条路。

**顺带收敛的写法**：删掉 `libExists()`（把接口 `cast` 成 `AssetLibrary` 再调 `exists`），
改成在 `IModsAssetLibrary` 里声明 `exists(asset, type)`——四个实现类本来就有这个方法，
接口只是把既有事实写下来，调用方不必再降级到具体的库类。`CharacterEditor` 的"父目录可写"
也不再自己写一遍，改用 `Chart.isWritablePath()`（改为 public）。

**保留的**：`ScriptableShader` 的 “Missing name” 异常（1.1.0 本来就抛，450 退化成静默
DummyScript）；`Flags.SHADERS_CACHE_RESET_ON_SWITCH_STATE`（默认 false 的调试开关，
上游已移除，本 fork 仍在用它调试自定义 shader）。

**没有做的**：没有逐个重读那 64 个偏离文件。这轮是"用 blob 找出偏离集合 + 抽查高风险接缝"
（Freeplay、PlayState、StrumLine、CharacterEditor、Controls、Options、ScriptableShader、
Paths、ModsFolder、MainState、Chart、HScript、Stage、GlobalScript）。剩余偏离按 i18n、
`RuntimeDirs`、加密接缝三类归口，没有发现合并残留的迹象。

**编译**：这次跑的就是 `Build.bat` 内部那条命令（`haxelib run lime build windows -nocolor`，
缓存 `%LOCALAPPDATA%\cne-hxcpp-cache`），退出码 0、日志无 `error:`；以后统一走
`building\Build.bat -Yes`。产物 `export/release/windows/bin/CodenameEngine.exe` 70,206,464 字节；
`integrity.dat` 已按新 exe 重算 exe 条目并重签，937 条。没有启动游戏。
