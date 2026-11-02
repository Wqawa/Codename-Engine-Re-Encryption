# 完整性校验

每次启动检查一件事：**磁盘上的文件还是不是构建出来的那一份。**

---

## 1. 先说清楚它防得住什么、防不住什么

**防得住**：有人改了资源或运行库，但没动 exe。启动时会列出被改动的文件。

**防不住**：把 exe 一起换掉的人。清单的签名密钥编译在 exe 里，能重编 exe 的人也能去掉这个检查、或重新签一份清单。
本地完整性校验的天花板就到这儿——任何"绝对防篡改"的说法在本地环境里都不成立。

还有一条要记住：`integrity.dat` 不存在时校验直接跳过（开发构建常见）。**删掉清单等于关掉检查**，这是对称密钥方案的固有问题，文档不粉饰。

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
密钥 `cnez::integrity::manifest::v1` 编译在 `IntegrityCheck` 里。

**覆盖范围**

- `CodenameEngine.exe`
- 同目录的 `*.ndll` / `*.dll`
- `assets/` 下所有文件（递归）

**不覆盖**

- `mods/`：玩家的内容；加密包自带分块 tag（见 [RE-ENCRYPTION.md](RE-ENCRYPTION.md)）
- `saves/`、`logs/`、`.cne/`：运行时产物，每次启动都会变

---

## 3. 怎么生成

编辑器 `F7` → Encryption Tool → **Tools → Generate integrity manifest**。

要哈希整个 `assets/`，所以跑在工作线程上，完成后状态栏报「N file(s), signed」。

> **每次构建后都要重新生成。** 清单记录的是上一次构建的 exe，构建产物变了清单就该变，
> 否则下次启动会把新 exe 报成「被修改」。这不是 bug，是设计。

---

## 4. 启动时怎么校验

1. `Main.loadGameSettings` 末尾调 `IntegrityCheck.startVerify()`——工作线程，不挡窗口
2. 读清单 → 验签 → 逐个文件算 SHA256 比对
3. 主菜单 `update` 里轮询结果，有差异弹**一次**提示，按钮是「Continue」
4. 没有清单 → 静默跳过，写一条 info 日志

校验结果同时写日志：

- 全部通过：`Integrity check: all N file(s) match`
- 有差异：`Integrity check: X modified, Y missing - see the list in the dialog`

---

## 5. 差异分类

| 分类 | 含义 | 处理 |
| --- | --- | --- |
| `missing` | 清单里有、磁盘上没有 | 弹提示 |
| `changed` | 大小或 SHA256 对不上 | 弹提示 |
| 清单签名不符 | 清单本身被改过 | 弹提示，且**整个清单作废**（不逐个比对，因为基准已不可信） |
| `extra` | `assets/` 下多出清单没有的文件 | 只记日志，不弹窗 |

`extra` 不弹窗是有意的：玩家往 `assets/` 扔东西是常见操作（换皮肤、加字体），
挡这个只会让人关掉校验。

---

## 6. 已知限制

- **全量哈希**：`assets/` 大的工程要十几秒。后台跑不挡启动，但仍占 IO；在机械硬盘上能感觉到
- **删清单即绕过**：见第 1 节
- **不覆盖 mod 包**：玩家随时增删，做成固定清单会天天误报；加密包的完整性由分块 tag 自己保证
- **单文件读取**：目前整个文件读进内存再哈希，`assets/` 里若有超大单文件，峰值内存会跟着涨

---

*本文件由本 fork 维护。改了清单格式、签名密钥或覆盖范围，三处要一起改：`IntegrityCheck`、本文件、[AGENTS.md](../AGENTS.md) 的文档地图。*
