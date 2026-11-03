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

`UIWarningSubstate` 的两个 bool（isError / 有没有输入框）换成：

```haxe
new UIWarningSubstate(title, message, buttons, ?kind = ERROR, ?wantsInput = false)
```

`kind` 是 `ERROR` / `WARNING` / `INFO`，枚举值就是图标文件名（`error.png`、`warning.png`、
`info.png`），类型和贴图不会对不上。`wantsInput` 加一行 `UITextBox`，用 `inputValue()` 读，
对话框本身不解释内容。`keepOpen` 让按钮在验证失败时把窗口留住。

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

## 七、没做的

| 项 | 状态 |
| --- | --- |
| `UIWarningSubstate.wantsInput` | 接口在，目前没有调用方 |
| 加密包内部条目被增删 | 检测不到。清单按文件校验，`mods/x.zip` 整体算一个文件 |
| `assets/` 之外的文件 | 不校验。`saves/`、`options/` 是玩家数据，`mods/` 是玩家内容 |
