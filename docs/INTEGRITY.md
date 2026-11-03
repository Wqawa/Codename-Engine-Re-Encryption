# 完整性校验

每次启动检查一件事：磁盘上的文件还是不是构建出来的那一份。

---

## 1. 能防什么，不能防什么

**能防**：有人换了资源或运行库，但没动 exe。启动时会列出被改动的文件。

**不能防**：把 exe 一起换掉的人。签名密钥编译在 exe 里，能重编 exe 的人也能删掉这个检查、或者重新签一份清单。本地校验的天花板就在这里，说"绝对防篡改"是不成立的。

还有一条要记住：**`integrity.dat` 不存在时校验直接跳过**。删掉清单等于关掉检查，这是对称密钥方案的固有问题，文档不粉饰。

---

## 2. 清单长什么样

`integrity.dat`，纯文本，放在 exe 旁边：

```
CNEZ-INTEGRITY 1
<大小>\t<sha256>\t<相对路径>
<大小>\t<sha256>\t<相对路径>
...
# hmac <签名>
```

签名是 HMAC-SHA256，覆盖「第一行到最后一个条目行」的全部文本（不含签名行），
密钥 `cnez::integrity::manifest::v1` 编译在 `IntegrityCheck` 里。读清单时先把 CRLF 归一成 LF，
否则 Windows 上换行符一变，签名就对不上。

**覆盖范围**

- `CodenameEngine.exe`
- 同目录的 `*.ndll` / `*.dll`
- `assets/` 下所有文件（递归）

**不覆盖**

- `mods/`：玩家的内容；加密包自带分块 tag（见 [RE-ENCRYPTION.md](RE-ENCRYPTION.md)）
- `saves/`、`.cne/`：运行时产物，每次启动都会变

---

## 3. 怎么生成

两种方式，都调 `IntegrityCheck.generate()`：

- **构建**：`CodenameEngine.exe --generate-integrity`，写完清单直接退出。`Build.bat` 和两个 Unix 脚本在编译成功后会跑这一步。
- **编辑器**：`F7` → Encryption Tool → Tools → *Generate integrity manifest*。跑在工作线程上，完成后状态栏报「N file(s), signed」。

> **每次构建后都要重新生成。** 清单记录的是上一次构建的产物，文件变了清单就该变，
> 否则下次启动会把新 exe 报成「被修改」。这不是 bug，是设计。

---

## 4. 启动时怎么跑

1. `Main.loadGameSettings` 末尾调 `startVerify()`——工作线程，不挡窗口
2. 读清单、验签，然后逐个文件算 SHA256
3. 结果由**一个**界面显示：
   - 本次有加密包要解锁 → `IntegrityScreen` 在密码框之前显示进度条和结果
   - 没有加密包 → 主菜单第一次 `update` 时弹结果（`IntegrityScreen.reportOnMenu`）
4. `reported` 标记保证一次运行只弹一次；没有清单就静默跳过，写一条 info 日志

校验结果同时写日志：

- 全部通过：`Integrity check: all N file(s) match`
- 有差异：`Integrity check: X missing, Y modified, Z unlisted - see the list in the dialog.`

---

## 5. 差异分类

| 分类 | 含义 | 处理 |
| --- | --- | --- |
| `missing` | 清单里有、磁盘上没有 | 弹提示 |
| `changed` | 大小或 SHA256 对不上 | 弹提示 |
| `extra` | `assets/` 下多出清单没有的文件 | 弹提示 |
| 清单签名不符 | 清单本身被改过 | 弹提示，且**整份清单作废**（基准已经不可信） |
| exe 对不上 | 重新构建过，没重生成清单 | 只跳过 exe 这一条，其余照查 |

`extra` 也算差异：`assets/` 里冒出一个清单没有的文件，正是塞脚本的形状。早先版本只记日志，
等于这类改动永远不会被看见。

exe 单独处理是因为它每次重建都会变。整个清单作废过一次的代价太大——一次重建就能让检查失效到
有人记得重新生成清单为止，期间改个资源名都发现不了。

---

## 6. 已知限制

- **全量哈希**：`assets/` 大的工程要十几秒。后台跑不挡启动，但在机械硬盘上能感觉到
- **删清单即绕过**：见第 1 节
- **不覆盖 mod 包**：玩家随时增删，做成固定清单会天天误报；加密包的完整性由分块 tag 自己保证
- **单文件读取**：整个文件读进内存再哈希，`assets/` 里有超大单文件时峰值内存会跟着涨

---

*改了清单格式、签名密钥或覆盖范围，三处要一起改：`IntegrityCheck`、本文件、[AGENTS.md](../AGENTS.md) 的文档地图。*
